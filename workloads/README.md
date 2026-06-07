# SAMON Workloads

6가지 벤치마크 워크로드. 각각 다른 I/O 패턴을 발생시켜 SAMON 히트맵에서 시각적으로 구분 가능.

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

- 모든 워크로드는 `--direct=1` 또는 동등한 설정으로 page cache를 우회
- pgbench는 사전에 DB 초기화 필요 (위 사전 요구사항 참조)
- 워크로드 실행 전 `sync; echo 3 > /proc/sys/vm/drop_caches`로 캐시 비우면 패턴이 더 명확
