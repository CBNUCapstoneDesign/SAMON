# SAMON Workloads (초기 히트맵용)

6가지 벤치마크 워크로드. 각각 다른 I/O 패턴을 발생시켜 SAMON 히트맵에서 시각적으로 구분 가능.

> 이 디렉터리는 초기 프로토타입(eBPF 모니터, samon_kernel_monitor.py 히트맵)용이다. 검증과 측정에 쓰는 워크로드는 여기가 아니라 `bench/samon_workloads.sh`(mixed, reread, loop, seqwrite와 Verify 형태 p1~p4, rand)에 있다.
>
> saddr의 LBA to page 연동과 패턴 감지(P1~P6)는 buffered I/O만 본다. direct I/O segment는 skip_anon/skip_pinned로 걸러진다. 아래 워크로드 중 run_fio.sh, run_sysbench.sh와 run_dbbench.sh의 read·flush·compaction은 direct I/O라 패턴 감지와 page 조작에는 잡히지 않고, region 카운터 경로(samon_kernel_monitor.py가 읽는 damon_aggregated의 nr_accesses)에만 반영된다. region 카운터는 segment 필터 앞에서 세므로 direct I/O도 포함한다(saddr.c samon_legacy_region_count). 스크립트의 설정만 보고 판단했으며 실행해서 확인하지는 않았다.

## 사전 요구사항

```bash
sudo apt-get install -y fio sysbench postgresql rocksdb-tools python3-numpy
sudo -u postgres createdb samontest
sudo -u postgres pgbench -i -s 50 samontest
```

## 사용법

터미널 2개를 열고:

**터미널 1 (모니터링):**
```bash
# eBPF 방식
sudo python3 samon_monitor.py -i 1 -d 95 -s 251658240 --min-regions 32 --max-regions 256 -o result.csv

# 또는 커널 saddr 방식
sudo python3 samon_kernel_monitor.py -d 95 -r 16 -s 100 -a 1000 -o result.csv
```

**터미널 2 (워크로드):**
```bash
sudo bash workloads/run_fio.sh          # ~85초
sudo bash workloads/run_pgbench.sh      # ~80초
sudo python3 workloads/btree_workload.py    # ~90초
sudo bash workloads/run_dbbench.sh      # ~60초 (자동 종료)
sudo bash workloads/run_sysbench.sh     # ~85초
sudo python3 workloads/zipfian_workload.py  # ~90초
```

**히트맵 생성:**
```bash
python3 samon_plot.py result.csv -o heatmap.png
```

## 워크로드 설명

| # | 파일 | 설명 | 예상 패턴 |
|---|------|------|----------|
| 1 | `run_fio.sh` | 합성 I/O (random mix → sequential → burst) | phase별 뚜렷한 전환 |
| 2 | `run_pgbench.sh` | PostgreSQL OLTP (select → TPC-B → mixed) | WAL write 집중, 인덱스 read |
| 3 | `btree_workload.py` | SQLite B-tree lookup 5-phase | B-tree 계층적 접근 패턴 |
| 4 | `run_dbbench.sh` | RocksDB LSM-tree (fill → read → compaction) | compaction 시 wide write burst |
| 5 | `run_sysbench.sh` | sysbench fileio direct I/O | sequential → random 전환 |
| 6 | `zipfian_workload.py` | Zipfian 분포 (uniform → skewed) | alpha 증가에 따라 hot region 집중 |

## 주의사항

- run_fio.sh(`--direct=1`), run_sysbench.sh(`--file-extra-flags=direct`)는 page cache를 우회한다. run_dbbench.sh는 read와 flush·compaction에 direct I/O를 쓴다(`--use_direct_reads=true`, `--use_direct_io_for_flush_and_compaction=true`). run_pgbench.sh, btree_workload.py, zipfian_workload.py에는 direct 설정이 없다(zipfian_workload.py 설명의 "direct I/O characteristics"는 설정이 아니라 설명 문구)
- pgbench는 사전에 DB 초기화 필요 (위 사전 요구사항 참조)
- 워크로드 실행 전 `sync; echo 3 > /proc/sys/vm/drop_caches`로 캐시 비우면 패턴이 더 명확
