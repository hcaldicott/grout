// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "event.h"
#include "iface.h"
#include "l2.h"
#include "module.h"
#include "rcu.h"

#include <gr_l2.h>

#include <rte_malloc.h>
#include <rte_rcu_qsbr.h>

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic(struct gr_bridge_port_policy *) policies[GR_MAX_IFACES];

const struct gr_bridge_port_policy *bridge_port_policy_get(uint16_t iface_id) {
	if (iface_id >= GR_MAX_IFACES)
		return NULL;
	return atomic_load_explicit(&policies[iface_id], memory_order_acquire);
}

static int bridge_port_policy_replace(const struct gr_bridge_port_policy *policy) {
	struct gr_bridge_port_policy *next, *old;

	next = rte_zmalloc(__func__, sizeof(*next), RTE_CACHE_LINE_SIZE);
	if (next == NULL)
		return errno_set(ENOMEM);

	*next = *policy;
	old = atomic_exchange_explicit(&policies[policy->iface_id], next, memory_order_acq_rel);
	rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);
	rte_free(old);

	return 0;
}

static int bridge_port_policy_validate(const struct gr_bridge_port_policy *policy) {
	const struct iface *iface;

	if (policy->iface_id >= GR_MAX_IFACES)
		return errno_set(EINVAL);
	if (policy->flags & ~GR_BRIDGE_PORT_F_NON_DF)
		return errno_set(EINVAL);
	if (policy->n_sph_filters > GR_BRIDGE_PORT_MAX_SPH_FILTERS)
		return errno_set(E2BIG);

	iface = iface_from_id(policy->iface_id);
	if (iface == NULL)
		return errno_set(ENODEV);
	if (iface->mode != GR_IFACE_MODE_BRIDGE || iface->type == GR_IFACE_TYPE_VXLAN
	    || iface->type == GR_IFACE_TYPE_BRIDGE)
		return errno_set(EMEDIUMTYPE);

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

	policy = bridge_port_policy_get(req->iface_id);
	if (policy == NULL)
		return api_out(ENOENT, 0, NULL);
	copy = malloc(sizeof(*copy));
	if (copy == NULL)
		return api_out(ENOMEM, 0, NULL);
	*copy = *policy;

	return api_out(0, sizeof(*copy), copy);
}

static void bridge_port_iface_remove(uint32_t, const void *obj) {
	const struct iface *iface = obj;
	struct gr_bridge_port_policy *old;

	old = atomic_exchange_explicit(&policies[iface->id], NULL, memory_order_acq_rel);
	if (old == NULL)
		return;

	rte_rcu_qsbr_synchronize(gr_datapath_rcu(), RTE_QSBR_THRID_INVALID);
	rte_free(old);
}

RTE_INIT(bridge_port_constructor) {
	api_handler(GR_BRIDGE_PORT_SET, bridge_port_set);
	api_handler(GR_BRIDGE_PORT_GET, bridge_port_get);
	event_subscribe(GR_EVENT_IFACE_REMOVE, bridge_port_iface_remove);
}
