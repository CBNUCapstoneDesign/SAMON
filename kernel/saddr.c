// SPDX-License-Identifier: GPL-2.0
/*
 * DAMON Primitives for Storage (Block Device) Address Spaces
 *
 * Author: Sangsoo Park
 */

#define pr_fmt(fmt) "damon-sa: " fmt

#include <linux/damon.h>
#include <linux/module.h>
#include <linux/blk-mq.h>

#include <trace/events/block.h>

#include "ops-common.h"

#define DAMON_SA_MAX_REGIONS 1024

struct damon_sa_ctx {
	atomic_t io_counts[DAMON_SA_MAX_REGIONS];
	unsigned int nr_regions;
	unsigned long region_starts[DAMON_SA_MAX_REGIONS];
	unsigned long region_ends[DAMON_SA_MAX_REGIONS];
	bool active;
};

static struct damon_sa_ctx sa_ctx;
static DEFINE_MUTEX(sa_ctx_lock);

static void damon_sa_bio_trace(void *data, struct request *rq,
			       blk_status_t error, unsigned int nr_bytes)
{
	unsigned long sector;
	int lo, hi, mid;

	if (!sa_ctx.active || !sa_ctx.nr_regions)
		return;

	sector = blk_rq_pos(rq);

	/* Binary search for the region containing this sector */
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
			return;
		}
	}
}

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
			sa_ctx.region_ends[idx] = r->ar.end;
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
	sa_ctx.active = true;
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
			max_nr_accesses = max(r->nr_accesses,
					      max_nr_accesses);
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
}

static int damon_sa_scheme_score(struct damon_ctx *c, struct damon_target *t,
				 struct damon_region *r, struct damos *s)
{
	return damon_hot_score(c, r, s);
}

static int __init damon_sa_initcall(void)
{
	struct damon_operations ops = {
		.id = DAMON_OPS_SADDR,
		.init = damon_sa_init,
		.update = NULL,
		.prepare_access_checks = damon_sa_prepare_access_checks,
		.check_accesses = damon_sa_check_accesses,
		.reset_aggregated = NULL,
		.target_valid = NULL,
		.cleanup = damon_sa_cleanup,
		.apply_scheme = NULL,
		.get_scheme_score = damon_sa_scheme_score,
	};

	return damon_register_ops(&ops);
};

subsys_initcall(damon_sa_initcall);
