#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 Harrison Caldicott

set -eu

unit=${1:?systemd drop-in path is required}

assert_directive() {
	section=$1
	key=$2
	value=$3

	count=$(awk -v expected_section="$section" -v expected="$key=$value" '
		/^\[[^]]+\]$/ {
			current_section = substr($0, 2, length($0) - 2)
			next
		}
		$0 == expected && current_section == expected_section { count++ }
		END { print count + 0 }
	' "$unit")

	if [ "$count" -ne 1 ]; then
		echo "$unit: expected exactly one $key=$value in [$section]" >&2
		exit 1
	fi
}

assert_not_in_other_section() {
	section=$1
	key=$2

	if awk -v expected_section="$section" -v key="$key" '
		/^\[[^]]+\]$/ {
			current_section = substr($0, 2, length($0) - 2)
			next
		}
		index($0, key "=") == 1 && current_section != expected_section { found = 1 }
		END { exit !found }
	' "$unit"; then
		echo "$unit: $key must only appear in [$section]" >&2
		exit 1
	fi
}

assert_directive Unit Requires grout.service
assert_directive Unit After grout.service
assert_directive Unit JoinsNamespaceOf grout.service
assert_directive Service PrivateNetwork true

assert_not_in_other_section Unit Requires
assert_not_in_other_section Unit After
assert_not_in_other_section Unit JoinsNamespaceOf
assert_not_in_other_section Service PrivateNetwork
