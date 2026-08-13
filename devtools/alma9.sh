#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
platform=${PLATFORM:-linux/arm64}
engine=${CONTAINER_ENGINE:-docker}
image=${ALMA9_IMAGE:-grout-alma9-dev-${platform#linux/}}
jobs=${JOBS:-4}

build_image() {
	"$engine" build \
		--platform "$platform" \
		--file "$repo/devtools/alma9/Containerfile" \
		--tag "$image" \
		"$repo"
}

if test "${1:-}" = image; then
	build_image
	exit
fi

if ! "$engine" image inspect "$image" >/dev/null 2>&1; then
	build_image
fi

case "${1:-shell}" in
build)
	shift
	set -- make -j"$jobs" "$@"
	;;
test)
	shift
	set -- sh -lc 'make -j"$JOBS" unit-tests && make -j"$JOBS" smoke-tests' "$@"
	;;
shell)
	shift
	set -- bash "$@"
	;;
esac

run_flags=--interactive
if test -t 0 && test -t 1; then
	run_flags="$run_flags --tty"
fi

exec "$engine" run --rm $run_flags \
	--platform "$platform" \
	--privileged \
	--ulimit core=-1 \
	--volume "$repo:/workspace" \
	--volume grout-alma9-ccache:/ccache \
	--workdir /workspace \
	--env JOBS="$jobs" \
	"$image" "$@"
