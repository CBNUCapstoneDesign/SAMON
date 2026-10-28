# samon — SAMON 제어 도구

리눅스 셸에서 `samon` 명령어 하나로 SAMON(saddr)의 감시 on/off, 패턴 토글, 성능 파라미터를
터미널 화면이나 웹 페이지에서 바꾼다. saddr.c는 바꾸지 않으며, 이미 노출된 모듈 파라미터
(`/sys/module/saddr/parameters`), kdamond sysfs, debugfs(`/sys/kernel/debug/samon/stats`)만 사용한다.

## 설치

```sh
sudo apt install python3-rich        # 필요한 패키지는 python3, python3-rich뿐
sudo bash tools/samon/install.sh     # 인터넷 연결 없이 저장소 파일만 복사
```

## 실행

| 명령 | 동작 |
|---|---|
| `sudo samon` | 인자 없음: 대화형 CLI |
| `sudo samon web [--port N]` | 인자 있음: 웹 서버. `http://127.0.0.1:8765`를 이 장비의 브라우저에서 연다 |

웹 서버는 127.0.0.1에만 연결을 받으며, 외부 접속을 여는 옵션은 없다. 웹 페이지는 CSS와
JavaScript를 담은 파일 하나이고 외부 주소를 참조하지 않으므로 인터넷 없이 동작한다.

### 웹 페이지 탭

- **제어**: 기능 토글, 성능 파라미터, 프리셋, 감시 재시작·복원, 패턴 감지 그래프
- **성능·자원**: `/proc`에서 읽은 CPU 사용률, kdamond CPU(SAMON 오버헤드), 메모리, page cache
  (Cached, Active/Inactive file), major fault, page cache refault, 디스크 read/write를 1초 간격으로 보인다.
  같은 워크로드를 돌리면서 한 설정(예: 감시 off)에서 "기준 저장"을 누르고 설정을 바꾸면, 최근 30초
  평균을 기준과 비교해 나아진 지표는 초록, 나빠진 지표는 빨강으로 표시한다(5% 이상 차이, 기준 1 이상일 때).
  기준은 웹 서버가 켜져 있는 동안만 유지된다. 주소 끝에 `#sys`를 붙이면 이 탭으로 바로 열린다.

### 대화형 CLI 키

| 키 | 동작 |
|---|---|
| `m` | 감시 on/off (kdamond 0을 operations=saddr로 설정. target region이 비어 있으면 대상 디스크 전체로 설정) |
| `1`~`5` | 패턴 P1~P5 토글 |
| `l` | lba_map 토글 |
| `s` | 성능 파라미터 변경 (번호 또는 이름 선택 후 값 입력) |
| `p` | 프리셋 적용 |
| `r` | 재시작 필요 항목 반영 (감시 off 후 on) |
| `u` | 처음 상태로 복원 |
| `h` | 항목 목록·범위·적용 시점 |
| `q` | 종료 (바꾼 값은 그대로 둔다) |

## 항목

| 이름 | 대상 | 범위 | 적용 |
|---|---|---|---|
| monitor | kdamonds/0/state (ops=saddr) | on/off | 즉시 |
| p1 ~ p4 | samon_act_p1 ~ p4 | on/off | 즉시 |
| p5 | samon_opt_b | on/off | 즉시 |
| lba_map | samon_dbg_lba | on/off | 즉시 |
| classifier | samon_classifier (on = DAMON region 기반 판정, off = 요청 단위 판정) | on/off | 즉시 |
| rgn_seq_kb, rgn_min_ios, rgn_loop_gap | samon_rgn_* (region 판정 문턱값) | 0 이상 | 즉시 |
| rgn_hot_pct | samon_rgn_hot_pct | 0~100 | 즉시 |
| rgn_hold | samon_rgn_hold | 1 이상 | 즉시 |
| hot_threshold, window_ms, reread_ms, seq_min | samon_* | 1 이상 | 즉시 |
| loop_protect_pct | samon_loop_protect_pct | 0~100 | 즉시 |
| device | samon_dev_major:samon_dev_minor | major:minor (0:0 = 전체) | 즉시 |
| max_entries, q_max_ms, stream_new_kb, stream_gap_req, stream_idle_ms, loop_min_kb | samon_* | 1 이상 | 즉시 |
| q_len, stream_slots, loop_slots, reread_slots | samon_* | 1 이상 | 재시작 시 |
| sample_us, aggr_us | kdamond 감시 간격 | 1 이상 | 재시작 시 |

"재시작 시" 항목을 감시 중에 바꾸면 CLI와 웹에 "재시작 필요"가 표시되고, `r` 키나 웹의
"감시 재시작" 버튼으로 반영한다.

## 프리셋

- `observe`: 감시 on, P1~P5 모두 off (관측 전용)
- `all`: 감시 on, P1~P5 모두 on
- `default`: 모듈 적재 시 기본값 (감시 상태는 바꾸지 않는다)
- 사용자 정의: `/etc/samon/samon.conf`의 `[preset:이름]` 절 (`samon.conf.example` 참조)

## 안전 장치

- 감시를 켜기 전에 DAMON_LRU_SORT가 켜져 있으면 거부한다.
- kdamond 0이 saddr가 아닌 operations로 동작 중이면 건드리지 않는다.
- samon이 처음 값을 바꾸기 직전 상태를 `/run/samon/snapshot.json`에 저장한다. 복원(`u` 키, 웹의
  복원 버튼)은 이 파일로 되돌린다. 재부팅하면 사라진다.
- CLI와 웹이 동시에 값을 바꾸지 않도록 `/run/samon/lock`으로 쓰기를 잠근다.
- 웹 API는 Host·Origin이 127.0.0.1/localhost인 요청만, POST는 `application/json`만 받는다.
- `lba_page_map`은 읽지 않는다(엔트리가 많으면 LBA 트리 잠금을 오래 잡는다).
## DAMON target region (2026-10-28 커널)
region 기반 판정(`classifier` on, 커널 기본값)은 kdamond 0의 DAMON target region 안의 adaptive region으로
패턴을 정한다. 감시를 켤 때 `targets/0/regions/nr_regions`가 0이면 samon이 대상 디스크 전체
(`device`가 0:0이면 가장 큰 디스크, 아니면 그 디스크의 `/sys/dev/block/M:m/size`)를 region 하나로 설정한다.
이미 설정된 region(예: `samon_kernel_monitor.py`가 나눈 구간)은 바꾸지 않는다. region별 판정 결과는
`/sys/kernel/debug/samon/regions`에 있고, `demo/samon_dashboard.py`가 이 표를 보여 준다.

## 시험

가짜 sysfs 트리로 리눅스 밖에서도 돈다.

```sh
python3 -m pytest tools/samon/tests
```

`SAMON_SYSROOT=/tmp/fake samon web`처럼 SAMON_SYSROOT를 주면 모든 경로 앞에 붙인다(root 확인도 건너뛴다).
