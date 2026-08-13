#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Harrison Caldicott

set -eu

mkdir -p /dev/net
if ! test -c /dev/net/tun; then
	mknod /dev/net/tun c 10 200
fi

ulimit -c unlimited
exec "$@"
