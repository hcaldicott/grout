// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "_cmocka.h"
#include "event.h"
#include "iface.h"
#include "l2.h"
#include "module.h"
#include "rcu.h"

#include <rte_ip.h>

#include <stdlib.h>

static struct iface test_iface = {
	.id = 42,
	.type = GR_IFACE_TYPE_PORT,
	.mode = GR_IFACE_MODE_VRF,
};
static bool test_iface_present = true;

struct iface *__wrap_iface_from_id(uint16_t iface_id);
void *__wrap_rte_zmalloc(const char *type, size_t size, unsigned align);
void __wrap_rte_free(void *ptr);
void __wrap_rte_rcu_qsbr_synchronize(struct rte_rcu_qsbr *v, unsigned int thread_id);

void __api_handler(uint32_t, api_handler_func, const char *, size_t) { }
void event_subscribe(uint32_t, event_sub_cb_t) { }
struct rte_rcu_qsbr *gr_datapath_rcu(void) {
	static struct rte_rcu_qsbr rcu;
	return &rcu;
}
struct iface *__wrap_iface_from_id(uint16_t iface_id) {
	return test_iface_present && iface_id == test_iface.id ? &test_iface : NULL;
}
void *__wrap_rte_zmalloc(const char *, size_t size, unsigned) {
	return calloc(1, size);
}
void __wrap_rte_free(void *ptr) {
	free(ptr);
}
void __wrap_rte_rcu_qsbr_synchronize(struct rte_rcu_qsbr *, unsigned int) { }

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

static void policy_waits_until_interface_is_bridge_ready(void **) {
	const struct gr_bridge_port_policy policy = {
		.iface_id = test_iface.id,
		.flags = GR_BRIDGE_PORT_F_NON_DF,
	};

	test_iface_present = false;
	assert_int_equal(bridge_port_policy_test_set(&policy), 0);
	assert_null(bridge_port_policy_get(test_iface.id));

	test_iface_present = true;
	test_iface.mode = GR_IFACE_MODE_BRIDGE;
	bridge_port_policy_test_reconcile(test_iface.id);
	assert_non_null(bridge_port_policy_get(test_iface.id));
	assert_true(
		bridge_port_policy_get(test_iface.id)->flags & GR_BRIDGE_PORT_F_NON_DF
	);

	bridge_port_policy_test_clear(test_iface.id);
}

static void policy_deactivates_and_replays_across_reconfiguration(void **) {
	const struct gr_bridge_port_policy policy = {
		.iface_id = test_iface.id,
		.backup_nhg_id = 1234,
	};

	test_iface_present = true;
	test_iface.mode = GR_IFACE_MODE_BRIDGE;
	assert_int_equal(bridge_port_policy_test_set(&policy), 0);
	assert_non_null(bridge_port_policy_get(test_iface.id));

	test_iface.mode = GR_IFACE_MODE_VRF;
	bridge_port_policy_test_reconcile(test_iface.id);
	assert_null(bridge_port_policy_get(test_iface.id));

	test_iface.mode = GR_IFACE_MODE_BRIDGE;
	bridge_port_policy_test_reconcile(test_iface.id);
	assert_int_equal(bridge_port_policy_get(test_iface.id)->backup_nhg_id, 1234);

	bridge_port_policy_test_clear(test_iface.id);
}

static void empty_update_clears_active_and_pending_policy(void **) {
	const struct gr_bridge_port_policy policy = {
		.iface_id = test_iface.id,
		.flags = GR_BRIDGE_PORT_F_NON_DF,
		.backup_nhg_id = 1234,
		.n_sph_filters = 1,
		.sph_filters = {peer1},
	};
	const struct gr_bridge_port_policy clear = {
		.iface_id = test_iface.id,
	};

	test_iface_present = true;
	test_iface.mode = GR_IFACE_MODE_BRIDGE;
	assert_int_equal(bridge_port_policy_test_set(&policy), 0);
	assert_non_null(bridge_port_policy_get(test_iface.id));

	assert_int_equal(bridge_port_policy_test_set(&clear), 0);
	assert_null(bridge_port_policy_get(test_iface.id));

	// Reconciliation must not resurrect the deleted desired policy.
	test_iface.mode = GR_IFACE_MODE_VRF;
	bridge_port_policy_test_reconcile(test_iface.id);
	test_iface.mode = GR_IFACE_MODE_BRIDGE;
	bridge_port_policy_test_reconcile(test_iface.id);
	assert_null(bridge_port_policy_get(test_iface.id));
}

int main(void) {
	const struct CMUnitTest tests[] = {
		cmocka_unit_test(non_df_only_blocks_bum),
		cmocka_unit_test(peer_vtep_blocks_unicast_and_bum),
		cmocka_unit_test(non_overlay_traffic_is_never_blocked),
		cmocka_unit_test(policy_waits_until_interface_is_bridge_ready),
		cmocka_unit_test(policy_deactivates_and_replays_across_reconfiguration),
		cmocka_unit_test(empty_update_clears_active_and_pending_policy),
	};
	return cmocka_run_group_tests(tests, NULL, NULL);
}
