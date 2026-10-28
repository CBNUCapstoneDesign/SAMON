"""Tests for tools/samon (samonctl, samon_web, samon_cli 화면) — 가짜 sysfs 트리 사용."""
import io
import json
import os
import socket
import sys
import threading
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import samonctl as sc  # noqa: E402
import samon_web as sw  # noqa: E402

PARAMS = {
    "samon_act_p1": "0", "samon_act_p2": "0", "samon_act_p3": "0", "samon_act_p4": "0",
    "samon_opt_b": "Y", "samon_dbg_lba": "1", "samon_hot_threshold": "10", "samon_window_ms": "1000",
    "samon_reread_ms": "10000", "samon_seq_min": "4", "samon_loop_protect_pct": "50",
    "samon_dev_major": "0", "samon_dev_minor": "0", "samon_max_entries": "65536",
    "samon_q_max_ms": "100", "samon_stream_new_kb": "64", "samon_stream_gap_req": "2",
    "samon_stream_idle_ms": "1000", "samon_loop_min_kb": "8192", "samon_q_len": "1024",
    "samon_stream_slots": "16", "samon_loop_slots": "16", "samon_reread_slots": "65536",
}
STATS = ("rq_seen=100 seg_buffered=80\n"
         "det_p1=1 det_p2=2 det_p3=3 det_p4=4 det_p5=5 det_p6=6\n"
         "req_p1=10 exec_p1=8 drop_queue_p1=1 drop_stale_p1=1\n"
         "req_p2=0 exec_p2=0\nq_cur=0\n")


def _w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def _r(path):
    with open(path) as f:
        return f.read().strip()


@pytest.fixture
def root(tmp_path):
    r = str(tmp_path)
    kd = os.path.join(r, sc.KD_DEF.lstrip("/"))
    _w(os.path.join(kd, "nr_kdamonds"), "1\n")
    _w(os.path.join(kd, "0", "state"), "off\n")
    _w(os.path.join(kd, "0", "contexts", "nr_contexts"), "0\n")
    _w(os.path.join(kd, "0", "contexts", "0", "operations"), "vaddr\n")
    _w(os.path.join(kd, "0", "contexts", "0", "targets", "nr_targets"), "0\n")
    _w(os.path.join(kd, "0", sc.ATTRS, "sample_us"), "5000\n")
    _w(os.path.join(kd, "0", sc.ATTRS, "aggr_us"), "100000\n")
    for k, v in PARAMS.items():
        _w(os.path.join(r, sc.PARM_DEF.lstrip("/"), k), v + "\n")
    _w(os.path.join(r, sc.DBG_DEF.lstrip("/"), "stats"), STATS)
    _w(os.path.join(r, sc.LRUS_DEF.lstrip("/")), "N\n")
    _w(os.path.join(r, sc.LRU_GEN_DEF.lstrip("/")), "0x0007\n")
    return r


@pytest.fixture
def ctl(root):
    return sc.Ctl(root=root)


def P(root, name):
    return os.path.join(root, sc.PARM_DEF.lstrip("/"), name)


def KD(root, *parts):
    return os.path.join(root, sc.KD_DEF.lstrip("/"), *parts)


# --- 값 검증 -------------------------------------------------------------
@pytest.mark.parametrize("v,want", [("on", True), ("Y", True), ("1", True), (True, True),
                                    ("off", False), ("N", False), ("0", False)])
def test_parse_bool(v, want):
    assert sc.parse_bool(v) is want


@pytest.mark.parametrize("name,v", [("hot_threshold", "0"), ("hot_threshold", "abc"),
                                    ("loop_protect_pct", "101"), ("hot_threshold", True),
                                    ("device", "8"), ("device", "a:b"), ("p1", "maybe"),
                                    ("q_len", str(2**32))])
def test_coerce_rejects(name, v):
    with pytest.raises(sc.SamonError):
        sc.coerce(sc.ITEM[name], v)


def test_coerce_accepts():
    assert sc.coerce(sc.ITEM["loop_protect_pct"], "0") == 0
    assert sc.coerce(sc.ITEM["hot_threshold"], 20) == 20
    assert sc.coerce(sc.ITEM["device"], " 8 : 16 ") == "8:16"


def test_unknown_item(ctl):
    with pytest.raises(sc.SamonError):
        ctl.set("samon_act_p1", 1)  # 짧은 이름만 받는다
    with pytest.raises(sc.SamonError):
        ctl.set("../../etc/passwd", 1)


# --- 읽기/쓰기 -----------------------------------------------------------
def test_get_values(ctl):
    assert ctl.get("p1") is False
    assert ctl.get("p5") is True          # Y/N bool 파라미터
    assert ctl.get("hot_threshold") == 10
    assert ctl.get("device") == "0:0"
    assert ctl.get("monitor") is False
    assert ctl.get("sample_us") == 5000


def test_set_toggle_and_param(ctl, root):
    assert ctl.set("p3", "on") is True
    assert _r(P(root, "samon_act_p3")) == "1"
    assert ctl.set("hot_threshold", "25") == 25
    assert ctl.set("device", "8:0") == "8:0"
    assert _r(P(root, "samon_dev_major")) == "8" and _r(P(root, "samon_dev_minor")) == "0"


def test_missing_param_reports(ctl, root):
    os.remove(P(root, "samon_seq_min"))
    assert ctl.get("seq_min") is None
    st = ctl.status()
    assert st["values"]["seq_min"] is None


# --- 감시 ----------------------------------------------------------------
def test_monitor_on_sets_up_saddr(ctl, root):
    ctl.monitor("on")
    assert _r(KD(root, "0", "state")) == "on"
    assert _r(KD(root, "0", "contexts", "0", "operations")) == "saddr"
    assert _r(KD(root, "0", "contexts", "nr_contexts")) == "1"
    assert _r(KD(root, "0", "contexts", "0", "targets", "nr_targets")) == "1"
    assert ctl.get("monitor") is True
    ctl.set("monitor", "off")
    assert _r(KD(root, "0", "state")) == "off"


def test_monitor_on_sets_target_region(ctl, root):
    """regions 디렉터리가 있고 비어 있으면 대상 디스크 전체를 region 하나로 설정한다."""
    rg = KD(root, "0", "contexts", "0", "targets", "0", "regions")
    _w(os.path.join(rg, "nr_regions"), "0\n")
    for n in ("0/start", "0/end"):
        _w(os.path.join(rg, n), "0\n")
    _w(os.path.join(root, "sys/block/sda/size"), "167772160\n")
    _w(os.path.join(root, "sys/block/loop0/size"), "999999999999\n")   # loop 장치는 무시
    ctl.monitor("on")
    assert _r(os.path.join(rg, "nr_regions")) == "1"
    assert _r(os.path.join(rg, "0", "start")) == "0"
    assert _r(os.path.join(rg, "0", "end")) == "167772160"
    assert ctl.status()["kdamond"]["target_regions"] == 1


def test_monitor_on_keeps_existing_regions(ctl, root):
    """이미 설정된 region(예: 히트맵 도구가 나눈 구간)은 바꾸지 않는다."""
    rg = KD(root, "0", "contexts", "0", "targets", "0", "regions")
    _w(os.path.join(rg, "nr_regions"), "8\n")
    _w(os.path.join(root, "sys/block/sda/size"), "1000\n")
    ctl.monitor("on")
    assert _r(os.path.join(rg, "nr_regions")) == "8"


def test_parse_regions():
    text = ("# iv=12 nr=2 max_acc=20 classifier=1\n"
            "# flags: S scan, L loop, H hot_r, W seqw, w hot_w, - none\n"
            "# start end acc rd_big ...\n"
            "0 4096 20 9 0 0 0 1152 0 SL 12 0 8192\n"
            "4096 8192 3 0 5 0 0 20 0 - 0 0 0\n")
    d = sc.parse_regions(text)
    assert d["head"] == {"iv": 12, "nr": 2, "max_acc": 20, "classifier": 1}
    assert d["rows"][0]["flags"] == "SL" and d["rows"][0]["acc"] == 20
    assert d["rows"][1]["rd_small"] == 5
    assert sc.parse_regions("") == {"head": {}, "rows": []}


def test_monitor_refuses_lru_sort(ctl, root):
    _w(os.path.join(root, sc.LRUS_DEF.lstrip("/")), "Y\n")
    with pytest.raises(sc.SamonError, match="DAMON_LRU_SORT"):
        ctl.monitor("on")
    assert _r(KD(root, "0", "state")) == "off"


def test_monitor_leaves_other_ops_alone(ctl, root):
    _w(KD(root, "0", "state"), "on\n")  # vaddr로 동작 중
    for action in ("on", "off", "restart"):
        with pytest.raises(sc.SamonError, match="operations=vaddr"):
            ctl.monitor(action)
    assert _r(KD(root, "0", "state")) == "on"


def test_pending_restart(ctl):
    ctl.set("q_len", 4096)               # 감시 off: 다음 시작에 적용되므로 표시 안 함
    assert ctl.pending() == []
    ctl.monitor("on")
    ctl.set("q_len", 8192)
    ctl.set("hot_threshold", 3)          # 즉시 적용 항목은 표시 안 함
    assert ctl.pending() == ["q_len"]
    assert ctl.status()["pending_restart"] == ["q_len"]
    ctl.monitor("restart")
    assert ctl.pending() == []


def test_status_modes(ctl):
    assert ctl.status()["observe_only"] is False   # 감시 off
    ctl.preset("observe")
    st = ctl.status()
    assert st["values"]["monitor"] is True and st["observe_only"] is True
    ctl.set("p2", True)
    assert ctl.status()["observe_only"] is False


# --- 프리셋 --------------------------------------------------------------
def test_presets(ctl, root):
    assert ctl.preset("all") == []
    assert all(ctl.get(p) for p in sc.PATTERN_TOGGLES) and ctl.get("monitor")
    ctl.set("hot_threshold", 99)
    assert ctl.preset("default") == []
    assert ctl.get("hot_threshold") == 10 and ctl.get("p1") is False and ctl.get("p5") is True
    assert ctl.get("monitor") is True    # default는 감시 상태를 바꾸지 않는다
    with pytest.raises(sc.SamonError):
        ctl.preset("nope")


def test_user_preset(root, tmp_path):
    conf = tmp_path / "samon.conf"
    conf.write_text("[web]\nport = 9001\n[preset:mine]\np4 = on\nhot_threshold = 7\nmonitor = on\n")
    ctl = sc.Ctl(root=root, conf=str(conf))
    assert "mine" in ctl.preset_names() and ctl.web_port() == 9001
    assert ctl.preset("mine") == []
    assert ctl.get("p4") is True and ctl.get("hot_threshold") == 7 and ctl.get("monitor") is True


def test_user_preset_bad_value_is_rejected_before_writing(root, tmp_path):
    conf = tmp_path / "samon.conf"
    conf.write_text("[preset:bad]\np1 = on\nhot_threshold = 0\n")
    ctl = sc.Ctl(root=root, conf=str(conf))
    with pytest.raises(sc.SamonError):
        ctl.preset("bad")
    assert ctl.get("p1") is False


# --- 스냅샷과 복원 -------------------------------------------------------
def test_restore(ctl, root):
    with pytest.raises(sc.SamonError):
        ctl.restore()
    ctl.preset("all")
    ctl.set("hot_threshold", 42)
    ctl.set("device", "8:0")
    ctl.set("q_len", 2048)
    ctl.set("sample_us", 1000)
    assert ctl.status()["has_snapshot"]
    assert ctl.restore() == []
    assert ctl.get("monitor") is False
    assert ctl.get("hot_threshold") == 10 and ctl.get("device") == "0:0" and ctl.get("q_len") == 1024
    assert ctl.get("sample_us") == 5000
    assert not any(ctl.get(p) for p in ("p1", "p2", "p3", "p4"))
    assert ctl.get("p5") is True
    assert not ctl.status()["has_snapshot"]


def test_snapshot_kept_from_first_change(ctl):
    ctl.set("hot_threshold", 11)
    ctl.set("hot_threshold", 12)
    ctl.restore()
    assert ctl.get("hot_threshold") == 10


def test_restore_removes_kdamond_samon_created(root):
    _w(KD(root, "nr_kdamonds"), "0\n")
    ctl = sc.Ctl(root=root)
    assert ctl.get("monitor") is False
    ctl.monitor("on")
    assert _r(KD(root, "nr_kdamonds")) == "1"
    assert ctl.restore() == []
    assert _r(KD(root, "nr_kdamonds")) == "0"


# --- stats ---------------------------------------------------------------
def test_parse_stats():
    d = sc.parse_stats("# head\n" + STATS + "entries=3 max_entries=10\n")
    assert d["det_p3"] == 3 and d["entries"] == 3 and d["max_entries"] == 10
    assert d["req_all"] == 10 and d["exec_all"] == 8 and d["drop_p1"] == 2 and d["drop_queue_all"] == 1


def test_sampler_rates(ctl, root):
    s = sc.Sampler(ctl, hist=5)
    s.sample()
    assert s.rates == {}
    _w(os.path.join(root, sc.DBG_DEF.lstrip("/"), "stats"), STATS.replace("rq_seen=100", "rq_seen=300"))
    s._prev_t -= 2.0                     # 2초 지난 것으로
    s.sample()
    assert 99 <= s.rates["rq_seen"] <= 101
    assert s.rates["det_p1"] == 0
    assert list(s.hist["rq_seen"])[0] is None
    os.remove(os.path.join(root, sc.DBG_DEF.lstrip("/"), "stats"))
    s.sample()
    assert s.error and s.rates == {}


# --- 웹 ------------------------------------------------------------------
def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def web(ctl):
    port = _free_port()
    srv = sw.serve(ctl, port)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield port
    srv.shutdown()
    srv.app.stop.set()
    srv.server_close()


def call(port, path, body=None, headers=None):
    h = {"Host": f"127.0.0.1:{port}"}
    data = None
    if body is not None:
        h["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    h.update(headers or {})
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if r.headers["Content-Type"].startswith("application/json") else raw)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_web_bind_is_loopback(web):
    assert sw.BIND == "127.0.0.1"


def test_web_status_and_stats(web):
    code, st = call(web, "/api/status")
    assert code == 200 and st["values"]["p5"] is True
    assert {i["name"] for i in st["items"]} == set(sc.ITEM)
    assert st["presets"][:3] == ["observe", "all", "default"]
    code, s = call(web, "/api/stats")
    assert code == 200 and s["stats"]["rq_seen"] == 100 and "det_p1" in s["hist"]


def test_web_page_is_self_contained(web):
    code, body = call(web, "/")
    assert code == 200
    html = body.decode()
    assert "<canvas" in html
    for bad in ('src="http', "src='http", 'href="http', "url(http", "@import", "//cdn"):
        assert bad not in html


def test_web_writes(web, ctl):
    code, r = call(web, "/api/toggle", {"name": "p2", "value": True})
    assert code == 200 and r["status"]["values"]["p2"] is True and ctl.get("p2") is True
    code, r = call(web, "/api/param", {"name": "hot_threshold", "value": 15})
    assert code == 200 and ctl.get("hot_threshold") == 15
    code, r = call(web, "/api/preset", {"name": "observe"})
    assert code == 200 and r["status"]["observe_only"] is True
    code, r = call(web, "/api/monitor", {"action": "off"})
    assert code == 200 and ctl.get("monitor") is False
    code, r = call(web, "/api/restore", {})
    assert code == 200 and ctl.get("hot_threshold") == 10 and ctl.get("p2") is False


def test_web_rejects(web, ctl):
    assert call(web, "/api/param", {"name": "hot_threshold", "value": 0})[0] == 400
    assert call(web, "/api/toggle", {"name": "hot_threshold", "value": True})[0] == 400
    assert call(web, "/api/param", {"name": "p1", "value": 1})[0] == 400
    assert call(web, "/api/toggle", {"name": "p1"})[0] == 400
    assert call(web, "/api/nope", {})[0] == 404
    assert call(web, "/api/status", headers={"Host": "evil.example:80"})[0] == 403
    assert call(web, "/api/toggle", {"name": "p1", "value": True},
                headers={"Origin": "http://evil.example"})[0] == 403
    assert call(web, "/api/toggle", {"name": "p1", "value": True},
                headers={"Content-Type": "text/plain"})[0] == 415
    assert ctl.get("p1") is False and ctl.get("hot_threshold") == 10


def test_web_args():
    p = sw.build_parser()
    assert p.parse_args(["web", "--port", "9000"]).port == 9000
    with pytest.raises(SystemExit):
        p.parse_args(["toggle"])


# --- CLI 화면 ------------------------------------------------------------
def test_cli_render(ctl):
    pytest.importorskip("rich")
    import samon_cli as cli
    from rich.console import Console
    s = sc.Sampler(ctl, hist=cli.HIST)
    s.sample()
    ui = cli.Ui(ctl, s)
    ui.refresh()
    ui.note("p3 on")
    ui.show_help = True
    con = Console(file=io.StringIO(), width=120, color_system=None)
    con.print(ui.render())
    out = con.file.getvalue()
    for word in ("감시", "P3 loop read", "hot_threshold", "항목 목록", "q 종료"):
        assert word in out


# --- 성능·자원 지표 (/proc) ----------------------------------------------
def _proc(root, busy_idle=(1000, 9000), majflt=100, refault=50, pgpgin=4000, kd_ticks=None):
    pr = os.path.join(root, "proc")
    busy, idle = busy_idle
    _w(os.path.join(pr, "stat"), f"cpu  {busy} 0 0 {idle} 0 0 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0\ncpu1 1 0 0 1 0 0 0 0\n")
    _w(os.path.join(pr, "meminfo"), "MemTotal:  8192000 kB\nMemAvailable: 6144000 kB\nCached: 2048000 kB\n"
       "Active(file):  1024000 kB\nInactive(file): 512000 kB\n")
    _w(os.path.join(pr, "vmstat"), f"pgpgin {pgpgin}\npgpgout 10\npgmajfault {majflt}\n"
       f"workingset_refault_anon 3\nworkingset_refault_file {refault}\n")
    if kd_ticks is not None:
        _w(KD(root, "0", "pid"), "4242\n")
        _w(os.path.join(pr, "4242", "stat"), f"4242 (kdamond.0 x) S " + "0 " * 10 + f"{kd_ticks} 0 0 0\n")


def test_parse_proc():
    assert sc.parse_cpu("cpu  10 0 5 80 5 0 0 0 0 0\ncpu0 1\ncpu1 1\n") == (15, 100, 2)
    assert sc.parse_cpu("") is None
    assert sc.parse_pid_ticks("1 (a b) c) S " + "0 " * 10 + "7 3 0\n") == 10
    assert sc.parse_kv_table("Cached:  5 kB\npgmajfault 9\n") == {"Cached": 5, "pgmajfault": 9}


def test_sys_sampler(ctl, root, monkeypatch):
    clock = iter([100.0, 101.0])                      # 두 표본 사이 정확히 1초
    monkeypatch.setattr(sc.time, "monotonic", lambda: next(clock))
    _proc(root, kd_ticks=100)
    s = sc.SysSampler(ctl, hist=60)
    s.hz = 100
    s.sample()
    assert s.cur["mem_used_mb"] == 2000 and s.cur["cached_mb"] == 2000
    assert s.cur["cpu_pct"] is None and s.ncpu == 2
    _proc(root, busy_idle=(1500, 9500), majflt=120, refault=90, pgpgin=6000, kd_ticks=150)
    s.sample()
    assert s.cur["cpu_pct"] == 50                     # busy 500 / total 1000
    assert s.cur["majflt_s"] == 20 and s.cur["refault_s"] == 40 and s.cur["pgpgin_kb_s"] == 2000
    assert s.cur["kd_cpu_pct"] == 50                  # 50 tick / 100Hz / 1s
    b = s.set_baseline("감시 off")
    assert b["values"]["refault_s"] is not None and b["label"] == "감시 off"
    d = s.as_dict()
    assert d["baseline"] and {m["key"] for m in d["metrics"]} == set(sc.SYS_KEYS)
    s.clear_baseline()
    assert s.as_dict()["baseline"] is None


def test_sys_sampler_kdamond_off(ctl, root):
    _proc(root)
    _w(KD(root, "0", "pid"), "-1\n")
    s = sc.SysSampler(ctl)
    s.sample(); s.sample()
    assert s.cur["kd_cpu_pct"] is None and ctl.kd_pid() is None


def test_web_sys_and_baseline(root, ctl):
    _proc(root)
    port = _free_port()
    srv = sw.serve(ctl, port)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        code, d = call(port, "/api/sys")
        assert code == 200 and d["cur"]["cached_mb"] == 2000 and d["baseline"] is None
        code, _ = call(port, "/api/baseline", {"action": "set"})
        assert code == 200
        code, d = call(port, "/api/sys")
        assert d["baseline"]["label"].startswith("감시 off")
        assert call(port, "/api/baseline", {"action": "nope"})[0] == 400
        call(port, "/api/baseline", {"action": "clear"})
        assert call(port, "/api/sys")[1]["baseline"] is None
    finally:
        srv.shutdown(); srv.app.stop.set(); srv.server_close()
