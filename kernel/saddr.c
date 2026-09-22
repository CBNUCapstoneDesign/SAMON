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

	/* Allocate new entry — use GFP_ATOMIC: we may be in IRQ context */
	entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
	if (!entry)
		return NULL;

	entry->lba          = lba;
	entry->pfn          = 0;
	entry->read_count   = 0;
	entry->write_count  = 0;
	entry->last_jiffies = jiffies;

	rb_link_node(&entry->node, parent, link);
	rb_insert_color(&entry->node, &samon_lba_tree);

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
	spin_unlock_irqrestore(&samon_lba_lock, flags);
}

/* ------------------------------------------------------------------ */
/* direct-I/O detection                                                */
/* ------------------------------------------------------------------ */

/*
 * At the block layer we identify direct I/O by checking whether the bio
 * has no page-cache mapping on any of its pages.  A simpler and cheaper
 * heuristic is to check bi_opf for REQ_SYNC together with the absence
 * of a page-cache address_space.  We use the page-mapping check because
 * it is definitive: if page_mapping(page) is NULL the page does not
 * belong to the page cache, so we skip it regardless of origin.
 *
 * The function returns true when the entire bio looks like direct I/O
 * (first segment has no page-cache mapping).
 */
static bool samon_bio_is_direct(struct bio *bio)
{
	struct bio_vec bv;
	struct bvec_iter iter;

	bio_for_each_segment(bv, bio, iter) {
		struct page *page = bv.bv_page;

		if (!page)
			return true;  /* no page → direct or metadata I/O */

		/*
		 * If the first real page has a mapping this is buffered I/O.
		 * We stop at the first segment to keep the probe fast.
		 */
		return page_mapping(page) == NULL;
	}

	return true; /* empty bio — skip */
}

/* ------------------------------------------------------------------ */
/* Core bio handler                                                    */
/* ------------------------------------------------------------------ */

static void samon_handle_bio(struct bio *bio, int dir)
{
	struct bio_vec bv;
	struct bvec_iter iter;
	sector_t lba;
	unsigned long flags;
	unsigned long window_jiffies = msecs_to_jiffies(samon_window_ms);

	if (samon_bio_is_direct(bio))
		return;

	lba = bio->bi_iter.bi_sector;

	bio_for_each_segment(bv, bio, iter) {
		struct page   *page = bv.bv_page;
		struct folio  *folio;
		struct samon_lba_entry *entry;
		bool hot;

		/* Defensive: skip NULL or non-page-cache pages */
		if (!page)
			goto next_seg;
		if (!page_mapping(page))
			goto next_seg;

		folio = page_folio(page);

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
		entry->pfn = page_to_pfn(page);

		if (dir == READ)
			entry->read_count++;
		else
			entry->write_count++;

		hot = (dir == READ)
			? (entry->read_count  >= samon_hot_threshold)
			: (entry->write_count >= samon_hot_threshold);

		spin_unlock_irqrestore(&samon_lba_lock, flags);

		/*
		 * Option B: on hot write completion, call folio_mark_accessed()
		 * so that the next evict scan is less likely to reclaim this
		 * page.  For reads the kernel already marks the page accessed
		 * during I/O completion, so we only act on writes here.
		 */
		if (hot && dir == WRITE)
			folio_mark_accessed(folio);

next_seg:
		lba += bv.bv_len >> SECTOR_SHIFT;
	}
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
	int dir;

	/* Skip failed completions entirely */
	if (error)
		return;

	if (!sa_ctx.active)
		return;

	dir = rq_data_dir(rq); /* READ or WRITE */

	/* ---- Legacy region-counter path (binary access detection) ---- */
	if (sa_ctx.nr_regions) {
		sector = blk_rq_pos(rq);
		lo = 0;
		hi = sa_ctx.nr_regions - 1;
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
	__rq_for_each_bio(bio, rq)
		samon_handle_bio(bio, dir);
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
	sa_ctx.nr_regions = idx;
	mutex_unlock(&sa_ctx_lock);
}

static void damon_sa_init(struct damon_ctx *ctx)
{
	int i;

	mutex_lock(&sa_ctx_lock);
	for (i = 0; i < DAMON_SA_MAX_REGIONS; i++)
		atomic_set(&sa_ctx.io_counts[i], 0);
	sa_ctx.nr_regions = 0;
	sa_ctx.active     = true;
	mutex_unlock(&sa_ctx_lock);

	register_trace_block_rq_complete(damon_sa_bio_trace, NULL);
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
	unregister_trace_block_rq_complete(damon_sa_bio_trace, NULL);
	tracepoint_synchronize_unregister();

	mutex_lock(&sa_ctx_lock);
	sa_ctx.active = false;
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

	pr_info("SAMON saddr ops registered (hot_threshold=%u window_ms=%u)\n",
		samon_hot_threshold, samon_window_ms);
	return 0;
}

subsys_initcall(damon_sa_initcall);
