// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Harrison Caldicott

#pragma once

#include <rte_ether.h>
#include <rte_mbuf.h>

#include <stdbool.h>
#include <stdint.h>

typedef enum : uint8_t {
	GR_MBUF_FLOW_HASH_L2,
	GR_MBUF_FLOW_HASH_L3_L4,
	GR_MBUF_FLOW_HASH_RSS,
} gr_mbuf_flow_hash_mode_t;

extern int gr_mbuf_flow_hash_offset;
extern uint64_t gr_mbuf_flow_hash_flag;

// Calculate a packet-flow hash without caching it. The packet data must start
// with an Ethernet header. RSS mode uses a hardware hash when present and falls
// back to a software L3/L4 hash for virtual devices without RSS.
uint32_t gr_mbuf_flow_hash(const struct rte_mbuf *, gr_mbuf_flow_hash_mode_t);

static inline bool gr_mbuf_flow_hash_is_valid(const struct rte_mbuf *m) {
	return m->ol_flags & gr_mbuf_flow_hash_flag;
}

static inline void gr_mbuf_flow_hash_set(struct rte_mbuf *m, uint32_t hash) {
	*RTE_MBUF_DYNFIELD(m, gr_mbuf_flow_hash_offset, uint32_t *) = hash;
	m->ol_flags |= gr_mbuf_flow_hash_flag;
}

static inline void gr_mbuf_flow_hash_invalidate(struct rte_mbuf *m) {
	m->ol_flags &= ~gr_mbuf_flow_hash_flag;
}

// Return the canonical hash of the Ethernet-framed tenant flow. A genuine NIC
// RSS value is imported when available; otherwise a software L3/L4 hash is
// calculated. The result is cached in Grout-owned mbuf metadata.
uint32_t gr_mbuf_flow_hash_get(struct rte_mbuf *);

// Return the canonical hash when packet data starts with an IPv4 or IPv6
// header. eth_type must match that header. Existing canonical metadata or a
// genuine NIC RSS result still takes precedence over software calculation.
uint32_t gr_mbuf_flow_hash_get_l3(struct rte_mbuf *, rte_be16_t eth_type);

// A NIC RSS value on a decapsulated packet may describe the outer tunnel even
// when innermost RSS was requested. Rebase canonical metadata on the exposed
// inner Ethernet frame without modifying the NIC-owned RSS field or flag.
static inline void gr_mbuf_flow_hash_decap_reseed(struct rte_mbuf *m) {
	if (m->ol_flags & RTE_MBUF_F_RX_RSS_HASH)
		gr_mbuf_flow_hash_set(m, gr_mbuf_flow_hash(m, GR_MBUF_FLOW_HASH_L3_L4));
	else
		gr_mbuf_flow_hash_invalidate(m);
}
