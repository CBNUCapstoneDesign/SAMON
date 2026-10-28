"""samon_cli.py — samon 대화형 CLI (samon을 인자 없이 실행했을 때).

위쪽에는 상태를 1초마다 갱신해 보여 주고, 키 하나로 조작한다.

  m       감시 on/off            1 ~ 5   패턴 P1~P5 토글
  l       lba_map 토글           s       성능 파라미터 변경
  p       프리셋 적용            r       재시작 필요 항목 반영 (감시 off 후 on)
  u       처음 상태로 복원        h       항목 목록·범위·적용 시점
  q       종료 (바꾼 값은 그대로 둔다)

화면은 rich(시스템 패키지 python3-rich)로 그린다.
"""
from __future__ import annotations

import os
import select
import sys
import time
from contextlib import contextmanager

try:
    import termios
    import tty
except ImportError:  # pragma: no cover - 리눅스 전용
    termios = tty = None

try:
    from rich.console import Console, Group
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:  # pragma: no cover - 환경 문제를 바로 알린다
    sys.exit("rich가 없다: sudo apt install python3-rich")

from samonctl import ITEM, ITEMS, U32_MAX, Ctl, SamonError, Sampler, need_root

SPARK = " ▁▂▃▄▅▆▇█"
HIST = 30
PATTERNS = (  # (번호, 이름, 토글을 켰을 때의 조작, 색)
    (1, "순차 read", "demote", "cyan"),
    (2, "재읽기", "promote", "green"),
    (3, "loop read", "promote/demote", "magenta"),
    (4, "순차 write", "demote", "yellow"),
    (5, "hot write", "mark_accessed", "red"),
    (6, "기타", "-", "grey62"),
)
PARAM_ITEMS = [it for it in ITEMS if it.kind == "param"]


# ---------------------------------------------------------------------------
# 표시 도우미
# ---------------------------------------------------------------------------
def fmt_num(v: float | None) -> str:
    if v is None:
        return "—"
    a = abs(v)
    if a >= 1e6:
        return f"{v / 1e6:.1f}M"
    if a >= 1e4:
        return f"{v / 1e3:.0f}k"
    if a >= 1e3:
        return f"{v / 1e3:.1f}k"
    return f"{v:.0f}"


def spark(vals, width: int) -> str:
    vs = list(vals)[-width:]
    m = max((v for v in vs if v is not None), default=0)
    out = []
    for v in vs:
        if v is None:
            out.append(" ")
        elif v <= 0 or m <= 0:
            out.append("·")
        else:
            i = round(v / m * (len(SPARK) - 1))
            out.append(SPARK[max(1, min(len(SPARK) - 1, i))])
    return "".join(out).rjust(width)


def onoff(v: object) -> Text:
    if v is None:
        return Text("?", style="grey50")
    return Text("on", style="bold green") if v else Text("off", style="grey50")


def range_text(it) -> str:
    if it.where == "device":
        return "major:minor"
    return f"{it.lo} 이상" if it.hi >= U32_MAX else f"{it.lo}~{it.hi}"


# ---------------------------------------------------------------------------
# 화면
# ---------------------------------------------------------------------------
class Ui:
    def __init__(self, ctl: Ctl, sampler: Sampler):
        self.ctl = ctl
        self.s = sampler
        self.st: dict = {}
        self.msg = Text("")
        self.show_help = False

    def refresh(self) -> None:
        self.st = self.ctl.status()

    def note(self, text: str, ok: bool = True) -> None:
        self.msg = Text(f"{time.strftime('%H:%M:%S')}  {text}", style="green" if ok else "bold red")

    def render(self) -> Group:
        parts = [self.head(), self.patterns(), self.params_panel(), self.keys()]
        if self.show_help:
            parts.insert(3, self.help_panel())
        return Group(*parts)

    def head(self) -> Panel:
        st, v = self.st, self.st.get("values", {})
        kd = st.get("kdamond", {})
        l1 = Text()
        l1.append("SAMON  ", style="bold")
        l1.append("감시 ")
        l1.append("on" if v.get("monitor") else "off", style="bold green" if v.get("monitor") else "bold red")
        l1.append(f" (kdamond {kd.get('state') or '없음'}, ops={kd.get('ops') or '-'})   ")
        mode = "정지" if not v.get("monitor") else ("관측 전용" if st.get("observe_only") else "조작 중")
        l1.append(f"{mode}   ", style="bold")
        l1.append(f"dev {v.get('device') or '-'}   lru_gen {st.get('lru_gen') or '-'}   ")
        l1.append(time.strftime("%H:%M:%S"), style="grey62")
        warn = []
        if not st.get("saddr_loaded"):
            warn.append("saddr 모듈 파라미터가 없다 (SAMON 커널인지 확인)")
        if st.get("lru_sort_on"):
            warn.append("DAMON_LRU_SORT가 켜져 있다")
        if self.s.error:
            warn.append(self.s.error)
        if st.get("pending_restart"):
            warn.append("재시작 필요: " + ", ".join(st["pending_restart"]) + " (r 키로 반영)")
        lines = [l1]
        lines += [Text(w, style="bold yellow") for w in warn]
        lines.append(self.msg)
        return Panel(Group(*lines), padding=(0, 1))

    def patterns(self) -> Panel:
        v = self.st.get("values", {})
        t = Table(expand=True, box=None, pad_edge=False)
        t.add_column("키", no_wrap=True, style="bold")
        t.add_column("항목", no_wrap=True)
        t.add_column("조작", no_wrap=True)
        t.add_column("토글", justify="center", no_wrap=True)
        t.add_column("seg/s", justify="right", no_wrap=True)
        t.add_column(f"최근 {HIST}초", no_wrap=True, min_width=HIST, overflow="crop")
        for n, name, act, color in PATTERNS:
            k = f"det_p{n}"
            r = self.s.rates.get(k)
            t.add_row(str(n) if n <= 5 else "",
                      Text(f"P{n} {name}", style=f"bold {color}"), act,
                      onoff(v.get(f"p{n}")) if n <= 5 else Text("-", style="grey50"),
                      fmt_num(r), Text(spark(self.s.hist[k], HIST), style=color))
        t.add_row("l", "lba_map", ITEM["lba_map"].label, onoff(v.get("lba_map")), "", "")
        rt = self.s.rates
        foot = Text(f"관측 request {fmt_num(rt.get('rq_seen'))}/s   큐 요청 {fmt_num(rt.get('req_all'))}/s   "
                    f"실행 {fmt_num(rt.get('exec_all'))}/s   폐기 {fmt_num(rt.get('drop_all'))}/s   "
                    f"q_cur {self.s.stats.get('q_cur', '-')}", style="grey70")
        return Panel(Group(t, foot), title="기능 토글과 패턴 감지", padding=(0, 1))

    def params_panel(self) -> Panel:
        v = self.st.get("values", {})
        t = Table(expand=True, box=None, pad_edge=False, show_header=False)
        for _ in range(2):
            t.add_column(no_wrap=True)
            t.add_column(justify="right", no_wrap=True, style="bold")
        main = [it for it in PARAM_ITEMS if it.main]
        cells = []
        for it in main:
            val = v.get(it.name)
            cells.append((it.name, "읽기 불가" if val is None else str(val)))
        for i in range(0, len(cells), 2):
            row = list(cells[i]) + (list(cells[i + 1]) if i + 1 < len(cells) else ["", ""])
            t.add_row(*row)
        return Panel(t, title="성능 파라미터 (주요 항목)",
                     subtitle=f"고급 항목 {len(PARAM_ITEMS) - len(main)}개는 s 키에서 바꾼다", padding=(0, 1))

    def help_panel(self) -> Panel:
        v = self.st.get("values", {})
        t = Table(expand=True, box=None, pad_edge=False)
        for c in ("항목", "현재값", "범위", "적용", "설명"):
            t.add_column(c, no_wrap=c != "설명")
        for it in ITEMS:
            val = v.get(it.name)
            sval = ("on" if val else "off") if it.kind == "toggle" and val is not None else str(val)
            t.add_row(it.name, sval, "on/off" if it.kind == "toggle" else range_text(it),
                      "즉시" if it.apply == "now" else "재시작 시", it.label)
        return Panel(t, title="항목 목록 (h로 닫기)", padding=(0, 1))

    def keys(self) -> Text:
        return Text("m 감시 on/off   1-5 패턴 토글   l lba_map   s 파라미터   p 프리셋   "
                    "r 재시작 반영   u 복원   h 항목 목록   q 종료", style="reverse")


# ---------------------------------------------------------------------------
# 키 입력
# ---------------------------------------------------------------------------
@contextmanager
def cbreak(fd: int):
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def read_key(fd: int, timeout: float) -> str | None:
    r, _, _ = select.select([fd], [], [], max(0.0, timeout))
    if not r:
        return None
    b = os.read(fd, 16)  # 화살표 키 같은 ESC 시퀀스는 통째로 읽어 버린다
    if not b or b[:1] == b"\x1b":
        return None
    return b[:1].decode("ascii", "replace")


class App:
    def __init__(self, ctl: Ctl, console: Console, fd: int):
        self.ctl = ctl
        self.con = console
        self.fd = fd
        self.s = Sampler(ctl, hist=HIST)
        self.ui = Ui(ctl, self.s)
        self.live: Live | None = None

    def _do(self, what: str, fn, *args) -> None:
        try:
            errors = fn(*args)  # 목록이면 실패 사유들 (apply_many, preset, restore)
            if isinstance(errors, list) and errors:
                self.ui.note(f"{what}: 일부 실패 — " + "; ".join(errors), ok=False)
            else:
                self.ui.note(what)
        except SamonError as e:
            self.ui.note(f"{what} 실패: {e}", ok=False)
        self.ui.refresh()

    @contextmanager
    def prompt_mode(self):
        """Live 화면을 멈추고 일반 입력 모드로 바꾼다."""
        self.live.stop()
        old = termios.tcgetattr(self.fd)
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.cooked)
        try:
            yield
        except (EOFError, KeyboardInterrupt):
            self.ui.note("취소했다", ok=False)
        finally:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, old)
            self.live.start()

    def ask(self, q: str) -> str:
        return self.con.input(f"[bold]{q}[/] ").strip()

    def edit_param(self) -> None:
        with self.prompt_mode():
            v = self.ui.st.get("values", {})
            t = Table(box=None, pad_edge=False)
            for c in ("번호", "항목", "현재값", "범위", "적용", "설명"):
                t.add_column(c, no_wrap=True)
            for i, it in enumerate(PARAM_ITEMS, 1):
                t.add_row(str(i), it.name, str(v.get(it.name)), range_text(it),
                          "즉시" if it.apply == "now" else "재시작 시", it.label)
            self.con.clear()
            self.con.print(Panel(t, title="성능 파라미터 변경"))
            sel = self.ask("번호 또는 항목 이름 (빈 칸 = 취소):")
            if not sel:
                self.ui.note("취소했다", ok=False)
                return
            it = (PARAM_ITEMS[int(sel) - 1] if sel.isdigit() and 1 <= int(sel) <= len(PARAM_ITEMS)
                  else ITEM.get(sel))
            if it is None or it.kind != "param":
                self.ui.note(f"알 수 없는 항목: {sel}", ok=False)
                return
            val = self.ask(f"{it.name} 새 값 ({range_text(it)}, 현재 {v.get(it.name)}, 빈 칸 = 취소):")
            if not val:
                self.ui.note("취소했다", ok=False)
                return
            self._do(f"{it.name} = {val}", self.ctl.set, it.name, val)

    def choose_preset(self) -> None:
        with self.prompt_mode():
            names = self.ctl.preset_names()
            desc = {"observe": "관측 전용 (감시 on, 토글 모두 off)", "all": "감시 on, 토글 모두 on",
                    "default": "모듈 기본값"}
            self.con.clear()
            for i, n in enumerate(names, 1):
                self.con.print(f"  {i}. {n:10s} {desc.get(n, '사용자 정의 (/etc/samon/samon.conf)')}")
            sel = self.ask("번호 또는 프리셋 이름 (빈 칸 = 취소):")
            if not sel:
                self.ui.note("취소했다", ok=False)
                return
            name = names[int(sel) - 1] if sel.isdigit() and 1 <= int(sel) <= len(names) else sel
            self._do(f"프리셋 {name} 적용", self.ctl.preset, name)

    def confirm_restore(self) -> None:
        if not self.ui.st.get("has_snapshot"):
            self.ui.note("되돌릴 스냅샷이 없다 (아직 바꾼 값이 없다)", ok=False)
            return
        with self.prompt_mode():
            if self.ask("samon이 처음 값을 바꾸기 직전 상태로 되돌린다. 진행할까? [y/N]").lower() == "y":
                self._do("처음 상태로 복원", self.ctl.restore)
            else:
                self.ui.note("복원을 취소했다", ok=False)

    def handle(self, k: str) -> bool:
        """키 하나를 처리한다. 끝내야 하면 False."""
        v = self.ui.st.get("values", {})
        if k in ("q", "Q"):
            return False
        if k == "m":
            on = not v.get("monitor")
            self.ui.note("감시를 켜는 중..." if on else "감시를 끄는 중...")
            self.live.update(self.ui.render(), refresh=True)
            self._do(f"감시 {'on' if on else 'off'}", self.ctl.monitor, "on" if on else "off")
        elif k in "12345":
            name = f"p{k}"
            new = not v.get(name)
            self._do(f"{name} {'on' if new else 'off'}", self.ctl.set, name, new)
        elif k == "l":
            new = not v.get("lba_map")
            self._do(f"lba_map {'on' if new else 'off'}", self.ctl.set, "lba_map", new)
        elif k == "s":
            self.edit_param()
        elif k == "p":
            self.choose_preset()
        elif k == "r":
            self._do("감시 재시작 (재시작 필요 항목 반영)", self.ctl.monitor, "restart")
        elif k == "u":
            self.confirm_restore()
        elif k == "h":
            self.ui.show_help = not self.ui.show_help
        return True

    def run(self) -> int:
        self.cooked = termios.tcgetattr(self.fd)
        self.s.sample()
        self.ui.refresh()
        nxt = time.monotonic() + 1.0
        with cbreak(self.fd), Live(self.ui.render(), console=self.con, screen=True,
                                   auto_refresh=False) as live:
            self.live = live
            while True:
                k = read_key(self.fd, nxt - time.monotonic())
                if k is not None and not self.handle(k):
                    return 0
                if time.monotonic() >= nxt:
                    self.s.sample()
                    self.ui.refresh()
                    nxt = time.monotonic() + 1.0
                live.update(self.ui.render(), refresh=True)


def main() -> int:
    msg = need_root()
    if msg:
        print(msg, file=sys.stderr)
        return 2
    if termios is None or not sys.stdin.isatty():
        print("대화형 CLI는 터미널에서 실행한다. 웹으로 보려면: sudo samon web", file=sys.stderr)
        return 2
    try:
        return App(Ctl(), Console(), sys.stdin.fileno()).run()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
