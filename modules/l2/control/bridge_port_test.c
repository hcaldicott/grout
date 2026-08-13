// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "_cmocka.h"
#include "l2.h"

#include <rte_ip.h>

static const struct l3_addr peer1 = {
	.af = GR_AF_IP4,
	.ipv4 = RTE_BE32(0xac100002),
};

static const struct l3_addr peer2 = {
	.af = GR_AF_IP4,
	.ipv4 = RTE_BE32(0xac100003),
};

static void non_df_only_blocks_bum(void **) {
	const struct gr_bridge_port_policy policy = {
		.flags = GR_BRIDGE_PORT_F_NON_DF,
	};

	assert_true(bridge_port_policy_blocks_overlay(&policy, &peer1, true));
	assert_false(bridge_port_policy_blocks_overlay(&policy, &peer1, false));
}

static void peer_vtep_blocks_unicast_and_bum(void **) {
	const struct gr_bridge_port_policy policy = {
		.n_sph_filters = 1,
		.sph_filters = {peer1},
	};

	assert_true(bridge_port_policy_blocks_overlay(&policy, &peer1, true));
	assert_true(bridge_port_policy_blocks_overlay(&policy, &peer1, false));
	assert_false(bridge_port_policy_blocks_overlay(&policy, &peer2, true));
	assert_false(bridge_port_policy_blocks_overlay(&policy, &peer2, false));
}

static void non_overlay_traffic_is_never_blocked(void **) {
	const struct l3_addr local = {.af = GR_AF_UNSPEC};
	const struct gr_bridge_port_policy policy = {
		.flags = GR_BRIDGE_PORT_F_NON_DF,
		.n_sph_filters = 1,
		.sph_filters = {peer1},
	};

	assert_false(bridge_port_policy_blocks_overlay(&policy, &local, true));
	assert_false(bridge_port_policy_blocks_overlay(&policy, &local, false));
}

int main(void) {
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(non_df_only_blocks_bum),
		cmocka_unit_test(peer_vtep_blocks_unicast_and_bum),
		cmocka_unit_test(non_overlay_traffic_is_never_blocked),
	};
	return cmocka_run_group_tests(tests, NULL, NULL);
}
