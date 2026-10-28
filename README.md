# SAMON - Storage Access MONitor

SAMON은 Linux 6.8 DAMON의 operations set "saddr"(mm/damon/saddr.c)로 구현한 커널 내부 스토리지 접근 관측기이다. block layer의 `block_rq_complete` tracepoint에서 완료된 buffered I/O를 LBA 단위로 보고, LBA를 page cache의 folio(PFN)와 연결한다. DAMON이 디스크 섹터 공간을 adaptive region으로 나누고, SAMON은 region별 I/O 집계로 region 특성(scan, loop, hot read, 순차 write, hot write)을 정한 뒤, 그 특성과 요청 크기·방향으로 segment마다 접근 패턴(P1 순차 read, P2 hot read, P3 loop read, P4 순차 write, P5 hot write, P6 기타)을 판정한다(Region_Classifier, `samon_classifier=1`, 기본. `0`이면 이전의 요청 단위 판정). 판정 결과에 따른 LRU 조작(folio_activate, folio_deactivate, folio_mark_accessed)은 완료 콜백에서 직접 하지 않고 CPU별 큐를 거쳐 kdamond가 프로세스 컨텍스트에서 실행한다. 패턴별 조작 토글(samon_act_p1~p4)의 기본값은 0이다.

적용 방법, 사용법, 파라미터, 검증 상태, 측정 결과는 [kernel/README.md](kernel/README.md)에 있다. 2026-10-28 빌드에서 kernel/verify_samon.sh 37/37 PASS(요청 단위 판정 기준)였다. Region_Classifier는 fio 단독 시험으로 P1~P4 판정을 확인했다. mixed 워크로드 9개 시나리오(memory.max 2G/1G/512M × CPU 0/50/100%)에서 `samon_loop_protect_mem_pct=25`, `samon_p2_mode=2`로 MGLRU 대비 page cache refault가 23~49% 줄었고 나빠진 지표는 없었다(n=3). 이 두 값은 아직 커널 기본값이 아니다.

## 구성

| 경로 | 설명 |
|---|---|
| `kernel/saddr.c` | operations set 본체 (mm/damon/saddr.c로 배치) |
| `kernel/damon_Kconfig`, `kernel/damon_Makefile` | mm/damon/Kconfig, Makefile 대체본 (CONFIG_DAMON_SADDR) |
| `kernel/verify_samon.sh` | 기능 검증 스크립트 (root, 37개 항목) |
| `kernel/samon_qlen_sweep.sh` | samon_q_len별 큐 유실 측정 (root) |
| `kernel/test_pinned.c` | verify_samon.sh가 쓰는 pinned direct I/O 시험 |
| `bench/samon_bench.sh`, `bench/samon_benchlib.py`, `bench/summarize.py` | 측정 하네스: off, DAMON_LRU_SORT, SAMON 구성 비교 (구현됨, 커널 실측정 미실행) |
| `bench/samon_workloads.sh` | 하네스와 S0 수집이 같이 쓰는 워크로드 정의 |
| `bench/samon_trace.bt`, `bench/samon_s0_capture.sh` | block trace 수집. 측정 도구이며 구현의 기반이 아니다 |
| `bench/samon_replay.py` | trace에 패턴 규칙을 오프라인으로 적용하는 참조 모델 (보고서 CLI 미구현) |
| `bench/tests/` | pytest(hypothesis) 시험과 하네스 셸 시험 |
| `demo/` | 시연용 라이브 대시보드, 시나리오, PNG 타임라인 (아래 "시연") |
| `tools/samon/` | `samon` 제어 CLI(터미널)와 웹 제어판: 감시 on/off, 패턴 토글, 파라미터, 성능·자원 비교 ([tools/samon/README.md](tools/samon/README.md)) |
| `workloads/` | 초기 히트맵용 워크로드 ([workloads/README.md](workloads/README.md)) |

## 빠른 사용

```bash
# saddr kdamond 시작 (부팅만으로는 관측이 시작되지 않는다)
echo 1 | sudo tee /sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds
echo 1 | sudo tee /sys/kernel/mm/damon/admin/kdamonds/0/contexts/nr_contexts
echo saddr | sudo tee /sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/operations
echo 1 | sudo tee /sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/targets/nr_targets
# DAMON target region = 대상 디스크 전체 (비어 있으면 Region_Classifier는 P6만 낸다)
R=/sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/targets/0/regions
echo 1 | sudo tee $R/nr_regions; echo 0 | sudo tee $R/0/start
cat /sys/class/block/sda/size | sudo tee $R/0/end
echo on | sudo tee /sys/kernel/mm/damon/admin/kdamonds/0/state

sudo cat /sys/kernel/debug/samon/stats
sudo cat /sys/kernel/debug/samon/regions   # region별 라벨 (직전 집계 주기)

# 또는 CLI / 웹 제어판 (target region을 자동 설정)
sudo samon            # tools/samon/install.sh로 설치
sudo samon web

# 기능 검증
sudo bash kernel/verify_samon.sh -d /var/tmp/samon_verify

# 측정 하네스 (워크로드: mixed | reread | loop | seqwrite)
sudo bash bench/samon_bench.sh -w mixed -d /var/tmp/samon_bench
python3 bench/summarize.py bench/results/<date>-mixed/runs.csv
```

시험 실행 (root 불필요):

```bash
python3 -m venv bench/.venv && bench/.venv/bin/pip install -r bench/requirements-dev.txt
bench/.venv/bin/python -m pytest bench/tests
for t in bench/tests/test_samon_bench_*.sh; do bash "$t"; done
```

## 시연 (demo/)

debugfs(stats, streams, wb_hist, regions)를 읽는 터미널 대시보드와(`samon_classifier=1`이면 Stream_Table 패널 대신 region 라벨 패널), 패턴 P1~P6를 차례로 일으키는 시나리오이다. 시연 도구이며 검증이나 성능 측정 근거가 아니다.

```bash
# 터미널 1: 라이브 대시보드 (Ctrl-C로 종료). --record로 초당 값을 CSV에 남긴다
sudo python3 demo/samon_dashboard.py --record /tmp/samon_demo.csv

# 터미널 2: 시나리오 (idle, p1, rand, p2, p3, p4, p5, mix 순서, 약 2분)
sudo bash demo/samon_demo_scenario.sh            # -p p3,mix 로 단계 선택, -O 는 조작 토글 off

# 끝난 뒤: 발표용 PNG 타임라인
python3 demo/samon_demo_plot.py /tmp/samon_demo.csv -o samon_demo.png
```

- 시나리오는 kdamond 0을 saddr로 설정하고 samon_q_len 8192, sample_us 5000, 대상 디스크 필터를 쓴 뒤 시작한다. 끝나거나 중단되면 바꾼 값을 시작 값으로 되돌린다. DAMON_LRU_SORT가 켜져 있으면 시작하지 않는다.
- 기본으로 조작 토글 5개를 모두 켜므로 시연 파일의 page에 promote/demote/mark_accessed가 실제로 실행된다. 그 결과 page 상태가 바뀌었는지와 성능 효과는 화면에 나오지 않고, 아직 측정하지도 않았다.
- `--once --samples 10 --svg shot.svg`로 대시보드 한 화면을 SVG로 저장할 수 있다(라이브 시연이 어려울 때 슬라이드용).
- 토글 on/off 비교: `sudo bash demo/samon_demo_scenario.sh -A -p p2,p1`은 단계마다 토글 on(cgroup samon_on)과 off(cgroup samon_off)로 한 번씩, 서로 다른 파일로 실행한다. 대시보드의 "page cache 반영" 패널이 두 cgroup의 active_file/inactive_file, pgactivate/pgdeactivate를 나란히 보여 주고, --record CSV로 그린 PNG에는 세 번째 그래프로 들어간다. 이 기능을 넣기 전에 같은 방식으로 수동 실험한 결과(p2, MGLRU, 각 1회): on은 pgactivate 65,001에 active 90%였고, off는 pgactivate 0에 active 0%였다. 회수가 없는 조건이라 LRU 위치만 바뀌고 캐시에 남는 내용은 달라지지 않는다.

## 초기 프로토타입 (이번 구현의 기반 아님)

아래 스크립트는 커널 구현 이전에 만든 도구이다. saddr 커널 구현은 이 코드를 쓰지 않는다.

| 파일 | 설명 |
|---|---|
| `samon_probe.py` | eBPF(bcc) kprobe로 bio 제출 함수(`blk_mq_submit_bio` 등)의 개별 I/O 이벤트 출력 |
| `samon_heatmap.py` | eBPF(bcc) 기반 터미널 LBA 히트맵 |
| `samon_monitor.py` | eBPF(bcc) 기반 적응형 region 모니터와 CSV 기록 |
| `samon_kernel_monitor.py` | saddr kdamond를 띄우고 `damon_aggregated` tracepoint의 region별 nr_accesses를 CSV로 기록 (bcc 미사용) |
| `samon_plot.py` | 위 CSV로 matplotlib 히트맵 생성 |
| `bench_overhead.sh` | native / blktrace / eBPF 모니터 오버헤드 비교 (경로가 다른 머신 기준으로 하드코딩됨) |

eBPF 스크립트는 python3-bpfcc가 필요하고, samon_plot.py는 matplotlib이 필요하다.

## 요구 사항

- Linux 6.8 소스와 CONFIG_DAMON, CONFIG_DAMON_SYSFS, CONFIG_DAMON_SADDR (커널 빌드 주의사항은 kernel/README.md)
- 검증·측정: fio, filefrag, gcc, fincore(util-linux-extra), cgroup v2 memory controller
- S0 수집: bpftrace
- 시험: Python 3.12, bench/requirements-dev.txt (hypothesis, pytest)

## License

MIT (kernel/saddr.c는 SPDX GPL-2.0)
