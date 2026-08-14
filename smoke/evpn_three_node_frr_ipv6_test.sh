#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

# Run the three-node EVPN-MH topology with IPv6 BGP/VXLAN endpoints. The inner
# bridge domain carries both IPv4 and IPv6 so this verifies IPv6 VM traffic as
# well as IPv6 outer encapsulation and all-active L2 nexthop selection.

set -e -o pipefail

export EVPN_MH_PROBE=true
export EVPN_MH_DATA_PLANE=true
export EVPN_MH_IPV6=true

exec "$(dirname "$0")/evpn_three_node_frr_test.sh" "$@"
