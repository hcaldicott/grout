// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "config.h"
#include "event.h"
#include "iface.h"
#include "log.h"
#include "l2.h"
#include "module.h"
#include "rcu.h"

#include <gr_l2.h>

#include <rte_malloc.h>
#include <rte_rcu_qsbr.h>

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic(struct gr_bridge_port_policy *) *policies;
static struct gr_bridge_port_policy **desired_policies;

const struct gr_bridge_port_policy *bridge_port_policy_get(uint16_t iface_id) {
	if (iface_id >= gr_config.max_ifaces)
		return NULL;
	return atomic_load_explicit(&policies[iface_id], memory_order_acquire);
}

static int bridge_port_policy_validate(const struct gr_bridge_port_policy *policy) {
	if (policy->iface_id >= gr_config.max_ifaces)
		return errno_set(EINVAL);
	if (policy->flags & ~GR_BRIDGE_PORT_F_NON_DF)
		return errno_set(EINVAL);
	if (policy->n_sph_filters > GR_BRIDGE_PORT_MAX_SPH_FILTERS)
		return errno_set(E2BIG);

	for (uint8_t i = 0; i < policy->n_sph_filters; i++) {
		if (policy->sph_filters[i].af != GR_AF_IP4
		    && policy->sph_filters[i].af != GR_AF_IP6)
			return errno_set(EAFNOSUPPORT);
		for (uint8_t j = 0; j < i; j++)
			if (l3_addr_eq(&policy->sph_filters[i], &policy->sph_filters[j]))
				return errno_set(EEXIST);
	}

	return 0;
}

static bool bridge_port_iface_ready(uint16_t iface_id) {
	const struct iface *iface = iface_from_id(iface_id);

	return iface != NULL && iface->mode == GR_IFACE_MODE_BRIDGE
		&& iface->type != GR_IFACE_TYPE_VXLAN && iface->type != GR_IFACE_TYPE_BRIDGE;
}

static void bridge_port_policy_reconcile(uint16_t iface_id) {
	struct gr_bridge_port_policy *next, *old;

	if (iface_id >= gr_config.max_ifaces)
		return;
	next = bridge_port_iface_ready(iface_id) ? desired_policies[iface_id] : NULL;
	old = atomic_exchange_explicit(&policies[iface_id], next, memory_order_acq_rel);
	if (old != next)
		rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);
}

static int bridge_port_policy_replace(const struct gr_bridge_port_policy *policy) {
	struct gr_bridge_port_policy *next, *old_active, *old_desired;

	next = rte_zmalloc(__func__, sizeof(*next), RTE_CACHE_LINE_SIZE);
	if (next == NULL)
		return errno_set(ENOMEM);
	*next = *policy;

	old_desired = desired_policies[policy->iface_id];
	desired_policies[policy->iface_id] = next;
	old_active = atomic_exchange_explicit(
		&policies[policy->iface_id],
		bridge_port_iface_ready(policy->iface_id) ? next : NULL,
		memory_order_acq_rel
	);
	if (old_active != NULL)
		rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);

	// The active policy, when present, is the same allocation as the desired policy.
	assert(old_active == NULL || old_active == old_desired);
	rte_free(old_desired);
	return 0;
}

static struct api_out bridge_port_set(const void *request, struct api_ctx *) {
	const struct gr_bridge_port_set_req *req = request;
	int ret;

	if ((ret = bridge_port_policy_validate(&req->policy)) < 0)
		return api_out(-ret, 0, NULL);
	if ((ret = bridge_port_policy_replace(&req->policy)) < 0)
		return api_out(-ret, 0, NULL);

	return api_out(0, 0, NULL);
}

static struct api_out bridge_port_get(const void *request, struct api_ctx *) {
	const struct gr_bridge_port_get_req *req = request;
	const struct gr_bridge_port_policy *policy;
	struct gr_bridge_port_policy *copy;

	if (req->iface_id >= gr_config.max_ifaces)
		return api_out(EINVAL, 0, NULL);
	policy = desired_policies[req->iface_id];
	if (policy == NULL)
		return api_out(ENOENT, 0, NULL);
	copy = malloc(sizeof(*copy));
	if (copy == NULL)
		return api_out(ENOMEM, 0, NULL);
	*copy = *policy;

	return api_out(0, sizeof(*copy), copy);
}

static void bridge_port_policy_clear(uint16_t iface_id) {
	struct gr_bridge_port_policy *old, *desired;

	old = atomic_exchange_explicit(&policies[iface_id], NULL, memory_order_acq_rel);
	desired = desired_policies[iface_id];
	desired_policies[iface_id] = NULL;
	if (old != NULL)
		rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);
	assert(old == NULL || old == desired);
	rte_free(desired);
}

static void bridge_port_iface_remove(uint32_t, const void *obj) {
	const struct iface *iface = obj;

	bridge_port_policy_clear(iface->id);
}

static void bridge_port_iface_reconcile(uint32_t, const void *obj) {
	const struct iface *iface = obj;

	bridge_port_policy_reconcile(iface->id);
}

#ifdef __GROUT_UNIT_TEST__
int bridge_port_policy_test_set(const struct gr_bridge_port_policy *policy) {
	int ret = bridge_port_policy_validate(policy);

	return ret < 0 ? ret : bridge_port_policy_replace(policy);
}

void bridge_port_policy_test_reconcile(uint16_t iface_id) {
	bridge_port_policy_reconcile(iface_id);
}

void bridge_port_policy_test_clear(uint16_t iface_id) {
	bridge_port_policy_clear(iface_id);
}
#endif

static void bridge_port_init(struct event_base *) {
	policies = rte_calloc(
		__func__, gr_config.max_ifaces, sizeof(*policies), RTE_CACHE_LINE_SIZE
	);
	if (policies == NULL)
		ABORT("rte_calloc(bridge_port_policies)");
	desired_policies = rte_calloc(
		__func__, gr_config.max_ifaces, sizeof(*desired_policies), RTE_CACHE_LINE_SIZE
	);
	if (desired_policies == NULL)
		ABORT("rte_calloc(bridge_port_desired_policies)");
}

static void bridge_port_fini(struct event_base *) {
	// The active policy, when present, shares its allocation with the
	// desired policy: freeing the desired side covers both.
	for (uint16_t i = 0; i < gr_config.max_ifaces; i++)
		rte_free(desired_policies[i]);
	rte_free(desired_policies);
	desired_policies = NULL;
	rte_free(policies);
	policies = NULL;
}

static struct module bridge_port_module = {
	.name = "bridge_port_policy",
	.init = bridge_port_init,
	.fini = bridge_port_fini,
};

RTE_INIT(bridge_port_constructor) {
	module_register(&bridge_port_module);
	api_handler(GR_BRIDGE_PORT_SET, bridge_port_set);
	api_handler(GR_BRIDGE_PORT_GET, bridge_port_get);
	event_subscribe(GR_EVENT_IFACE_POST_ADD, bridge_port_iface_reconcile);
	event_subscribe(GR_EVENT_IFACE_POST_RECONFIG, bridge_port_iface_reconcile);
	event_subscribe(GR_EVENT_IFACE_REMOVE, bridge_port_iface_remove);
}
