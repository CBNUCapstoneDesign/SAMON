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

## 구현된 기능

### 1. 관측 훅지점
- block_rq_complete tracepoint를 register_trace_block_rq_complete()로 구독한다.
- 완료 에러(error != 0)인 request는 관측에서 제외한다.
- rq_data_dir()로 READ/WRITE를 구분한다.

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
- read는 커널이 이미 accessed 처리를 하므로 조작하지 않고 관측만 한다.

### 7. 안정성 보강 (이번에 추가)
- kdamond를 재시작해도 tracepoint가 중복 등록되지 않도록 등록 상태 플래그를 둔다.
- cleanup은 unregister 후 tracepoint_synchronize_unregister()를 호출한 뒤 트리를 해제한다.
- 기존 region 카운터 경로의 nr_regions는 READ_ONCE/WRITE_ONCE로 읽고 쓰며, 읽을 때 배열 크기로 clamp하여 동시 갱신 중에도 범위 밖 접근이 생기지 않게 한다.

### 8. 관측용 debugfs
- /sys/kernel/debug/samon/lba_page_map: 엔트리별 lba, pfn, reads, writes, hot_r, hot_w
- /sys/kernel/debug/samon/stats: rq_seen, seg_buffered, skip_null, skip_anon, skip_nomap, skip_pinned, drop_full, drop_nomem, entries

## 검증 상태

검증 상태를 근거별로 구분해서 적는다. "검증됨"은 실제 실행 결과가 있는 항목만 해당한다.

### 검증됨 (2026-09-22 실제 커널 실행, 이전 버전 코드 기준)
근거는 cap2/session-log-2026-09-22.txt이다.

| 항목 | 방식 | 결과 |
|---|---|---|
| tracepoint 등록 | kdamond를 saddr로 켠 뒤 lba_page_map 확인 | 엔트리 생성됨 |
| buffered write 관측 | fio --direct=0 4MB write 후 sync, debugfs 조회 | lba, pfn 기록 확인 |
| read/write 카운터 분리 | debugfs의 reads, writes 열 확인 | 분리되어 동작 |
| hot 판정 | dd oflag=sync 15회 반복 후 hot_w 확인 | writes=15, hot_w=1 |

### 이번 수정분 상태
| 항목 | 상태 |
|---|---|
| 새 saddr.c 컴파일 | 확인됨. 6.8 소스 트리에서 make mm/damon/saddr.o W=1, 경고 및 에러 없음 |
| 새 saddr.c 런타임 동작 | 미검증. 이 작업 환경에서 sudo와 재부팅이 불가능하여 새 커널을 올려 실행하지 못했다 |

### 아직 검증되지 않은 항목 (verify_samon.sh로 검증 예정)
이전 세션에서 "코드 로직상 정확함"으로만 넘어갔거나 근거가 부족했던 항목이다.

| 항목 | 검증 방식 | 통과 기준 |
|---|---|---|
| direct I/O 배제 | 같은 크기의 buffered 파일과 direct 파일(fio --direct=1)을 쓴다. filefrag로 direct 파일의 물리 섹터 집합을 구해 lba_page_map과 교집합을 계산한다. 추가로 stats의 skip 카운터 증가를 확인한다 | 교집합이 0이고 skip 카운터가 증가 |
| LBA와 파일 물리 위치 일치 | filefrag -e의 physical 블록에 (파일시스템 블록 크기 / 512)를 곱하고 파티션 시작 섹터(/sys/class/block/<part>/start)를 더해 섹터로 변환한 뒤 lba_page_map과 비교한다 | buffered 파일의 모든 블록 시작 섹터가 존재 |
| hot 전환 및 윈도우 리셋 | threshold 이상 반복 write 후 hot_w=1 확인, 윈도우 경과 후 한 번 더 write하여 카운터가 threshold 미만으로 돌아가는지 확인 | 두 조건 모두 충족 |
| 부하 및 에러 경로 | fio 병렬 I/O에서 오버헤드 측정, loop device와 dmsetup 에러 주입 | 미구현 (후속 작업) |

이전 세션에서 filefrag와 LBA 정밀 대조가 되지 않은 원인은 단위 변환 때문으로 보인다. filefrag의 physical은 파일시스템 블록 단위이고 파티션 시작 오프셋이 포함되지 않지만, bio의 섹터는 디스크 전체 기준 512바이트 단위이다. verify_samon.sh는 이 변환을 적용한다.

### 검증 실행 방법
```bash
sudo bash verify_samon.sh /var/tmp/samon_verify
```
tmpfs가 아닌 실제 디스크 위의 디렉터리를 지정해야 한다. 결과는 PASS/FAIL로 출력된다.

## 알려진 한계

- 시스템 전체의 buffered I/O를 관측한다. 백그라운드 I/O가 섞이므로 검증은 총 엔트리 수가 아니라 특정 파일의 섹터 집합으로 비교한다.
- direct I/O 판별은 folio 상태 기반이다. bio 플래그나 IOCB_DIRECT 같은 상위 컨텍스트는 block layer에서 접근할 수 없어 사용하지 않았다.
- debugfs 출력은 트리 순회 동안 spinlock을 잡는다. samon_max_entries로 상한을 두었지만 엔트리가 매우 많으면 조회 중 지연이 생길 수 있다.
- 콜백에서 segment마다 spinlock을 잡는다. 고부하에서의 오버헤드는 아직 측정하지 않았다.
- 옵션 A/B/C 중 B를 기본 적용했으나, 확정은 사용자 결정 사항이다.

## 범위 밖 (후순위)

점수 등급 체계(+++, ++, --, ---), DAMOS scheme 연동, DAMON/SAMON 비교 실험은 이 단계에서 구현하지 않았다.
