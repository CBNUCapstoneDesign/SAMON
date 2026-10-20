# SAMON 커널 operations set (saddr)

Linux 6.8 DAMON operations set `saddr`(mm/damon/saddr.c)의 구현이다. 하는 일은 셋이다.
- block layer에서 완료된 buffered I/O를 LBA 단위로 관측한다.
- segment마다 접근 패턴(P1~P6)을 판정한다.
- 판정 결과에 따른 LRU 조작을 kdamond가 프로세스 컨텍스트에서 실행한다.

## 상태 (6.8.0-SAMON #12)

| 기능 | 상태 |
|---|---|
| 관측, buffered I/O 필터, LBA to PFN 연결, hot 판정 | Verify PASS |
| 진입 계측 (ctx 합 = rq_seen, skip_passthru) | Verify PASS |
| Deferred_Queue 회계 (req = exec + drop), direct_ops = 0 | Verify PASS |
| 패턴 판정 P1~P4, 토글 on/off별 요청·실행 건수 | Verify PASS |
| P2 promote가 실제 LRU에 반영됨 | 수동 A/B 1회. on은 pgactivate 65,001에 active 90%, off는 0과 0% (MGLRU) |
| P5 판정 전용 시험, demote의 LRU 반영, debugfs streams·wb_hist 형식 | 미검증 |
| 부분 완료, 에러 완료, 실행 컨텍스트 안전성(lockdep), 고부하·장시간 | 미검증 |
| 효과 (hit율, refault, IOPS) | 미측정 (bench/ 하네스 준비됨) |

Verify는 `kernel/verify_samon.sh`이고 37개 항목이 있다. 최근 실행은 #12에서 `PASS=37 FAIL=0`이었다.

## 적용

1. `saddr.c`를 `mm/damon/saddr.c`로 복사한다.
2. `mm/damon/Makefile`을 `damon_Makefile`로, `mm/damon/Kconfig`를 `damon_Kconfig`로 교체한다.
3. `include/linux/damon.h`의 `enum damon_ops_id`에서 `NR_DAMON_OPS` 앞에 `DAMON_OPS_SADDR`를 추가한다.
4. `mm/damon/sysfs.c`의 `damon_sysfs_ops_strs[]`에 `"saddr"`를 추가한다.
5. `CONFIG_DAMON_SADDR=y`로 빌드, 설치, 재부팅한다. 아래 "빌드 주의"를 따른다.

## 사용

부팅만으로는 아무것도 관측하지 않는다. probe는 saddr kdamond가 시작할 때 등록된다.

```bash
K=/sys/kernel/mm/damon/admin/kdamonds
echo 1 > $K/nr_kdamonds
echo 1 > $K/0/contexts/nr_contexts
echo saddr > $K/0/contexts/0/operations
echo 1 > $K/0/contexts/0/targets/nr_targets
echo 8192 > /sys/module/saddr/parameters/samon_q_len   # 권장값, kdamond 시작 때 적용
echo on > $K/0/state
```

| debugfs (`/sys/kernel/debug/samon/`) | 내용 |
|---|---|
| `stats` | `이름=값` 누적 카운터 (부팅 이후 누적) |
| `lba_page_map` | LBA별 pfn, reads, writes, hot 여부 (엔트리가 많으면 읽는 동안 lock을 오래 잡음) |
| `streams` | Stream_Table 칸과 Loop_History 기록 |
| `wb_hist` | 최근 60초 write segment 수 (1초 단위) |

- SAMON은 saddr kdamond 하나만 가진다. 두 번째 saddr context는 경고를 남기고 probe 없이 돈다.
- saddr context에서는 DAMOS 액션이 실행되지 않는다(`apply_scheme` 없음). page를 조작하는 경로는 SAMON_Actuator 하나뿐이다.
- paddr/vaddr kdamond나 DAMON_LRU_SORT를 같이 켜는 것은 막지 않는다. 비교 측정에서는 한 번에 하나만 켠다.

## 동작 구조

```
block_rq_complete (softirq)
  ├─ 진입 분류: skip_error / skip_passthru / skip_dev / rq_seen(+ctx_*)
  ├─ segment 필터: null, anon·swapcache(direct), mapping 없음, DMA-pinned(direct) → skip_*
  ├─ LBA 트리 갱신 (4KB 단위 rbtree, read/write 카운터, 시간 창)
  ├─ 패턴 판정 (Stream_Table, Loop_History, Reread_Table) → det_pN
  └─ 토글이 켜진 패턴이면 folio_get 후 CPU별 Deferred_Queue에 넣음 → req_pN
kdamond (sample 주기마다, 프로세스 컨텍스트)
  └─ 큐 비우기: 토글 → stale → 재검증 → 실행(exec_pN) 또는 drop_*_pN, folio_put
```

## 패턴

우선순위는 P3 > P1 > P2 > P4 > P5 > P6이다. segment마다 정확히 하나로 판정한다.

| 패턴 | 조건 | 조작 | 토글 |
|---|---|---|---|
| P1 순차 read | read 흐름 칸 count ≥ `samon_seq_min` | demote (`folio_deactivate`) | `samon_act_p1` |
| P2 재읽기 | 같은 4KB LBA를 `samon_reread_ms` 안에 다시 read | promote (`folio_activate`) | `samon_act_p2` |
| P3 loop read | 같은 시작 sector의 긴 read 흐름을 다시 읽음 | 앞 `samon_loop_protect_pct`%는 promote, 나머지는 demote | `samon_act_p3` |
| P4 순차 write | write 흐름 칸 count ≥ `samon_seq_min` | demote | `samon_act_p4` |
| P5 hot write | LBA 트리 write 카운터 ≥ `samon_hot_threshold` | `folio_mark_accessed` | `samon_opt_b` |
| P6 기타 | 위에 해당 없음 | 없음 | - |

## 파라미터 (`/sys/module/saddr/parameters/`)

"즉시"는 바로 반영, "시작"은 다음 kdamond 시작 때 반영이다. 재부팅하면 기본값으로 돌아간다.

| 파라미터 | 기본 | 반영 | 의미 |
|---|---|---|---|
| `samon_act_p1`~`p4` | 0 | 즉시 | 패턴별 조작 토글 |
| `samon_opt_b` | 1 | 즉시 | P5 조작 토글 |
| `samon_dev_major`, `samon_dev_minor` | 0, 0 | 즉시 | 대상 whole disk (0이면 전체) |
| `samon_q_len` | 1024 | 시작 | CPU당 큐 칸 수. **8192 권장** (1024에서는 순차 I/O 유실 31~57%) |
| `samon_q_max_ms` | 100 | 즉시 | 큐 대기 상한. 넘으면 stale로 버림 |
| `samon_hot_threshold`, `samon_window_ms` | 10, 1000 | 즉시 | hot 판정 횟수와 창 |
| `samon_max_entries` | 65536 | 즉시 | LBA 트리 상한 (넘으면 drop_full) |
| `samon_dbg_lba` | 1 | 즉시 | 0이면 LBA 트리에 새 엔트리를 만들지 않음 → P5가 감지되지 않음 |
| `samon_seq_min` | 4 | 즉시 | P1·P4 판정 count |
| `samon_stream_new_kb` | 64 | 즉시 | 새 흐름 칸을 만드는 최소 요청 크기 |
| `samon_stream_gap_req` | 2 | 즉시 | 연장 허용 간격 = 이 값 × 요청 크기 |
| `samon_stream_idle_ms` | 1000 | 즉시 | read 칸 idle 정리 시간 |
| `samon_loop_min_kb` | 8192 | 즉시 | loop로 기록·대조할 최소 길이 |
| `samon_loop_protect_pct` | 50 | 즉시 | P3 promote 구간 비율 (0~100) |
| `samon_reread_ms` | 10000 | 즉시 | P2 재읽기 창 |
| `samon_stream_slots`, `samon_loop_slots` | 16, 16 | 시작 | 방향별 흐름 칸 수, Loop_History 칸 수 |
| `samon_reread_slots` | 65536 | 시작 | Reread_Table 칸 수 |
| `samon_dbg_nomap` | 0 | 즉시 | nomap_other segment를 dmesg에 기록할 개수 |

슬롯 수, `q_len`, `reread_slots`에는 상한 검사가 없다. 기본값 근처에서만 쓴다.

## 주요 stats 카운터

| 카운터 | 의미 |
|---|---|
| `rq_seen`, `ctx_softirq/hardirq/task` | 관측한 완료 수와 실행 컨텍스트 (ctx 합 = rq_seen) |
| `seg_buffered` | 필터를 통과한 segment 수 (= det_p1..p6 합) |
| `skip_anon`, `skip_pinned`, `skip_nomap`, `skip_dev`, `skip_passthru`, `skip_error` | 제외 사유별 개수 |
| `det_pN` | 패턴 판정 수 (토글과 무관하게 셈) |
| `req_pN`, `exec_pN`, `drop_{queue,stale,revalidate,toggle,shutdown}_pN` | 큐 회계 |
| `q_cur`, `q_max_delay_us`, `q_cap` | 큐 잔량, 최대 대기, 이번 실행의 칸 수 |
| `direct_ops` | 콜백 컨텍스트에서 LRU 조작을 시도한 수 (항상 0이어야 함) |
| `stream_{r,w}_{extend,prepend,fill,restart,new_slot,evict}` | Stream_Table 갱신 종류별 수 |
| `drop_full`, `entries` | LBA 트리 포화 수, 현재 엔트리 수 |

## 검증

```bash
sudo bash kernel/verify_samon.sh -d /var/tmp/samon_verify   # 마지막 줄 PASS=<n> FAIL=<n>, FAIL=0이면 종료 코드 0
sudo bash kernel/samon_qlen_sweep.sh -d /var/tmp/samon_verify  # q_len별 큐 유실
```

- 필요한 것: fio, filefrag, gcc, fincore(util-linux-extra). tmpfs가 아닌 디스크 위 디렉터리를 쓴다.
- 패턴 시험은 256MiB 파일 두 개와 64MiB 파일 하나를 만든다. 끝나면 kdamond를 끈 상태로 둔다.
- 판정 대상은 감지·요청·실행 건수와 회계 등식이다. page 상태 변화와 효과는 판정하지 않는다.

| 날짜 | 빌드 | 결과 |
|---|---|---|
| 2026-10-05 | #10 | 19/19 PASS |
| 2026-10-18 | #11 (S1+S2) | 37/37 PASS |
| 2026-10-18 | #12 (data 없는 bio 건너뛰기, saddr owner 하나) | 37/37 PASS, q_len 스윕 → 8192 채택 |

## 빌드 주의

- `CONFIG_DEBUG_INFO_BTF_MODULES=y`라서 vmlinux만 다시 빌드하면 모듈 BTF가 어긋난다. 그래서 `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y`로 둔다. 부팅 로그의 BTF mismatch 경고 한 줄은 정상이다.
- pahole BTF 생성에 메모리가 약 4.7GB 든다. 4GB VM에서는 실패했고 8GB에서 성공했다. 메모리가 부족하면 make에 `PAHOLE_FLAGS="--btf_gen_floats --lang_exclude=rust --skip_encoding_btf_inconsistent_proto --btf_gen_optimized"`를 준다(`-j` 제외).
- saddr는 빌트인이라 고칠 때마다 재부팅이 필요하다. 모듈 트리가 완전하면 modules_install은 생략할 수 있다.
- 설치 전에 확인할 것: bzImage 빌드 번호, vmlinux의 `.BTF` 섹션, 빌드 로그에 Killed/Error 없음.

## 알려진 한계

- 디스크 I/O가 생긴 page만 보인다. 캐시 히트는 관측되지 않는다.
- direct I/O는 folio 상태(anon, pinned)로만 거른다. 상위 플래그는 block layer에서 볼 수 없다.
- 이 VM은 완료가 CPU1 하나에 몰려서 CPU별 큐 중 하나만 쓰인다. `q_len` 1024에서는 순차 I/O 유실이 크다.
- 큐에 있는 항목은 folio 참조를 잡고 있다. 그래서 최대 `samon_q_max_ms` 동안 page 해제가 미뤄질 수 있다.
- LBA 트리 엔트리는 만료되지 않는다(aging 없음). 포화되면 kdamond를 껐다 켤 때까지 새 LBA가 기록되지 않는다.
- 흐름 칸 16개, Loop_History 16개라서 extent가 많이 흩어진 긴 loop는 앞부분이 P3 대신 P1로 잡힌다. 시연에서 8MiB extent 30개 이상인 256MiB 파일로 관찰했다.
- MGLRU에서 P5(`folio_mark_accessed`)는 참조 카운트만 올린다. classic LRU에서 demote는 이미 active인 page에만 작용한다.
- 메모리 압박이 없으면 LRU 위치만 바뀌고 캐시 내용은 달라지지 않는다.

## 남은 작업

| 단계 | 내용 | 상태 |
|---|---|---|
| S0 | block trace 수집, 오프라인 재현 보고서 | 파서와 규칙 엔진만 구현. 보고서·CLI 미구현, 수집 미실행 |
| S4 | 측정 하네스 (off / DAMON_LRU_SORT / SAMON) | 구현, 로컬 시험만 통과. 커밋 전 |
| S5 | soak, 1차 측정, 평가 문서 | 미착수 |
| S6 | 문서 정리 | 미착수 |
| 후속 | 엔트리 aging, 영역 단위 집계, 정책 판단 | 미구현 |

범위 밖: 점수 등급 체계, DAMOS 연동, DAMON과 SAMON의 한 context 통합.
