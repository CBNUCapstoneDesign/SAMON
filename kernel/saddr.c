// SPDX-License-Identifier: GPL-2.0
/*
 * DAMON Primitives for Storage (Block Device) Address Spaces
 *
 * Extends the base DAMON saddr operations with:
 *  - Separate read/write I/O counters per region
 *  - Forward LBA->page mapping via bio->bi_io_vec (buffered I/O only)
 *  - Hot-region detection based on per-direction frequency threshold
 *  - folio_mark_accessed() hint on hot write completions (Option B)
 *  - debugfs interface: /sys/kernel/debug/samon/lba_page_map
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

#include <trace/events/block.h>

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
	"Option B: call folio_mark_accessed() on hot write completion");

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

/* Observation statistics: lockless, only for verification/debugging */
static atomic64_t samon_st_rq_seen;	/* completed requests (no error) */
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
static atomic64_t samon_st_mark_accessed;/* folio_mark_accessed() calls    */

/* debugfs */
static struct dentry *samon_dbgfs_dir;

/* ------------------------------------------------------------------ */
/* rbtree helpers                                                      */
/* ------------------------------------------------------------------ */

/* Lookup or insert an entry for @lba.  Returns the entry (never NULL
 * unless kmalloc fails).  Caller must hold samon_lba_lock.           */
static struct samon_lba_entry *samon_lba_get_or_insert(sector_t lba)
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

/*
 * @budget: bytes completed by this block_rq_complete event.  The tracepoint
 * fires before bio_advance(), once per (possibly partial) completion, and
 * the bios still hanging off the request reflect only the not-yet-completed
 * part.  Walking only @budget bytes avoids counting a segment again when the
 * request completes in several steps.  Returns true once @budget is used up.
 */
static bool samon_handle_bio(struct bio *bio, int dir, unsigned int *budget)
{
	struct bio_vec bv;
	struct bvec_iter iter;
	sector_t lba = bio->bi_iter.bi_sector;
	unsigned long flags;
	unsigned long window_jiffies = msecs_to_jiffies(samon_window_ms);

	bio_for_each_segment(bv, bio, iter) {
		struct folio *folio;
		struct samon_lba_entry *entry;
		bool hot;

		if (!*budget)
			return true;
		*budget -= min(*budget, bv.bv_len);

		folio = samon_segment_folio(bio, &bv, dir);
		if (!folio)
			goto next_seg;

		spin_lock_irqsave(&samon_lba_lock, flags);

		entry = samon_lba_get_or_insert(lba);
		if (!entry) {
			spin_unlock_irqrestore(&samon_lba_lock, flags);
			goto next_seg;
		}

		/* Window reset */
		if (time_after(jiffies,
			       entry->last_jiffies + window_jiffies)) {
			entry->read_count   = 0;
			entry->write_count  = 0;
			entry->last_jiffies = jiffies;
		}

		/* Record PFN (avoid storing raw struct page* long-term) */
		entry->pfn = page_to_pfn(bv.bv_page);

		if (dir == READ)
			entry->read_count++;
		else
			entry->write_count++;

		hot = (dir == READ)
			? (entry->read_count  >= samon_hot_threshold)
			: (entry->write_count >= samon_hot_threshold);

		spin_unlock_irqrestore(&samon_lba_lock, flags);

		atomic64_inc(&samon_st_seg_buffered);

		/*
		 * Option B: on hot write completion, call folio_mark_accessed()
		 * so that the next evict scan is less likely to reclaim this
		 * page.  Reads are observation-only at this stage: whether a
		 * read-side hint helps is to be decided by measurement.
		 * Toggle with samon_opt_b to compare on/off.
		 */
		if (hot && dir == WRITE && READ_ONCE(samon_opt_b)) {
			folio_mark_accessed(folio);
			atomic64_inc(&samon_st_mark_accessed);
		}

next_seg:
		lba += bv.bv_len >> SECTOR_SHIFT;
	}

	return !*budget;
}

/* ------------------------------------------------------------------ */
/* block_rq_complete tracepoint probe                                  */
/* ------------------------------------------------------------------ */

static void damon_sa_bio_trace(void *data, struct request *rq,
			       blk_status_t error, unsigned int nr_bytes)
{
	struct bio *bio;
	unsigned long sector;
	int lo, hi, mid;
	unsigned int nr;
	unsigned int budget;
	int dir;

	/* Skip failed completions entirely */
	if (error)
		return;

	if (!sa_ctx.active)
		return;

	dir = rq_data_dir(rq); /* READ or WRITE */
	if (READ_ONCE(samon_dev_major)) {
		struct gendisk *disk = rq->q ? rq->q->disk : NULL;

		if (!disk || disk->major != READ_ONCE(samon_dev_major) ||
		    disk->first_minor != READ_ONCE(samon_dev_minor)) {
			atomic64_inc(&samon_st_skip_dev);
			return;
		}
	}
	atomic64_inc(&samon_st_rq_seen);

	/*
	 * Legacy region-counter path (binary access detection).
	 * nr_regions is published with WRITE_ONCE() by the updater and read
	 * once here, clamped to the array size, so a concurrent update can at
	 * worst yield a stale region lookup but never an out-of-bounds index.
	 */
	nr = min_t(unsigned int, READ_ONCE(sa_ctx.nr_regions),
		   DAMON_SA_MAX_REGIONS);
	if (nr) {
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

	/* ---- New path: LBA->page mapping + frequency tracking ---- */
	if (nr_bytes < blk_rq_bytes(rq))
		atomic64_inc(&samon_st_budget_cut);
	budget = nr_bytes;
	__rq_for_each_bio(bio, rq) {
		if (samon_handle_bio(bio, dir, &budget))
			break;
	}
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

static void damon_sa_init(struct damon_ctx *ctx)
{
	int i;

	mutex_lock(&sa_ctx_lock);
	for (i = 0; i < DAMON_SA_MAX_REGIONS; i++)
		atomic_set(&sa_ctx.io_counts[i], 0);
	WRITE_ONCE(sa_ctx.nr_regions, 0);
	sa_ctx.active     = true;

	/* kdamond may be restarted: never register the probe twice */
	if (!samon_probe_registered) {
		if (register_trace_block_rq_complete(damon_sa_bio_trace, NULL))
			pr_err("failed to register block_rq_complete probe\n");
		else
			samon_probe_registered = true;
	}
	mutex_unlock(&sa_ctx_lock);
}

static void damon_sa_prepare_access_checks(struct damon_ctx *ctx)
{
	int i;

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
	sa_ctx.active = false;
	mutex_unlock(&sa_ctx_lock);
	tracepoint_synchronize_unregister();

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

/* debugfs: /sys/kernel/debug/samon/stats */
static int samon_stats_show(struct seq_file *m, void *v)
{
	unsigned long flags;
	unsigned int nr;

	spin_lock_irqsave(&samon_lba_lock, flags);
	nr = samon_nr_entries;
	spin_unlock_irqrestore(&samon_lba_lock, flags);

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
	seq_printf(m, "mark_accessed=%lld\n",
		   (long long)atomic64_read(&samon_st_mark_accessed));
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

	pr_info("SAMON saddr ops registered (hot_threshold=%u window_ms=%u)\n",
		samon_hot_threshold, samon_window_ms);
	return 0;
}

subsys_initcall(damon_sa_initcall);
