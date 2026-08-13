// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Robin Jarry

#include "log.h"
#include "nexthop.h"
#include "rcu.h"

#include <rte_malloc.h>

#include <stdint.h>

LOG_TYPE("nexthop");

static bool group_equal(const struct nexthop *a, const struct nexthop *b) {
	const struct nexthop_group_state *da =
		atomic_load_explicit(&nexthop_info_group(a)->state, memory_order_acquire);
	const struct nexthop_group_state *db =
		atomic_load_explicit(&nexthop_info_group(b)->state, memory_order_acquire);

	if (da == NULL || db == NULL)
		return da == db;
	if (da->n_members != db->n_members)
		return false;
	for (uint32_t i = 0; i < da->n_members; i++)
		if (da->members[i].nh != db->members[i].nh
		    || da->members[i].weight != db->members[i].weight)
			return false;
	return true;
}

static void group_reta_distribute(
	const uint16_t n_members,
	const uint16_t reta_size,
	struct nh_group_member *members,
	struct nexthop **reta
) {
	// Fill the reta table with weighted distribution
	uint32_t total_weight = 0;
	for (uint16_t i = 0; i < n_members; i++)
		total_weight += members[i].weight;

	assert(total_weight > 0);

	uint32_t reta_idx = 0;
	uint32_t entries;

	for (uint16_t i = 0; i < n_members && reta_idx < reta_size; i++) {
		entries = (members[i].weight * reta_size + total_weight / 2) / total_weight;

		if (entries == 0 && members[i].weight > 0)
			entries = 1;

		for (uint16_t j = 0; j < entries && reta_idx < reta_size; j++)
			reta[reta_idx++] = members[i].nh;
	}

	// Fill remaining entries with the first member if any slots left
	while (reta_idx < reta_size && n_members > 0)
		reta[reta_idx++] = members[0].nh;
}

static void remove_group_member_cb(struct nexthop *nh, void *deleted) {
	struct nexthop_info_group *group;
	struct nexthop_group_state *state;
	uint16_t dst = 0;

	if (nh->type != GR_NH_T_GROUP)
		return;

	group = nexthop_info_group(nh);
	state = atomic_load_explicit(&group->state, memory_order_acquire);
	if (state == NULL)
		return;

	for (uint16_t i = 0; i < state->n_members; i++)
		if (state->members[i].nh == deleted)
			goto remove;
	return;

remove:
	// Publish a safe empty state and wait for readers before editing the existing
	// allocation in place. Member destruction cannot fail because of allocation.
	atomic_store_explicit(&group->state, NULL, memory_order_release);
	rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);

	for (uint16_t src = 0; src < state->n_members; src++) {
		if (state->members[src].nh == deleted)
			continue;
		state->members[dst++] = state->members[src];
	}
	state->n_members = dst;
	state->nh = dst == 1 ? state->members[0].nh : NULL;
	if (dst > 1)
		group_reta_distribute(dst, state->reta_size, state->members, state->reta);
	// Keep the forwarding class when the last member disappears. The group may
	// still be referenced by an FDB or route while FRR reorders delete/create
	// operations; allowing the empty group to change class would weaken those
	// references after it is repopulated.

	atomic_store_explicit(&group->state, state, memory_order_release);
}

static void group_remove_references(struct nexthop *nh) {
	nexthop_iter(remove_group_member_cb, nh);
}

static void group_free(struct nexthop *nh) {
	struct nexthop_info_group *pvt = nexthop_info_group(nh);
	struct nexthop_group_state *state =
		atomic_load_explicit(&pvt->state, memory_order_relaxed);

	if (state == NULL)
		return;
	for (uint32_t i = 0; i < state->n_members; i++)
		nexthop_decref(state->members[i].nh);
	rte_free(state->members);
	rte_free(state->reta);
	rte_free(state);
}

static int order_by_weight_desc(const void *a, const void *b) {
	const struct nh_group_member *ma = a;
	const struct nh_group_member *mb = b;
	return mb->weight - ma->weight;
}

static int group_import_info(struct nexthop *nh, const void *info) {
	struct nexthop_info_group *pvt = nexthop_info_group(nh);
	const struct gr_nexthop_info_group *group = info;
	struct nexthop_group_state *next = NULL;
	struct nexthop_group_state *old = NULL;
	const struct nexthop_group_state *current = NULL;
	uint32_t min_weight, max_weight;
	bool refs_acquired = false;

	next = rte_zmalloc(__func__, sizeof(*next), RTE_CACHE_LINE_SIZE);
	if (next == NULL)
		return errno_set(ENOMEM);
	next->n_members = group->n_members;
	next->member_type = GR_NH_T_ALL;

	next->members = rte_zmalloc(
		__func__, group->n_members * sizeof(next->members[0]), RTE_CACHE_LINE_SIZE
	);
	if (group->n_members > 0 && next->members == NULL) {
		errno_set(ENOMEM);
		goto cleanup;
	}

	for (uint16_t i = 0; i < group->n_members; i++) {
		struct nexthop *member = nexthop_lookup_id(group->members[i].nh_id);
		if (member == NULL) {
			errno = ENOENT;
			goto cleanup;
		}
		if (member->type == GR_NH_T_GROUP) {
			errno = ELOOP;
			goto cleanup;
		}
		if (i == 0)
			next->member_type = member->type;
		else if (member->type != next->member_type) {
			errno = EINVAL;
			goto cleanup;
		}
		next->members[i].nh = member;
		next->members[i].weight = group->members[i].weight ?: 1;
	}

	if (group->n_members == 1) {
		next->nh = next->members[0].nh;
	} else if (group->n_members > 1) {
		// Order by desc weight: if we have too many nh in the nhg, the ones with
		// a higher weight will be included.
		qsort(
			next->members,
			group->n_members,
			sizeof(next->members[0]),
			order_by_weight_desc
		);

		max_weight = next->members[0].weight;
		min_weight = next->members[group->n_members - 1].weight;

		next->reta_size = (max_weight / min_weight) * group->n_members;
		if (next->reta_size > MAX_NH_GROUP_RETA_SIZE) {
			LOG(WARNING,
			    "nhg(%u) reta overflow (%u > %u)",
			    nh->nh_id,
			    next->reta_size,
			    MAX_NH_GROUP_RETA_SIZE);
			next->reta_size = MAX_NH_GROUP_RETA_SIZE;
		}
		next->reta_size = rte_align32pow2(next->reta_size);

		next->reta = rte_zmalloc(
			__func__, next->reta_size * sizeof(next->reta[0]), RTE_CACHE_LINE_SIZE
		);
		if (next->reta == NULL) {
			errno = ENOMEM;
			goto cleanup;
		}

		group_reta_distribute(
			group->n_members, next->reta_size, next->members, next->reta
		);
	}

	if (nh->ref_count > 0)
		current = atomic_load_explicit(&pvt->state, memory_order_acquire);
	if (current != NULL && current->member_type != GR_NH_T_ALL) {
		if (next->member_type == GR_NH_T_ALL)
			next->member_type = current->member_type;
		else if (next->member_type != current->member_type) {
			errno = EPROTOTYPE;
			goto cleanup;
		}
	}

	for (uint16_t i = 0; i < group->n_members; i++)
		nexthop_incref(next->members[i].nh);
	refs_acquired = true;

	if (nh->ref_count == 0)
		atomic_init(&pvt->state, next);
	else
		old = atomic_exchange_explicit(&pvt->state, next, memory_order_acq_rel);

	if (old == NULL)
		return 0;

	rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);

	for (uint32_t i = 0; i < old->n_members; i++)
		nexthop_decref(old->members[i].nh);
	rte_free(old->reta);
	rte_free(old->members);
	rte_free(old);
	return 0;

cleanup:
	if (refs_acquired)
		for (uint16_t i = 0; i < next->n_members; i++)
			nexthop_decref(next->members[i].nh);
	rte_free(next->reta);
	rte_free(next->members);
	rte_free(next);
	return errno_set(errno);
}

static struct gr_nexthop *group_to_api(const struct nexthop *nh, size_t *len) {
	const struct nexthop_group_state *group_priv = atomic_load_explicit(
		&nexthop_info_group(nh)->state, memory_order_acquire
	);
	struct gr_nexthop_info_group *group_pub;
	struct gr_nexthop *pub;
	if (group_priv == NULL)
		return errno_set_null(EAGAIN);
	*len = sizeof(*pub) + sizeof(*group_pub)
		+ group_priv->n_members * sizeof(group_priv->members[0]);

	pub = malloc(*len);
	if (pub == NULL) {
		*len = 0;
		return errno_set_null(ENOMEM);
	}

	pub->base = nh->base;
	group_pub = (struct gr_nexthop_info_group *)pub->info;

	group_pub->n_members = group_priv->n_members;
	for (uint32_t i = 0; i < group_pub->n_members; i++) {
		group_pub->members[i].nh_id = group_priv->members[i].nh->nh_id;
		group_pub->members[i].weight = group_priv->members[i].weight;
	}

	return pub;
}

static struct nexthop_type_ops group_nh_ops = {
	.equal = group_equal,
	.remove_references = group_remove_references,
	.free = group_free,
	.import_info = group_import_info,
	.to_api = group_to_api,
};

RTE_INIT(init) {
	nexthop_type_ops_register(GR_NH_T_GROUP, &group_nh_ops);
}
