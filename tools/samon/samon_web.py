"""samon_web.py — samon 웹 서버 (samon에 인자를 주어 실행했을 때).

127.0.0.1에만 연결을 받는다. 외부 접속을 여는 옵션은 두지 않는다.
웹 페이지(web/index.html)는 CSS와 JavaScript를 모두 담은 파일 하나이며 외부 주소를
참조하지 않으므로, 인터넷이 없는 VM에서도 그대로 동작한다.

API (모두 JSON)
  GET  /api/status    항목 값, kdamond 상태, 재시작 필요 항목, 항목 정의, 프리셋 목록
  GET  /api/stats     카운터, 초당 변화량, 최근 60표본 이력
  GET  /api/sys       CPU·메모리·page cache 지표, 최근 60표본 이력, 기준 구간
  POST /api/toggle    {"name": "p3", "value": true}
  POST /api/param     {"name": "hot_threshold", "value": 20}
  POST /api/preset    {"name": "observe"}
  POST /api/monitor   {"action": "on" | "off" | "restart"}
  POST /api/restore   {}
  POST /api/baseline  {"action": "set" | "clear"}  최근 30초 평균을 기준으로 저장 / 지우기

같은 장비의 다른 웹사이트가 브라우저를 통해 이 API를 부르지 못하도록 Host와 Origin을
확인하고, POST는 Content-Type application/json만 받는다.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from samonctl import ITEMS, PATTERN_TOGGLES, Ctl, SamonError, Sampler, SysSampler, need_root

BIND = "127.0.0.1"
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "index.html")
MAX_BODY = 4096


def item_defs() -> list[dict]:
    return [{"name": it.name, "kind": it.kind, "label": it.label, "lo": it.lo, "hi": it.hi,
             "apply": it.apply, "main": it.main, "device": it.where == "device"} for it in ITEMS]


class App:
    """요청 처리기들이 함께 쓰는 상태: 제어 코어와 1초마다 도는 표본기."""

    def __init__(self, ctl: Ctl, interval: float = 1.0):
        self.ctl = ctl
        self.sampler = Sampler(ctl)
        self.sys = SysSampler(ctl)
        self.interval = interval
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.sampler.sample()
        self.sys.sample()
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _loop(self) -> None:
        while not self.stop.wait(self.interval):
            with self.lock:
                self.sampler.sample()
                self.sys.sample()

    def stats(self) -> dict:
        with self.lock:
            return self.sampler.as_dict()

    def sys_stats(self) -> dict:
        with self.lock:
            return self.sys.as_dict()

    def baseline(self, action: str) -> None:
        if action not in ("set", "clear"):
            raise SamonError(f"알 수 없는 동작: {action!r}")
        with self.lock:
            if action == "clear":
                self.sys.clear_baseline()
            else:
                self.sys.set_baseline(self.config_label())

    def config_label(self) -> str:
        """기준을 저장할 때의 SAMON 설정을 한 줄로 남긴다."""
        if not self.ctl.get("monitor"):
            return "감시 off"
        on = [p for p in PATTERN_TOGGLES if self.ctl.get(p)]
        return "감시 on, 토글 " + (", ".join(on) if on else "모두 off (관측 전용)")

    def status(self) -> dict:
        st = self.ctl.status()
        st["items"] = item_defs()
        st["presets"] = self.ctl.preset_names()
        return st


def make_handler(app: App, port: int):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    allowed_origins = {f"http://{h}" for h in allowed_hosts}

    class Handler(BaseHTTPRequestHandler):
        server_version = "samon"

        def log_message(self, fmt: str, *args) -> None:  # 요청마다 찍지 않는다
            pass

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, obj: object) -> None:
            self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                       "application/json; charset=utf-8")

        def _host_ok(self) -> bool:
            if self.headers.get("Host", "") not in allowed_hosts:
                self._json(403, {"error": "127.0.0.1 또는 localhost 주소로만 접속할 수 있다"})
                return False
            return True

        def do_GET(self) -> None:
            if not self._host_ok():
                return
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                try:
                    with open(PAGE, "rb") as f:
                        body = f.read()
                except OSError:
                    self._json(500, {"error": f"웹 페이지 파일이 없다: {PAGE}"})
                    return
                self._send(200, body, "text/html; charset=utf-8")
            elif path == "/api/status":
                self._json(200, app.status())
            elif path == "/api/stats":
                self._json(200, app.stats())
            elif path == "/api/sys":
                self._json(200, app.sys_stats())
            else:
                self._json(404, {"error": "없는 경로"})

        def do_POST(self) -> None:
            if not self._host_ok():
                return
            origin = self.headers.get("Origin")
            if origin is not None and origin not in allowed_origins:
                self._json(403, {"error": "다른 출처의 요청은 받지 않는다"})
                return
            if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
                self._json(415, {"error": "Content-Type은 application/json이어야 한다"})
                return
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if not 0 <= n <= MAX_BODY:
                self._json(400, {"error": "요청 본문 길이가 잘못되었다"})
                return
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                self._json(400, {"error": "JSON 객체가 필요하다"})
                return
            try:
                errors = self._dispatch(self.path.split("?", 1)[0], body)
            except SamonError as e:
                self._json(400, {"error": str(e), "status": app.status()})
                return
            if errors is None:
                self._json(404, {"error": "없는 경로"})
                return
            self._json(200 if not errors else 400,
                       {"error": "; ".join(errors) if errors else None, "status": app.status()})

        def _dispatch(self, path: str, body: dict) -> list[str] | None:
            ctl = app.ctl
            if path in ("/api/toggle", "/api/param"):
                name = str(body.get("name", ""))
                it = next((i for i in ITEMS if i.name == name), None)
                want = "toggle" if path == "/api/toggle" else "param"
                if it is None or it.kind != want:
                    raise SamonError(f"알 수 없는 {want} 항목: {name!r}")
                if "value" not in body:
                    raise SamonError("value가 필요하다")
                ctl.set(name, body["value"])
                return []
            if path == "/api/preset":
                return ctl.preset(str(body.get("name", "")))
            if path == "/api/monitor":
                ctl.monitor(str(body.get("action", "")))
                return []
            if path == "/api/restore":
                return ctl.restore()
            if path == "/api/baseline":
                app.baseline(str(body.get("action", "")))
                return []
            return None

    return Handler


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="samon",
        description="인자 없이 실행하면 대화형 CLI, 인자를 주면 웹 서버를 띄운다.",
        epilog="예) sudo samon            대화형 CLI\n"
               "    sudo samon web        웹 서버 (http://127.0.0.1:8765)\n"
               "    sudo samon web --port 9000",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["web"], help="web: 웹 서버를 띄운다")
    p.add_argument("--port", type=int, help="포트 (기본: /etc/samon/samon.conf의 [web] port, 없으면 8765)")
    return p


def serve(ctl: Ctl, port: int) -> ThreadingHTTPServer:
    """서버를 만들어 돌려준다. 시험에서는 serve_forever를 별도 스레드로 부른다."""
    app = App(ctl)
    app.start()
    srv = ThreadingHTTPServer((BIND, port), make_handler(app, port))
    srv.daemon_threads = True
    srv.app = app  # type: ignore[attr-defined]
    return srv


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    msg = need_root()
    if msg:
        print(msg, file=sys.stderr)
        return 2
    ctl = Ctl()
    port = args.port if args.port is not None else ctl.web_port()
    if not 1 <= port <= 65535:
        print(f"포트 범위는 1~65535이다: {port}", file=sys.stderr)
        return 2
    try:
        srv = serve(ctl, port)
    except OSError as e:
        print(f"포트 {port}를 열 수 없다: {e.strerror or e} (다른 포트: samon web --port N)",
              file=sys.stderr)
        return 1
    print(f"samon 웹: http://127.0.0.1:{port}  (이 장비의 브라우저에서만 접속, Ctrl-C로 종료)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.app.stop.set()  # type: ignore[attr-defined]
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
