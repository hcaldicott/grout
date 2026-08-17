// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Robin Jarry

#include "flow_hash.h"
#include "graph.h"
#include "iface.h"
#include "l2.h"
#include "mbuf.h"
#include "nexthop.h"
#include "rxtx.h"

#include <rte_ether.h>

enum edges {
	OUTPUT = 0,
	INPUT,
	FLOOD,
	NEIGH_SUPPRESS,
	BRIDGE_INVAL,
	HAIRPIN,
	OUT_IFACE_INVAL,
	NHG_INVAL,
	FLOOD_DISABLED,
	SPLIT_HORIZON,
	EDGE_COUNT
};

struct bridge_input_trace {
	uint16_t iface_id;
	uint16_t bridge_id;
};

static const struct iface *bridge_vxlan_member(const struct iface_info_bridge *bridge) {
	for (uint16_t i = 0; i < bridge->n_members; i++)
		if (bridge->members[i]->type == GR_IFACE_TYPE_VXLAN
		    && (bridge->members[i]->flags & GR_IFACE_F_UP))
			return bridge->members[i];
	return NULL;
}

static bool bridge_nhg_select_vtep(struct rte_mbuf *m, uint32_t nhg_id, struct l3_addr *vtep) {
	struct nexthop *nh = nexthop_lookup_id(nhg_id);
	uint32_t flow_hash;

	if (nh == NULL || nh->type != GR_NH_T_GROUP)
		return false;

	flow_hash = gr_mbuf_flow_hash_get(m);
	nh = nexthop_group_get_nh(nexthop_info_group(nh), flow_hash);
	if (nh == NULL || nh->type != GR_NH_T_L2)
		return false;

	*vtep = nexthop_info_l2(nh)->vtep;
	return true;
}

static uint16_t bridge_input_process(
	struct rte_graph *graph,
	struct rte_node *node,
	void **objs,
	uint16_t nb_objs
) {
	const struct iface *bridge, *iface, *ingress;
	const struct iface_info_bridge *br;
	const struct gr_fdb_entry *fdb;
	struct iface_mbuf_data *d;
	struct rte_ether_hdr *eth;
	struct rte_mbuf *m;
	rte_edge_t edge;

	for (uint16_t i = 0; i < nb_objs; i++) {
		m = objs[i];
		d = iface_mbuf_data(m);
		ingress = d->iface;
		eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
		fdb = NULL;

		if (gr_mbuf_is_traced(m)) {
			struct bridge_input_trace *t = gr_mbuf_trace_add(m, node, sizeof(*t));
			t->iface_id = d->iface->id;
			t->bridge_id = d->iface->domain_id;
		}

		bridge = iface_from_id(d->iface->domain_id);
		if (bridge == NULL || bridge->type != GR_IFACE_TYPE_BRIDGE) {
			edge = BRIDGE_INVAL;
			goto next;
		}
		br = iface_info_bridge(bridge);

		if (rte_is_unicast_ether_addr(&eth->src_addr) && (br->flags & GR_BRIDGE_F_LEARN)) {
			struct l3_addr vtep = {0};
			if (d->iface->type == GR_IFACE_TYPE_VXLAN)
				vtep = d->vtep;
			fdb_learn(bridge->id, d->iface->id, &eth->src_addr, d->vlan_id, &vtep);
		}

		if (rte_is_unicast_ether_addr(&eth->dst_addr)) {
			fdb = fdb_lookup(bridge->id, &eth->dst_addr, d->vlan_id);
			if (fdb == NULL) {
				// Unknown unicast
				edge = FLOOD;
				goto next;
			}
			if (fdb->iface_id == d->iface->id) {
				const struct gr_bridge_port_policy *policy = bridge_port_policy_get(
					ingress->id
				);

				// EVPN-MH local bias: a MAC learned on the local ES may
				// actually sit behind another PE. Redirect the hairpin via
				// the ES backup NHG instead of dropping it locally.
				if (policy == NULL || policy->backup_nhg_id == GR_NH_ID_UNSET) {
					edge = HAIRPIN;
					goto next;
				}
				iface = bridge_vxlan_member(br);
				if (iface == NULL) {
					edge = OUT_IFACE_INVAL;
					goto next;
				}
				if (!bridge_nhg_select_vtep(m, policy->backup_nhg_id, &d->vtep)) {
					edge = NHG_INVAL;
					goto next;
				}
				d->iface = iface;
				edge = OUTPUT;
				goto next;
			}
			iface = iface_from_id(fdb->iface_id);
			if (iface == NULL) {
				edge = OUT_IFACE_INVAL;
				goto next;
			}
			// Direct output to learned interface
			if (ingress->type == GR_IFACE_TYPE_VXLAN
			    && bridge_port_policy_blocks_overlay(
				    bridge_port_policy_get(iface->id), &d->vtep, false
			    )) {
				edge = SPLIT_HORIZON;
				goto next;
			}

			d->iface = iface;
			if (fdb->nhg_id != GR_NH_ID_UNSET) {
				if (!bridge_nhg_select_vtep(m, fdb->nhg_id, &d->vtep)) {
					edge = NHG_INVAL;
					goto next;
				}
			} else {
				d->vtep = fdb->vtep;
			}

			if (iface->type == GR_IFACE_TYPE_BRIDGE) {
				edge = INPUT;
			} else {
				edge = OUTPUT;
			}
		} else if (br->flags & GR_BRIDGE_F_NEIGH_SUPPRESS) {
			edge = NEIGH_SUPPRESS;
		} else {
			edge = FLOOD;
		}
next:
		if (edge == FLOOD && !(br->flags & GR_BRIDGE_F_FLOOD))
			edge = FLOOD_DISABLED;

		rte_node_enqueue_x1(graph, node, edge, m);
	}

	return nb_objs;
}

static int bridge_input_trace_format(char *buf, size_t len, const void *data, size_t /*data_len*/) {
	const struct bridge_input_trace *t = data;
	const struct iface *iface = iface_from_id(t->iface_id);
	const struct iface *bridge = iface_from_id(t->bridge_id);
	return snprintf(
		buf,
		len,
		"iface=%s bridge=%s",
		iface ? iface->name : "[deleted]",
		bridge ? bridge->name : "[deleted]"
	);
}

static void bridge_input_register(void) {
	iface_input_mode_register(GR_IFACE_MODE_BRIDGE, "bridge_input");
	iface_output_type_register(GR_IFACE_TYPE_BRIDGE, "bridge_input");
}

static struct rte_node_register node = {
	.name = "bridge_input",
	.process = bridge_input_process,
	.nb_edges = EDGE_COUNT,
	.next_nodes = {
		[OUTPUT] = "iface_output",
		[INPUT] = "iface_input",
		[FLOOD] = "bridge_flood",
		[NEIGH_SUPPRESS] = "bridge_neigh_suppress",
		[BRIDGE_INVAL] = "bridge_input_invalid_domain",
		[HAIRPIN] = "bridge_input_hairpin",
		[OUT_IFACE_INVAL] = "bridge_input_invalid_output",
		[NHG_INVAL] = "bridge_input_invalid_nhg",
		[FLOOD_DISABLED] = "bridge_input_flood_disabled",
		[SPLIT_HORIZON] = "bridge_input_split_horizon",
	},
};

static struct gr_node_info info = {
	.node = &node,
	.type = GR_NODE_T_L2,
	.register_callback = bridge_input_register,
	.trace_format = bridge_input_trace_format,
};

GR_NODE_REGISTER(info);

GR_DROP_REGISTER(bridge_input_invalid_domain);
GR_DROP_REGISTER(bridge_input_hairpin);
GR_DROP_REGISTER(bridge_input_invalid_output);
GR_DROP_REGISTER(bridge_input_invalid_nhg);
GR_DROP_REGISTER(bridge_input_flood_disabled);
GR_DROP_REGISTER(bridge_input_split_horizon);
