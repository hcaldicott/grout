#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

# Exercise L2 nexthop-group lifecycle ordering independently of FRR. Missing
# dependencies must fail closed, live deletes must leave a coherent group, and
# an empty referenced group must retain its L2 forwarding class.

. $(dirname $0)/_init.sh

port_add p0

group_member_count_is() {
	local id="$1"
	local expected="$2"

	grcli -j nexthop show id "$id" | jq -e --argjson expected "$expected" \
		'.type == "group" and (.members | length) == $expected' >/dev/null
}

group_only_member_is() {
	local id="$1"
	local member="$2"

	grcli -j nexthop show id "$id" | jq -e --argjson member "$member" \
		'.type == "group" and (.members | length) == 1 and .members[0].id == $member' \
		>/dev/null
}

# A group arriving before its member is rejected and is not partially created.
if grcli nexthop add group id 20 member 200; then
	fail "L2 group with a missing member was accepted"
fi
if grcli -j nexthop show id 20 >/dev/null 2>&1; then
	fail "failed L2 group creation left an object behind"
fi

grcli nexthop add l2 vtep 172.16.0.1 vrf main id 200
grcli nexthop add l2 vtep 172.16.0.2 vrf main id 201
grcli nexthop add group id 20 member 200 member 201
group_member_count_is 20 2 || fail "two-member L2 group was not installed"

# Deleting a referenced member forces every group to remove it. Readers must
# see the remaining complete member set rather than a dangling pointer.
grcli nexthop del 200
group_only_member_is 20 201 || fail "deleted L2 member remained in its group"

# Removing the final member leaves an empty but still typed L2 group. It may be
# repopulated with L2 state after FRR reordering, but never with an L3 member.
grcli nexthop del 201
group_member_count_is 20 0 || fail "last L2 member deletion did not empty group"

grcli nexthop add l3 iface p0 address 192.0.2.1 id 202
if grcli nexthop add group id 20 member 202; then
	fail "empty L2 group changed forwarding class to L3"
fi
group_member_count_is 20 0 || fail "rejected class change modified L2 group"

grcli nexthop add l2 vtep 172.16.0.3 vrf main id 203
grcli nexthop add group id 20 member 203
group_only_member_is 20 203 || fail "empty L2 group did not accept an L2 replacement"

# Nested groups are invalid regardless of create ordering.
if grcli nexthop add group id 21 member 20; then
	fail "nested L2 nexthop group was accepted"
fi

# Deleting the group before its final member must leave the member valid and
# permit clean ID reuse without stale group state.
grcli nexthop del 20
grcli -j nexthop show id 203 | jq -e \
	'.type == "L2" and .vtep == "172.16.0.3"' >/dev/null ||
	fail "group deletion removed or corrupted its L2 member"
grcli nexthop del 203
grcli nexthop add l2 vtep 172.16.0.4 vrf main id 203
grcli -j nexthop show id 203 | jq -e \
	'.type == "L2" and .vtep == "172.16.0.4"' >/dev/null ||
	fail "L2 nexthop ID reuse retained stale state"

echo "PASS: L2 nexthop groups fail closed and survive lifecycle reordering"
