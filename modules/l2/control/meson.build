# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

src += files(
	'bridge.c',
	'bridge_port.c',
	'fdb.c',
  'flood.c',
  'vxlan.c',
)

inc += include_directories('.')

tests += [
  {
    'sources': files('bridge_port_test.c'),
    'link_args': [],
  }
]
