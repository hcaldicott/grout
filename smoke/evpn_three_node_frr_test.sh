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
carrier="$prefix-carrier"
hosts=("$prefix-h1" "$prefix-h2" "$prefix-h3")
nodes=("$prefix-n1" "$prefix-n2" "$prefix-n3")
grout_pids=()
mh_enabled="${EVPN_MH_PROBE:-false}"

fail() {
	echo "FAIL: $*" >&2
	return 1
}

wait_until() {
	local description="$1"
	shift
	local attempts=300

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

	if [ "$status" -ne 0 ]; then
		for index in 1 2 3; do
			echo "=== Grout node $index log ===" >&2
			tail -n 100 "$tmp/grout$index.log" >&2
		done
	fi
	for node in "${nodes[@]}"; do
		frrinit.sh stop "$node" >/dev/null 2>&1
	done
	for pid in "${grout_pids[@]}"; do
		kill -TERM "$pid" >/dev/null 2>&1
	done
	for pid in "${grout_pids[@]}"; do
		wait "$pid" >/dev/null 2>&1
	done
	for ns in "${hosts[@]}" "${nodes[@]}" "$carrier" "$fabric"; do
		ip netns del "$ns" >/dev/null 2>&1
	done
	rm -rf "$tmp"
	exit "$status"
}

carrier_member_synced() {
	local details

	details=$(ip -n "$carrier" -d link show "$1")
	printf '%s\n' "$details" | grep -q 'ad_actor_oper_port_state 63' &&
		printf '%s\n' "$details" | grep -q 'ad_partner_oper_port_state 63'
}

carrier_member_not_synced() {
	! carrier_member_synced "$1"
}

grout_carrier_member_state() {
	local sock="$1"
	local protodown="$2"
	local active="$3"

	grcli -s "$sock" -j interface show name carrier 2>/dev/null |
		jq -e --argjson protodown "$protodown" --argjson active "$active" \
			'.bond_members[0] | .protodown == $protodown and .active == $active' \
			>/dev/null
}

nhg_member_count_is() {
	local sock="$1"
	local nhg_id="$2"
	local expected="$3"

	grcli -s "$sock" -j nexthop show id "$nhg_id" 2>/dev/null |
		jq -e --argjson expected "$expected" \
		'.type == "group" and (.members | length) == $expected' >/dev/null
}

nhg_only_vtep_is() {
	local sock="$1"
	local nhg_id="$2"
	local vtep="$3"
	local l2_id

	l2_id=$(grcli -s "$sock" -j nexthop show type l2 2>/dev/null |
		jq -r --arg vtep "$vtep" '[.[] | select(.vtep == $vtep)][0].id // 0')
	[ "$l2_id" -ne 0 ] || return 1
	grcli -s "$sock" -j nexthop show id "$nhg_id" 2>/dev/null |
		jq -e --argjson l2_id "$l2_id" \
		'.type == "group" and (.members | length) == 1 and .members[0].id == $l2_id' \
		>/dev/null
}

bridge_port_policy_is() {
	local sock="$1"
	local non_df="$2"
	local peer_vtep="$3"

	grcli -s "$sock" -j bridge-port show iface carrier 2>/dev/null |
		jq -e --argjson non_df "$non_df" --arg peer_vtep "$peer_vtep" '
			.non_df == $non_df and
			.backup_nhg != 0 and
			.split_horizon_vteps == [$peer_vtep]
		' >/dev/null
}

remote_fdb_has_nhg() {
	local sock="$1"
	local mac="$2"

	grcli -s "$sock" -j fdb show 2>/dev/null |
		jq -e --arg mac "$mac" \
		'any(.[]; .mac == $mac and .iface == "vxlan100" and .nhg != 0)' \
		>/dev/null
}

local_fdb_has_mac() {
	local sock="$1"
	local mac="$2"

	grcli -s "$sock" -j fdb show 2>/dev/null |
		jq -e --arg mac "$mac" \
		'any(.[]; .mac == $mac and .iface == "carrier")' >/dev/null
}

local_fdb_lacks_mac() {
	local sock="$1"
	local mac="$2"

	! local_fdb_has_mac "$sock" "$mac"
}

send_carrier_learning_frame() {
	local iface="$1"
	local source_mac="$2"

	ip netns exec "$carrier" python3 - "$iface" "$source_mac" <<-'PY'
	import socket
	import struct
	import sys

	iface, source_mac = sys.argv[1:]
	frame = (
	    b"\xff" * 6
	    + bytes.fromhex(source_mac.replace(":", ""))
	    + struct.pack("!H", 0x88b4)
	    + b"evpn-mh-carrier-learn"
	)
	frame += b"\x00" * (60 - len(frame))
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
}

capture_carrier_bum() {
	local ether_type="$1"
	local expected_pe1="$2"
	local expected_pe2="$3"
	local pcap1="$tmp/bum-${ether_type}-pe1.pcap"
	local pcap2="$tmp/bum-${ether_type}-pe2.pcap"
	local pid1 pid2 count1 count2

	ip netns exec "$carrier" timeout 2 tcpdump -U -qn -i x-carrier1 \
		-w "$pcap1" "ether proto $ether_type" 2>/dev/null &
	pid1=$!
	ip netns exec "$carrier" timeout 2 tcpdump -U -qn -i x-carrier2 \
		-w "$pcap2" "ether proto $ether_type" 2>/dev/null &
	pid2=$!
	sleep 0.2
	ip netns exec "${hosts[2]}" python3 - x-a3 "$ether_type" <<-'PY'
	import socket
	import struct
	import sys

	iface = sys.argv[1]
	ether_type = int(sys.argv[2], 0)
	with open(f"/sys/class/net/{iface}/address", encoding="ascii") as f:
	    src = bytes.fromhex(f.read().strip().replace(":", ""))
	frame = b"\xff" * 6 + src + struct.pack("!H", ether_type) + b"evpn-mh-bum"
	frame += b"\x00" * (60 - len(frame))
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
	wait "$pid1" || true
	wait "$pid2" || true
	count1=$(tcpdump -qn -r "$pcap1" "ether proto $ether_type" 2>/dev/null | wc -l)
	count2=$(tcpdump -qn -r "$pcap2" "ether proto $ether_type" 2>/dev/null | wc -l)
	[ "$count1" -eq "$expected_pe1" ] ||
		fail "PE1 received $count1 BUM copies, expected $expected_pe1"
	[ "$count2" -eq "$expected_pe2" ] ||
		fail "PE2 received $count2 BUM copies, expected $expected_pe2"
}

capture_injected_vxlan_bum() {
	local source_vtep="$1"
	local ether_type="$2"
	local expected="$3"
	local pcap="$tmp/vxlan-bum-${source_vtep}-${ether_type}.pcap"
	local underlay_mac capture_pid count

	underlay_mac=$(grcli -s "$tmp/grout2.sock" -j interface show name underlay 2>/dev/null |
		jq -er '.mac') || fail "could not discover PE2 underlay MAC"
	ip netns exec "$carrier" timeout 2 tcpdump -U -qn -i x-carrier2 \
		-w "$pcap" "ether proto $ether_type" 2>/dev/null &
	capture_pid=$!
	sleep 0.2
	ip netns exec "$fabric" python3 - x-u2 "$underlay_mac" \
		"$source_vtep" 172.16.0.2 "$ether_type" <<-'PY'
	import socket
	import struct
	import sys

	iface, dst_mac, source_vtep, dest_vtep, ether_type = sys.argv[1:]
	ether_type = int(ether_type, 0)

	def checksum(data):
	    if len(data) % 2:
	        data += b"\x00"
	    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
	    total = (total & 0xffff) + (total >> 16)
	    total = (total & 0xffff) + (total >> 16)
	    return (~total) & 0xffff

	inner = (
	    b"\xff" * 6
	    + bytes.fromhex("02000000aa01")
	    + struct.pack("!H", ether_type)
	    + b"evpn-mh-split-horizon"
	)
	inner += b"\x00" * (60 - len(inner))
	vxlan = struct.pack("!II", 0x08000000, 100 << 8)
	udp_len = 8 + len(vxlan) + len(inner)
	udp = struct.pack("!HHHH", 49152, 4789, udp_len, 0)
	src_ip = socket.inet_aton(source_vtep)
	dst_ip = socket.inet_aton(dest_vtep)
	ip_header = struct.pack(
	    "!BBHHHBBH4s4s",
	    0x45, 0, 20 + udp_len, 1, 0x4000, 64, socket.IPPROTO_UDP, 0,
	    src_ip, dst_ip,
	)
	ip_header = ip_header[:10] + struct.pack("!H", checksum(ip_header)) + ip_header[12:]
	outer = (
	    bytes.fromhex(dst_mac.replace(":", ""))
	    + bytes.fromhex("020000009901")
	    + struct.pack("!H", 0x0800)
	)
	frame = outer + ip_header + udp + vxlan + inner
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
	wait "$capture_pid" || true
	count=$(tcpdump -qn -r "$pcap" "ether proto $ether_type" 2>/dev/null | wc -l) ||
		fail "could not inspect PE2 carrier capture for $ether_type"
	[ "$count" -eq "$expected" ] ||
		fail "PE2 emitted $count BUM copies from VTEP $source_vtep, expected $expected"
}

capture_local_bias_redirect() {
	local learned_mac=02:00:00:00:aa:02
	local pcap="$tmp/local-bias.pcap"
	local capture_pid count

	# Teach the destination on PE2's local ES without relying on the carrier
	# bond hash to select that member for an ordinary flow.
	ip netns exec "$carrier" python3 - x-carrier2 "$learned_mac" <<-'PY'
	import socket
	import struct
	import sys

	iface, source_mac = sys.argv[1:]
	frame = (
	    b"\xff" * 6
	    + bytes.fromhex(source_mac.replace(":", ""))
	    + struct.pack("!H", 0x88b9)
	    + b"evpn-mh-local-bias-learn"
	)
	frame += b"\x00" * (60 - len(frame))
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
	wait_until "PE2 local-ES MAC learning" sh -c \
		"grcli -s '$tmp/grout2.sock' -j fdb show | jq -e --arg mac '$learned_mac' \
		'any(.[]; .mac == \$mac and .iface == \"carrier\")' >/dev/null"

	ip netns exec "$fabric" timeout 2 tcpdump -Q in -U -qn -i x-u2 -w "$pcap" \
		'src host 172.16.0.2 and dst host 172.16.0.1 and udp dst port 4789' \
		2>/dev/null &
	capture_pid=$!
	sleep 0.2
	ip netns exec "$carrier" python3 - x-carrier2 "$learned_mac" <<-'PY'
	import socket
	import struct
	import sys

	iface, dest_mac = sys.argv[1:]
	frame = (
	    bytes.fromhex(dest_mac.replace(":", ""))
	    + bytes.fromhex("02000000aa03")
	    + struct.pack("!H", 0x88ba)
	    + b"evpn-mh-local-bias-redirect"
	)
	frame += b"\x00" * (60 - len(frame))
	sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
	sock.bind((iface, 0))
	sock.send(frame)
	sock.close()
	PY
	wait "$capture_pid" || true
	# Ethernet(14) + IPv4(20) + UDP(8) + VXLAN(8) + inner MACs(12).
	count=$(tcpdump -qn -r "$pcap" 'ether[62:2] = 0x88ba' \
		2>/dev/null | wc -l) || fail "could not inspect local-bias capture"
	[ "$count" -eq 1 ] ||
		fail "PE2 emitted $count local-bias redirects through its backup NHG, expected 1"
}

configure_mh_carrier() {
	local system_mac=02:00:00:00:10:00
	local esi=03:02:00:00:00:10:00:00:00:01
	local carrier_mac

	ip netns add "$carrier"
	ip -n "$carrier" link set lo up
	ip netns exec "$carrier" sysctl -qw \
		net.ipv6.conf.all.disable_ipv6=1 \
		net.ipv6.conf.default.disable_ipv6=1
	ip -n "$carrier" link add bond0 type bond mode 802.3ad \
		lacp_active on lacp_rate fast xmit_hash_policy layer3+4

	for index in 1 2; do
		local node="${nodes[$((index - 1))]}"
		local sock="$tmp/grout$index.sock"
		local tap="x-carrier$index"

		grcli -s "$sock" interface add bond carrier mode lacp \
			mac "$system_mac" domain br100
		grcli -s "$sock" interface add port carrier-port \
			devargs "net_tap2,iface=$tap" domain carrier
		ip -n "$node" link set "$tap" address "02:00:00:00:20:0$index"
		ip -n "$node" link set "$tap" netns "$carrier"
		ip -n "$carrier" link set "$tap" master bond0
		ip -n "$carrier" link set "$tap" up
	done

	ip -n "$carrier" link set bond0 up
	for index in 1 2; do
		wait_until "carrier LACP member $index" \
			carrier_member_synced "x-carrier$index"
	done

	carrier_mac=$(ip -n "$carrier" -j link show bond0 | jq -er '.[0].address')
	send_carrier_learning_frame x-carrier1 "$carrier_mac"
	wait_until "PE1 pre-ES carrier MAC learning" \
		local_fdb_has_mac "$tmp/grout1.sock" "$carrier_mac"

	for index in 1 2; do
		local node="${nodes[$((index - 1))]}"

		wait_until "node $index carrier interface in FRR" \
			sh -c "vtysh -N '$node' -c 'show interface carrier' | grep -q 'Interface carrier'"
		vtysh -N "$node" <<-EOF
		configure terminal
		evpn mh startup-delay 0
		evpn mh redirect-off
		interface underlay
		 evpn mh uplink
		exit
		interface carrier
		 evpn mh es-id 1
		 evpn mh es-sys-mac $system_mac
		exit
		EOF

		wait_until "node $index local Ethernet Segment" \
			sh -c "vtysh -N '${nodes[$((index - 1))]}' -c 'show evpn es' | grep -qi '$esi'"
	done
	wait_until "pre-ES carrier MAC reconciliation" \
		local_fdb_lacks_mac "$tmp/grout1.sock" "$carrier_mac"
	send_carrier_learning_frame x-carrier1 "$carrier_mac"

	sleep 2
	for index in 1 2 3; do
		echo "=== node $index EVPN Ethernet Segments ==="
		vtysh -N "${nodes[$((index - 1))]}" -c 'show evpn es detail'
		vtysh -N "${nodes[$((index - 1))]}" -c 'show evpn es-evi detail'
	done
	vtysh -N "${nodes[2]}" -c 'show bgp l2vpn evpn route type 1'
	vtysh -N "${nodes[2]}" -c 'show bgp l2vpn evpn route type 4'

	wait_until "remote type-1 Ethernet A-D route" \
		sh -c "vtysh -N '${nodes[2]}' -c 'show bgp l2vpn evpn route type 1' | grep -qi '$esi'"
	wait_until "remote type-4 Ethernet Segment route" \
		sh -c "vtysh -N '${nodes[2]}' -c 'show bgp l2vpn evpn route type 4' | grep -qi '$esi'"
	wait_until "PE1 DF bridge-port policy" \
		bridge_port_policy_is "$tmp/grout1.sock" false 172.16.0.2
	wait_until "PE2 non-DF bridge-port policy" \
		bridge_port_policy_is "$tmp/grout2.sock" true 172.16.0.1

	if [ "${EVPN_MH_DATA_PLANE:-false}" != true ]; then
		echo "PASS: EVPN-MH control plane converged"
		return
	fi

	ip -n "$carrier" address add 10.0.0.10/24 dev bond0

	if ! ip netns exec "$carrier" ping -c 3 -W 2 10.0.0.4; then
		echo "GAP: EVPN-MH control plane converged but carrier traffic failed" >&2
		for index in 1 2 3; do
			grcli -s "$tmp/grout$index.sock" fdb show
		done
		return 2
	fi

	local l2_nhs remote_fdb nhg_id
	if ! wait_until "remote all-active MAC NHG" \
		remote_fdb_has_nhg "$tmp/grout3.sock" "$carrier_mac"; then
		for index in 1 2 3; do
			echo "DIAG: node $index FDB $(grcli -s "$tmp/grout$index.sock" -j fdb show)" \
				>&2
			echo "DIAG: node $index EVPN MAC $(vtysh -N "${nodes[$((index - 1))]}" \
				-c "show evpn mac vni 100 mac $carrier_mac json" | jq -c .)" >&2
		done
		vtysh -N "${nodes[2]}" -c 'show bgp l2vpn evpn route type macip' >&2
		fail "remote all-active MAC NHG did not converge"
	fi
	l2_nhs=$(grcli -s "$tmp/grout3.sock" -j nexthop show type l2)
	printf '%s\n' "$l2_nhs" | jq -e '
		length == 2 and
		any(.[]; .vtep == "172.16.0.1") and
		any(.[]; .vtep == "172.16.0.2")
	' >/dev/null || fail "remote PE did not install both L2 VTEP nexthops"

	remote_fdb=$(grcli -s "$tmp/grout3.sock" -j fdb show)
	nhg_id=$(printf '%s\n' "$remote_fdb" | jq -r '
		[.[] | select(.iface == "vxlan100" and .nhg != 0)][0].nhg // 0
	')
	[ "$nhg_id" -ne 0 ] || fail "remote all-active MAC was not installed against an NHG"
	grcli -s "$tmp/grout3.sock" -j nexthop show id "$nhg_id" |
		jq -e '.type == "group" and (.members | length) == 2' >/dev/null ||
		fail "remote MAC NHG does not contain both PE nexthops"

	local capture_pid capture_file
	capture_file="$tmp/evpn-mh-ecmp.capture"
	ip netns exec "$fabric" timeout 3 tcpdump -l -nn -i any \
		'src host 172.16.0.3 and udp dst port 4789' >"$capture_file" 2>/dev/null &
	capture_pid=$!
	sleep 0.2
	ip netns exec "${hosts[2]}" python3 - <<-'PY'
	import socket

	for port in range(20000, 20064):
	    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	    sock.bind(("10.0.0.4", port))
	    sock.sendto(b"evpn-mh", ("10.0.0.10", 9000))
	    sock.close()
	PY
	wait "$capture_pid" || true
	grep -q '172\.16\.0\.3\.[0-9]* > 172\.16\.0\.1\.4789' "$capture_file" ||
		{ cat "$capture_file" >&2; fail "MAC ECMP did not select PE1"; }
	grep -q '172\.16\.0\.3\.[0-9]* > 172\.16\.0\.2\.4789' "$capture_file" ||
		{ cat "$capture_file" >&2; fail "MAC ECMP did not select PE2"; }

	capture_carrier_bum 0x88b5 1 0
	vtysh -N "${nodes[1]}" <<-EOF
	configure terminal
	interface carrier
	 evpn mh es-df-pref 50000
	EOF
	wait_until "PE1 non-DF policy after DF preference change" \
		bridge_port_policy_is "$tmp/grout1.sock" true 172.16.0.2
	wait_until "PE2 DF policy after DF preference change" \
		bridge_port_policy_is "$tmp/grout2.sock" false 172.16.0.1
	capture_carrier_bum 0x88b6 0 1
	echo "PASS: DF election and preference change gate carrier BUM traffic"
	# Prove the split-horizon filter independently of DF election: PE2 is DF,
	# so BUM from an ordinary remote VTEP is forwarded, while BUM arriving
	# from its Ethernet Segment peer VTEP is suppressed.
	capture_injected_vxlan_bum 172.16.0.3 0x88b7 1
	capture_injected_vxlan_bum 172.16.0.1 0x88b8 0
	echo "PASS: ES peer-VTEP split horizon suppresses carrier BUM traffic"
	ip netns exec "${hosts[2]}" ping -c 3 -W 2 10.0.0.10 ||
		fail "known unicast failed after DF change"

	# Fail PE1's EVPN-MH uplink while leaving its carrier-facing port physically
	# up. FRR must translate uplink tracking into Grout member protodown; Grout
	# must then withdraw LACP collecting/distributing without silencing LACP.
	ip -n "$fabric" link set x-u1 down
	wait_until "FRR-driven PE1 carrier protodown" \
		grout_carrier_member_state "$tmp/grout1.sock" true false
	wait_until "carrier LACP member PE1 withdrawal" \
		carrier_member_not_synced x-carrier1
	if ! ip -n "$carrier" link show x-carrier1 | grep -qw LOWER_UP; then
		fail "FRR protodown lowered PE1's physical carrier link"
	fi
	wait_until "remote MAC NHG to retain only PE2 after PE1 uplink failure" \
		nhg_only_vtep_is "$tmp/grout3.sock" "$nhg_id" 172.16.0.2
	if ! ip netns exec "${hosts[2]}" ping -c 3 -W 2 10.0.0.10; then
		for index in 1 2 3; do
			echo "DIAG: node $index FDB $(grcli -s "$tmp/grout$index.sock" -j fdb show)" \
				>&2
		done
		fail "carrier traffic failed after PE1 uplink-triggered protodown"
	fi

	ip -n "$fabric" link set x-u1 up
	wait_until "PE1 underlay recovery" \
		sh -c "ip -n '${nodes[0]}' -o link show underlay | grep -qw 'state UP'"
	wait_evpn_peers "${nodes[0]}"
	wait_until "FRR clears PE1 carrier protodown" \
		grout_carrier_member_state "$tmp/grout1.sock" false true
	wait_until "carrier LACP member PE1 recovery" carrier_member_synced x-carrier1
	wait_until "remote MAC NHG to restore PE1" \
		nhg_member_count_is "$tmp/grout3.sock" "$nhg_id" 2
	capture_local_bias_redirect
	echo "PASS: local-ES hairpin traffic uses the EVPN backup NHG"

	# A carrier-side physical failure follows the complementary path: LACP and
	# the bond go down first, then FRR performs the EVPN mass withdrawal.
	ip -n "$carrier" link set x-carrier1 down
	wait_until "Grout detects PE1 physical carrier loss" \
		grout_carrier_member_state "$tmp/grout1.sock" false false
	wait_until "remote MAC NHG after PE1 carrier loss" \
		nhg_only_vtep_is "$tmp/grout3.sock" "$nhg_id" 172.16.0.2
	ip netns exec "${hosts[2]}" ping -c 3 -W 2 10.0.0.10 ||
		fail "carrier traffic failed after PE1 physical carrier loss"

	ip -n "$carrier" link set x-carrier1 up
	wait_until "carrier LACP member PE1 physical recovery" carrier_member_synced x-carrier1
	wait_until "Grout reactivates PE1 after physical carrier recovery" \
		grout_carrier_member_state "$tmp/grout1.sock" false true
	wait_until "remote MAC NHG after PE1 physical carrier recovery" \
		nhg_member_count_is "$tmp/grout3.sock" "$nhg_id" 2

	echo "PASS: EVPN-MH survived both FRR protodown and physical carrier loss"
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
	local memory=1024

	ip netns add "$node"
	ip -n "$node" link set lo up
	ip netns exec "$node" env GROUT_SOCK_PATH="$sock" \
		grout -t -M "unix:$tmp/metrics$index.sock" -- \
		--file-prefix="$prefix-$index" -m "$memory" >"$log" 2>&1 &
	grout_pids+=("$!")
	wait_until "Grout node $index API socket" test -S "$sock"
	grcli -s "$sock" nexthop config set max 128
	grcli -s "$sock" route config set default rib4-routes 128 rib6-routes 128
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
	local peer1 peer2 timer1 timer2

	case "$index" in
	1) peer1=2; peer2=3 ;;
	2) peer1=1; peer2=3 ;;
	3) peer1=1; peer2=2 ;;
	esac
	if [ "$mh_enabled" = true ]; then
		timer1=" neighbor 172.16.0.$peer1 timers 1 3"
		timer2=" neighbor 172.16.0.$peer2 timers 1 3"
	fi

	vtysh -N "$node" <<-EOF
	configure terminal
	router bgp 65000
	 bgp router-id 172.16.0.$index
	 no bgp default ipv4-unicast
	 neighbor 172.16.0.$peer1 remote-as 65000
	$timer1
	 neighbor 172.16.0.$peer2 remote-as 65000
	$timer2
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

if [ "$mh_enabled" = true ]; then
	configure_mh_carrier
fi

ip netns exec "${hosts[0]}" ping -c 3 -W 2 10.0.0.4
ip netns exec "${hosts[2]}" ping -c 3 -W 2 10.0.0.2

for index in 1 2 3; do
	grcli -s "$tmp/grout$index.sock" fdb show
done
