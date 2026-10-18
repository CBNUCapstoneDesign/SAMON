// SPDX-License-Identifier: GPL-2.0
/*
 * DAMON Primitives for Storage (Block Device) Address Spaces
 *
 * Extends the base DAMON saddr operations with:
 *  - Separate read/write I/O counters per region
 *  - Forward LBA->page mapping via bio->bi_io_vec (buffered I/O only)
 *  - Hot-region detection based on per-direction frequency threshold
 *  - folio_mark_accessed() hint on hot write completions (Option B),
 *    requested from the probe through the Deferred_Queue (P5, act MARK)
 *  - debugfs interface: /sys/kernel/debug/samon/{lba_page_map,stats,
 *    streams,wb_hist}
 *
 * Direct I/O is excluded per segment (anon / no mapping / DMA-pinned
 * folio), and every skip reason is counted in /sys/kernel/debug/samon/stats.
 *
 * Author: Sangsoo Park, Sumin Sim
 */

#define pr_fmt(fmt) "damon-sa: " fmt

#include <linux/damon.h>
#include <linux/module.h>
#include <linux/blk-mq.h>
#include <linux/rbtree.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/swap.h>      /* folio_mark_accessed */
#include <linux/pagemap.h>   /* page_mapping, page_folio */
#include <linux/jiffies.h>
#include <linux/mm.h>        /* folio_maybe_dma_pinned */
#include <linux/percpu.h>    /* DEFINE_PER_CPU, this_cpu_inc/dec */
#include <linux/preempt.h>   /* in_hardirq, in_serving_softirq */
#include <linux/hash.h>      /* hash_64 */
#include <linux/math.h>      /* reciprocal_scale */

#include <trace/events/block.h>

#include "../internal.h"     /* folio_activate (declared in mm/internal.h) */
#include "ops-common.h"

/* ------------------------------------------------------------------ */
/* Tunables (adjustable via module_param at load time)                 */
/* ------------------------------------------------------------------ */

#define DAMON_SA_MAX_REGIONS	1024

static unsigned int samon_hot_threshold = 10;
module_param(samon_hot_threshold, uint, 0644);
MODULE_PARM_DESC(samon_hot_threshold,
	"Number of accesses within the window to classify a region as hot");

static unsigned int samon_window_ms = 1000;
module_param(samon_window_ms, uint, 0644);
MODULE_PARM_DESC(samon_window_ms,
	"Observation window in milliseconds for hot-region detection");

static bool samon_opt_b = true;
module_param(samon_opt_b, bool, 0644);
MODULE_PARM_DESC(samon_opt_b,
	"Option B: queue a folio_mark_accessed() request (P5) on hot write completion");

static unsigned int samon_dev_major;
module_param(samon_dev_major, uint, 0644);
MODULE_PARM_DESC(samon_dev_major,
	"Observe only this whole disk (major); 0 = observe all devices");

static unsigned int samon_dev_minor;
module_param(samon_dev_minor, uint, 0644);
MODULE_PARM_DESC(samon_dev_minor,
	"Observe only this whole disk (first_minor), used with samon_dev_major");

static unsigned int samon_dbg_nomap;
module_param(samon_dbg_nomap, uint, 0644);
MODULE_PARM_DESC(samon_dbg_nomap,
	"Log no-mapping segments of the unexplained class (nomap_other) to dmesg while the cumulative nomap_other count is <= this value (0 = off)");

static unsigned int samon_max_entries = 65536;
module_param(samon_max_entries, uint, 0644);
MODULE_PARM_DESC(samon_max_entries,
	"Upper bound on LBA entries kept in the tree (bounds memory use)");

/*
 * Deferred_Queue defaults (appendix A).  Only these constants change when
 * the values are confirmed.
 *   SAMON_DEF_Q_LEN    : per-CPU ring size (initial proposal, S0 follow-up)
 *   SAMON_DEF_Q_MAX_MS : pending-time limit in ms (initial proposal)
 */
#define SAMON_DEF_Q_LEN		1024
#define SAMON_DEF_Q_MAX_MS	100

/*
 * Pattern_Detector defaults (appendix A).  Only these constants change when
 * the values are confirmed.
 *   SAMON_DEF_STREAM_SLOTS / SAMON_DEF_LOOP_SLOTS : confirmed 16 / 16
 *       (tasks 15.1, 2026-10-18)
 *   the rest are the appendix A proposals, "before measurement" items that
 *   are not yet confirmed by the User.
 * The "after S0" items (samon_seq_min, samon_stream_new_kb,
 * samon_stream_gap_req, samon_stream_idle_ms) are now confirmed by the User
 * at the appendix A proposal values (2026-10-18).  Revisit them if the S0
 * report suggests otherwise; only the SAMON_DEF_* constants change.
 */
#define SAMON_DEF_SEQ_MIN		4
#define SAMON_DEF_STREAM_NEW_KB		64
#define SAMON_DEF_STREAM_GAP_REQ	2
#define SAMON_DEF_STREAM_IDLE_MS	1000
#define SAMON_DEF_STREAM_SLOTS		16
#define SAMON_DEF_LOOP_SLOTS		16
#define SAMON_DEF_LOOP_MIN_KB		8192
#define SAMON_DEF_LOOP_PROTECT_PCT	50
#define SAMON_DEF_REREAD_SLOTS		65536
#define SAMON_DEF_REREAD_MS		10000

/*
 * Unsigned parameters with a range check.  param_set_uint_minmax() parses
 * and range-checks before it stores, so a rejected write (-EINVAL) leaves
 * the old value.  The three ops share param_get_uint.
 */
static int samon_param_set_uint_min1(const char *val,
				     const struct kernel_param *kp)
{
	return param_set_uint_minmax(val, kp, 1, UINT_MAX);
}

static const struct kernel_param_ops samon_uint_min1_ops = {
	.set = samon_param_set_uint_min1,
	.get = param_get_uint,
};

/* 0 or 1 only */
static int samon_param_set_uint_01(const char *val,
				   const struct kernel_param *kp)
{
	return param_set_uint_minmax(val, kp, 0, 1);
}

static const struct kernel_param_ops samon_uint_01_ops = {
	.set = samon_param_set_uint_01,
	.get = param_get_uint,
};

/* 0..100 only */
static int samon_param_set_uint_pct(const char *val,
				    const struct kernel_param *kp)
{
	return param_set_uint_minmax(val, kp, 0, 100);
}

static const struct kernel_param_ops samon_uint_pct_ops = {
	.set = samon_param_set_uint_pct,
	.get = param_get_uint,
};

/* Read once at kdamond start (damon_sa_init); a later write applies to the
 * next start.  Per-CPU ring and drain array both have this many slots. */
static unsigned int samon_q_len = SAMON_DEF_Q_LEN;
module_param_cb(samon_q_len, &samon_uint_min1_ops, &samon_q_len, 0644);
MODULE_PARM_DESC(samon_q_len,
	"Per-CPU Deferred_Queue slots, >= 1 (0 is rejected); applied at the next kdamond start");

/* Read every time a queued item is processed: takes effect immediately. */
static unsigned int samon_q_max_ms = SAMON_DEF_Q_MAX_MS;
module_param(samon_q_max_ms, uint, 0644);
MODULE_PARM_DESC(samon_q_max_ms,
	"Maximum time in ms an item may wait in the Deferred_Queue before it is dropped as stale");

/*
 * Per-pattern action toggles for P1..P4 (P5 stays samon_opt_b).  0 = detect
 * and count only, 1 = also queue the action.  Read with READ_ONCE() every
 * time a segment is classified or a queued item is processed (immediate).
 * samon_act[k] is the toggle of pattern P(k+1).
 */
static unsigned int samon_act[4];
module_param_cb(samon_act_p1, &samon_uint_01_ops, &samon_act[0], 0644);
MODULE_PARM_DESC(samon_act_p1, "P1 (sequential scan read) action toggle: 0 or 1");
module_param_cb(samon_act_p2, &samon_uint_01_ops, &samon_act[1], 0644);
MODULE_PARM_DESC(samon_act_p2, "P2 (re-read) action toggle: 0 or 1");
module_param_cb(samon_act_p3, &samon_uint_01_ops, &samon_act[2], 0644);
MODULE_PARM_DESC(samon_act_p3, "P3 (loop read) action toggle: 0 or 1");
module_param_cb(samon_act_p4, &samon_uint_01_ops, &samon_act[3], 0644);
MODULE_PARM_DESC(samon_act_p4, "P4 (sequential write) action toggle: 0 or 1");

/* SAMON_Map insertion switch: 0 = lookup only, so P5 is not detected. */
static unsigned int samon_dbg_lba = 1;
module_param_cb(samon_dbg_lba, &samon_uint_01_ops, &samon_dbg_lba, 0644);
MODULE_PARM_DESC(samon_dbg_lba,
	"0 = do not insert new SAMON_Map entries (lookup only; P5 is then not detected), 1 = insert; 0 or 1");

/*
 * Table sizes: read once at kdamond start (damon_sa_init), fixed for that
 * run; a write applies to the next start.  0 is rejected.
 */
static unsigned int samon_stream_slots = SAMON_DEF_STREAM_SLOTS;
module_param_cb(samon_stream_slots, &samon_uint_min1_ops, &samon_stream_slots, 0644);
MODULE_PARM_DESC(samon_stream_slots,
	"Stream_Table slots per direction, >= 1; applied at the next kdamond start");

static unsigned int samon_loop_slots = SAMON_DEF_LOOP_SLOTS;
module_param_cb(samon_loop_slots, &samon_uint_min1_ops, &samon_loop_slots, 0644);
MODULE_PARM_DESC(samon_loop_slots,
	"Loop_History slots, >= 1; applied at the next kdamond start");

static unsigned int samon_reread_slots = SAMON_DEF_REREAD_SLOTS;
module_param_cb(samon_reread_slots, &samon_uint_min1_ops, &samon_reread_slots, 0644);
MODULE_PARM_DESC(samon_reread_slots,
	"Reread_Table slots, >= 1; applied at the next kdamond start");

/* Loop protection ratio in percent, read on every P3 classification. */
static unsigned int samon_loop_protect_pct = SAMON_DEF_LOOP_PROTECT_PCT;
module_param_cb(samon_loop_protect_pct, &samon_uint_pct_ops, &samon_loop_protect_pct, 0644);
MODULE_PARM_DESC(samon_loop_protect_pct,
	"P3: first this percent of the loop range is promoted, the rest demoted; 0..100");

/* Immediately applied (read with READ_ONCE where used), no range check
 * (design K9). */
static unsigned int samon_seq_min = SAMON_DEF_SEQ_MIN;
module_param(samon_seq_min, uint, 0644);
MODULE_PARM_DESC(samon_seq_min,
	"Minimum consecutive-request count of a Stream_Table slot for its requests to be classified P1 (sequential read) or P4 (sequential write)");

static unsigned int samon_stream_new_kb = SAMON_DEF_STREAM_NEW_KB;
module_param(samon_stream_new_kb, uint, 0644);
MODULE_PARM_DESC(samon_stream_new_kb,
	"Minimum request size in KiB that may start a new Stream_Table slot when no slot matches");

static unsigned int samon_stream_gap_req = SAMON_DEF_STREAM_GAP_REQ;
module_param(samon_stream_gap_req, uint, 0644);
MODULE_PARM_DESC(samon_stream_gap_req,
	"Stream gap tolerance: gap = this value x the size of the completed request; used by extend/prepend/fill matching");

static unsigned int samon_stream_idle_ms = SAMON_DEF_STREAM_IDLE_MS;
module_param(samon_stream_idle_ms, uint, 0644);
MODULE_PARM_DESC(samon_stream_idle_ms,
	"A read slot not updated for this many ms is treated as idle: recorded in Loop_History if long enough, then cleared");

static unsigned int samon_loop_min_kb = SAMON_DEF_LOOP_MIN_KB;
module_param(samon_loop_min_kb, uint, 0644);
MODULE_PARM_DESC(samon_loop_min_kb,
	"Minimum read stream length in KiB to be recorded in Loop_History and matched as a loop");

static unsigned int samon_reread_ms = SAMON_DEF_REREAD_MS;
module_param(samon_reread_ms, uint, 0644);
MODULE_PARM_DESC(samon_reread_ms,
	"Window in ms within which a second read of the same 4KB LBA is a re-read (P2)");

/* ------------------------------------------------------------------ */
/* Per-LBA entry stored in an rbtree                                   */
/* ------------------------------------------------------------------ */

struct samon_lba_entry {
	sector_t	 lba;		/* starting sector (512-byte units) */
	unsigned long	 pfn;		/* PFN captured at last hit         */
	u64		 read_count;
	u64		 write_count;
	unsigned long	 last_jiffies;	/* window start timestamp           */
	struct rb_node	 node;
};

/* ------------------------------------------------------------------ */
/* Deferred_Queue data model                                           */
/* ------------------------------------------------------------------ */

/* Pattern numbers.  Only P1..P5 are queued; P6 never enters the queue. */
enum samon_pat  { SAMON_P1 = 1, SAMON_P2, SAMON_P3, SAMON_P4, SAMON_P5, SAMON_P6 };
enum samon_act  { SAMON_ACT_NONE, SAMON_ACT_PROMOTE, SAMON_ACT_DEMOTE,
		  SAMON_ACT_MARK };
enum samon_drop { SAMON_DROP_QUEUE, SAMON_DROP_STALE, SAMON_DROP_REVALIDATE,
		  SAMON_DROP_TOGGLE, SAMON_DROP_SHUTDOWN, SAMON_NR_DROP };

#define SAMON_NR_QPAT	5	/* queued patterns: P1..P5, index = pat - 1 */

/* Deferred_Queue item, 24 B on x86_64 */
struct samon_qitem {
	struct folio	*folio;		/* reference taken with folio_get() */
	unsigned long	 t_req;		/* request time, jiffies            */
	u8		 act;		/* enum samon_act                   */
	u8		 pat;		/* enum samon_pat, 1..5             */
};

/*
 * Queue accounting, protected by the owning queue's lock.  Per queue
 *   req = exec + sum(drop) + inflight
 * holds whenever the lock is not held, so the sum over CPUs does too.
 */
struct samon_qacct {
	u64		 req[SAMON_NR_QPAT];
	u64		 exec[SAMON_NR_QPAT];
	u64		 drop[SAMON_NR_DROP][SAMON_NR_QPAT];
	u64		 inflight;	/* ring + drained items not yet counted */
};

struct samon_cpuq {			/* per-CPU queue */
	spinlock_t		 lock;
	u32			 count;	/* ring items, 0..samon_q_cap       */
	struct samon_qitem	*ring;	/* samon_q_cap slots                */
	struct samon_qitem	*drain;	/* samon_q_cap slots, kdamond only  */
	struct samon_qacct	 acct;
} ____cacheline_aligned_in_smp;

/* ------------------------------------------------------------------ */
/* Pattern_Detector data model (S2)                                    */
/* ------------------------------------------------------------------ */

/*
 * Stream_Table counter kinds, also the index into samon_st_stream[X][].
 * The order is the stats line order (K10 67~78): extend, prepend, fill,
 * restart, new_slot, evict.
 */
enum samon_sev  { SAMON_SEV_EXTEND, SAMON_SEV_PREPEND, SAMON_SEV_FILL,
		  SAMON_SEV_RESTART, SAMON_SEV_NEW_SLOT, SAMON_SEV_EVICT,
		  SAMON_NR_SEV };

/* Result of the per-request Stream_Table update (flow pattern). */
enum samon_flow_kind { SAMON_FLOW_UNSET, SAMON_FLOW_NONE,
		       SAMON_FLOW_P1, SAMON_FLOW_P3, SAMON_FLOW_P4 };

/* Stream_Table slot, 64 B on x86_64 (R8.3).  Protected by samon_pat_lock. */
struct samon_stream {
	sector_t	 start;		/* first sector                      */
	sector_t	 end;		/* end sector (exclusive)            */
	sector_t	 loop_len;	/* L, sectors                        */
	unsigned long	 t_start;	/* start time, jiffies               */
	unsigned long	 t_last;	/* last update time, jiffies         */
	unsigned long	 period;	/* loop period, jiffies              */
	dev_t		 dev;
	u32		 count;		/* consecutive requests              */
	u8		 used;
	u8		 loop;
};

/* Loop_History slot, 32 B (R8.12).  Protected by samon_pat_lock. */
struct samon_loop_rec {
	sector_t	 start;
	sector_t	 end;
	unsigned long	 t_start;
	dev_t		 dev;
	u8		 used;
};

/* Reread_Table slot, 16 B (R8.17).  dev == 0 means empty. */
struct samon_reread {
	u64		 lba4k;		/* key origin: 4KB-unit LBA          */
	u32		 dev;		/* key origin: dev_t, 0 = empty      */
	u32		 t;		/* last read time, (u32)jiffies      */
};
static_assert(sizeof(struct samon_reread) <= 16);

/*
 * Copy of the flow decision, taken under samon_pat_lock and used by the
 * caller after the lock is released.
 */
struct samon_flow {
	u8		 kind;		/* enum samon_flow_kind              */
	sector_t	 start;		/* P3: slot start at decision time   */
	sector_t	 loop_len;	/* P3: L, sectors                    */
};

/* ------------------------------------------------------------------ */
/* Module-level state                                                  */
/* ------------------------------------------------------------------ */

struct damon_sa_ctx {
	/* Legacy per-region I/O counters (binary access detection) */
	atomic_t	 io_counts[DAMON_SA_MAX_REGIONS];
	unsigned int	 nr_regions;
	unsigned long	 region_starts[DAMON_SA_MAX_REGIONS];
	unsigned long	 region_ends[DAMON_SA_MAX_REGIONS];
	bool		 active;
};

static struct damon_sa_ctx sa_ctx;
static DEFINE_MUTEX(sa_ctx_lock);

/* rbtree for LBA->page mapping and frequency tracking */
static struct rb_root samon_lba_tree = RB_ROOT;
static DEFINE_SPINLOCK(samon_lba_lock);
static unsigned int samon_nr_entries;	/* protected by samon_lba_lock */

/* tracepoint registration state (protected by sa_ctx_lock) */
static bool samon_probe_registered;

/*
 * Deferred_Queue state.  The queue and its size are allocated in
 * damon_sa_init() before the probe is registered and freed in
 * damon_sa_cleanup() after tracepoint_synchronize_unregister(); the probe
 * never takes sa_ctx_lock and never allocates or frees queue memory.
 */
static struct samon_cpuq __percpu *samon_q;	/* NULL when not allocated   */
static unsigned int samon_q_cap;		/* slots per CPU, fixed per run */
static bool samon_ready;			/* queue allocated, probe may use it */
static struct samon_qacct samon_qacct_total;	/* finished runs, sa_ctx_lock */
static u64 samon_q_max_delay_us;		/* written by kdamond only   */

/*
 * Pattern tables.  Allocated in samon_alloc_all() (kdamond start, before
 * the probe is registered), sizes fixed for the run, freed in
 * samon_free_all() after tracepoint_synchronize_unregister().  The three
 * tables are protected by one spinlock (L_pat); it is never held together
 * with another spinlock, and folio_get()/folio_put() are never called under
 * it.
 */
static DEFINE_SPINLOCK(samon_pat_lock);
static struct samon_stream *samon_streams[2];	/* [0] read, [1] write       */
static struct samon_loop_rec *samon_loops;
static unsigned int samon_loop_next;		/* circular write cursor     */
static struct samon_reread *samon_reread;
static unsigned int samon_streams_n, samon_loops_n, samon_reread_n; /* per run */

/* Pattern detections, index = enum samon_pat - 1.  Counted for every
 * classified segment, independent of the per-pattern toggle. */
static atomic64_t samon_st_det[6];

/* Stream_Counters: [0] read (stream_r_*), [1] write (stream_w_*), index =
 * enum samon_sev.  Lockless; shown by stats (K10 lines 67~78). */
static atomic64_t samon_st_stream[2][SAMON_NR_SEV];

/*
 * wb_hist (P7 observation, R8.21): completed SAMON_Filter-passing write
 * segments per one-second bucket, 60 buckets in a ring indexed by
 * (jiffies / HZ) % 60.  A bucket whose sec differs from the second being
 * looked at is stale.  Protected by samon_wb_lock (L_wb), a leaf spinlock
 * (irqsave) never held together with another spinlock.  Not used for
 * classification or for the Deferred_Queue.
 */
#define SAMON_WB_BUCKETS	60

struct samon_wb_bucket {
	u32		 sec;		/* jiffies / HZ this bucket counts   */
	u32		 cnt;		/* write segments in that second     */
};

static DEFINE_SPINLOCK(samon_wb_lock);
static struct samon_wb_bucket samon_wb[SAMON_WB_BUCKETS];

/* LRU operations that samon_apply() refused because it was reached from
 * the probe or a non-task context.  Unreachable by design: stays 0. */
static atomic64_t samon_st_direct_ops;

/* Observation statistics: lockless, only for verification/debugging */
static atomic64_t samon_st_rq_seen;	/* requests that passed (1)-(3)    */
static atomic64_t samon_st_skip_error;	/* (1) completion with error       */
static atomic64_t samon_st_skip_passthru;/* (2) passthrough request        */
static atomic64_t samon_st_ctx_hardirq;	/* rq_seen completed in hardirq    */
static atomic64_t samon_st_ctx_softirq;	/* rq_seen completed in softirq    */
static atomic64_t samon_st_ctx_task;	/* rq_seen completed otherwise     */
/* per-CPU: >0 while this CPU is inside damon_sa_bio_trace() */
static DEFINE_PER_CPU(int, samon_in_probe);
static atomic64_t samon_st_seg_buffered;/* segments recorded               */
static atomic64_t samon_st_skip_null;	/* bv_page == NULL                 */
static atomic64_t samon_st_skip_anon;	/* anon/swapcache folio            */
static atomic64_t samon_st_skip_nomap;	/* no address_space                */
static atomic64_t samon_st_skip_pinned;	/* DMA-pinned (direct I/O)         */
static atomic64_t samon_st_drop_full;	/* tree at samon_max_entries       */
static atomic64_t samon_st_drop_nomem;	/* GFP_ATOMIC failure              */
/* breakdown of skip_nomap (the four below always sum to skip_nomap) */
static atomic64_t samon_st_nomap_slab;	/* slab-backed buffer              */
static atomic64_t samon_st_nomap_flagged;/* mapping has movable/ksm flags   */
static atomic64_t samon_st_nomap_meta;	/* mapping==NULL, REQ_META set     */
static atomic64_t samon_st_nomap_other;	/* mapping==NULL, REQ_META clear   */
static atomic64_t samon_st_nomap_write;	/* nomap segments of WRITE (all)   */
static atomic64_t samon_st_skip_dev;	/* request on a non-target disk    */
static atomic64_t samon_st_budget_cut;	/* partial completion (< rq bytes) */

/* debugfs */
static struct dentry *samon_dbgfs_dir;

/* ------------------------------------------------------------------ */
/* rbtree helpers                                                      */
/* ------------------------------------------------------------------ */

/*
 * Lookup or insert an entry for @lba.  Caller must hold samon_lba_lock.
 *
 * @may_insert false (samon_dbg_lba == 0): lookup only.  A missing entry
 * returns NULL without any insertion attempt, so drop_full and drop_nomem
 * are not counted (R8.23).  @may_insert true: returns the entry, NULL only
 * when the tree is full (drop_full) or kmalloc fails (drop_nomem).
 */
static struct samon_lba_entry *samon_lba_get_or_insert(sector_t lba,
						       bool may_insert)
{
	struct rb_node **link = &samon_lba_tree.rb_node;
	struct rb_node  *parent = NULL;
	struct samon_lba_entry *entry;

	while (*link) {
		entry = rb_entry(*link, struct samon_lba_entry, node);
		parent = *link;

		if (lba < entry->lba)
			link = &(*link)->rb_left;
		else if (lba > entry->lba)
			link = &(*link)->rb_right;
		else
			return entry;	/* found */
	}

	if (!may_insert)
		return NULL;

	if (samon_nr_entries >= samon_max_entries) {
		atomic64_inc(&samon_st_drop_full);
		return NULL;
	}

	/* Allocate new entry — use GFP_ATOMIC: we may be in IRQ context */
	entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
	if (!entry) {
		atomic64_inc(&samon_st_drop_nomem);
		return NULL;
	}

	entry->lba          = lba;
	entry->pfn          = 0;
	entry->read_count   = 0;
	entry->write_count  = 0;
	entry->last_jiffies = jiffies;

	rb_link_node(&entry->node, parent, link);
	rb_insert_color(&entry->node, &samon_lba_tree);
	samon_nr_entries++;

	return entry;
}

static void samon_lba_tree_free(void)
{
	struct rb_node *node;
	unsigned long flags;

	spin_lock_irqsave(&samon_lba_lock, flags);
	node = rb_first(&samon_lba_tree);
	while (node) {
		struct samon_lba_entry *e =
			rb_entry(node, struct samon_lba_entry, node);
		node = rb_next(node);
		rb_erase(&e->node, &samon_lba_tree);
		kfree(e);
	}
	samon_nr_entries = 0;
	spin_unlock_irqrestore(&samon_lba_lock, flags);
}

/* ------------------------------------------------------------------ */
/* buffered / direct I/O discrimination (per segment)                  */
/* ------------------------------------------------------------------ */

/*
 * A segment is treated as buffered (page-cache) I/O only if its folio:
 *   - exists (bv_page != NULL),
 *   - is not anonymous / swap cache (anon pages are user buffers handed to
 *     direct I/O, or swap I/O),
 *   - has an address_space (page cache or block-device buffer cache),
 *   - is not DMA-pinned.  Direct I/O pins the user buffer with
 *     pin_user_pages(), so a file-backed (mmap) buffer used for direct I/O
 *     is still rejected here; page-cache folios in buffered I/O are not
 *     pinned by the I/O path.
 *
 * Returns the folio on success, NULL when the segment must be skipped.
 * Every skip reason is counted so the filter can be verified from userspace.
 */
static void samon_classify_nomap(struct bio *bio, struct folio *folio, int dir)
{
	unsigned long raw = (unsigned long)READ_ONCE(folio->mapping);

	atomic64_inc(&samon_st_skip_nomap);
	if (dir == WRITE)
		atomic64_inc(&samon_st_nomap_write);

	if (folio_test_slab(folio)) {
		atomic64_inc(&samon_st_nomap_slab);
	} else if (raw & PAGE_MAPPING_FLAGS) {
		atomic64_inc(&samon_st_nomap_flagged);
	} else if (bio->bi_opf & REQ_META) {
		atomic64_inc(&samon_st_nomap_meta);
	} else {
		atomic64_inc(&samon_st_nomap_other);
		/* the unexplained class: log a few for inspection */
		if (READ_ONCE(samon_dbg_nomap) &&
		    atomic64_read(&samon_st_nomap_other) <= READ_ONCE(samon_dbg_nomap))
			pr_info("nomap: dir=%s opf=0x%x sector=%llu folio_flags=%pGp refcount=%d\n",
				dir == WRITE ? "W" : "R",
				(unsigned int)bio->bi_opf,
				(unsigned long long)bio->bi_iter.bi_sector,
				&folio->flags, folio_ref_count(folio));
	}
}

static struct folio *samon_segment_folio(struct bio *bio, struct bio_vec *bv,
					 int dir)
{
	struct folio *folio;

	if (!bv->bv_page) {
		atomic64_inc(&samon_st_skip_null);
		return NULL;
	}

	folio = page_folio(bv->bv_page);

	if (folio_test_anon(folio) || folio_test_swapcache(folio)) {
		atomic64_inc(&samon_st_skip_anon);
		return NULL;
	}
	if (!folio_mapping(folio)) {
		samon_classify_nomap(bio, folio, dir);
		return NULL;
	}
	if (folio_maybe_dma_pinned(folio)) {
		atomic64_inc(&samon_st_skip_pinned);
		return NULL;
	}

	return folio;
}

/* ------------------------------------------------------------------ */
/* Core bio handler                                                    */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* SAMON_Map update                                                    */
/* ------------------------------------------------------------------ */

struct samon_map_res {
	bool found;	/* an entry exists (found or newly inserted)   */
	bool hot_w;	/* dir == WRITE && write_count >= hot threshold */
};

/*
 * Update the SAMON_Map entry for @lba: window reset, PFN, read/write
 * counter.  Probe context, so the lock is taken with irqsave and the
 * allocation in samon_lba_get_or_insert() is GFP_ATOMIC.
 *
 * @may_insert (samon_dbg_lba != 0): insert a missing entry.  When false
 * (samon_dbg_lba == 0) only existing entries are updated and no new entry is
 * created (R8.23); a missing entry yields found = false, and drop_full /
 * drop_nomem are not counted because no insertion is attempted.
 *
 * Consequence (R8.19): P5 needs a SAMON_Map entry with a hot write counter,
 * so with samon_dbg_lba == 0 no new entries appear and P5 is not detected
 * (write segments without an entry are classified P6).  Entries created
 * earlier while samon_dbg_lba was 1 keep being updated until the tree is
 * freed at kdamond stop.
 */
static struct samon_map_res samon_map_update(sector_t lba, struct page *pg,
					     int dir, bool may_insert)
{
	struct samon_map_res res = { .found = false, .hot_w = false };
	struct samon_lba_entry *entry;
	unsigned long window_jiffies = msecs_to_jiffies(samon_window_ms);
	unsigned long flags;

	spin_lock_irqsave(&samon_lba_lock, flags);

	entry = samon_lba_get_or_insert(lba, may_insert);
	if (!entry)
		goto out;

	/* Window reset */
	if (time_after(jiffies, entry->last_jiffies + window_jiffies)) {
		entry->read_count   = 0;
		entry->write_count  = 0;
		entry->last_jiffies = jiffies;
	}

	/* Record PFN (avoid storing raw struct page* long-term) */
	entry->pfn = page_to_pfn(pg);

	if (dir == READ)
		entry->read_count++;
	else
		entry->write_count++;

	res.found = true;
	res.hot_w = (dir == WRITE) &&
		    (entry->write_count >= samon_hot_threshold);
out:
	spin_unlock_irqrestore(&samon_lba_lock, flags);
	return res;
}

/* ------------------------------------------------------------------ */
/* Deferred_Queue: toggle and enqueue (probe side)                     */
/* ------------------------------------------------------------------ */

/*
 * Is the action of pattern @p enabled?  P5 follows samon_opt_b (bool),
 * P1..P4 follow samon_act_p1..p4 (non-zero = on).  P6 has no action.
 * Used both when queueing and when a queued item is processed.
 */
static bool samon_toggle(enum samon_pat p)
{
	if (p == SAMON_P5)
		return READ_ONCE(samon_opt_b);
	if (p >= SAMON_P1 && p <= SAMON_P4)
		return READ_ONCE(samon_act[p - SAMON_P1]) != 0;
	return false;
}

/*
 * Queue one deferred action on this CPU's queue.  Called from the probe
 * with preemption disabled, so this_cpu_ptr() stays valid.  Everything
 * below runs under q->lock (irqsave) and no other spinlock is taken inside:
 *   - req[] counts every attempt first (R7.2),
 *   - a full ring only counts drop_queue and takes no folio reference,
 *   - otherwise folio_get() (the page cache already holds a reference,
 *     the folio cannot be freed under us), item stored, inflight++.
 * The probe never calls folio_put() or any LRU function.
 */
static void samon_enqueue(struct folio *folio, enum samon_act act,
			  enum samon_pat pat)
{
	struct samon_cpuq *q = this_cpu_ptr(samon_q);
	int k = pat - 1;
	unsigned long flags;

	spin_lock_irqsave(&q->lock, flags);
	q->acct.req[k]++;
	if (q->count >= samon_q_cap) {
		q->acct.drop[SAMON_DROP_QUEUE][k]++;
	} else {
		folio_get(folio);
		q->ring[q->count++] = (struct samon_qitem){
			.folio = folio,
			.t_req = jiffies,
			.act   = act,
			.pat   = pat,
		};
		q->acct.inflight++;
	}
	spin_unlock_irqrestore(&q->lock, flags);
}

/* ------------------------------------------------------------------ */
/* Stream_Table and Loop_History (R8.3 - R8.16, R8.25)                 */
/* ------------------------------------------------------------------ */

/*
 * Everything in this section runs under samon_pat_lock (irqsave) except the
 * entry point samon_stream_update(), which takes it itself.  No other
 * spinlock is taken inside and no folio reference is touched.  Times are
 * jiffies compared with time_after().
 */

/*
 * Candidate comparison (R8.6): larger count wins, then the more recent
 * t_last, then the smaller index.  The caller scans in ascending index, so
 * @a always has a smaller index than @b and a complete tie keeps @a.
 */
static struct samon_stream *samon_better(struct samon_stream *a,
					 struct samon_stream *b)
{
	if (!a)
		return b;
	if (b->count != a->count)
		return b->count > a->count ? b : a;
	return time_after(b->t_last, a->t_last) ? b : a;
}

static void samon_bump(struct samon_stream *x, unsigned long now)
{
	x->count++;
	x->t_last = now;
}

/*
 * Slot to use for a new stream (R8.7): the empty slot with the smallest
 * index; if none is empty, the slot with the smallest count, then the oldest
 * t_last, then the smaller index.
 */
static struct samon_stream *samon_pick_slot(struct samon_stream *T)
{
	struct samon_stream *best = NULL;
	unsigned int i;

	for (i = 0; i < samon_streams_n; i++) {
		struct samon_stream *y = &T[i];

		if (!y->used)
			return y;
		if (!best || y->count < best->count ||
		    (y->count == best->count &&
		     time_after(best->t_last, y->t_last)))
			best = y;
	}
	return best;
}

/*
 * Called right before a read slot is cleared or replaced (R8.13).  If its
 * length reached samon_loop_min_kb, record it in Loop_History at the
 * circular cursor.  Recording and clearing happen in the same lock hold, so
 * a slot is recorded at most once.
 */
static void samon_loop_retire(struct samon_stream *x)
{
	if (x->end - x->start >= (sector_t)READ_ONCE(samon_loop_min_kb) * 2) {
		struct samon_loop_rec *h = &samon_loops[samon_loop_next];

		*h = (struct samon_loop_rec){
			.used    = 1,
			.dev     = x->dev,
			.start   = x->start,
			.end     = x->end,
			.t_start = x->t_start,
		};
		samon_loop_next = (samon_loop_next + 1) % samon_loops_n;
	}
	x->used = 0;
}

/*
 * Loop check of a newly created read slot @n (R8.15): (b) live read slots
 * first, then (a) Loop_History.  Same dev and same start sector is a match;
 * among several matches on one side the latest t_start wins.  A (b) match
 * is retired (recorded and cleared); an (a) record is kept.
 */
static void samon_loop_match(struct samon_stream *n, unsigned long now)
{
	struct samon_stream *live = NULL;
	struct samon_loop_rec *hist = NULL;
	sector_t min = (sector_t)READ_ONCE(samon_loop_min_kb) * 2;
	unsigned int i;

	for (i = 0; i < samon_streams_n; i++) {
		struct samon_stream *y = &samon_streams[0][i];

		if (y == n || !y->used || y->dev != n->dev ||
		    y->start != n->start || y->end - y->start < min)
			continue;
		if (!live || time_after(y->t_start, live->t_start))
			live = y;
	}
	for (i = 0; i < samon_loops_n; i++) {
		struct samon_loop_rec *h = &samon_loops[i];

		if (!h->used || h->dev != n->dev || h->start != n->start)
			continue;
		if (!hist || time_after(h->t_start, hist->t_start))
			hist = h;
	}

	if (live) {
		n->loop = 1;
		n->loop_len = live->end - live->start;
		n->period = now - live->t_start;
		samon_loop_retire(live);	/* length already >= min */
	} else if (hist) {
		n->loop = 1;
		n->loop_len = hist->end - hist->start;
		n->period = now - hist->t_start;
	}
}

/*
 * Flow decision of the slot @x that the request belongs to (R8.1 (나)):
 * a loop read slot is P3 regardless of count (R8.16); otherwise a slot with
 * count >= samon_seq_min is P1 (read) or P4 (write).  @x == NULL: no flow.
 */
static void samon_flow_of(int dir, const struct samon_stream *x,
			  struct samon_flow *f)
{
	f->kind = SAMON_FLOW_NONE;
	if (!x)
		return;
	if (dir == READ && x->loop) {
		f->kind = SAMON_FLOW_P3;
		f->start = x->start;		/* start after any prepend */
		f->loop_len = x->loop_len;
	} else if (x->count >= READ_ONCE(samon_seq_min)) {
		f->kind = dir == READ ? SAMON_FLOW_P1 : SAMON_FLOW_P4;
	}
}

/*
 * Update the Stream_Table of direction @dir once for one request (@devt,
 * start sector @s, @n completed sectors) and fill @flow.  Takes
 * samon_pat_lock itself.
 *
 * Candidates (same dev, used slot), scanned in ascending index:
 *   extend   s >= end && s <= end + gap
 *   prepend  e <= start && e + gap >= start
 *   fill     start <= s && e <= end && s + gap >= end
 *   restart  start <= s && e <= end && s + gap <  end
 * with gap = samon_stream_gap_req * n.  There is no subtraction in any
 * comparison.  Priority extend > prepend > fill; within one kind samon_better().
 * Restart slots are never modified: if no extend/prepend/fill candidate
 * exists and at least one restart slot does, stream_X_restart is counted
 * once for the request, then the "no matching slot" path runs.
 */
static void samon_stream_update(int dir, dev_t devt, sector_t s, sector_t n,
				struct samon_flow *flow)
{
	struct samon_stream *T = samon_streams[dir];
	struct samon_stream *x = NULL;
	struct samon_stream *ext = NULL, *pre = NULL, *fil = NULL;
	sector_t e = s + n;
	sector_t gap = (sector_t)READ_ONCE(samon_stream_gap_req) * n;
	unsigned long now = jiffies, flags;
	int X = dir == READ ? 0 : 1;
	unsigned int i;
	bool rst = false;

	spin_lock_irqsave(&samon_pat_lock, flags);
	for (i = 0; i < samon_streams_n; i++) {
		struct samon_stream *y = &T[i];

		if (!y->used || y->dev != devt)
			continue;
		if (s >= y->end && s <= y->end + gap) {
			ext = samon_better(ext, y);
		} else if (e <= y->start && e + gap >= y->start) {
			pre = samon_better(pre, y);
		} else if (s >= y->start && e <= y->end) {
			if (s + gap >= y->end)
				fil = samon_better(fil, y);
			else
				rst = true;
		}
	}

	if (ext) {
		x = ext;
		x->end = e;
		samon_bump(x, now);
		atomic64_inc(&samon_st_stream[X][SAMON_SEV_EXTEND]);
	} else if (pre) {
		x = pre;
		x->start = s;
		samon_bump(x, now);
		atomic64_inc(&samon_st_stream[X][SAMON_SEV_PREPEND]);
	} else if (fil) {
		x = fil;
		samon_bump(x, now);	/* boundaries, t_start, loop unchanged */
		atomic64_inc(&samon_st_stream[X][SAMON_SEV_FILL]);
	} else {
		/* no matching slot; restart slots stay as they are */
		if (rst)
			atomic64_inc(&samon_st_stream[X][SAMON_SEV_RESTART]);
		if (n >= (sector_t)READ_ONCE(samon_stream_new_kb) * 2) {
			x = samon_pick_slot(T);
			if (x->used) {
				atomic64_inc(&samon_st_stream[X][SAMON_SEV_EVICT]);
				if (dir == READ)
					samon_loop_retire(x);
			}
			*x = (struct samon_stream){
				.used    = 1,
				.dev     = devt,
				.start   = s,
				.end     = e,
				.count   = 1,
				.t_start = now,
				.t_last  = now,
			};
			atomic64_inc(&samon_st_stream[X][SAMON_SEV_NEW_SLOT]);
			if (dir == READ)
				samon_loop_match(x, now);
		}
	}

	samon_flow_of(dir, x, flow);	/* x == NULL -> SAMON_FLOW_NONE */
	spin_unlock_irqrestore(&samon_pat_lock, flags);
}

/* ------------------------------------------------------------------ */
/* Segment classification                                              */
/* ------------------------------------------------------------------ */

/*
 * Reread_Table lookup and overwrite in one samon_pat_lock hold (R8.17,
 * R8.18).  Called only for read segments that are neither P3 nor P1, and
 * only with @devt != 0 (dev == 0 marks an empty slot).
 *
 * Slot = reciprocal_scale((u32)hash_64(key, 32), samon_reread_n) with
 * key = lba4k ^ ((u64)devt << 40).  A hit needs the same stored key origin
 * (dev, lba4k) and (u32)(now32 - r->t) <= window.  The slot is overwritten
 * with the current key and time whether or not it hit.  The time difference
 * is explicit u32 arithmetic: time_after() would type-check against
 * unsigned long, and the slot only keeps 32 bits.  The window is clamped to
 * U32_MAX so a huge samon_reread_ms cannot wrap to a short window.
 */
static bool samon_reread_hit(dev_t devt, u64 lba4k)
{
	u64 key = lba4k ^ ((u64)devt << 40);
	u32 idx = reciprocal_scale((u32)hash_64(key, 32), samon_reread_n);
	struct samon_reread *r = &samon_reread[idx];
	u32 now32 = (u32)jiffies;
	u32 win = min_t(unsigned long,
			msecs_to_jiffies(READ_ONCE(samon_reread_ms)), U32_MAX);
	unsigned long flags;
	bool hit;

	spin_lock_irqsave(&samon_pat_lock, flags);
	hit = r->dev == (u32)devt && r->lba4k == lba4k &&
	      (u32)(now32 - r->t) <= win;
	r->dev = (u32)devt;		/* overwrite whether or not it hit */
	r->lba4k = lba4k;
	r->t = now32;
	spin_unlock_irqrestore(&samon_pat_lock, flags);
	return hit;
}

/*
 * Per-segment decision: exactly one pattern per segment, priority
 * P3 > P1 > P2 > P4 > P5 > P6 (R8.2).  *act is the action to queue for the
 * pattern (NONE for P6).
 *
 * @lba is the starting sector of this segment (disk based), @f the
 * request's flow decision from samon_stream_update(), @m the SAMON_Map
 * result of this segment.
 *   read : P3 if the flow is a loop (promote when 100*d < L*pct, d being
 *          the distance from the slot start, else demote; u64 math, no
 *          division), else P1 (demote) if the flow is a sequential read,
 *          else P2 (promote) if Reread_Table hits, else P6.  Reread_Table
 *          is touched only for reads that are neither P3 nor P1 (R8.18).
 *   write: P4 (demote) if the flow is a sequential write, else P5 (mark) if
 *          the SAMON_Map entry exists and is hot for writes, else P6.
 *          With samon_dbg_lba == 0 no new SAMON_Map entries are created, so
 *          P5 is not detected and such segments become P6 (R8.19).
 */
static enum samon_pat samon_classify_seg(int dir, dev_t devt, sector_t lba,
					 const struct samon_flow *f,
					 const struct samon_map_res *m,
					 enum samon_act *act)
{
	*act = SAMON_ACT_NONE;
	if (dir == READ) {
		if (f->kind == SAMON_FLOW_P3) {
			u64 d = lba > f->start ? lba - f->start : 0;

			*act = (100 * d < (u64)f->loop_len *
				READ_ONCE(samon_loop_protect_pct))
				? SAMON_ACT_PROMOTE : SAMON_ACT_DEMOTE;
			return SAMON_P3;
		}
		if (f->kind == SAMON_FLOW_P1) {
			*act = SAMON_ACT_DEMOTE;
			return SAMON_P1;
		}
		if (samon_reread_hit(devt, lba >> 3)) {
			*act = SAMON_ACT_PROMOTE;
			return SAMON_P2;
		}
		return SAMON_P6;
	}
	if (f->kind == SAMON_FLOW_P4) {
		*act = SAMON_ACT_DEMOTE;
		return SAMON_P4;
	}
	if (m->found && m->hot_w) {
		*act = SAMON_ACT_MARK;
		return SAMON_P5;
	}
	return SAMON_P6;
}

/* ------------------------------------------------------------------ */
/* wb_hist (P7 observation)                                            */
/* ------------------------------------------------------------------ */

/*
 * Add @nw write segments to the bucket of the current second (K8).  Called
 * from the probe at most once per request, with no other spinlock held.
 */
static void samon_wb_add(u32 nw)
{
	u32 sec = (u32)(jiffies / HZ);
	struct samon_wb_bucket *b = &samon_wb[sec % SAMON_WB_BUCKETS];
	unsigned long flags;

	spin_lock_irqsave(&samon_wb_lock, flags);
	if (b->sec != sec) {
		b->sec = sec;
		b->cnt = 0;
	}
	b->cnt += nw;
	spin_unlock_irqrestore(&samon_wb_lock, flags);
}

/* Empty all buckets.  Called at kdamond start, probe not registered yet. */
static void samon_wb_reset(void)
{
	unsigned long flags;

	spin_lock_irqsave(&samon_wb_lock, flags);
	memset(samon_wb, 0, sizeof(samon_wb));
	spin_unlock_irqrestore(&samon_wb_lock, flags);
}

/* ------------------------------------------------------------------ */
/* Core request handler                                                */
/* ------------------------------------------------------------------ */

/*
 * @nr_bytes: bytes completed by this block_rq_complete event.  The
 * tracepoint fires before bio_advance(), once per (possibly partial)
 * completion, and the bios still hanging off the request reflect only the
 * not-yet-completed part.  Walking only @nr_bytes avoids counting a segment
 * again when the request completes in several steps.
 *
 * Every SAMON_Filter-passing segment updates SAMON_Map and counts into
 * seg_buffered.  If the disk is unknown (@devt == 0) or the tables/queue
 * are not ready, classification and queueing are skipped.  Otherwise the
 * Stream_Table is updated once per request, at the first filter-passing
 * segment (R8.1 (가)); the flow decision it returns applies to all
 * filter-passing segments of the request.  Each segment gets exactly one
 * pattern (det_pN, independent of the toggle) and, for P1..P5 with the
 * toggle on, one queue request.
 */
static void samon_handle_rq(struct request *rq, int dir, dev_t devt,
			    unsigned int nr_bytes)
{
	struct samon_flow flow = { .kind = SAMON_FLOW_UNSET };
	sector_t rq_start = blk_rq_pos(rq);		/* start of the not yet completed part */
	sector_t rq_nsec = nr_bytes >> SECTOR_SHIFT;	/* sectors completed now */
	unsigned int budget = nr_bytes;
	u32 nw = 0;			/* classified write segments (wb_hist) */
	struct bio *bio;

	__rq_for_each_bio(bio, rq) {
		struct bio_vec bv;
		struct bvec_iter iter;
		sector_t lba = bio->bi_iter.bi_sector;

		bio_for_each_segment(bv, bio, iter) {
			struct folio *folio;
			struct samon_map_res m;
			enum samon_pat pat;
			enum samon_act act;

			if (!budget)
				goto done;
			budget -= min(budget, bv.bv_len);

			folio = samon_segment_folio(bio, &bv, dir);
			if (!folio)
				goto next_seg;

			/* once per request, at the first passing segment */
			if (devt && READ_ONCE(samon_ready) &&
			    flow.kind == SAMON_FLOW_UNSET)
				samon_stream_update(dir, devt, rq_start,
						    rq_nsec, &flow);

			m = samon_map_update(lba, bv.bv_page, dir,
					     READ_ONCE(samon_dbg_lba) != 0);
			atomic64_inc(&samon_st_seg_buffered);

			if (!devt || !READ_ONCE(samon_ready))
				goto next_seg;

			pat = samon_classify_seg(dir, devt, lba, &flow, &m, &act);
			atomic64_inc(&samon_st_det[pat - 1]);
			if (dir == WRITE)
				nw++;

			if (pat != SAMON_P6 && samon_toggle(pat))
				samon_enqueue(folio, act, pat);
next_seg:
			lba += bv.bv_len >> SECTOR_SHIFT;
		}
	}
done:
	/* once per request, after the segment walk and outside any lock (K2) */
	if (nw)
		samon_wb_add(nw);
}

/* ------------------------------------------------------------------ */
/* block_rq_complete tracepoint probe                                  */
/* ------------------------------------------------------------------ */

/*
 * Legacy region-counter path (binary access detection), unchanged.
 * nr_regions is published with WRITE_ONCE() by the updater and read
 * once here, clamped to the array size, so a concurrent update can at
 * worst yield a stale region lookup but never an out-of-bounds index.
 */
static void samon_legacy_region_count(struct request *rq)
{
	unsigned long sector;
	int lo, hi, mid;
	unsigned int nr;

	nr = min_t(unsigned int, READ_ONCE(sa_ctx.nr_regions),
		   DAMON_SA_MAX_REGIONS);
	if (!nr)
		return;

	sector = blk_rq_pos(rq);
	lo = 0;
	hi = nr - 1;
	while (lo <= hi) {
		mid = (lo + hi) / 2;
		if (sector < sa_ctx.region_starts[mid])
			hi = mid - 1;
		else if (sector >= sa_ctx.region_ends[mid])
			lo = mid + 1;
		else {
			atomic_inc(&sa_ctx.io_counts[mid]);
			break;
		}
	}
}

static void damon_sa_bio_trace(void *data, struct request *rq,
			       blk_status_t error, unsigned int nr_bytes)
{
	struct gendisk *disk;
	dev_t devt;
	int dir;

	/* Outside the registered window: not counted at all */
	if (!READ_ONCE(sa_ctx.active))
		return;

	/* Watch counter for samon_apply(); nesting allowed, every path below
	 * leaves through "out" so the decrement always pairs with this. */
	this_cpu_inc(samon_in_probe);

	/*
	 * Exactly one of (1)..(4) counts each completion in the window:
	 *   (1) skip_error, (2) skip_passthru, (3) skip_dev, (4) rq_seen.
	 */
	if (error) {					/* (1) */
		atomic64_inc(&samon_st_skip_error);
		goto out;
	}
	if (blk_rq_is_passthrough(rq)) {		/* (2) */
		atomic64_inc(&samon_st_skip_passthru);
		goto out;
	}
	disk = rq->q ? rq->q->disk : NULL;
	if (READ_ONCE(samon_dev_major) &&		/* (3) */
	    (!disk || disk->major != READ_ONCE(samon_dev_major) ||
	     disk->first_minor != READ_ONCE(samon_dev_minor))) {
		atomic64_inc(&samon_st_skip_dev);
		goto out;
	}
	atomic64_inc(&samon_st_rq_seen);		/* (4) */
	if (in_hardirq())
		atomic64_inc(&samon_st_ctx_hardirq);
	else if (in_serving_softirq())
		atomic64_inc(&samon_st_ctx_softirq);
	else
		atomic64_inc(&samon_st_ctx_task);

	samon_legacy_region_count(rq);

	if (nr_bytes < blk_rq_bytes(rq))
		atomic64_inc(&samon_st_budget_cut);

	dir = rq_data_dir(rq); /* READ or WRITE */
	devt = disk ? disk_devt(disk) : 0; /* samon_dev_major == 0: disk may be NULL */
	samon_handle_rq(rq, dir, devt, nr_bytes);
out:
	this_cpu_dec(samon_in_probe);
}

/* ------------------------------------------------------------------ */
/* DAMON operations callbacks                                          */
/* ------------------------------------------------------------------ */

static void damon_sa_update_region_map(struct damon_ctx *ctx)
{
	struct damon_target *t;
	struct damon_region *r;
	int idx = 0;

	mutex_lock(&sa_ctx_lock);
	damon_for_each_target(t, ctx) {
		damon_for_each_region(r, t) {
			if (idx >= DAMON_SA_MAX_REGIONS)
				break;
			sa_ctx.region_starts[idx] = r->ar.start;
			sa_ctx.region_ends[idx]   = r->ar.end;
			idx++;
		}
	}
	WRITE_ONCE(sa_ctx.nr_regions, idx);
	mutex_unlock(&sa_ctx_lock);
}

/* ------------------------------------------------------------------ */
/* Deferred_Queue: allocation, release, shutdown                       */
/* ------------------------------------------------------------------ */

/* dst += src, every field.  Callers serialize access to both. */
static void samon_qacct_add(struct samon_qacct *dst,
			    const struct samon_qacct *src)
{
	int k, r;

	for (k = 0; k < SAMON_NR_QPAT; k++) {
		dst->req[k]  += src->req[k];
		dst->exec[k] += src->exec[k];
		for (r = 0; r < SAMON_NR_DROP; r++)
			dst->drop[r][k] += src->drop[r][k];
	}
	dst->inflight += src->inflight;
}

/*
 * Release everything samon_alloc_all() may have allocated.  Safe on a
 * partial allocation (alloc_percpu() zeroes, kvfree(NULL) is a no-op).
 * Caller holds sa_ctx_lock and guarantees no probe or actuator is using
 * the queue (probe unregistered and synchronized, or never registered).
 */
static void samon_free_all(void)
{
	int cpu;

	if (samon_q) {
		for_each_possible_cpu(cpu) {
			struct samon_cpuq *q = per_cpu_ptr(samon_q, cpu);

			kvfree(q->ring);
			kvfree(q->drain);
			q->ring = NULL;
			q->drain = NULL;
		}
		free_percpu(samon_q);
		samon_q = NULL;
	}
	samon_q_cap = 0;

	/* pattern tables (NULL-safe: kfree/kvfree accept NULL) */
	kfree(samon_streams[0]);
	kfree(samon_streams[1]);
	samon_streams[0] = NULL;
	samon_streams[1] = NULL;
	kfree(samon_loops);
	samon_loops = NULL;
	kvfree(samon_reread);
	samon_reread = NULL;
	samon_streams_n = 0;
	samon_loops_n = 0;
	samon_reread_n = 0;
	samon_loop_next = 0;
}

/*
 * Allocate the per-CPU Deferred_Queue and the pattern tables.  Process
 * context only (GFP_KERNEL); caller holds sa_ctx_lock and has not
 * registered the probe yet.
 *   1. fix the sizes for this run from samon_q_len, samon_stream_slots,
 *      samon_loop_slots, samon_reread_slots
 *   2. per-CPU struct, then per CPU: lock, ring, drain array
 *   3. Stream_Table (one array per direction), Loop_History (cursor 0),
 *      Reread_Table; all zero-filled, so every table starts empty
 * On failure everything allocated so far is released and -ENOMEM returned.
 * __GFP_NOWARN: the caller logs the failure itself (also covers an absurd
 * size parameter, for which the allocators would otherwise WARN).
 */
static int samon_alloc_all(void)
{
	unsigned int cap = READ_ONCE(samon_q_len);
	int cpu;

	samon_wb_reset();		/* wb_hist starts empty each run */
	samon_q_cap = cap;
	samon_streams_n = READ_ONCE(samon_stream_slots);
	samon_loops_n = READ_ONCE(samon_loop_slots);
	samon_reread_n = READ_ONCE(samon_reread_slots);

	samon_q = alloc_percpu(struct samon_cpuq);
	if (!samon_q)
		goto nomem;

	for_each_possible_cpu(cpu) {
		struct samon_cpuq *q = per_cpu_ptr(samon_q, cpu);

		spin_lock_init(&q->lock);
		q->ring = kvcalloc(cap, sizeof(*q->ring),
				   GFP_KERNEL | __GFP_NOWARN);
		q->drain = kvcalloc(cap, sizeof(*q->drain),
				    GFP_KERNEL | __GFP_NOWARN);
		if (!q->ring || !q->drain)
			goto nomem;
	}

	samon_streams[0] = kcalloc(samon_streams_n, sizeof(*samon_streams[0]),
				   GFP_KERNEL | __GFP_NOWARN);
	samon_streams[1] = kcalloc(samon_streams_n, sizeof(*samon_streams[1]),
				   GFP_KERNEL | __GFP_NOWARN);
	samon_loops = kcalloc(samon_loops_n, sizeof(*samon_loops),
			      GFP_KERNEL | __GFP_NOWARN);
	samon_loop_next = 0;
	samon_reread = kvcalloc(samon_reread_n, sizeof(*samon_reread),
				GFP_KERNEL | __GFP_NOWARN);
	if (!samon_streams[0] || !samon_streams[1] || !samon_loops ||
	    !samon_reread)
		goto nomem;
	return 0;

nomem:
	samon_free_all();
	return -ENOMEM;
}

/*
 * kdamond stop: every item still in a ring gets drop_shutdown_pN and one
 * folio_put(), with no LRU operation.  Then each queue's accounting is
 * folded into samon_qacct_total so the counters stay cumulative.
 *
 * Caller holds sa_ctx_lock; the probe is unregistered and synchronized
 * (no producer) and the actuator runs on this same kthread (no consumer).
 * Queue locks are still taken one at a time and folio_put() runs outside
 * them.  samon_qacct_total is protected by sa_ctx_lock, not by a spinlock.
 */
static void samon_q_shutdown(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct samon_cpuq *q = per_cpu_ptr(samon_q, cpu);
		struct samon_qacct b = {};
		unsigned long flags;
		u32 i, n;

		spin_lock_irqsave(&q->lock, flags);
		n = q->count;
		if (n)
			memcpy(q->drain, q->ring, n * sizeof(*q->ring));
		q->count = 0;
		spin_unlock_irqrestore(&q->lock, flags);

		for (i = 0; i < n; i++) {
			b.drop[SAMON_DROP_SHUTDOWN][q->drain[i].pat - 1]++;
			folio_put(q->drain[i].folio);
		}

		spin_lock_irqsave(&q->lock, flags);
		samon_qacct_add(&q->acct, &b);
		q->acct.inflight -= n;
		/* inflight is 0 now: fold into the cumulative total */
		samon_qacct_add(&samon_qacct_total, &q->acct);
		memset(&q->acct, 0, sizeof(q->acct));
		spin_unlock_irqrestore(&q->lock, flags);

		cond_resched();
	}
}

static void damon_sa_init(struct damon_ctx *ctx)
{
	int i;

	mutex_lock(&sa_ctx_lock);
	for (i = 0; i < DAMON_SA_MAX_REGIONS; i++)
		atomic_set(&sa_ctx.io_counts[i], 0);
	WRITE_ONCE(sa_ctx.nr_regions, 0);
	WRITE_ONCE(samon_q_max_delay_us, 0);

	/* kdamond may be restarted: never register the probe twice */
	if (samon_probe_registered) {
		WRITE_ONCE(sa_ctx.active, true);
		goto unlock;
	}

	/*
	 * Allocate the queue before the probe exists.  ops.init cannot fail
	 * the kdamond start, so on failure the probe is simply not registered
	 * (req_pN / exec_pN stay put) and the error is logged.
	 */
	if (samon_alloc_all()) {
		pr_err("queue/table allocation failed (q_len=%u stream_slots=%u loop_slots=%u reread_slots=%u), block_rq_complete probe not registered\n",
		       READ_ONCE(samon_q_len), READ_ONCE(samon_stream_slots),
		       READ_ONCE(samon_loop_slots),
		       READ_ONCE(samon_reread_slots));
		goto unlock;
	}
	WRITE_ONCE(samon_ready, true);
	WRITE_ONCE(sa_ctx.active, true);

	if (register_trace_block_rq_complete(damon_sa_bio_trace, NULL)) {
		pr_err("failed to register block_rq_complete probe\n");
		WRITE_ONCE(sa_ctx.active, false);
		WRITE_ONCE(samon_ready, false);
		samon_free_all();
	} else {
		samon_probe_registered = true;
	}
unlock:
	mutex_unlock(&sa_ctx_lock);
}

/* ------------------------------------------------------------------ */
/* SAMON_Actuator (kdamond, process context)                           */
/* ------------------------------------------------------------------ */

/*
 * The one and only place that calls an LRU function (folio_activate,
 * folio_deactivate, folio_mark_accessed).  All three need task context
 * (folio_activate/deactivate take local_lock(&cpu_fbatches.lock), which
 * does not disable interrupts).  Reaching this from the probe or from a
 * non-task context cannot happen by design; if it ever does, do nothing
 * and count it (direct_ops must stay 0).  No spinlock may be held.
 */
static void samon_apply(struct folio *folio, enum samon_act act)
{
	if (unlikely(!in_task() || this_cpu_read(samon_in_probe))) {
		atomic64_inc(&samon_st_direct_ops);
		return;
	}

	switch (act) {
	case SAMON_ACT_PROMOTE:
		folio_activate(folio);
		break;
	case SAMON_ACT_DEMOTE:
		folio_deactivate(folio);
		break;
	case SAMON_ACT_MARK:
		folio_mark_accessed(folio);
		break;
	default:
		break;
	}
}

/*
 * Handle one drained item with no lock held.  Exactly one outcome is
 * counted into @b, in this order:
 *   (a) toggle now off          -> drop_toggle
 *   (b) waited too long         -> drop_stale
 *   (c) no longer a valid LRU page-cache target (P4 also: dirty or
 *       under writeback)        -> drop_revalidate
 *   (d) otherwise               -> samon_apply(), exec
 * The pending delay maximum is updated for every outcome, and the
 * reference taken by samon_enqueue() is released exactly once.
 */
static void samon_process(const struct samon_qitem *it, struct samon_qacct *b)
{
	struct folio *folio = it->folio;
	unsigned long now = jiffies;
	int k = it->pat - 1;
	u64 us;

	if (!samon_toggle(it->pat))						/* (a) */
		b->drop[SAMON_DROP_TOGGLE][k]++;
	else if (time_after(now, it->t_req +
			    msecs_to_jiffies(READ_ONCE(samon_q_max_ms))))	/* (b) */
		b->drop[SAMON_DROP_STALE][k]++;
	else if (!folio_test_lru(folio) || !folio_mapping(folio) ||
		 folio_test_unevictable(folio) ||
		 (it->pat == SAMON_P4 &&
		  (folio_test_dirty(folio) ||
		   folio_test_writeback(folio))))				/* (c) */
		b->drop[SAMON_DROP_REVALIDATE][k]++;
	else {									/* (d) */
		samon_apply(folio, it->act);
		b->exec[k]++;
	}

	/* only this kthread writes it; stats readers use READ_ONCE */
	us = jiffies_to_usecs(now - it->t_req);
	if (us > READ_ONCE(samon_q_max_delay_us))
		WRITE_ONCE(samon_q_max_delay_us, us);

	folio_put(folio);
}

/*
 * Drain every CPU's queue.  Per CPU: under q->lock copy the ring into the
 * drain array and empty it; process the copies with no lock held; then
 * under q->lock add the batch result and release the inflight count.  Items
 * queued after the copy wait for the next call.  The locks are never
 * nested and folio_put()/LRU functions never run under a spinlock.
 */
static void samon_actuate(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct samon_cpuq *q = per_cpu_ptr(samon_q, cpu);
		struct samon_qacct b = {};
		unsigned long flags;
		u32 i, n;

		spin_lock_irqsave(&q->lock, flags);
		n = q->count;
		if (n)
			memcpy(q->drain, q->ring, n * sizeof(*q->ring));
		q->count = 0;
		spin_unlock_irqrestore(&q->lock, flags);

		for (i = 0; i < n; i++)
			samon_process(&q->drain[i], &b);

		spin_lock_irqsave(&q->lock, flags);
		samon_qacct_add(&q->acct, &b);
		q->acct.inflight -= n;
		spin_unlock_irqrestore(&q->lock, flags);

		cond_resched();
	}
}

/*
 * Idle sweep of the read Stream_Table (R8.14, K6).  Runs in kdamond (process
 * context) right after samon_actuate().  Under samon_pat_lock (irqsave, no
 * other spinlock, no folio_get()/folio_put()) every used read slot whose
 * last update is at least samon_stream_idle_ms old and whose length is at
 * least samon_loop_min_kb is recorded in Loop_History and cleared by
 * samon_loop_retire().  Idle slots shorter than the minimum length are left
 * alone, as are all write slots: R8.14 says slots that do not meet both
 * conditions are not changed (they are only replaced through
 * samon_pick_slot()).
 */
static void samon_idle_sweep(void)
{
	unsigned long now = jiffies, flags;
	unsigned long idle = msecs_to_jiffies(READ_ONCE(samon_stream_idle_ms));
	sector_t min = (sector_t)READ_ONCE(samon_loop_min_kb) * 2;
	unsigned int i;

	spin_lock_irqsave(&samon_pat_lock, flags);
	for (i = 0; i < samon_streams_n; i++) {
		struct samon_stream *x = &samon_streams[0][i];

		if (x->used && time_after_eq(now, x->t_last + idle) &&
		    x->end - x->start >= min)
			samon_loop_retire(x);
	}
	spin_unlock_irqrestore(&samon_pat_lock, flags);
}

static void damon_sa_prepare_access_checks(struct damon_ctx *ctx)
{
	int i;

	/* S1: consume the Deferred_Queue first (kdamond, process context).
	 * samon_ready is only set between init and cleanup of this kthread. */
	if (READ_ONCE(samon_ready)) {
		samon_actuate();
		samon_idle_sweep();	/* S2, R8.14 */
	}

	damon_sa_update_region_map(ctx);

	for (i = 0; i < sa_ctx.nr_regions; i++)
		atomic_set(&sa_ctx.io_counts[i], 0);
}

static unsigned int damon_sa_check_accesses(struct damon_ctx *ctx)
{
	struct damon_target *t;
	struct damon_region *r;
	unsigned int max_nr_accesses = 0;
	int idx = 0;

	damon_for_each_target(t, ctx) {
		damon_for_each_region(r, t) {
			bool accessed;

			if (idx >= sa_ctx.nr_regions)
				break;

			accessed = (atomic_read(&sa_ctx.io_counts[idx]) > 0);
			damon_update_region_access_rate(r, accessed,
							&ctx->attrs);
			max_nr_accesses = max(r->nr_accesses, max_nr_accesses);
			idx++;
		}
	}

	return max_nr_accesses;
}

static void damon_sa_cleanup(struct damon_ctx *ctx)
{
	mutex_lock(&sa_ctx_lock);
	if (samon_probe_registered) {
		unregister_trace_block_rq_complete(damon_sa_bio_trace, NULL);
		samon_probe_registered = false;
	}
	WRITE_ONCE(sa_ctx.active, false);
	mutex_unlock(&sa_ctx_lock);
	tracepoint_synchronize_unregister();	/* sleeps: no lock held */

	/* No producer is left.  Drain what is queued, then free. */
	mutex_lock(&sa_ctx_lock);
	WRITE_ONCE(samon_ready, false);
	if (samon_q) {
		samon_q_shutdown();
		samon_free_all();
	}
	mutex_unlock(&sa_ctx_lock);

	samon_lba_tree_free();
}

static int damon_sa_scheme_score(struct damon_ctx *c, struct damon_target *t,
				 struct damon_region *r, struct damos *s)
{
	return damon_hot_score(c, r, s);
}

/* ------------------------------------------------------------------ */
/* debugfs: /sys/kernel/debug/samon/lba_page_map                      */
/* ------------------------------------------------------------------ */

static int samon_dbgfs_show(struct seq_file *m, void *v)
{
	struct rb_node *node;
	unsigned long flags;

	seq_puts(m, "# lba(sector) pfn reads writes hot_r hot_w\n");

	spin_lock_irqsave(&samon_lba_lock, flags);
	for (node = rb_first(&samon_lba_tree); node; node = rb_next(node)) {
		struct samon_lba_entry *e =
			rb_entry(node, struct samon_lba_entry, node);

		seq_printf(m,
			   "lba=%-12llu pfn=%-8lu reads=%-6llu writes=%-6llu"
			   " hot_r=%d hot_w=%d\n",
			   (unsigned long long)e->lba,
			   e->pfn,
			   e->read_count,
			   e->write_count,
			   (e->read_count  >= samon_hot_threshold),
			   (e->write_count >= samon_hot_threshold));
	}
	spin_unlock_irqrestore(&samon_lba_lock, flags);

	return 0;
}

static int samon_dbgfs_open(struct inode *inode, struct file *file)
{
	return single_open(file, samon_dbgfs_show, NULL);
}

static const struct file_operations samon_dbgfs_fops = {
	.owner   = THIS_MODULE,
	.open    = samon_dbgfs_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

/*
 * Aggregate the Deferred_Queue accounting for SAMON_Stats: the total of
 * finished runs plus every live per-CPU queue.  Everything runs under
 * sa_ctx_lock (the queue cannot be freed meanwhile) and the queue locks are
 * taken one at a time, never nested (lock order: sa_ctx_lock -> q->lock,
 * same as samon_q_shutdown()).  Each queue satisfies
 *   req = exec + sum(drop) + inflight
 * on its own whenever its lock is not held, and samon_qacct_total satisfies
 * it with inflight = 0, so the sum satisfies it as well.
 * *cap is 0 when no queue is allocated (kdamond stopped).
 */
static void samon_stats_collect(struct samon_qacct *a, u32 *cap)
{
	int cpu;

	*cap = 0;
	mutex_lock(&sa_ctx_lock);
	*a = samon_qacct_total;			/* earlier runs */
	if (samon_q) {
		*cap = samon_q_cap;
		for_each_possible_cpu(cpu) {
			struct samon_cpuq *q = per_cpu_ptr(samon_q, cpu);
			unsigned long flags;

			spin_lock_irqsave(&q->lock, flags);
			samon_qacct_add(a, &q->acct);	/* inflight too */
			spin_unlock_irqrestore(&q->lock, flags);
		}
	}
	mutex_unlock(&sa_ctx_lock);
}

/* debugfs: /sys/kernel/debug/samon/stats (line order: design K10) */
static int samon_stats_show(struct seq_file *m, void *v)
{
	static const char * const drop_name[SAMON_NR_DROP] = {
		[SAMON_DROP_QUEUE]	= "queue",
		[SAMON_DROP_STALE]	= "stale",
		[SAMON_DROP_REVALIDATE]	= "revalidate",
		[SAMON_DROP_TOGGLE]	= "toggle",
		[SAMON_DROP_SHUTDOWN]	= "shutdown",
	};
	static const char * const sev_name[SAMON_NR_SEV] = {
		[SAMON_SEV_EXTEND]	= "extend",
		[SAMON_SEV_PREPEND]	= "prepend",
		[SAMON_SEV_FILL]	= "fill",
		[SAMON_SEV_RESTART]	= "restart",
		[SAMON_SEV_NEW_SLOT]	= "new_slot",
		[SAMON_SEV_EVICT]	= "evict",
	};
	struct samon_qacct a;
	unsigned long flags;
	unsigned int nr;
	u32 cap;
	int k, r;

	spin_lock_irqsave(&samon_lba_lock, flags);
	nr = samon_nr_entries;
	spin_unlock_irqrestore(&samon_lba_lock, flags);

	samon_stats_collect(&a, &cap);

	/* K10 1~15: existing counters */
	seq_printf(m, "rq_seen=%lld\n",
		   (long long)atomic64_read(&samon_st_rq_seen));
	seq_printf(m, "seg_buffered=%lld\n",
		   (long long)atomic64_read(&samon_st_seg_buffered));
	seq_printf(m, "skip_null=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_null));
	seq_printf(m, "skip_anon=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_anon));
	seq_printf(m, "skip_nomap=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_nomap));
	seq_printf(m, "skip_pinned=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_pinned));
	seq_printf(m, "drop_full=%lld\n",
		   (long long)atomic64_read(&samon_st_drop_full));
	seq_printf(m, "drop_nomem=%lld\n",
		   (long long)atomic64_read(&samon_st_drop_nomem));
	seq_printf(m, "nomap_slab=%lld\n",
		   (long long)atomic64_read(&samon_st_nomap_slab));
	seq_printf(m, "nomap_flagged=%lld\n",
		   (long long)atomic64_read(&samon_st_nomap_flagged));
	seq_printf(m, "nomap_meta=%lld\n",
		   (long long)atomic64_read(&samon_st_nomap_meta));
	seq_printf(m, "nomap_other=%lld\n",
		   (long long)atomic64_read(&samon_st_nomap_other));
	seq_printf(m, "nomap_write=%lld\n",
		   (long long)atomic64_read(&samon_st_nomap_write));
	seq_printf(m, "skip_dev=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_dev));
	seq_printf(m, "budget_cut=%lld\n",
		   (long long)atomic64_read(&samon_st_budget_cut));

	/* 16: compatibility alias, always equal to req_p5 */
	seq_printf(m, "mark_accessed=%llu\n",
		   (unsigned long long)a.req[SAMON_P5 - 1]);

	/* 17~21: probe entry accounting (R6) */
	seq_printf(m, "skip_error=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_error));
	seq_printf(m, "skip_passthru=%lld\n",
		   (long long)atomic64_read(&samon_st_skip_passthru));
	seq_printf(m, "ctx_hardirq=%lld\n",
		   (long long)atomic64_read(&samon_st_ctx_hardirq));
	seq_printf(m, "ctx_softirq=%lld\n",
		   (long long)atomic64_read(&samon_st_ctx_softirq));
	seq_printf(m, "ctx_task=%lld\n",
		   (long long)atomic64_read(&samon_st_ctx_task));

	/* 22~27: det_p1..det_p6 */
	for (k = 0; k < ARRAY_SIZE(samon_st_det); k++)
		seq_printf(m, "det_p%d=%lld\n", k + 1,
			   (long long)atomic64_read(&samon_st_det[k]));

	/* 28~32: req_p1..req_p5, 33~37: exec_p1..exec_p5 (aggregated) */
	for (k = 0; k < SAMON_NR_QPAT; k++)
		seq_printf(m, "req_p%d=%llu\n", k + 1,
			   (unsigned long long)a.req[k]);
	for (k = 0; k < SAMON_NR_QPAT; k++)
		seq_printf(m, "exec_p%d=%llu\n", k + 1,
			   (unsigned long long)a.exec[k]);

	/* 38~62: drop_<reason>_pN, reason-major, N = 1..5 */
	for (r = 0; r < SAMON_NR_DROP; r++)
		for (k = 0; k < SAMON_NR_QPAT; k++)
			seq_printf(m, "drop_%s_p%d=%llu\n", drop_name[r],
				   k + 1,
				   (unsigned long long)a.drop[r][k]);

	/* 63~66: queue state.  q_cur is the aggregated inflight (ring items
	 * plus drained items whose outcome is not counted yet), so
	 * req_pN = exec_pN + sum(drop_*_pN) + (inflight share) holds exactly
	 * and the R4.3 equality is exact whenever q_cur is 0. */
	seq_printf(m, "q_cur=%llu\n", (unsigned long long)a.inflight);
	seq_printf(m, "q_max_delay_us=%llu\n",
		   (unsigned long long)READ_ONCE(samon_q_max_delay_us));
	seq_printf(m, "q_cap=%u\n", cap);
	seq_printf(m, "direct_ops=%lld\n",
		   (long long)atomic64_read(&samon_st_direct_ops));

	/* 67~78: Stream_Counters, read (r) first then write (w), each in
	 * enum samon_sev order (R8.11); cumulative, never reset */
	for (r = 0; r < 2; r++)
		for (k = 0; k < SAMON_NR_SEV; k++)
			seq_printf(m, "stream_%c_%s=%lld\n", r ? 'w' : 'r',
				   sev_name[k],
				   (long long)atomic64_read(&samon_st_stream[r][k]));

	/* last line keeps its legacy format (verify entries parser) */
	seq_printf(m, "entries=%u max_entries=%u\n", nr, samon_max_entries);
	return 0;
}

static int samon_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, samon_stats_show, NULL);
}

static const struct file_operations samon_stats_fops = {
	.owner   = THIS_MODULE,
	.open    = samon_stats_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

/* ------------------------------------------------------------------ */
/* debugfs: /sys/kernel/debug/samon/streams (R8.24, design K10)       */
/* ------------------------------------------------------------------ */

/*
 * Stream_Table (both directions, used slots) and Loop_History (recorded
 * slots).  seq_printf() output is produced only after every lock is
 * dropped, from a private copy:
 *   1. sa_ctx_lock (mutex): the tables cannot be allocated or freed while
 *      it is held, so samon_streams_n / samon_loops_n and the table
 *      pointers are stable.  The snapshot buffers are sized from them
 *      (kvcalloc, GFP_KERNEL, process context) while the mutex is held.
 *   2. samon_pat_lock (spinlock, irqsave), taken inside the mutex: memcpy
 *      of both tables, nothing else.  Never nested with another spinlock.
 *   3. both locks released, then print.
 * When the tables are not allocated (kdamond off) only the header line is
 * printed, with stream_slots=0 loop_slots=0.
 */
static int samon_streams_show(struct seq_file *m, void *v)
{
	struct samon_stream *ssnap = NULL;
	struct samon_loop_rec *lsnap = NULL;
	unsigned int sn, ln, i;
	unsigned long flags, now;
	int d;

	mutex_lock(&sa_ctx_lock);
	sn = samon_streams[0] && samon_streams[1] ? samon_streams_n : 0;
	ln = samon_loops ? samon_loops_n : 0;
	if (sn) {
		ssnap = kvcalloc(2 * (size_t)sn, sizeof(*ssnap), GFP_KERNEL);
		if (!ssnap)
			goto nomem;
	}
	if (ln) {
		lsnap = kvcalloc(ln, sizeof(*lsnap), GFP_KERNEL);
		if (!lsnap)
			goto nomem;
	}

	spin_lock_irqsave(&samon_pat_lock, flags);
	now = jiffies;
	if (sn) {
		memcpy(ssnap, samon_streams[0], sn * sizeof(*ssnap));
		memcpy(ssnap + sn, samon_streams[1], sn * sizeof(*ssnap));
	}
	if (ln)
		memcpy(lsnap, samon_loops, ln * sizeof(*lsnap));
	spin_unlock_irqrestore(&samon_pat_lock, flags);
	mutex_unlock(&sa_ctx_lock);

	seq_printf(m, "# now=%lu stream_slots=%u loop_slots=%u\n", now, sn, ln);
	for (d = 0; d < 2; d++) {
		for (i = 0; i < sn; i++) {
			const struct samon_stream *x = &ssnap[d * sn + i];

			if (!x->used)
				continue;
			seq_printf(m,
				   "stream dir=%c idx=%u dev=%u:%u start=%llu end=%llu count=%u t_start=%lu t_last=%lu loop=%u L=%llu period_ms=%u\n",
				   d ? 'w' : 'r', i,
				   MAJOR(x->dev), MINOR(x->dev),
				   (unsigned long long)x->start,
				   (unsigned long long)x->end,
				   x->count, x->t_start, x->t_last,
				   x->loop ? 1 : 0,
				   (unsigned long long)x->loop_len,
				   jiffies_to_msecs(x->period));
		}
	}
	for (i = 0; i < ln; i++) {
		const struct samon_loop_rec *h = &lsnap[i];

		if (!h->used)
			continue;
		seq_printf(m, "loop idx=%u dev=%u:%u start=%llu end=%llu t_start=%lu\n",
			   i, MAJOR(h->dev), MINOR(h->dev),
			   (unsigned long long)h->start,
			   (unsigned long long)h->end, h->t_start);
	}
	kvfree(ssnap);
	kvfree(lsnap);
	return 0;

nomem:
	mutex_unlock(&sa_ctx_lock);
	kvfree(ssnap);
	kvfree(lsnap);
	return -ENOMEM;
}

static int samon_streams_open(struct inode *inode, struct file *file)
{
	return single_open(file, samon_streams_show, NULL);
}

static const struct file_operations samon_streams_fops = {
	.owner   = THIS_MODULE,
	.open    = samon_streams_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

/* ------------------------------------------------------------------ */
/* debugfs: /sys/kernel/debug/samon/wb_hist (R8.21, design K8/K10)    */
/* ------------------------------------------------------------------ */

/*
 * 60 one-second buckets, oldest first: t=-59 ... t=0, t=0 being the current
 * (partial) second.  A bucket counts only if its sec equals the second it
 * stands for, otherwise it is 0.  The buckets are copied under
 * samon_wb_lock (irqsave, no other lock) and printed after unlocking.
 */
static int samon_wb_hist_show(struct seq_file *m, void *v)
{
	struct samon_wb_bucket snap[SAMON_WB_BUCKETS];
	unsigned long flags;
	u32 sec;
	int i;

	spin_lock_irqsave(&samon_wb_lock, flags);
	sec = (u32)(jiffies / HZ);
	memcpy(snap, samon_wb, sizeof(snap));
	spin_unlock_irqrestore(&samon_wb_lock, flags);

	seq_puts(m, "# 1s buckets, oldest first; t=0 is the current (partial) second\n");
	for (i = SAMON_WB_BUCKETS - 1; i >= 0; i--) {
		const struct samon_wb_bucket *b =
			&snap[(u32)(sec - i) % SAMON_WB_BUCKETS];

		seq_printf(m, "t=%d writes=%u\n", -i,
			   b->sec == (u32)(sec - i) ? b->cnt : 0);
	}
	return 0;
}

static int samon_wb_hist_open(struct inode *inode, struct file *file)
{
	return single_open(file, samon_wb_hist_show, NULL);
}

static const struct file_operations samon_wb_hist_fops = {
	.owner   = THIS_MODULE,
	.open    = samon_wb_hist_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

/* ------------------------------------------------------------------ */
/* Module init / exit                                                  */
/* ------------------------------------------------------------------ */

static int __init damon_sa_initcall(void)
{
	struct damon_operations ops = {
		.id                   = DAMON_OPS_SADDR,
		.init                 = damon_sa_init,
		.update               = NULL,
		.prepare_access_checks = damon_sa_prepare_access_checks,
		.check_accesses       = damon_sa_check_accesses,
		.reset_aggregated     = NULL,
		.target_valid         = NULL,
		.cleanup              = damon_sa_cleanup,
		.apply_scheme         = NULL,
		.get_scheme_score     = damon_sa_scheme_score,
	};
	int ret;

	ret = damon_register_ops(&ops);
	if (ret)
		return ret;

	/* Set up debugfs entries */
	samon_dbgfs_dir = debugfs_create_dir("samon", NULL);
	if (!IS_ERR_OR_NULL(samon_dbgfs_dir))
		debugfs_create_file("lba_page_map", 0444,
				    samon_dbgfs_dir, NULL,
				    &samon_dbgfs_fops);
	if (!IS_ERR_OR_NULL(samon_dbgfs_dir))
		debugfs_create_file("stats", 0444, samon_dbgfs_dir, NULL,
				    &samon_stats_fops);
	if (!IS_ERR_OR_NULL(samon_dbgfs_dir))
		debugfs_create_file("streams", 0444, samon_dbgfs_dir, NULL,
				    &samon_streams_fops);
	if (!IS_ERR_OR_NULL(samon_dbgfs_dir))
		debugfs_create_file("wb_hist", 0444, samon_dbgfs_dir, NULL,
				    &samon_wb_hist_fops);

	pr_info("SAMON saddr ops registered (hot_threshold=%u window_ms=%u)\n",
		samon_hot_threshold, samon_window_ms);
	return 0;
}

subsys_initcall(damon_sa_initcall);
