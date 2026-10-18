# SAMON 커널 operations set (saddr)

Linux 커널 6.8의 DAMON operations set으로 구현한 스토리지(블록 디바이스) 주소 공간 관측 코드이다. block layer에서 완료된 I/O를 LBA 단위로 관측하고, read/write 빈도수로 자주 발생하는 I/O를 판정하며, 해당 LBA를 실제 page(PFN)와 정방향으로 연결한다. 현재 Verify_Script로 확인한 page 조작은 hot write(P5)에 `folio_mark_accessed()`를 호출하는 힌트 한 가지뿐이며 그 효과는 측정하지 않았다. S1부터 이 호출은 block 완료 콜백에서 직접 하지 않고, 콜백이 요청만 큐(Deferred_Queue)에 넣으면 kdamond가 프로세스 컨텍스트에서 실행한다. S2는 segment마다 패턴 P1~P6 중 하나를 판정하고, P1~P4에는 `folio_activate()`(promote) 또는 `folio_deactivate()`(demote) 요청을 같은 큐로 보내는 코드를 더했다. 이 지연 경로와 패턴 감지는 구현되어 있으나 아직 Verify_Script로 검증하지 않았다(구현됨, 미검증). 패턴별 조작 토글 samon_act_p1~p4의 기본값은 0(끔)이다.

eBPF 기반 유저스페이스 스크립트(samon_probe.py, samon_monitor.py 등)는 이 구현의 기반이 아니다. 이 디렉터리의 코드는 모두 커널 내부(mm/damon/saddr.c)에서 동작한다.

## 현재 구현 범위 한눈에 보기

상태 값은 PASS, FAIL, 미검증, 미실행, 기각, 구현됨(미검증), 미구현만 쓴다. PASS는 현재 설치된 커널 빌드에서 Verify_Script 항목이 PASS한 기능에만 붙인다.

| 구분 | 상태 |
|---|---|
| 관측 (block_rq_complete, buffered I/O 한정, 디스크 필터) | 구현, 기존 Verify 항목 PASS (#11, 19/19) |
| LBA to page 정방향 연동 (4KB 단위 rbtree, PFN 기록) | 구현, 기존 Verify 항목 PASS (#11, 19/19) |
| 빈도 판정 (read/write 분리 카운터, 시간 창, 단일 임계값) | 구현, 기존 Verify 항목 PASS (#11, 19/19) |
| 진입 계측 (skip_error, skip_passthru, ctx_hardirq/softirq/task) | 구현됨, 미검증 (Verify 항목 없음) |
| 지연 조작 구조 (Deferred_Queue, SAMON_Actuator, 큐 회계 카운터 req/exec/drop) | 구현됨, 미검증 (Verify 항목 없음) |
| page 조작 (hot write에 folio_mark_accessed, P5 요청을 큐에 넣고 kdamond가 실행) | 구현됨, 미검증. 옵션 B 토글(samon_opt_b)은 기존 Verify 항목이 #11에서 PASS했으나 지연 경로의 실행 컨텍스트와 효과는 미검증 |
| 패턴 감지 P1~P6 (S2: Stream_Table, Loop_History, Reread_Table, 패턴 분류 우선순위) | 구현됨, 미검증 (Verify 항목 없음) |
| 패턴별 조작 (S2: samon_act_p1~p4 토글, P1/P4 demote, P2 promote, P3 promote/demote 분할) | 구현됨, 미검증 (토글 기본값 0, 동작 시험과 효과 측정 없음) |
| 관측용 debugfs 확장 (S2: streams, wb_hist, stream_* stats 줄) | 구현됨, 미검증 |
| 영역(region) 단위 집계, 엔트리 aging | 미구현 |
| 정책 판단(promote/유지/demote를 자동으로 고르는 정책, 폴백), 효과 있는 read 쪽 조작 | 미구현 (토글로 켜는 고정 규칙 조작만 코드에 있고 미검증) |
| 점수 체계, DAMOS 연동 | 미구현 (범위 밖) |
| 효과 측정 | 하네스 스크립트만 있고 실행하지 않음 |

## 파일

| 파일 | 설명 |
|---|---|
| saddr.c | operations set 본체. mm/damon/saddr.c로 배치한다. |
| damon_Makefile | mm/damon/Makefile 대체본 (CONFIG_DAMON_SADDR 추가) |
| damon_Kconfig | mm/damon/Kconfig 대체본 (CONFIG_DAMON_SADDR 추가) |
| verify_samon.sh | 기능 검증 스크립트 (root 권한, 재부팅 후 실행) |
| test_pinned.c | verify_samon.sh가 컴파일해서 쓰는 테스트. mmap한 파일 페이지를 소스로 하는 O_DIRECT write |
| ../bench/samon_bench.sh, ../bench/summarize.py | 측정 하네스 (아래 참조) |

## 적용 방법

1. saddr.c를 mm/damon/saddr.c로 복사한다.
2. mm/damon/Makefile을 damon_Makefile로, mm/damon/Kconfig를 damon_Kconfig로 교체한다.
3. include/linux/damon.h의 enum damon_ops_id에 DAMON_OPS_SADDR을 추가한다 (NR_DAMON_OPS 앞).
4. mm/damon/sysfs.c의 damon_sysfs_ops_strs[]에 "saddr"를 추가한다.
5. .config에 CONFIG_DAMON_SADDR=y를 설정하고 커널을 빌드, 설치, 재부팅한다. 빌드 시 주의사항은 아래 "빌드 시 주의"를 따른다.
6. 재부팅할 때마다 kdamond를 saddr operations로 설정하고 켠다 (아래 사용법 참조). tracepoint는 kdamond가 시작될 때 등록되므로 부팅만으로는 관측이 시작되지 않는다.

## 사용법

```bash
echo 1 > /sys/kernel/mm/damon/admin/kdamonds/nr_kdamonds
echo 1 > /sys/kernel/mm/damon/admin/kdamonds/0/contexts/nr_contexts
echo saddr > /sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/operations
echo 1 > /sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/targets/nr_targets
echo on > /sys/kernel/mm/damon/admin/kdamonds/0/state

cat /sys/kernel/debug/samon/lba_page_map
cat /sys/kernel/debug/samon/stats
```

모듈 파라미터 (빌트인이므로 /sys/module/saddr/parameters/ 에서 런타임 변경 가능, 재부팅하면 기본값으로 돌아간다):

| 파라미터 | 기본값 | 의미 |
|---|---|---|
| samon_hot_threshold | 10 | 윈도우 안에서 이 횟수 이상 발생하면 hot으로 판정 |
| samon_window_ms | 1000 | 빈도수를 세는 관측 윈도우(ms) |
| samon_opt_b | 1 | 옵션 B 토글(P5 동작). 0이면 hot write에서도 folio_mark_accessed() 요청을 큐에 넣지 않는다 (효과 비교용). 즉시 반영 |
| samon_q_len | 1024 | CPU마다 두는 Deferred_Queue 칸 수 (1 이상, 0은 거부). 다음 kdamond 시작 때 적용 |
| samon_q_max_ms | 100 | 큐에서 이 시간(ms) 넘게 기다린 항목은 실행하지 않고 stale로 버린다. 즉시 반영 |
| samon_dev_major, samon_dev_minor | 0, 0 | 관측 대상 디스크(whole disk의 major, first_minor). major가 0이면 모든 디바이스를 관측한다 |
| samon_max_entries | 65536 | LBA 트리에 보관하는 엔트리 상한 (메모리 상한) |
| samon_dbg_nomap | 0 | nomap_other 부류의 segment를 누적 개수가 이 값 이하인 동안 dmesg에 기록, 0이면 끔 |

S2가 추가한 파라미터 (모두 구현됨, 미검증이며 기본값은 saddr.c의 SAMON_DEF_* 상수와 선언에서 가져왔다). "즉시"는 읽을 때마다 반영, "다음 시작"은 kdamond를 다시 켤 때 반영한다.
| 파라미터 | 기본값 | 허용 범위 | 반영 시점 | 의미 |
|---|---|---|---|---|
| samon_act_p1, p2, p3, p4 | 0, 0, 0, 0 | 0 또는 1 | 즉시 | 패턴별 조작 토글. 0이면 감지와 집계만 하고 요청을 큐에 넣지 않으며, 큐에서 꺼낼 때도 다시 확인한다. P5는 samon_opt_b를 따른다 |
| samon_dbg_lba | 1 | 0 또는 1 | 즉시 | 0이면 LBA 트리에 새 엔트리를 만들지 않고 조회만 한다. 이 경우 새 엔트리가 없어 **P5는 감지되지 않고** 해당 write segment는 P6이 된다 (아래 "9. 패턴 감지" 참조) |
| samon_seq_min | 4 | 제한 없음 | 즉시 | Stream_Table 칸의 연속 요청 수(count)가 이 값 이상이면 그 칸의 요청을 P1(read) 또는 P4(write)로 판정 |
| samon_stream_new_kb | 64 | 제한 없음 | 즉시 | 맞는 칸이 없을 때 새 칸을 시작할 수 있는 최소 요청 크기(KiB) |
| samon_stream_gap_req | 2 | 제한 없음 | 즉시 | 허용 간격 gap = 이 값 x 완료된 요청 크기. extend, prepend, fill 판정에 쓴다 |
| samon_stream_idle_ms | 1000 | 제한 없음 | 즉시 | read 칸이 이 시간(ms) 동안 갱신되지 않으면 idle로 보고, 길이가 충분하면 Loop_History에 기록한 뒤 비운다 |
| samon_loop_min_kb | 8192 | 제한 없음 | 즉시 | Loop_History에 기록하고 loop로 대조할 read 스트림의 최소 길이(KiB) |
| samon_loop_protect_pct | 50 | 0~100 | 즉시 | P3: loop 범위 앞쪽 이 퍼센트는 promote, 나머지는 demote |
| samon_reread_ms | 10000 | 제한 없음 | 즉시 | 같은 4KB LBA를 이 시간(ms) 안에 다시 read하면 P2 (재읽기) |
| samon_stream_slots | 16 | 1 이상 (0 거부) | 다음 시작 | 방향(read, write)마다 Stream_Table 칸 수 |
| samon_loop_slots | 16 | 1 이상 (0 거부) | 다음 시작 | Loop_History 칸 수 |
| samon_reread_slots | 65536 | 1 이상 (0 거부) | 다음 시작 | Reread_Table 칸 수 (칸당 16바이트 이하) |
참고: "제한 없음" 파라미터는 코드가 범위를 검사하지 않는다. saddr.c 주석에 따르면 samon_stream_slots, samon_loop_slots(16/16)와 samon_seq_min, samon_stream_new_kb, samon_stream_gap_req, samon_stream_idle_ms는 User가 부록 A 제안값으로 확정했고(2026-10-18), 나머지 S2 기본값은 부록 A 제안값으로 User 확정 전이다. S0 수집 결과(7.x)는 아직 없어서 어떤 기본값도 측정으로 뒷받침되지 않는다.

## 구현 내용

### 1. 관측 훅지점
- block_rq_complete tracepoint에 register_trace_block_rq_complete()로 콜백을 등록한다.
- 콜백 진입 때 완료 하나를 아래 네 부류 중 정확히 하나로 센다 (kdamond 등록 구간 안에서만). (1) 완료 에러(error != 0)는 skip_error, (2) passthrough request(blk_rq_is_passthrough)는 skip_passthru, (3) 대상 디스크 필터에 맞지 않으면 skip_dev, (4) 나머지는 rq_seen이며 이 경우 실행 컨텍스트에 따라 ctx_hardirq, ctx_softirq, ctx_task 중 하나를 센다. 따라서 ctx_hardirq + ctx_softirq + ctx_task = rq_seen이어야 한다 (이 등식은 아직 Verify 항목이 아니다).
- rq_data_dir()로 READ/WRITE를 구분한다.
- 부분 완료 처리: 이 tracepoint는 blk_update_request() 맨 앞에서 bio_advance()/bio_endio() 이전에 발화하며, request가 여러 번에 나뉘어 완료되면 그때마다 발화한다. 콜백은 nr_bytes만큼의 segment만 순회해서 같은 segment를 중복 집계하지 않는다. nr_bytes가 request 전체보다 작았던 횟수는 stats의 budget_cut에 기록한다.
- 대상 디스크 필터(samon_dev_major/minor)에 맞지 않는 request는 skip_dev로 세고 건너뛴다.
- 이 훅은 block 완료 경로(softirq 또는 인터럽트 컨텍스트일 수 있음)에서 실행된다. 실제 컨텍스트 분포는 아래 "진입 컨텍스트 분포"에 기록한다.

#### 진입 컨텍스트 분포 (S1 계측)

- 커널: 6.8.0-SAMON #11 (S1+S2 합본 빌드). 대상 디스크: sda (samon_dev_major:samon_dev_minor = 8:0, 이 VM에서 verify_samon.sh가 지정한 값)
- 기록 출처: `sudo bash kernel/verify_samon.sh` 실행 출력(/tmp/samon_13_2_verify.log, 2026-10-18)의 마지막 stats 스냅샷. kdamond를 다시 시작한 뒤부터 그 실행이 끝날 때까지의 **누적값**이다. 워크로드별 차분이 아니며, 이 실행에는 4MB buffered write, direct write, test_pinned, 옵션 B 토글, kdamond off/on 10회 반복, fsync x50이 섞여 있다.

| 구간 | rq_seen | ctx_hardirq | ctx_softirq | ctx_task | skip_error | skip_passthru | skip_dev |
|---|---|---|---|---|---|---|---|
| Verify 실행 전체 누적 (#11) | 2301 | 0 | 2301 | 0 | 0 | 14 | 10 |
| buffered write 차분 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 |
| buffered read 차분 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 |
| fsync 차분 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 | 미실행 |

- 워크로드별 차분 세 행은 값이 이 저장소와 작업 기록에 없어 채우지 않았다 (미실행 또는 미보고). 측정 명령은 워크로드마다 `/sys/kernel/debug/samon/stats` 전후 스냅샷을 찍고 위 일곱 항목의 차분을 구하면 된다. 예: buffered write는 `dd if=/dev/zero of=<DIR>/w bs=1M count=64 conv=fsync`, buffered read는 캐시를 비운 뒤 `dd if=<DIR>/w of=/dev/null bs=1M`, fsync는 4KB write 후 `fsync`를 50회 반복한다 (명령은 예시이며 아직 실행하지 않았다).
- 누적 행에서 ctx 합(2301) = rq_seen(2301)이다. 이는 한 번의 관찰이며 Verify 항목이 아니므로 등식의 PASS 근거로 쓰지 않는다 (미검증).
- 누적 행에서 ctx_hardirq = 0, ctx_task = 0이고 전부 softirq였다. 이 VM(VMware, SCSI)의 한 번 실행 결과이며 다른 디스크 드라이버에서의 분포는 확인하지 않았다.
- skip_passthru 14의 출처 디바이스는 확인하지 않았다. 이전에 nomap_other로 섞여 세던 sr 폴링(REQ_OP_DRV_IN)이 여기로 분리된다는 것이 예상이지만, 같은 실행의 nomap_other = 0이라는 사실만 확인했고 14건이 sr0/sr1 것이라는 직접 증거는 없다. 10초 무 I/O 구간의 skip_passthru ≥ 1은 S3 Verify 항목(미작성)으로 남아 있다.

### 2. bio에서 page 추출
- request에 연결된 bio를 __rq_for_each_bio()로 순회하고, bio_for_each_segment()로 bi_io_vec의 각 segment에 접근한다.
- LBA는 bio->bi_iter.bi_sector(512바이트 섹터)에서 시작해 segment마다 bv_len >> SECTOR_SHIFT 만큼 누적한다.

### 3. buffered I/O 한정 필터 (segment 단위)
segment마다 다음을 검사하고, 하나라도 해당하면 건너뛰며 사유별로 센다.

| 검사 | 건너뛰는 이유 | 통계 항목 |
|---|---|---|
| bv_page가 NULL | 유효하지 않은 page | skip_null |
| folio가 anon 또는 swapcache | direct I/O의 사용자 버퍼, swap I/O | skip_anon |
| address_space가 없음 | page cache와 무관 | skip_nomap |
| folio_maybe_dma_pinned() | direct I/O는 사용자 버퍼를 pin하므로, mmap된 파일 버퍼를 쓰는 direct I/O도 걸러진다 | skip_pinned |

skip_nomap은 원인별로 다시 분류해서 센다. 네 부류(nomap_slab, nomap_flagged, nomap_meta, nomap_other)의 합은 항상 skip_nomap과 같고, nomap_write는 이 중 WRITE 방향의 개수이다.

| 카운터 | 의미 |
|---|---|
| nomap_slab | slab에서 할당된 버퍼 |
| nomap_flagged | mapping에 movable/KSM 플래그가 있음 |
| nomap_meta | mapping이 NULL이고 REQ_META가 설정됨 |
| nomap_other | mapping이 NULL이고 REQ_META도 없음 |

nomap의 정체에 대한 확인 결과:

- "nomap은 ext4 저널(jbd2) I/O일 것"이라는 가설은 측정으로 기각되었다 (커널 #10, fsync 50회 후 nomap_meta +0, nomap_write +0). 저널 블록은 블록 디바이스 page cache에 mapping이 있어 일반 관측 대상으로 기록되는 것으로 보이나, 이를 직접 확인하지는 않았다.
- nomap_other는 samon_dbg_nomap 로그로 확인했다. 기록된 segment는 모두 dir=R, opf=0x22, sector=0, 데이터 page가 아닌 커널 내부 버퍼(refcount=1)였다. opf 하위 8비트 0x22(34)는 REQ_OP_DRV_IN이며 drivers/scsi/sr.c(CD-ROM 드라이버)가 이 op로 명령을 보낸다. 발생 주기는 약 2.05초마다 2건이었고, 이 VM에는 media_change 폴링 대상 CD-ROM(sr0, sr1)이 2개 있다. 따라서 CD-ROM 미디어 변경 감지 폴링으로 판단한다.
- 한계: 로그에 디바이스 이름이 없어 두 CD-ROM에서 나온다는 것을 직접 확인한 것은 아니고 정황(op 코드, 호출 위치, 주기와 개수)의 일치에 근거한다. 이 부류는 page cache I/O가 아니므로 관측 대상에서 제외되는 것이 맞다.
- 필터(samon_dev_major=8)를 켠 뒤 nomap_other가 +8 늘어난 것을 한때 sda에서도 nomap이 나오는 증거로 해석했으나, 폴링 주기(약 1건/초)와 필터를 켜기까지의 시간으로 설명되므로 그 해석은 철회했다.
- 이전 실행에서 보였던 수만 건의 nomap은 이 폴링만으로 설명되지 않는다(1초에 약 1건 수준). 그 값이 어디서 나왔는지는 확인하지 못했다.
- passthrough request(blk_rq_is_passthrough)는 S1에서 콜백 진입 단계에서 별도 카운터 skip_passthru로 분리했다(구현됨, 미검증). 이 빌드에서는 passthrough request가 segment 검사까지 오지 않으므로 nomap_other에 섞이지 않는다. 위 nomap_other 관찰은 분리 이전 빌드(#10)의 결과이다.

### 4. LBA to page 연동 자료구조
- LBA를 키로 하는 rbtree. 엔트리는 lba, pfn, read_count, write_count, last_jiffies를 가진다. 엔트리는 4KB segment 단위이며 영역(region) 단위 집계는 하지 않는다.
- struct page 포인터는 저장하지 않고 PFN만 저장한다.
- spinlock(irqsave)으로 보호한다. 콜백 안에서는 GFP_ATOMIC만 사용한다.
- 엔트리 수는 samon_max_entries로 제한한다 (초과 시 drop_full 증가).

### 5. 빈도수 기반 판정
- read/write 카운터를 분리해서 센다.
- 윈도우(samon_window_ms)가 지나면 카운터를 0으로 리셋한다.
- 방향별 카운터가 samon_hot_threshold 이상이면 hot으로 판정한다 (이진 판정). 순차/반복 같은 패턴 분류는 S2에서 별도 구조로 추가했고(9절, 구현됨, 미검증), 점수 등급 체계는 구현하지 않았다.

### 6. 옵션 B (미래 접근 예측 반영)
- hot으로 판정된 write completion에서 folio_mark_accessed()를 호출한다. 기존 커널 API만 사용하며 커널 소스는 수정하지 않는다.
- read는 관측만 한다. read 시점 힌트의 효과는 측정으로 판단할 사안으로 남겨 둔다. read 완료 시점의 page는 LRU에 올라가 있지만 사용자 접근 전이다.
- samon_opt_b 파라미터로 호출을 끌 수 있어, 켠 경우와 끈 경우를 같은 워크로드로 비교할 수 있다. 호출 횟수는 stats의 mark_accessed에 기록한다.
- S1 변경 (구현됨, 미검증): 콜백은 더 이상 folio_mark_accessed()를 직접 호출하지 않는다. hot write(P5)로 판정하면 folio_get()으로 참조를 잡고 CPU별 Deferred_Queue에 요청을 넣는다. kdamond가 한 샘플링 주기의 맨 앞(damon_sa_prepare_access_checks)에서 큐를 비우며(SAMON_Actuator), 항목마다 토글, stale(samon_q_max_ms), 재검증(LRU 상태, dirty/writeback 등) 순으로 확인한 뒤 실행하고 참조를 놓는다. page를 조작하는 지점은 이 경로 하나뿐이고, 프로세스가 아닌 컨텍스트에서 호출되면 실행하지 않고 direct_ops만 올린다. 큐가 가득 차면 항목을 버리고 drop_queue_p5로 센다.
- 아래는 S1 이전 구조(콜백 직접 호출)에 대한 안전성 우려이다. 지연 경로로 바꾼 뒤에도 이 우려가 해소됐다는 검증은 하지 않았다 (미검증).
- 호출 컨텍스트 안전성 (미검증): folio_mark_accessed()는 내부에서 folio_activate()를 호출하고, 이 함수는 mm/swap.c에서 local_lock(&cpu_fbatches.lock)(인터럽트를 막지 않는 형태)을 쓴다. 이 훅은 softirq/인터럽트 컨텍스트에서 실행될 수 있으므로, 프로세스가 같은 per-CPU 배치를 갱신하는 도중에 끼어들면 배치가 손상될 가능성이 있다. 지금까지 경고나 이상은 관찰되지 않았지만 lockdep 등 엄격한 검사 빌드로 확인한 적이 없어, 안전하다고 확인된 것이 아니다. 해결 방향은 콜백에서는 기록만 하고 조작은 프로세스 컨텍스트로 지연 실행하는 것이다.

### 7. 안정성 처리
- kdamond를 재시작해도 tracepoint가 중복 등록되지 않도록 등록 상태 플래그를 둔다.
- cleanup은 unregister 후 tracepoint_synchronize_unregister()를 호출한 뒤 큐에 남은 항목을 drop_shutdown_pN으로 세며 folio 참조를 놓고(shutdown), 그 다음 트리와 큐를 해제한다. 큐 메모리 할당에 실패하면 probe를 등록하지 않는다 (구현됨, 미검증).
- 큐 회계: 패턴 N마다 req_pN = exec_pN + drop_*_pN 합 + 아직 끝나지 않은 항목(q_cur)이어야 한다. 이 등식을 Verify_Script로 확인하는 항목은 아직 없다 (미검증).
- 기존 region 카운터 경로의 nr_regions는 READ_ONCE/WRITE_ONCE로 읽고 쓰며, 읽을 때 배열 크기로 clamp하여 동시 갱신 중에도 범위 밖 접근이 생기지 않게 한다.

### 8. 관측용 debugfs
- /sys/kernel/debug/samon/lba_page_map: 엔트리별 lba, pfn, reads, writes, hot_r, hot_w
- /sys/kernel/debug/samon/stats: `이름=값` 한 줄씩. rq_seen, seg_buffered, skip_null, skip_anon, skip_nomap(nomap_slab, nomap_flagged, nomap_meta, nomap_other, nomap_write), skip_pinned, skip_dev, budget_cut, mark_accessed(req_p5의 별칭), 진입 계측(skip_error, skip_passthru, ctx_hardirq, ctx_softirq, ctx_task), 패턴 감지 det_pN, 큐 회계(req_pN, exec_pN, drop_<queue|stale|revalidate|toggle|shutdown>_pN, q_cur, q_max_delay_us, q_cap, direct_ops), 마지막 줄 `entries=<n> max_entries=<n>`. 값은 부팅 이후 누적이며 kdamond를 다시 시작해도 0으로 돌아가지 않는다.
- seg_buffered의 정의가 바뀌었다. 이전에는 SAMON_Map(LBA 트리)에 항목이 생긴 segment만 셌다. 지금은 SAMON_Filter(error, passthrough, 대상 디스크, 그리고 segment 단위의 null/anon/no-mapping/pinned 검사)를 통과한 모든 segment를 센다. 트리가 가득 차서 새 항목을 못 만든 segment(drop_full)와 메모리 부족으로 못 만든 segment(drop_nomem)도 포함한다. 그래서 값이 이전 빌드보다 클 수 있고, 빌드 간 직접 비교는 하지 않는다. #11 Verify 출력에서 seg_buffered(22823)는 det_p1..det_p6의 합(2885 + 0 + 0 + 1346 + 18 + 18574 = 22823)과 같았다. 이는 한 번의 관찰이며 Verify 항목이 아니다 (미검증).
- S2가 추가한 stats 줄과 debugfs 파일(streams, wb_hist)은 9절에 적었다.

### 9. 패턴 감지 (S2, 구현됨, 미검증)

이 절의 모든 기능은 saddr.c에 구현되어 #11 빌드에 들어 있으나, #11에서 통과한 Verify 19개 항목은 이 기능을 확인하지 않는다. 따라서 이 절의 어떤 항목도 PASS가 아니다.

#### 패턴 판정

segment마다 정확히 하나의 패턴을 판정하고 det_pN을 센다(토글과 무관하게 센다). 우선순위는 P3 > P1 > P2 > P4 > P5 > P6이다. SAMON_Filter를 통과한 segment만 대상이며, devt를 알 수 없거나(0) 표와 큐가 준비되지 않았으면 판정하지 않는다.

| 패턴 | 방향 | 조건 | 조작 (토글을 켠 경우) |
|---|---|---|---|
| P1 | read | 순차 read 흐름: 속한 Stream_Table 칸의 count가 samon_seq_min 이상 | demote (folio_deactivate) |
| P2 | read | 재읽기: Reread_Table에서 같은 4KB LBA가 samon_reread_ms 안에 다시 읽힘 | promote (folio_activate) |
| P3 | read | loop 읽기: 칸이 loop 표시됨 (같은 시작 sector의 긴 read 스트림을 다시 읽음). 칸 시작에서 거리 d가 `100*d < L*samon_loop_protect_pct`이면 promote, 아니면 demote | promote 또는 demote |
| P4 | write | 순차 write 흐름: write 칸의 count가 samon_seq_min 이상 | demote (folio_deactivate) |
| P5 | write | LBA 트리 엔트리가 있고 write 카운터가 samon_hot_threshold 이상 (hot write) | folio_mark_accessed (samon_opt_b) |
| P6 | 둘 다 | 위에 해당하지 않음 | 없음 |

- P3는 칸의 count와 상관없이 loop 표시만으로 판정한다. Reread_Table은 P3도 P1도 아닌 read segment에서만 조회하고 덮어쓴다.
- **samon_dbg_lba = 0이면 P5는 감지되지 않는다.** P5는 LBA 트리에 write 카운터가 쌓인 엔트리가 있어야 하는데, 0이면 새 엔트리를 만들지 않고 조회만 하므로 엔트리가 없는 write segment는 P6이 된다. samon_dbg_lba가 1일 때 이미 만들어진 엔트리는 kdamond를 끌 때까지 계속 갱신된다.

#### Stream_Table

- 방향(read, write)마다 samon_stream_slots개의 칸. 칸은 dev, start, end, count, t_start, t_last, loop, loop_len(L), 주기를 가진다. spinlock 하나(samon_pat_lock)가 세 표(Stream_Table, Loop_History, Reread_Table)를 보호한다.
- request마다 첫 통과 segment에서 한 번만 갱신한다. 같은 dev의 사용 중인 칸을 index 순으로 훑고 gap = samon_stream_gap_req x n(n은 완료된 sector 수)으로 아래를 가른다. 비교에 뺄셈을 쓰지 않는다.
  - extend: `s >= end && s <= end + gap` (end를 e로 늘림)
  - prepend: `e <= start && e + gap >= start` (start를 s로 당김)
  - fill: `start <= s && e <= end && s + gap >= end` (경계 불변, count만 증가)
  - restart: `start <= s && e <= end && s + gap < end` (칸 안쪽의 되돌아간 위치)
- 고르는 순서는 extend > prepend > fill이고 같은 종류 안에서는 count가 큰 칸, t_last가 최근인 칸, 작은 index 순이다. 고른 칸의 count를 올리고 t_last를 갱신한다.
- 셋 다 없으면 새 칸 후보다. restart 칸이 하나 이상 있으면 stream_X_restart를 request당 1회 세고 그 칸들은 바꾸지 않는다. 요청 크기가 samon_stream_new_kb x 2 sector 이상이면 새 칸을 만든다(빈 칸 중 가장 작은 index, 없으면 count가 가장 작은 칸, 같으면 t_last가 오래된 칸, 같으면 작은 index를 교체하고 stream_X_evict를 센다). 그보다 작으면 표를 바꾸지 않고 흐름 없음으로 둔다.
- 칸 교체나 비움 직전에 read 칸의 길이가 samon_loop_min_kb x 2 sector 이상이면 Loop_History에 기록한다.

#### Loop_History

- samon_loop_slots개의 칸을 가진 원형 기록. 기록되는 값은 dev, start, end, t_start이다.
- 새 read 칸이 만들어질 때 같은 dev, 같은 start의 (b) 살아 있는 read 칸(길이가 최소 길이 이상)과 (a) Loop_History 기록을 대조한다. 둘 다 맞으면 (b)를 우선하고 같은 쪽 안에서는 t_start가 최신인 것을 고른다. 맞으면 새 칸에 loop 표시, L, 주기를 넣는다. (b)를 쓰면 옛 칸을 기록 후 비우고 (a) 기록은 지우지 않는다.
- idle 정리: kdamond가 샘플링 주기 맨 앞에서 큐를 비운 다음, samon_stream_idle_ms 동안 갱신되지 않은 read 칸을 길이가 충분하면 Loop_History에 기록하고 비운다.

#### Reread_Table

- samon_reread_slots개의 칸(칸당 16바이트 이하)을 가진 해시 표. 키는 `lba4k ^ (dev_t << 40)`, 칸 번호는 hash_64와 reciprocal_scale로 구한다. 저장된 dev와 lba4k가 같고 시각 차가 samon_reread_ms 이하일 때 hit이다. 조회한 칸은 hit 여부와 상관없이 현재 키와 시각으로 덮어쓴다.

#### debugfs와 stats 확장

- /sys/kernel/debug/samon/streams: 첫 줄 `# now=<jiffies> stream_slots=<n> loop_slots=<n>`, 이어서 사용 중인 칸마다 `stream dir=<r|w> idx= dev= start= end= count= t_start= t_last= loop= L= period_ms=`, 기록된 Loop_History 칸마다 `loop idx= dev= start= end= t_start=`. kdamond가 꺼져 표가 없으면 머리 줄만 나오고 slots는 0이다.
- /sys/kernel/debug/samon/wb_hist: SAMON_Filter를 통과한 write segment 수를 1초 단위 60칸으로 보여 준다. 첫 줄은 설명 주석이고, 이어서 오래된 구간부터 `t=-59 writes=<n>` ... `t=0 writes=<n>`(t=0은 진행 중인 현재 초)을 출력한다. 분류나 큐에는 쓰지 않는 관측 전용이다.
- stats의 stream_* 줄: `stream_r_<종류>`가 먼저, `stream_w_<종류>`가 뒤에 온다. 종류 순서는 extend, prepend, fill, restart, new_slot, evict이고 모두 12줄이다. 값은 부팅 이후 누적이다. 패턴별 det_p1..det_p6와 큐 회계 줄(req_pN 등)은 8절에 있다.

#### 검증 상태 (S2)

Verify 항목이 없어서 위 모든 기능이 구현됨, 미검증이다. #11의 Verify 19/19 PASS는 이 기능과 무관하다. 참고 관찰 하나: #11 Verify 실행 출력의 마지막 stats에서 det_p1..det_p6는 2885, 0, 0, 1346, 18, 18574였다(8절의 seg_buffered 합과 일치). 이 값이 의도한 패턴 판정의 결과인지는 확인하지 않았다.

## 검증 상태

PASS는 실제 커널에서 Verify_Script로 실행한 결과가 있는 항목만 해당한다. 아래 표의 PASS 행은 #11(현재 설치된 빌드)의 19/19 PASS에도 포함된다. 환경은 VMware VM, ext4(/dev/sda2, 파티션 시작 섹터 4096, 블록 4096바이트), 메모리 8GB이며 커널 6.8.0-SAMON이다.

### 항목별 상태

| 항목 | 상태 | 근거 (커널 빌드, 방식, 결과) |
|---|---|---|
| tracepoint 등록, stats/debugfs 노출 | PASS | #8 이후 매 실행; #11 Verify 재확인 PASS |
| LBA와 파일 물리 위치 일치 | PASS | 4MB buffered write 후 filefrag -e의 physical 블록을 섹터로 변환(블록 크기 / 512배 + 파티션 시작 섹터)해 lba_page_map과 비교, 1024개 중 1024개 일치 (#8, #9, #10 모두 동일); #11 Verify 재확인 PASS |
| direct I/O 배제 (anon 경로) | PASS | fio --direct=1 4MB write, 해당 파일 섹터와 맵의 교집합 0개, skip_anon +1024; #11 Verify 재확인 PASS |
| direct I/O 배제 (pin 경로) | PASS | test_pinned(mmap 소스 O_DIRECT 1MiB), skip_pinned +256, 대상 섹터 0개 (#9); #11 Verify 재확인 PASS |
| hot 판정 | PASS | threshold(10) 이상 반복 write 후 hot_w=1; #11 Verify 재확인 PASS |
| 윈도우 리셋 | PASS | 윈도우(1000ms) 경과 후 writes=1로 리셋; #11 Verify 재확인 PASS |
| read/write 카운터 분리 | PASS (#8~#10), #11 전용 항목 없음 | reads/writes 열 확인 |
| 옵션 B 토글 | PASS | samon_opt_b=0이면 mark_accessed +0, 1이면 +6 (#9); #11 Verify 재확인 PASS |
| 대상 디스크 필터 | PASS | 존재하지 않는 디스크로 지정 시 rq_seen +0, skip_dev 증가. 실제 디스크(sda 8:0) 지정 시 관측됨 (#9); #11 Verify 재확인 PASS |
| kdamond off/on 10회 반복 | PASS | 매 stop마다 entries=0, 쓴 파일의 LBA별 writes 최댓값 1(probe 중복 등록 없음), 커널 경고(BUG/WARNING/Oops/lockdep/RCU stall/soft lockup) 없음 (#9); #11 Verify 재확인 PASS |
| nomap 분류 카운터 일관성 | PASS | 네 부류의 합이 skip_nomap과 일치 (#10); #11 Verify 재확인 PASS |
| nomap_other의 정체 | 정황 근거로 판단 | REQ_OP_DRV_IN, sr 드라이버, 약 2초 주기 2건. 디바이스 이름 직접 확인은 못 함 |
| 부분 완료(nr_bytes 반영) 경로 | **미검증** | 코드 반영, #11 Verify 실행에서도 budget_cut=0으로 한 번도 실행되지 않음 |
| 에러 completion 경로 | **미검증** | skip_error 카운터는 S1에서 추가했으나(구현됨) 에러 주입 실험을 하지 않았다. #11 Verify 실행에서 skip_error=0 |
| 진입 계측 등식 (ctx 합 = rq_seen) | **미검증** | 구현됨. #11 Verify 실행 누적에서 2301 = 2301이었으나 Verify 항목이 없고 한 번의 관찰이다 |
| skip_passthru 분리 | **미검증** | 구현됨. #11 Verify 실행 누적에서 skip_passthru=14, 출처 디바이스는 미확인. Verify 항목 없음 |
| Deferred_Queue와 SAMON_Actuator (지연 조작) | **미검증** | 구현됨. #11 Verify 실행 누적에서 req_p5 = exec_p5 = 12, drop 전부 0, q_cur = 0이었으나 Verify 항목이 없는 한 번의 관찰이다 |
| 패턴 감지 P1~P6 (Stream_Table, Loop_History, Reread_Table, 우선순위) | **미검증** | 구현됨 (S2, 9절). #11 Verify 실행 누적에서 det_p1..p6 = 2885, 0, 0, 1346, 18, 18574였으나 Verify 항목이 없고 의도한 패턴과의 대응은 확인하지 않았다 |
| 패턴별 조작 토글 samon_act_p1~p4 (promote/demote) | **미검증** | 구현됨. 기본값 0이라 #11 Verify 실행에서는 켜지 않았고 동작 시험이 없다 |
| samon_dbg_lba = 0에서 P5 비감지 | **미검증** | 코드 동작은 9절에 기술했으나 시험하지 않았다 |
| debugfs streams, wb_hist, stats의 stream_* 줄 | **미검증** | 구현됨. 출력 형식 확인 실행을 하지 않았다 |
| seg_buffered 새 정의 | **미검증** | 구현됨. #11 Verify 실행 누적에서 seg_buffered = det_p1..p6 합이었으나 Verify 항목이 없다 |
| 호출 컨텍스트 안전성 (6절 참조) | **미검증** | lockdep 등 검사 빌드로 확인한 적 없음. 지연 경로(S1)로 바뀐 뒤에도 같다 |
| 고부하(fio 병렬) 락 경합과 오버헤드 | **미측정** | |
| 장시간, 다중 CPU 동시성 | **미검증** | |
| 옵션 B의 실제 효과 (refault, pgsteal, IOPS 변화) | **미측정** | 호출 on/off 토글만 준비됨 |

검증력에 대한 메모:

- 각 항목은 1회 또는 소수 회 실행 결과이다. 다른 파일시스템, 다른 워크로드에서의 재현은 확인하지 않았다.
- 시스템 전체를 관측하므로 백그라운드 I/O가 섞인다. 그래서 검증은 총 개수가 아니라 특정 파일의 섹터 집합이나 LBA별 카운터로 판정한다. 총량(seg_buffered) 증가량 비교는 구분력이 없어 판정에 쓰지 않는다.
- 옵션 B 토글 시험은 백그라운드의 같은 LBA 반복 write가 mark_accessed를 호출하면 off 항목이 오탐 FAIL이 될 수 있다. FAIL 시 재실행해서 확인한다.

### 검증 실행 방법
```bash
sudo bash verify_samon.sh /var/tmp/samon_verify
```
tmpfs가 아닌 실제 디스크 위의 디렉터리를 지정해야 한다. 마지막 줄에 PASS/FAIL 개수가 출력된다. nomap 분류 부분(섹션 8)은 부류별 개수를 보고만 하고 정체를 판정하지 않는다.

### 실행 기록

| 날짜 | 커널 | 결과 |
|---|---|---|
| 2026-09-22 | 구버전 (세션 로그) | 기본 동작 확인. direct 배제와 LBA 정밀 대조는 근거 부족으로 이후 재검증 |
| 2026-10-05 | #8 | verify_samon.sh 7개 항목 PASS |
| 2026-10-05 | #9 | 16개 항목 PASS (skip_pinned, 옵션 B 토글, 디스크 필터, kdamond 반복, probe 중복 검사 포함) |
| 2026-10-05 | #10 | nomap 분류 합 일치 PASS. nomap_meta 가설은 기각. 총 17 PASS |
| 2026-10-05 | #10 | 하네스 실행 직후 재실행에서 3개 FAIL (LBA 일치, 윈도우 리셋, 옵션 B). 원인은 코드가 아니라 트리 포화(drop_full 약 1332만)였으며, 검증이 빈 트리에서 시작하도록 스크립트를 고친 뒤 재실행하여 19개 모두 PASS (빈 트리 재시작, 포화 없음 확인 항목 포함) |
| 2026-10-18 | #11 (S1+S2 합본 빌드) | 기존 verify_samon.sh 19개 항목 모두 PASS, 종료 코드 0. 출력은 /tmp/samon_13_2_verify.log. S1 기능(진입 계측, 지연 큐)을 확인하는 Verify 항목은 아직 없어 이 PASS는 S1 기능의 PASS 근거가 아니다. 워크로드별 ctx 차분은 미실행 |

## 측정 하네스 (bench/, 준비됨, 아직 커널에서 실행하지 않음)

옵션 B 효과와 오버헤드를 같은 도구로 비교한다. on 구성은 실행마다 kdamond를 재시작해 빈 LBA 트리에서 시작하고, 실행 동안 samon_max_entries를 2097152로 올린다(데이터셋이 약 78만 개의 4KB LBA라 기본 상한 65536으로는 실행 중에 포화된다). 포화(drop_full 증가)가 나면 경고를 출력하고 CSV에도 기록한다. 전역 vmstat의 pgscan/pgsteal(kswapd, direct)은 cgroup 한도에 의한 회수를 세지 않으므로 cgroup의 memory.stat 값(pgscan, pgsteal, pgactivate, workingset_refault 등)도 함께 기록한다. samon_bench.sh는 구성 4개를 반복 실행한다: off(kdamond 정지, probe 없음), off2(두 번째 기준선, 실행 간 잡음 추정용), on_noB(samon_opt_b=0), on_B(samon_opt_b=1). 구성은 매 반복마다 섞어서 실행하고, 매번 cgroup v2 memory.max(기본 768M)와 drop_caches로 시작한다. 워크로드는 zipf 랜덤 read/write(hot, 2잡, fdatasync 32회마다)와 큰 파일 순차 read(scan)를 동시에 돌리며 hot 잡의 IOPS와 p99 지연을 보고한다. 실행 전후로 /proc/vmstat(refault, activate, steal, scan 등)와 saddr stats의 차분을 CSV에 기록하고, summarize.py가 구성별 평균과 표준편차, off 대비 차이, off 대 off2 차이(잡음)를 표로 만든다.

- 실행: sudo bash bench/samon_bench.sh -d /var/tmp/samon_bench -n 5
- 검증된 것: 스크립트 문법, fio 잡 정의에서 hot과 scan이 별도로 보고되는 것(드라이런), summarize.py의 계산(합성 데이터). 드라이런(-D)은 cgroup, kdamond, 모듈 파라미터를 건드리지 않으며 수치는 의미가 없다.
- 첫 실행(20초 x 2회, 2026-10-05)은 동작 확인용이었다. 구성 간 차이는 같은 구성끼리의 흔들림(약 8%) 안이었고, 이 실행은 실행 간 트리 상태가 이어지고 실행 중 트리가 포화되었을 가능성이 있어(당시 drop_full을 기록하지 않았다) 효과나 오버헤드에 대한 결론으로 쓰지 않는다. 관찰로만 남긴다: mark_accessed가 실행당 수만~십수만 회 호출되었으나 전역 pgactivate는 23~25로 거의 변하지 않았다(원인 미확인). 위 수정(트리 재시작, 상한 상향, 포화 경고, 반복 3회 미만이면 판정 안 함) 이후의 재실행은 아직 하지 않았다.
- 검증되지 않은 것: 수정된 하네스의 실제 실행, 메모리 압박 설정의 적절성(워킹셋 대비 한도), 반복 횟수 5의 충분성. summarize.py의 판정 규칙은 대략적 선별 기준이며 유의성 검정이 아니다.
- pgbench는 이 VM에 설치되어 있지 않아 첫 하네스는 fio 기반이다.

## 빌드 시 주의 (6.8.0-SAMON 커널)

- 이 커널은 CONFIG_DEBUG_INFO_BTF_MODULES=y이다. saddr.c를 고쳐 vmlinux만 다시 빌드하면 모듈의 BTF와 vmlinux의 BTF가 어긋나, CONFIG_MODULE_ALLOW_BTF_MISMATCH가 꺼져 있을 때 모듈 로드가 거부된다. 디스크 드라이버(mptspi 등)가 모듈이면 initramfs에서 루트 디스크를 찾지 못해 부팅이 실패한다.
- 이 때문에 .config에 CONFIG_MODULE_ALLOW_BTF_MISMATCH=y를 설정했다. 부팅 로그에 BTF mismatch 경고가 한 번 출력되는 것은 정상이다.
- vmlinux 링크 단계의 BTF 생성(pahole)은 약 4.7GB 메모리를 쓴다. 메모리 4GB VM에서는 OOM으로 빌드가 실패하거나 VM이 멈췄다. 8GB에서는 성공했고 빌드 중 전체 사용량 최대는 약 7GB였다. pahole 병렬 옵션(-j)을 빼려면 make에 PAHOLE_FLAGS="--btf_gen_floats --lang_exclude=rust --skip_encoding_btf_inconsistent_proto --btf_gen_optimized"를 지정한다.
- saddr는 빌트인이라 수정 후 재부팅이 필요하다. 모듈 트리(/lib/modules/6.8.0-SAMON)가 이미 완전하면 modules_install은 다시 할 필요가 없다. modules_install을 할 때는 INSTALL_MOD_STRIP=1을 쓰면 모듈과 initrd 크기가 줄어든다.
- 설치 전에 bzImage의 빌드 번호, vmlinux의 .BTF 섹션 존재, 빌드 로그에 Killed/Error가 없음을 확인한다.

## 알려진 한계

- 시스템 전체의 buffered I/O를 관측한다. 대상 디스크 필터로 좁힐 수 있다.
- 이 방식은 디스크 I/O가 발생한 page만 볼 수 있다. 캐시 히트인 page는 I/O가 없어 관측되지 않으므로, 캐시에 남아 있는 page를 대상으로 한 정책(오래 안 쓰인 page를 evict 우선 등)은 이 방식으로 구현할 수 없다.
- direct I/O 판별은 folio 상태 기반이다. bio 플래그나 IOCB_DIRECT 같은 상위 컨텍스트는 block layer에서 접근할 수 없어 사용하지 않았다.
- debugfs 출력은 트리 순회 동안 spinlock을 잡는다. samon_max_entries로 상한을 두었지만 엔트리가 매우 많으면 조회 중 지연이 생길 수 있다.
- 콜백에서 segment마다 전역 spinlock(LBA 트리)을 잡고, P5 요청을 큐에 넣을 때 CPU별 큐 lock을 잡는다. 고부하에서의 오버헤드는 아직 측정하지 않았다.
- Deferred_Queue는 kdamond 샘플링 주기마다 비운다. 주기보다 큐 항목이 빨리 쌓이면 samon_q_len에서 가득 차 drop_queue_p5로 버려진다. 실제 필요 크기(q_max_delay_us 등)는 측정하지 않았다 (S1 기능 전체가 미검증).
- 큐에 대기 중인 항목은 folio 참조를 잡고 있으므로 samon_q_max_ms 동안 해당 page 해제가 미뤄질 수 있다. 영향은 측정하지 않았다.
- seg_buffered는 SAMON_Filter를 통과한 segment 수이고 트리 포화나 할당 실패로 항목을 못 만든 segment도 포함한다. 이전 빌드(#10 이하)의 seg_buffered와 값을 직접 비교할 수 없다.
- 옵션 A/B/C 중 B를 기본 적용했으나, 확정은 사용자 결정 사항이다.
- 엔트리가 만료되지 않는다. 트리가 samon_max_entries에 도달하면 이후 새 LBA는 기록되지 않고(drop_full 증가) kdamond를 껐다 켜서 트리를 비우기 전까지 복구되지 않는다. 이 때문에 검증 스크립트가 빈 트리에서 시작하도록 고쳤고, 큰 데이터셋을 쓰는 측정에서는 samon_max_entries를 올려야 한다. 오래된 엔트리를 주기적으로 정리하는 aging은 아직 구현하지 않았다.

## 남은 개발

최종 목표(경로 B, 커널 내 bio to page 직접 조작)까지의 단계는 설계 문서(dev-manual 10부, dev-step 단계 11~18)에 정리되어 있다. 아래는 그 요약이며 상태는 2026-10-18 기준이다 (12단계와 13단계 행만 이 날짜로 갱신, 나머지는 2026-10-05 이후 변화 없음).

| 단계 | 내용 | 상태 |
|---|---|---|
| 11 | 관측 범위 확정 (nomap 분류) | 완료 |
| 12 | 조작 컨텍스트 안전화와 계측 (콜백 컨텍스트 측정, skip_passthru, skip_error, 지연 조작 구조) | 구현됨, 미검증 (2026-10-18 기준 #11에 포함, Verify 항목은 S3에서 추가 예정. 워크로드별 ctx 차분 미실행) |
| 13 | 영역 단위 집계, 패턴 분류, 엔트리 aging | 패턴 분류(P1~P6)만 구현됨, 미검증 (S2, #11에 포함, 9절). 영역 단위 집계와 엔트리 aging은 대기 (결정 게이트 A: aging을 먼저 넣을지 함께 할지) |
| 14 | 정책 판단 (promote/유지/demote, 불확실하면 기본 LRU로 폴백) | 대기 (결정 게이트 B) |
| 15 | 조작 프리미티브 (promote, demote, read 쪽 조작) | 대기 (결정 게이트 B) |
| 16 | 효과 측정 (수정된 하네스 실행) | 하네스 준비됨, 수정본은 미실행 |
| 17 | 안정성과 오버헤드 (부분 완료, 에러 주입, 고부하, 장시간) | 대기 |
| 18 | 정리와 보고 | 대기 |

미결정 사항: 엔트리 aging의 도입 시점, 옵션 A/B/C, read 시점 힌트 도입 여부, 점수 모델 대 규칙 기반, 오버헤드 허용 임계값.

## 범위 밖 (후순위)

점수 등급 체계(+++, ++, --, ---), DAMOS scheme 연동, DAMON/SAMON 통합 비교 실험은 구현하지 않았다. 사용자가 명시적으로 지시하기 전까지 착수하지 않는다.
