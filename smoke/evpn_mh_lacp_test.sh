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
stress_cycles="${EVPN_MH_STRESS_CYCLES:-3}"

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
		--file-prefix="$prefix-$index" -m 1024 >"$tmp/grout$index.log" 2>&1 &
	grout_pids+=("$!")
	wait_until "Grout node $index API socket" test -S "$sock"
	grcli -s "$sock" nexthop config set max 128
	grcli -s "$sock" route config set default rib4-routes 128 rib6-routes 128

	grcli -s "$sock" interface add bridge br-carrier
	grcli -s "$sock" interface add bond carrier mode lacp \
		mac 02:00:00:00:10:00 domain br-carrier
	grcli -s "$sock" interface add port carrier-port \
		devargs "net_tap0,iface=$tap" domain carrier
	# Keep the Linux TAP identity distinct from Grout's physical-port MAC.
	ip -n "$node" link set "$tap" address "02:00:00:00:20:0$index"
	ip -n "$node" link set "$tap" netns "$carrier"
	ip -n "$carrier" link set "$tap" master bond0
	ip -n "$carrier" link set "$tap" up
	wait_until "$tap dataplane link" \
		sh -c "ip -n '$carrier' link show '$tap' | grep -qw LOWER_UP"

	if [ "$index" -eq 1 ]; then
		grcli -s "$sock" interface add port access-port \
			devargs "net_tap1,iface=x-access1" domain br-carrier
		ip -n "$node" link set x-access1 netns "$carrier"
		ip -n "$carrier" link set x-access1 up
		wait_until "access dataplane link" \
			sh -c "ip -n '$carrier' link show x-access1 | grep -qw LOWER_UP"
	fi
done

ip -n "$carrier" link set bond0 up

member_synced() {
	local details

	details=$(ip -n "$carrier" -d link show "$1")
	printf '%s\n' "$details" | grep -q 'ad_actor_oper_port_state 63' &&
		printf '%s\n' "$details" | grep -q 'ad_partner_oper_port_state 63'
}

member_not_synced() {
	! member_synced "$1"
}

grout_member_state() {
	local sock="$1"
	local protodown="$2"
	local active="$3"

	grcli -s "$sock" -j interface show name carrier 2>/dev/null |
		jq -e --argjson protodown "$protodown" --argjson active "$active" \
			'.bond_members[0] | .protodown == $protodown and .active == $active' \
			>/dev/null
}

fdb_has_mac() {
	local mac="$1"

	grcli -s "$tmp/grout1.sock" -j fdb show 2>/dev/null |
		jq -e --arg mac "$mac" 'any(.[]; .mac == $mac)' >/dev/null
}

fdb_lacks_mac() {
	! fdb_has_mac "$1"
}

send_frame() {
	local iface="$1"
	local source_mac="$2"
	local ether_type="$3"

	ip netns exec "$carrier" python3 - "$iface" "$source_mac" "$ether_type" <<-'PY'
	import socket
	import struct
	import sys

	iface, source_mac, ether_type = sys.argv[1:]
	frame = (
	    b"\xff" * 6
	    + bytes.fromhex(source_mac.replace(":", ""))
	    + struct.pack("!H", int(ether_type, 0))
	    + b"evpn-mh-protodown"
	)
	frame += b"\x00" * (60 - len(frame))
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
}

graph_stat_count() {
	local name="$1"

	grcli -s "$tmp/grout1.sock" -j stats show software brief zero \
		pattern '*bond*' 2>/dev/null | jq -r --arg name "$name" '.[$name] // 0'
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

normal_ingress_mac=02:00:00:00:aa:01
suppressed_ingress_mac=02:00:00:00:aa:02
send_frame x-carrier1 "$normal_ingress_mac" 0x88bc
wait_until "ordinary carrier ingress before protodown" fdb_has_mac "$normal_ingress_mac"

grcli -s "$tmp/grout1.sock" interface set bond carrier member carrier-port protodown on
wait_until "Grout member protodown" \
	grout_member_state "$tmp/grout1.sock" true false
wait_until "carrier removes protodown member from LACP" member_not_synced x-carrier1
if ! ip -n "$carrier" link show x-carrier1 | grep -qw LOWER_UP; then
	echo "FAIL: protodown lowered the physical carrier link" >&2
	exit 1
fi
if ! member_synced x-carrier2; then
	echo "FAIL: surviving carrier member lost LACP synchronization" >&2
	exit 1
fi

send_frame x-carrier1 "$suppressed_ingress_mac" 0x88bd
sleep 0.2
fdb_lacks_mac "$suppressed_ingress_mac" || {
	echo "FAIL: ordinary carrier ingress was accepted while protodown" >&2
	exit 1
}
grcli -s "$tmp/grout1.sock" stats reset
send_frame x-access1 02:00:00:00:bb:01 0x88be
wait_until "ordinary access ingress while carrier is protodown" \
	fdb_has_mac 02:00:00:00:bb:01
sleep 0.2
protodown_egress_drops=$(graph_stat_count bond_no_member)
if [ "$protodown_egress_drops" -lt 1 ]; then
	echo "FAIL: ordinary carrier egress did not reach the no-member drop while protodown" >&2
	exit 1
fi

# Protodown must not silence the LACP state machine. Otherwise the carrier can
# retain stale collecting/distributing state and blackhole traffic.
if ! timeout 5 ip netns exec "$carrier" tcpdump -Q in -c 1 -nn -i x-carrier1 \
	'ether proto 0x8809' >/dev/null 2>&1; then
	echo "FAIL: Grout stopped transmitting LACP while the member was protodown" >&2
	exit 1
fi

grcli -s "$tmp/grout1.sock" interface set bond carrier member carrier-port protodown off
wait_until "Grout member protodown clear" \
	grout_member_state "$tmp/grout1.sock" false false
wait_until "carrier reselects recovered member" member_synced x-carrier1
wait_until "Grout reactivates recovered member" \
	grout_member_state "$tmp/grout1.sock" false true
send_frame x-carrier1 "$suppressed_ingress_mac" 0x88bd
wait_until "ordinary carrier ingress after recovery" \
	fdb_has_mac "$suppressed_ingress_mac"
grcli -s "$tmp/grout1.sock" stats reset
send_frame x-access1 02:00:00:00:bb:02 0x88bf
wait_until "ordinary access ingress after carrier recovery" \
	fdb_has_mac 02:00:00:00:bb:02
sleep 0.2
recovered_bond_output=$(graph_stat_count bond_output)
recovered_egress_drops=$(graph_stat_count bond_no_member)
if [ "$recovered_bond_output" -lt 1 ] || [ "$recovered_egress_drops" -ne 0 ]; then
	echo "FAIL: carrier bond did not select the recovered member for ordinary egress" >&2
	exit 1
fi

# Repeat the state transition to catch stale actor/partner state, timer leaks
# and members that recover once but fail on a later negotiation cycle.
for cycle in $(seq 1 "$stress_cycles"); do
	grcli -s "$tmp/grout1.sock" interface set bond carrier member carrier-port protodown on
	wait_until "stress cycle $cycle Grout member protodown" \
		grout_member_state "$tmp/grout1.sock" true false
	wait_until "stress cycle $cycle carrier withdrawal" member_not_synced x-carrier1
	member_synced x-carrier2 || {
		echo "FAIL: stress cycle $cycle disturbed the surviving LACP member" >&2
		exit 1
	}
	if ! timeout 5 ip netns exec "$carrier" tcpdump -Q in -c 1 -nn -i x-carrier1 \
		'ether proto 0x8809' >/dev/null 2>&1; then
		echo "FAIL: stress cycle $cycle silenced LACP while protodown" >&2
		exit 1
	fi

	grcli -s "$tmp/grout1.sock" interface set bond carrier member carrier-port protodown off
	wait_until "stress cycle $cycle protodown clear" \
		grout_member_state "$tmp/grout1.sock" false false
	wait_until "stress cycle $cycle carrier reselection" member_synced x-carrier1
	wait_until "stress cycle $cycle Grout member reactivation" \
		grout_member_state "$tmp/grout1.sock" false true
done

stress_mac=$(printf '02:00:00:00:cc:%02x' "$stress_cycles")
send_frame x-carrier1 "$stress_mac" 0x88c0
wait_until "ordinary ingress after repeated protodown cycles" fdb_has_mac "$stress_mac"

echo "PASS: protodown suppresses ordinary traffic, keeps LACP alive, and recovers repeatedly"
