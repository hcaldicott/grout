// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#include "cli.h"
#include "cli_iface.h"
#include "display.h"

#include <gr_l2.h>

#include <ecoli.h>

static cmd_status_t bridge_port_show(struct gr_api_client *c, const struct ec_pnode *p) {
	struct gr_bridge_port_get_req req;
	const struct gr_bridge_port_policy *policy;
	void *resp = NULL;

	if (arg_iface(c, p, "IFACE", GR_IFACE_TYPE_UNDEF, &req.iface_id) < 0)
		return CMD_ERROR;
	if (gr_api_client_send_recv(c, GR_BRIDGE_PORT_GET, sizeof(req), &req, &resp) < 0)
		return CMD_ERROR;
	policy = resp;

	struct gr_object *o = gr_object_new(NULL);
	gr_object_field(o, "iface", 0, "%s", iface_name_from_id(c, policy->iface_id));
	gr_object_field(
		o, "non_df", GR_DISP_BOOL, "%u", !!(policy->flags & GR_BRIDGE_PORT_F_NON_DF)
	);
	gr_object_field(o, "backup_nhg", GR_DISP_INT, "%u", policy->backup_nhg_id);
	gr_object_array_open(o, "split_horizon_vteps");
	for (uint8_t i = 0; i < policy->n_sph_filters; i++)
		gr_object_array_item(
			o,
			0,
			ADDR_F,
			ADDR_W(policy->sph_filters[i].af),
			&policy->sph_filters[i].addr
		);
	gr_object_array_close(o);
	gr_object_free(o);
	free(resp);

	return CMD_SUCCESS;
}

#define BRIDGE_PORT_CTX(root)                                                                      \
	CLI_CONTEXT(root, CTX_ARG("bridge-port", "EVPN multihoming bridge-port policy."))

static int ctx_init(struct ec_node *root) {
	return CLI_COMMAND(
		BRIDGE_PORT_CTX(root),
		"[show] iface IFACE",
		bridge_port_show,
		"Display an EVPN multihoming bridge-port policy.",
		with_help(
			"Bridge member interface name.",
			ec_node_dyn("IFACE", complete_iface_names, INT2PTR(GR_IFACE_TYPE_UNDEF))
		)
	);
}

static struct cli_context ctx = {
	.name = "bridge-port",
	.init = ctx_init,
};

static void __attribute__((constructor, used)) init(void) {
	cli_context_register(&ctx);
}
