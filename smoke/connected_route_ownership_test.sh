#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

# A routing daemon can briefly replay a connected prefix before it has learned
# the interface address. Neither that add nor its subsequent withdrawal may
# replace or remove the address-owned connected route.

. $(dirname $0)/_init.sh

grcli interface add port p0 devargs net_tap0,iface=x-p0
grcli address add 172.16.0.1/24 iface p0
grcli address add 2001::1/64 iface p0

grcli route add 172.16.0.0/24 via 172.16.0.2
grcli route del 172.16.0.0/24
grcli route add 2001::/64 via 2001::2
grcli route del 2001::/64

grcli -j route show | jq -e \
	'.[] | select(.destination == "172.16.0.0/24" and .origin == "link")' >/dev/null
grcli -j route show | jq -e \
	'.[] | select(.destination == "2001::/64" and .origin == "link")' >/dev/null
