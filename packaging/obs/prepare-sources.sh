#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
version=${GROUT_RPM_VERSION:-0.16.3}
dist="$repo/dist/obs"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM

# Prevent macOS bsdtar from emitting AppleDouble ._ files and provenance
# xattrs. Meson treats ._*.wrap files as package definitions on Linux.
export COPYFILE_DISABLE=1

verify_source() {
	expected=$1
	file=$2
	actual=$(sha256sum "$file" | awk '{print $1}')
	if test "$actual" != "$expected"; then
		echo "checksum mismatch: $file" >&2
		exit 1
	fi
}

dpdk="$repo/subprojects/packagecache/dpdk-25.11.2.tar.xz"
ecoli="$repo/subprojects/packagecache/libecoli-0.11.3.tar.gz"
frr="$repo/subprojects/packagecache/frr-10.6.1.tar.gz"

verify_source 418bfe3212640ee95a1cb10af6ed360cad2387686fe2721f8a3a9cd02d5ef4f2 "$dpdk"
verify_source 25ed9638452fa050749746c863574dfd47df95bde98347d210c9deedea188151 "$ecoli"
verify_source 35f2cb4328617261db687e1d4e400c7c491b41b3aa4a109d7da9ebff0cf7e402 "$frr"

mkdir -p "$dist" "$stage/grout-$version/subprojects/packagecache"
git -C "$repo" archive --format=tar HEAD | tar -xf - -C "$stage/grout-$version"
cp "$dpdk" "$ecoli" "$stage/grout-$version/subprojects/packagecache/"
# COPYFILE_DISABLE prevents AppleDouble sidecars, while --no-xattrs also keeps
# com.apple.provenance metadata out of the POSIX source archive. GNU tar in the
# AlmaLinux builder otherwise warns about every such extended header.
tar --no-xattrs -C "$stage" -czf "$dist/grout-$version.tar.gz" "grout-$version"
cp "$frr" "$dist/frr-10.6.1.tar.gz"
cp "$repo/rpm/grout.spec" "$dist/grout.spec"
cp "$repo/rpm/frr.spec" "$dist/frr.spec"
cp "$repo/subprojects/packagefiles/frr/10.5-zebra-route-IPv4-link-local-neighbor-updates-through.patch" \
	"$dist/zebra-route-IPv4-link-local-neighbor-updates-through.patch"
cp "$repo/subprojects/packagefiles/frr/10.6-zebra-route-EVPN-MH-L2-nexthops-through-dplane.patch" \
	"$dist/zebra-route-EVPN-MH-L2-nexthops-through-dplane.patch"
cp "$repo/subprojects/packagefiles/frr/10.6-zebra-reconcile-EVPN-MH-interface-MACs.patch" \
	"$dist/zebra-reconcile-EVPN-MH-interface-MACs.patch"

echo "Prepared OBS sources in $dist"
