#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

# Run three independent Grout and FRR stacks over a shared virtual underlay.
# This is the baseline for EVPN multihoming tests: it deliberately exercises
# ordinary EVPN type-2/type-3 exchange before adding an Ethernet Segment.

set -e -o pipefail

if [ "${_THREE_NODE_UNSHARED:-}" != 1 ]; then
	export _THREE_NODE_UNSHARED=1
	exec unshare --mount --net -- "$0" "$@"
fi

builddir=$(realpath "${1:-build}")
export PATH="$builddir:$builddir/frr_install/sbin:$builddir/frr_install/bin:$PATH"
export GROUT_PAGER=""

tmp=$(mktemp -d)
chmod 0777 "$tmp"
prefix="e3n-$$"
fabric="$prefix-f"
hosts=("$prefix-h1" "$prefix-h2" "$prefix-h3")
nodes=("$prefix-n1" "$prefix-n2" "$prefix-n3")
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

dump_diagnostics() {
	set +e
	echo "=== shared underlay ===" >&2
	ip -n "$fabric" -d link show >&2
	for index in 1 2 3; do
		local node="${nodes[$((index - 1))]}"
		echo "=== node $index interfaces ===" >&2
		ip -n "$node" -br address show >&2
		grcli -s "$tmp/grout$index.sock" interface show >&2
		echo "=== node $index BGP configuration ===" >&2
		vtysh -N "$node" -c 'show running-config' >&2
		echo "=== node $index EVPN summary ===" >&2
		vtysh -N "$node" -c 'show bgp l2vpn evpn summary json' >&2
	done
}

cleanup() {
	local status=$?
	set +e

	for node in "${nodes[@]}"; do
		frrinit.sh stop "$node" >/dev/null 2>&1
	done
	for pid in "${grout_pids[@]}"; do
		kill -TERM "$pid" >/dev/null 2>&1
	done
	for pid in "${grout_pids[@]}"; do
		wait "$pid" >/dev/null 2>&1
	done
	for ns in "${hosts[@]}" "${nodes[@]}" "$fabric"; do
		ip netns del "$ns" >/dev/null 2>&1
	done
	rm -rf "$tmp"
	exit "$status"
}
trap cleanup EXIT

mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
for dir in etc/frr var/log/frr var/run/frr var/lib/frr; do
	mkdir -p "$builddir/frr_install/$dir"
	mount -t tmpfs -o mode=1777 tmpfs "$builddir/frr_install/$dir"
done

ip netns add "$fabric"
ip -n "$fabric" link add fabric0 type bridge
ip -n "$fabric" link set fabric0 up

start_grout() {
	local index="$1"
	local node="${nodes[$((index - 1))]}"
	local sock="$tmp/grout$index.sock"
	local log="$tmp/grout$index.log"

	ip netns add "$node"
	ip -n "$node" link set lo up
	ip netns exec "$node" env GROUT_SOCK_PATH="$sock" \
		grout -t -M "unix:$tmp/metrics$index.sock" -- \
		--file-prefix="$prefix-$index" >"$log" 2>&1 &
	grout_pids+=("$!")
	wait_until "Grout node $index API socket" test -S "$sock"
}

start_frr() {
	local index="$1"
	local node="${nodes[$((index - 1))]}"
	local sock="$tmp/grout$index.sock"
	local confdir="$builddir/frr_install/etc/frr/$node"
	local logfile="$tmp/$node.log"

	mkdir -p "$confdir"
	touch "$confdir/vtysh.conf" "$logfile"
	chmod 0666 "$logfile"
	cat >"$confdir/daemons" <<-EOF
	bfdd=no
	bgpd=yes
	isisd=no
	ospfd=no
	ospf6d=no
	vtysh_enable=yes
	frr_global_options="-A 127.0.0.1 --log file:$logfile"
	zebra_options="-s 90000000 -M dplane_grout"
	watchfrr_options="--netns=$node"
	EOF
	cat >"$confdir/frr.conf" <<-EOF
	hostname node$index
	EOF

	GROUT_SOCK_PATH="$sock" frrinit.sh start "$node" >/dev/null
	wait_until "FRR node $index Grout subscription" \
		grep -q "GROUT:.*iface/ip events" "$logfile"
}

configure_underlay() {
	local index="$1"
	local node="${nodes[$((index - 1))]}"
	local sock="$tmp/grout$index.sock"
	local tap="x-u$index"

	grcli -s "$sock" interface add port underlay \
		devargs "net_tap0,iface=$tap"
	# The Linux endpoint must not share Grout's port MAC. Otherwise Linux
	# treats frames emitted by Grout as locally originated and drops them.
	ip -n "$node" link set "$tap" address "02:00:00:00:01:0$index"
	ip -n "$node" link set "$tap" netns "$fabric"
	ip -n "$fabric" link set "$tap" master fabric0
	ip -n "$fabric" link set "$tap" up
	wait_until "$tap dataplane link" \
		sh -c "ip -n '$fabric' link show '$tap' | grep -qw LOWER_UP"
	wait_until "node $index underlay control-plane link" \
		sh -c "ip -n '$node' -o link show underlay | grep -qw 'state UP'"

	vtysh -N "$node" <<-EOF
	configure terminal
	interface underlay
	 ip address 172.16.0.$index/24
	exit
	EOF
}

configure_bgp() {
	local index="$1"
	local node="${nodes[$((index - 1))]}"
	local peer1 peer2

	case "$index" in
	1) peer1=2; peer2=3 ;;
	2) peer1=1; peer2=3 ;;
	3) peer1=1; peer2=2 ;;
	esac

	vtysh -N "$node" <<-EOF
	configure terminal
	router bgp 65000
	 bgp router-id 172.16.0.$index
	 no bgp default ipv4-unicast
	 neighbor 172.16.0.$peer1 remote-as 65000
	 neighbor 172.16.0.$peer2 remote-as 65000
	 address-family l2vpn evpn
	  neighbor 172.16.0.$peer1 activate
	  neighbor 172.16.0.$peer2 activate
	  advertise-all-vni
	 exit-address-family
	EOF
}

evpn_peers_established() {
	local node="$1"
	vtysh -N "$node" -c 'show bgp l2vpn evpn summary json' 2>/dev/null | \
		jq -e '.peers | length == 2 and all(.[]; .state == "Established")' \
		>/dev/null
}

wait_evpn_peers() {
	local node="$1"
	local attempts=300

	until evpn_peers_established "$node"; do
		attempts=$((attempts - 1))
		if [ "$attempts" -eq 0 ]; then
			echo "timeout waiting for $node EVPN peers" >&2
			dump_diagnostics
			return 1
		fi
		sleep 0.1
	done
}

configure_overlay() {
	local index="$1"
	local node="${nodes[$((index - 1))]}"
	local host="${hosts[$((index - 1))]}"
	local sock="$tmp/grout$index.sock"
	local tap="x-a$index"

	wait_until "node $index EVPN enablement" \
		sh -c "vtysh -N '$node' -c 'show evpn' | grep -q 'L2 VNIs'"
	grcli -s "$sock" interface add bridge br100
	grcli -s "$sock" interface add vxlan vxlan100 vni 100 \
		local "172.16.0.$index" domain br100
	wait_until "node $index VNI 100" \
		sh -c "vtysh -N '$node' -c 'show evpn vni 100' | grep -q 'VNI: 100'"
	grcli -s "$sock" interface add port access \
		devargs "net_tap1,iface=$tap" domain br100
	ip -n "$node" link set "$tap" address "02:00:00:00:02:0$index"

	ip netns add "$host"
	ip -n "$host" link set lo up
	ip -n "$node" link set "$tap" netns "$host"
	ip -n "$host" link set "$tap" up
	ip -n "$host" addr add "10.0.0.$((index + 1))/24" dev "$tap"
}

for index in 1 2 3; do
	start_grout "$index"
	start_frr "$index"
	configure_underlay "$index"
done
for index in 1 2 3; do
	for peer in 1 2 3; do
		if [ "$peer" -ne "$index" ]; then
			if ! grcli -s "$tmp/grout$index.sock" \
					ping "172.16.0.$peer" count 1 delay 10; then
				dump_diagnostics
				exit 1
			fi
		fi
	done
done
for index in 1 2 3; do
	configure_bgp "$index"
done
for index in 1 2 3; do
	configure_overlay "$index"
done

for node in "${nodes[@]}"; do
	wait_evpn_peers "$node"
done

ip netns exec "${hosts[0]}" ping -c 3 -W 2 10.0.0.4
ip netns exec "${hosts[2]}" ping -c 3 -W 2 10.0.0.2

for index in 1 2 3; do
	grcli -s "$tmp/grout$index.sock" fdb show
done
