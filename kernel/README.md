# SAMON 커널 operations set (saddr)

Linux 커널 6.8의 DAMON operations set으로 구현한 스토리지(블록 디바이스) 주소 공간 모니터링 코드이다. block layer에서 완료된 I/O를 LBA 단위로 관측하고, read/write 빈도수로 자주 발생하는 I/O를 판정하며, 해당 LBA를 실제 page(PFN)와 정방향으로 연결한다.

eBPF 기반 유저스페이스 스크립트(samon_probe.py, samon_monitor.py 등)는 이 구현의 기반이 아니다. 이 디렉터리의 코드는 모두 커널 내부(mm/damon/saddr.c)에서 동작한다.

## 파일

| 파일 | 설명 |
|---|---|
| saddr.c | operations set 본체. mm/damon/saddr.c로 배치한다. |
| damon_Makefile | mm/damon/Makefile 대체본 (CONFIG_DAMON_SADDR 추가) |
| damon_Kconfig | mm/damon/Kconfig 대체본 (CONFIG_DAMON_SADDR 추가) |
| verify_samon.sh | 기능 검증 스크립트 (root 권한, 재부팅 후 실행) |
| test_pinned.c | verify_samon.sh가 컴파일해서 쓰는 테스트. mmap한 파일 페이지를 소스로 하는 O_DIRECT write |

## 적용 방법

1. saddr.c를 mm/damon/saddr.c로 복사한다.
2. mm/damon/Makefile을 damon_Makefile로, mm/damon/Kconfig를 damon_Kconfig로 교체한다.
3. include/linux/damon.h의 enum damon_ops_id에 DAMON_OPS_SADDR을 추가한다 (NR_DAMON_OPS 앞).
4. mm/damon/sysfs.c의 damon_sysfs_ops_strs[]에 "saddr"를 추가한다.
5. .config에 CONFIG_DAMON_SADDR=y를 설정하고 커널을 빌드, 설치, 재부팅한다.
6. 재부팅할 때마다 kdamond를 saddr operations로 설정하고 켠다 (아래 사용법 참조). tracepoint는 kdamond가 시작될 때 등록된다.

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

모듈 파라미터 (빌트인이므로 /sys/module/saddr/parameters/ 에서 런타임 변경 가능):

| 파라미터 | 기본값 | 의미 |
|---|---|---|
| samon_hot_threshold | 10 | 윈도우 안에서 이 횟수 이상 발생하면 hot으로 판정 |
| samon_window_ms | 1000 | 빈도수를 세는 관측 윈도우(ms) |
| samon_max_entries | 65536 | LBA 트리에 보관하는 엔트리 상한 (메모리 상한) |
| samon_opt_b | 1 | 옵션 B 토글. 0이면 hot write에서도 folio_mark_accessed()를 호출하지 않는다 (효과 비교용) |
| samon_dev_major, samon_dev_minor | 0, 0 | 관측 대상 디스크(whole disk의 major, first_minor). major가 0이면 모든 디바이스를 관측한다 |

## 구현된 기능

### 1. 관측 훅지점
- block_rq_complete tracepoint를 register_trace_block_rq_complete()로 구독한다.
- 완료 에러(error != 0)인 request는 관측에서 제외한다.
- rq_data_dir()로 READ/WRITE를 구분한다.
- 부분 완료 처리: 이 tracepoint는 blk_update_request() 맨 앞에서 bio_advance()/bio_endio() 이전에 발화하며, request가 여러 번에 나뉘어 완료되면 그때마다 발화한다. 콜백은 nr_bytes만큼의 segment만 순회해서 같은 segment를 중복 집계하지 않는다. nr_bytes가 request 전체보다 작았던 횟수는 stats의 budget_cut에 기록한다.
- 대상 디스크 필터(samon_dev_major/minor)에 맞지 않는 request는 skip_dev로 세고 건너뛴다.

### 2. bio에서 page 추출
- request에 연결된 bio를 __rq_for_each_bio()로 순회하고, bio_for_each_segment()로 bi_io_vec의 각 segment에 접근한다.
- LBA는 bio->bi_iter.bi_sector(512바이트 섹터)에서 시작해 segment마다 bv_len >> SECTOR_SHIFT 만큼 누적한다.

### 3. buffered I/O 한정 필터 (이번에 재작성)
이전 구현은 bio의 첫 segment만 page_mapping()으로 확인했다. 이는 direct I/O 여부가 아니라 page cache 여부만 보는 방식이어서 segment마다 다른 경우를 놓칠 수 있었다. 현재는 segment마다 다음을 검사하고, 하나라도 해당하면 건너뛴다.

| 검사 | 건너뛰는 이유 | 통계 항목 |
|---|---|---|
| bv_page가 NULL | 유효하지 않은 page | skip_null |
| folio가 anon 또는 swapcache | direct I/O의 사용자 버퍼, swap I/O | skip_anon |
| address_space가 없음 | page cache와 무관 | skip_nomap |
| folio_maybe_dma_pinned() | direct I/O는 사용자 버퍼를 pin하므로, mmap된 파일 버퍼를 쓰는 direct I/O도 걸러진다 | skip_pinned |

### 4. LBA→page 연동 자료구조
- LBA를 키로 하는 rbtree. 엔트리는 lba, pfn, read_count, write_count, last_jiffies를 가진다.
- struct page 포인터는 저장하지 않고 PFN만 저장한다.
- spinlock(irqsave)으로 보호한다. 콜백 안에서는 GFP_ATOMIC만 사용한다.
- 엔트리 수는 samon_max_entries로 제한한다 (초과 시 drop_full 증가).

### 5. 빈도수 기반 패턴 판정
- read/write 카운터를 분리해서 센다.
- 윈도우(samon_window_ms)가 지나면 카운터를 0으로 리셋한다.
- 방향별 카운터가 samon_hot_threshold 이상이면 hot으로 판정한다 (이진 판정. 점수 등급 체계는 구현하지 않았다).

### 6. 옵션 B (미래 접근 예측 반영)
- hot으로 판정된 write completion에서 folio_mark_accessed()를 호출한다. 기존 커널 API만 사용하며 커널 소스는 수정하지 않는다.
- read는 이 단계에서 관측만 하며, read 시점 힌트의 효과는 측정으로 판단할 사안으로 남겨 둔다. 이전 버전의 "read는 커널이 이미 accessed 처리를 한다"는 주석은 근거가 부족하여 제거했다. read 완료 시점의 page는 LRU에 올라가 있지만 사용자 접근 전이다.
- samon_opt_b 파라미터로 호출을 끌 수 있어, 켠 경우와 끈 경우를 같은 워크로드로 비교할 수 있다. 호출 횟수는 stats의 mark_accessed에 기록한다.

### 7. 안정성 보강 (이번에 추가)
- kdamond를 재시작해도 tracepoint가 중복 등록되지 않도록 등록 상태 플래그를 둔다.
- cleanup은 unregister 후 tracepoint_synchronize_unregister()를 호출한 뒤 트리를 해제한다.
- 기존 region 카운터 경로의 nr_regions는 READ_ONCE/WRITE_ONCE로 읽고 쓰며, 읽을 때 배열 크기로 clamp하여 동시 갱신 중에도 범위 밖 접근이 생기지 않게 한다.

### 8. 관측용 debugfs
- /sys/kernel/debug/samon/lba_page_map: 엔트리별 lba, pfn, reads, writes, hot_r, hot_w
- /sys/kernel/debug/samon/stats: rq_seen, seg_buffered, skip_null, skip_anon, skip_nomap, skip_pinned, skip_dev, budget_cut, mark_accessed, drop_full, drop_nomem, entries

## 검증 상태

"검증됨"은 실제 커널에서 실행한 결과가 있는 항목만 해당한다.

### 검증됨 (2026-10-05, 커널 6.8.0-SAMON #8, verify_samon.sh 실행 결과 PASS 7 / FAIL 0)

환경: VMware VM, ext4(/dev/sda2, 파티션 시작 섹터 4096, 블록 4096바이트), 디렉터리 /var/tmp/samon_verify.

| 항목 | 방식 | 결과 |
|---|---|---|
| tracepoint 등록 및 stats 노출 | kdamond를 saddr로 켠 뒤 stats 파일 확인 | 정상 |
| LBA와 파일 물리 위치 일치 | fio --direct=0 4MB write 후 sync. filefrag -e의 physical 블록을 (블록 크기 / 512)배하고 파티션 시작 섹터를 더해 섹터로 변환하여 lba_page_map과 비교 | 파일의 블록 시작 섹터 1024개 중 1024개 모두 존재 |
| direct I/O 배제 | fio --direct=1 4MB write 후 sync. 해당 파일의 섹터 집합과 lba_page_map의 교집합 계산, stats의 skip 카운터 증가량 확인 | 교집합 0개, skip 카운터 +1024 (4MB / 4KB와 일치) |
| hot 판정 | threshold(10) 이상 dd oflag=sync로 같은 위치에 반복 write 후 hot_w 확인 | hot_w=1 엔트리 확인 |
| 윈도우 리셋 | 윈도우(1000ms) 경과 후 한 번 더 write, 같은 LBA의 writes 값 확인 | writes=1로 리셋됨 |
| read/write 카운터 분리 | 2026-09-22 세션 로그(이전 버전) 및 이번 실행의 reads/writes 열 | 분리 동작 |
| 부팅 및 모듈 로드 | 6.8.0-SAMON #8로 부팅, 부팅 로그에서 saddr ops 등록 확인 | 정상 |

실행 직후 stats:

```
rq_seen=1406  seg_buffered=6164
skip_null=0  skip_anon=1024  skip_nomap=8  skip_pinned=0
drop_full=0  drop_nomem=0   entries=6120 (max 65536)
```

해석 시 주의할 점은 다음과 같다.

- direct I/O 4MB write가 건너뛴 1024개 segment는 모두 skip_anon으로 분류되었다. 사용자 anon 버퍼를 쓰는 일반적인 direct I/O 경로는 검증되었다.
- skip_pinned 경로(mmap한 파일 버퍼를 쓰는 direct I/O)는 이번 시험에서 한 번도 실행되지 않았다. 해당 경로는 코드만 있고 검증되지 않았다.
- direct 시험 중 seg_buffered가 63 늘었다. 시스템 전체를 관측하므로 백그라운드 buffered I/O가 섞인 것이며, 그래서 검증은 총 개수가 아니라 특정 파일의 섹터 집합으로 비교한다.
- skip_nomap=8은 page cache 매핑이 없는 segment이다. 어떤 I/O인지는 분류하지 않았다.
- 각 항목은 1회 실행 결과이다. 반복 실행, 다른 파일시스템, 다른 워크로드에서의 재현은 확인하지 않았다.

### 코드는 반영되었으나 아직 실행 검증하지 않은 항목 (verify_samon.sh 섹션 4~7에 포함)

| 항목 | 검증 방식 | 통과 기준 |
|---|---|---|
| skip_pinned 경로 | test_pinned로 1MiB를 mmap 소스 O_DIRECT write 후 skip_pinned 증가량 확인, 대상 파일 섹터가 lba_page_map에 없는지 확인 | skip_pinned가 230 이상 증가, 섹터 0개 |
| 옵션 B 토글 | samon_opt_b를 0과 1로 바꿔 각각 hot write 반복, mark_accessed 증가량 비교 | 0이면 증가 0, 1이면 증가 |
| 대상 디스크 필터 | 존재하지 않는 디스크로 필터 후 I/O(rq_seen 증가 없음, skip_dev 증가), 실제 디스크로 필터 후 I/O(rq_seen 증가) | 두 조건 충족 |
| kdamond off/on 10회 반복 | 매번 stop 후 entries가 0인지, 같은 I/O의 seg_buffered 증가량이 회차 간 유지되는지(probe 중복 등록 없음), dmesg에 BUG/WARNING/Oops/lockdep 없는지 | 모두 충족 |

참고: 옵션 B 토글 시험은 백그라운드의 같은 LBA 반복 write(예: 파일시스템 저널)가 mark_accessed를 호출하면 off 항목이 오탐 FAIL이 될 수 있다. FAIL 시 재실행하여 확인한다.

### 검증되지 않은 항목

| 항목 | 상태 |
|---|---|
| 부분 완료(nr_bytes 반영) 경로의 정확성 | 코드 반영, budget_cut 카운터가 실제로 증가하는 워크로드는 아직 찾지 못함 |
| 고부하(fio 병렬)에서의 락 경합과 오버헤드 | 미측정 |
| 에러 주입(completion error) 경로 | 미실행 |
| 장시간, 다중 CPU 동시성 | 미검증 |
| 옵션 B의 실제 효과(refault, pgsteal, IOPS 변화) | 미측정. 호출 on/off 토글만 준비됨 |

### 검증 실행 방법
```bash
sudo bash verify_samon.sh /var/tmp/samon_verify
```
tmpfs가 아닌 실제 디스크 위의 디렉터리를 지정해야 한다. 결과는 PASS/FAIL로 출력된다.

## 빌드 시 주의 (6.8.0-SAMON 커널)

- 이 커널은 CONFIG_DEBUG_INFO_BTF_MODULES=y이다. saddr.c를 고쳐 vmlinux만 다시 빌드하면 모듈의 BTF와 vmlinux의 BTF가 어긋나, CONFIG_MODULE_ALLOW_BTF_MISMATCH가 꺼져 있을 때 모듈 로드가 거부된다. 디스크 드라이버(mptspi 등)가 모듈이면 initramfs에서 루트 디스크를 찾지 못해 부팅이 실패한다.
- 이 때문에 .config에 CONFIG_MODULE_ALLOW_BTF_MISMATCH=y를 설정했다. 부팅 로그에 BTF mismatch 경고가 한 번 출력되는 것은 정상이다.
- vmlinux 링크 단계의 BTF 생성(pahole)은 약 4.7GB 메모리를 쓴다. 메모리 4GB VM에서는 OOM으로 빌드가 실패하거나 VM이 멈췄다. 8GB에서는 성공했고 빌드 중 전체 사용량 최대는 약 7GB였다. 병렬 옵션(-j)을 빼려면 make에 PAHOLE_FLAGS를 지정한다.
- modules_install은 INSTALL_MOD_STRIP=1로 하면 모듈과 initrd 크기가 줄어든다.

## 알려진 한계

- 시스템 전체의 buffered I/O를 관측한다. 백그라운드 I/O가 섞이므로 검증은 총 엔트리 수가 아니라 특정 파일의 섹터 집합으로 비교한다.
- direct I/O 판별은 folio 상태 기반이다. bio 플래그나 IOCB_DIRECT 같은 상위 컨텍스트는 block layer에서 접근할 수 없어 사용하지 않았다.
- debugfs 출력은 트리 순회 동안 spinlock을 잡는다. samon_max_entries로 상한을 두었지만 엔트리가 매우 많으면 조회 중 지연이 생길 수 있다.
- 콜백에서 segment마다 spinlock을 잡는다. 고부하에서의 오버헤드는 아직 측정하지 않았다.
- 옵션 A/B/C 중 B를 기본 적용했으나, 확정은 사용자 결정 사항이다.

## 범위 밖 (후순위)

점수 등급 체계(+++, ++, --, ---), DAMOS scheme 연동, DAMON/SAMON 비교 실험은 이 단계에서 구현하지 않았다.
