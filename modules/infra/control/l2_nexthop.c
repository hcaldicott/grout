// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "nexthop.h"

#include <errno.h>
#include <stdlib.h>

static bool l2_equal(const struct nexthop *a, const struct nexthop *b) {
	return l3_addr_eq(&nexthop_info_l2(a)->vtep, &nexthop_info_l2(b)->vtep);
}

static int l2_import_info(struct nexthop *nh, const void *info) {
	const struct gr_nexthop_info_l2 *pub = info;

	switch (pub->vtep.af) {
	case GR_AF_IP4:
		if (pub->vtep.ipv4 == 0)
			return errno_set(EDESTADDRREQ);
		break;
	case GR_AF_IP6:
		if (rte_ipv6_addr_is_unspec(&pub->vtep.ipv6))
			return errno_set(EDESTADDRREQ);
		break;
	default:
		return errno_set(EAFNOSUPPORT);
	}

	nexthop_info_l2(nh)->base = *pub;
	return 0;
}

static struct gr_nexthop *l2_to_api(const struct nexthop *nh, size_t *len) {
	struct gr_nexthop_info_l2 *info;
	struct gr_nexthop *pub;

	*len = sizeof(*pub) + sizeof(*info);
	pub = malloc(*len);
	if (pub == NULL) {
		*len = 0;
		return errno_set_null(ENOMEM);
	}

	pub->base = nh->base;
	info = (struct gr_nexthop_info_l2 *)pub->info;
	*info = nexthop_info_l2(nh)->base;
	return pub;
}

static struct nexthop_type_ops l2_nh_ops = {
	.equal = l2_equal,
	.import_info = l2_import_info,
	.to_api = l2_to_api,
};

RTE_INIT(init) {
	nexthop_type_ops_register(GR_NH_T_L2, &l2_nh_ops);
}
