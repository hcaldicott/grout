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
    'sources': files('bridge_port_test.c', 'bridge_port.c'),
    'link_args': [
      '-Wl,--wrap=iface_from_id',
      '-Wl,--wrap=rte_free',
      '-Wl,--wrap=rte_rcu_qsbr_synchronize',
      '-Wl,--wrap=rte_zmalloc',
    ],
  }
]
