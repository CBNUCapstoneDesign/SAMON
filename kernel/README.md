# SAMON Kernel Operation Set (saddr)

DAMON storage address space operation set for Linux kernel 6.8.

## Files

- `saddr.c` — The storage operation set implementation
- `damon_Makefile` — Modified mm/damon/Makefile (add saddr.o)
- `damon_Kconfig` — Modified mm/damon/Kconfig (add CONFIG_DAMON_SADDR)

## How to apply

1. Copy `saddr.c` to `mm/damon/saddr.c`
2. Replace `mm/damon/Makefile` with `damon_Makefile`
3. Replace `mm/damon/Kconfig` with `damon_Kconfig`
4. Add `DAMON_OPS_SADDR` to `enum damon_ops_id` in `include/linux/damon.h` (before NR_DAMON_OPS)
5. Add `"saddr"` to `damon_sysfs_ops_strs[]` in `mm/damon/sysfs.c`
6. Add `CONFIG_DAMON_SADDR=y` to `.config`
7. Build and install kernel
