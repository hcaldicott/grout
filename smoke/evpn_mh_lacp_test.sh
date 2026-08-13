#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

# Probe whether a Linux carrier LAG will select two links terminated by two
# independent Grout instances. Both Grout bonds deliberately use the same MAC,
# which makes them advertise one LACP system ID as EVPN multihoming requires.

set -e -o pipefail

if [ "${_EVPN_MH_LACP_UNSHARED:-}" != 1 ]; then
	export _EVPN_MH_LACP_UNSHARED=1
	exec unshare --mount --net -- "$0" "$@"
fi

builddir=$(realpath "${1:-build}")
export PATH="$builddir:$PATH"
export GROUT_PAGER=""

tmp=$(mktemp -d)
prefix="emh-$$"
carrier="$prefix-carrier"
nodes=("$prefix-n1" "$prefix-n2")
grout_pids=()

wait_until() {
	local description="$1"
	shift
	local attempts=100

	until "$@"; do
		attempts=$((attempts - 1))
		if [ "$attempts" -eq 0 ]; then
			echo "timeout waiting for $description" >&2
			return 1
		fi
		sleep 0.1
	done
}

cleanup() {
	local status=$?
	set +e

	for pid in "${grout_pids[@]}"; do
		kill -TERM "$pid" >/dev/null 2>&1
	done
	for pid in "${grout_pids[@]}"; do
		wait "$pid" >/dev/null 2>&1
	done
	for ns in "${nodes[@]}" "$carrier"; do
		ip netns del "$ns" >/dev/null 2>&1
	done
	rm -rf "$tmp"
	exit "$status"
}
trap cleanup EXIT

mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
ip netns add "$carrier"
ip -n "$carrier" link set lo up
ip -n "$carrier" link add bond0 type bond mode 802.3ad \
	lacp_active on lacp_rate fast xmit_hash_policy layer3+4

for index in 1 2; do
	node="${nodes[$((index - 1))]}"
	sock="$tmp/grout$index.sock"
	tap="x-carrier$index"

	ip netns add "$node"
	ip -n "$node" link set lo up
	ip netns exec "$node" env GROUT_SOCK_PATH="$sock" \
		grout -t -M "unix:$tmp/metrics$index.sock" -- \
		--file-prefix="$prefix-$index" >"$tmp/grout$index.log" 2>&1 &
	grout_pids+=("$!")
	wait_until "Grout node $index API socket" test -S "$sock"

	grcli -s "$sock" interface add bond carrier mode lacp \
		mac 02:00:00:00:10:00
	grcli -s "$sock" interface add port carrier-port \
		devargs "net_tap0,iface=$tap" domain carrier
	# Keep the Linux TAP identity distinct from Grout's physical-port MAC.
	ip -n "$node" link set "$tap" address "02:00:00:00:20:0$index"
	ip -n "$node" link set "$tap" netns "$carrier"
	ip -n "$carrier" link set "$tap" master bond0
	ip -n "$carrier" link set "$tap" up
	wait_until "$tap dataplane link" \
		sh -c "ip -n '$carrier' link show '$tap' | grep -qw LOWER_UP"
done

ip -n "$carrier" link set bond0 up

member_synced() {
	local details

	details=$(ip -n "$carrier" -d link show "$1")
	printf '%s\n' "$details" | grep -q 'ad_actor_oper_port_state 63' &&
		printf '%s\n' "$details" | grep -q 'ad_partner_oper_port_state 63'
}

for index in 1 2; do
	wait_until "carrier LACP member $index" member_synced "x-carrier$index"
done

ip netns exec "$carrier" cat /proc/net/bonding/bond0
for index in 1 2; do
	grcli -s "$tmp/grout$index.sock" interface show name carrier
done

selected=0
for index in 1 2; do
	if member_synced "x-carrier$index"; then
		selected=$((selected + 1))
	fi
done

if [ "$selected" -ne 2 ]; then
	echo "GAP: carrier selected $selected of 2 split LACP links" >&2
	exit 2
fi

echo "PASS: carrier selected both split LACP links"
