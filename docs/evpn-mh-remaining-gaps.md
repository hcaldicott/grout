# EVPN multihoming remaining-gaps backlog

## Purpose

This document is the active engineering backlog for the switchless SE350 EVPN
multihoming project. It records work that remains after the initial Grout and
FRR prototype and the August 2026 datapath safety review.

The target deployment is four Lenovo SE350 hosts running Grout and FRR. A
carrier presents an 802.3ad LAG with one 10 Gb/s member on each of two hosts.
A 6WIND VM may run on any of the four hosts and must retain Layer-2 access to
the carrier service, including across live migration. Carrier-facing ports,
inter-host links and VM attachment should remain in a DPDK-accelerated
datapath.

This backlog complements:

- `docs/se350-switchless-evpn-mh-product-spec.md`, which defines the product;
- `docs/evpn-mh-development.md`, which records implementation evidence and the
  development phases.

## Status definitions

- **Open**: no complete implementation exists.
- **Prototype**: the main behavior exists but lacks production hardening or
  sufficient test coverage.
- **Constrained**: safe for the documented single-purpose configuration, but
  not a general implementation.
- **Blocked by lab**: implementation can proceed only so far without physical
  hardware or the target orchestration environment.
- **Complete**: implemented with proportionate automated coverage.

## Priority summary

| ID | Gap | Priority | Status | Production impact |
| --- | --- | --- | --- | --- |
| HASH-001 | Grout-owned canonical flow-hash metadata | P0 | Complete | Removes misuse of NIC RSS metadata and guarantees one flow decision across EVPN, VXLAN, underlay ECMP and LACP. |
| LIFE-001 | L2 NH/NHG lifecycle and failure injection | P0 | Prototype with timeout/partial-replay smoke coverage | Ordering/type invariants, rejection, timeout, fail-closed partial state and repair pass; sanitizer and broader concurrent replacement stress remain. |
| RESTART-001 | FRR/Zebra/Grout restart reconciliation | P0 | Prototype with daemon and stack-restart coverage | bgpd-only, Zebra dependency restart, and both full-stack replay cases pass; Grout restart and release-duration storms remain. |
| FRR-001 | Upstream FRR dataplane abstraction changes | P0 | Prototype | The project carries an FRR 10.6.1 fork and rebase burden. |
| MIG-001 | Migration-compatible VM attachment | P0 | Open | Seamless migration cannot be claimed until vhost-user reconnect and switchover are validated. |
| VLAN-001 | General bridge-domain/VLAN representation | P1 | Constrained | The current single synthetic VLAN is safe but cannot represent general tagged services. |
| META-001 | Audit direct `m->hash.rss` consumers | P1 | Complete | L3-framed consumers use the canonical getter and local producers seed Grout-owned metadata. |
| PROTO-001 | Repeated protodown and LACP failure cycles | P1 | Prototype | Long-running convergence and stale-state behavior remain unqualified. |
| PERF-001 | X710/SE350 line-rate and NUMA qualification | P0 before release | Blocked by lab | Functional simulation cannot establish 10/20 Gb/s throughput or loss characteristics. |
| OPER-001 | AlmaLinux/OpenNebula packaging and lifecycle | P1 | Open | The prototype is not yet an installable, supportable edge product. |

## Workstream 1: canonical flow-hash metadata

### HASH-001: separate Grout flow identity from hardware RSS metadata

**Status:** Complete

**Priority:** P0

**Origin:** EVPN-MH implementation review

The implementation uses DPDK dynamic mbuf metadata rather than treating a
software value as NIC RSS output. Upstream review should confirm whether this
metadata remains a dynamic field/flag or moves into Grout's fixed private area,
but the packet-lifetime and ownership contracts are now explicit.

#### Problem

Upstream Grout uses `m->hash.rss` when a NIC has supplied
`RTE_MBUF_F_RX_RSS_HASH`. It also has existing datapath consumers that read
`m->hash.rss` during VXLAN and route processing. Grout did not have an
application-owned, persistent flow-hash abstraction for packets arriving from
TAP, vhost-user or other devices without hardware RSS.

The EVPN-MH prototype introduced software fallback hashing so that one tenant
flow selects a stable remote VTEP. To make downstream VXLAN and bond processing
consume that same value, `bridge_input.c` wrote the software value to
`m->hash.rss` and set `RTE_MBUF_F_RX_RSS_HASH`.

That behavior was functional but semantically wrong: the DPDK flag means that
the RX device supplied a valid RSS result. Software forwarding code should not
forge an RX offload result.

The bug also affected VXLAN traffic that did not traverse an EVPN NHG.
`rte_pktmbuf_reset()` clears RSS validity but does not clear `m->hash.rss`, and
`vxlan_output.c` previously read the field unconditionally. Static-VTEP
unicast and bridge-flood traffic from TAP, vhost-user or another software-only
ingress could therefore select its VXLAN source port and underlay ECMP path
using stale metadata from an earlier use of the mbuf.

#### Implemented design

Grout registers a DPDK mbuf dynamic field containing a 32-bit canonical flow
hash and a Grout-owned dynamic flag indicating validity.

The canonical hash represents the original tenant flow. It must remain stable
through bridge forwarding, EVPN NHG selection, VXLAN encapsulation, underlay
ECMP and LACP member selection.

The API is:

```c
bool gr_mbuf_flow_hash_is_valid(const struct rte_mbuf *m);
uint32_t gr_mbuf_flow_hash_get(struct rte_mbuf *m);
uint32_t gr_mbuf_flow_hash_get_l3(struct rte_mbuf *m, rte_be16_t eth_type);
void gr_mbuf_flow_hash_set(struct rte_mbuf *m, uint32_t hash);
void gr_mbuf_flow_hash_invalidate(struct rte_mbuf *m);
```

`gr_mbuf_flow_hash_get()` must:

1. return the Grout dynamic field when already valid;
2. otherwise import a genuine NIC RSS result when
   `RTE_MBUF_F_RX_RSS_HASH` is set;
3. otherwise calculate the software Toeplitz hash over the tenant packet;
4. cache the result in the Grout field and set only the Grout validity flag;
5. never set or clear `RTE_MBUF_F_RX_RSS_HASH` merely because software
   calculated a value.

The Ethernet getter and stateless calculator require `mtod` to point at an
Ethernet frame. The separate L3 getter requires `mtod` to point at the IPv4 or
IPv6 header identified by its EtherType argument.

After VXLAN decapsulation, an RX RSS result is treated as outer-scoped even
though Grout requests innermost RSS: PMD support is not universal. Immediately
after exposing the inner Ethernet frame, `vxlan_input.c` recalculates and sets
canonical metadata when hardware RSS is present, without changing the
hardware field or flag. When hardware RSS is absent, it invalidates canonical
metadata so a later consumer calculates it lazily from the inner frame.

DPDK dynamic metadata is preferred over enlarging or repurposing Grout's fixed
mbuf private area because DPDK copies dynamic fields during mbuf copy/clone
operations and resets the associated dynamic validity flag when an mbuf is
reused.

#### Migrated consumers

- EVPN L2 NHG/VTEP selection in `modules/l2/datapath/bridge_input.c`;
- VXLAN UDP source-port selection in `modules/l2/datapath/vxlan_output.c`;
- VXLAN underlay IPv4/IPv6 route lookup in the same node;
- RSS-mode LACP member selection in
  `modules/infra/datapath/bond_output.c`;

Explicit L2-only and explicit L3/L4 bond algorithms may continue to calculate
their requested hash mode independently. The canonical hash is specifically
the end-to-end flow identity used where RSS semantics are requested.

#### Correctness constraints

- A real hardware RSS value must remain intact in `m->hash.rss`.
- Software fallback must not set `RTE_MBUF_F_RX_RSS_HASH`.
- Encapsulation must not cause the canonical hash to be recalculated from the
  outer VXLAN headers.
- Decapsulation must not import an outer-tunnel RSS value as tenant-flow
  identity.
- Packet copies and bridge-flood copies must retain canonical metadata.
- Freshly allocated or recycled mbufs must not inherit valid stale metadata.
- First and subsequent IPv4 fragments of one datagram must retain the same
  flow hash.
- The hot path must not allocate memory or take a lock per packet.

#### Acceptance tests

- Unit test: genuine hardware RSS is imported and returned unchanged.
- Unit test: software fallback leaves NIC RSS fields and flags unchanged.
- Unit test: two distinct L4 flows normally produce distinct fallback hashes.
- Unit test: first and later IPv4 fragments produce the same hash.
- Unit test: mbuf reset/reuse clears canonical validity.
- Unit test: VXLAN decapsulation quarantines an outer RSS result and reseeds
  canonical metadata from the inner frame.
- Smoke test: software-ingress bridge-flood copies use the intended VTEPs and
  retain one canonical VXLAN source port.
- Datapath test: EVPN NHG, VXLAN source port, underlay ECMP and LACP consume the
  same canonical value.
- Regression: all existing unit and three-node EVPN-MH/LACP tests remain green.

Validation completed with all Meson tests, the IPv4 and IPv6 static VXLAN
smokes, the EVPN-MH/LACP smokes and the software-ingress flood-copy affinity
assertion passing.

#### Completion condition

No software path writes a generated value into `m->hash.rss` or sets
`RTE_MBUF_F_RX_RSS_HASH`. Hardware RSS remains imported only through the
canonical flow-hash abstraction.

### META-001: audit existing direct RSS consumers

**Status:** Complete

**Priority:** P1

The audit classified all direct reads of `m->hash.rss` as:

1. hardware-RSS-only by design;
2. should consume the Grout canonical flow hash;
3. should calculate a specific L2 or L3/L4 hash;
4. locally generated traffic that must explicitly seed canonical metadata.

The resulting `gr_mbuf_flow_hash_get_l3()` API has the same cache and genuine
hardware-RSS import precedence as the Ethernet getter, but calculates its
software fallback from an explicitly identified IPv4 or IPv6 header at
`mtod`. IPv4/IPv6 input and ICMP output, policy/NAT, IP-in-IP and SRv6 now use
that API. Nodes that transform or prepend headers acquire the canonical hash
while the original L3 header is still exposed, preserving the tenant-flow
identity across the transformation.

The IPv4/IPv6 local ping generators seed the canonical field with their
identifier to retain ECMP and active/active bond distribution without writing
NIC-owned RSS metadata or setting `RTE_MBUF_F_RX_RSS_HASH`.

There are no direct RSS-field consumers or software RSS-flag producers outside
the canonical flow-hash implementation and its tests. The full build and all
Meson tests pass, as do the IPv4/IPv6 local ICMP, forwarding, load-balancing,
DNAT and IP-in-IP smokes. The SRv6 smoke cannot run in the current container
because its kernel rejects the Linux `seg6local` fixture before traffic reaches
Grout; the affected Grout SRv6 module builds successfully.

## Workstream 2: bridge-domain representation

### VLAN-001: replace the single synthetic VLAN constraint

**Status:** Constrained

**Priority:** P1 for the current untagged product; P0 if tagged carrier
services enter scope

#### Current behavior

FRR requires VLAN/VNI metadata for EVPN-MH ES-to-EVI association, while Grout's
bridge model is VLAN-abstracted. The prototype presents every applicable
bridge to FRR using one synthetic VLAN and translates that representation back
to Grout's untagged bridge domain. Grout's numeric key 0 is internal provider
metadata; it does not request or emit an IEEE 802.1Q VLAN ID 0 priority tag on
a fabric or carrier port.

Unsupported tagged state now fails visibly instead of silently collapsing into
the internal untagged-domain key 0. This makes the current untagged product
safe, but it is not general per-VLAN bridging.

#### Remaining work

- Define whether product scope requires multiple tagged carrier services on a
  single bridge or physical handoff.
- If not required, retain the constraint and add explicit configuration/API
  validation plus operator documentation.
- If required, allocate synthetic VLAN identifiers per bridge domain within
  the valid 1-4094 range, persist the mapping, and reconcile it across restart.
- Test bridge/VXLAN/member add, update, delete and replay ordering.
- Ensure no FRR MAC, ES-EVI or FDB operation can address the wrong bridge
  domain after identifier reuse.

#### Acceptance tests

- Unsupported configurations are rejected before traffic is admitted.
- Two bridge domains cannot alias to the same FRR VLAN identity.
- Mapping survives configuration replay and daemon restart.
- Add/delete/recreate does not leave stale MAC or ES-EVI state.
- If multi-VLAN is implemented, tagged traffic remains isolated end-to-end.

## Workstream 3: L2 nexthop lifecycle and type safety

### LIFE-001: adversarial L2 NH/NHG lifecycle coverage

**Status:** Prototype

**Priority:** P0

The reported mixed L2/L3 group vulnerability is fixed: Grout rejects nested or
mixed groups and rejects invalid group use by IP routes and the FDB. Group
state is published atomically and old state is reclaimed after datapath QSBR.

What remains is failure-oriented coverage of the full FRR-to-Grout lifecycle:

- member-before-group and group-before-member creation;
- delete member before group and delete group before FDB reference;
- replace a two-member group while traffic is active;
- provider rejection, timeout and partial replay;
- missing referenced NH/NHG during convergence;
- ID reuse after deletion;
- repeated remote VTEP withdrawal and restoration;
- concurrent FDB replacement and NHG replacement.

The direct Grout smoke test now covers missing members, two-member L2 group
creation, forced first/last member deletion, preservation of the empty group's
L2 forwarding class, rejection of L3 repopulation, L2 repopulation, nested
group rejection, group-before-member deletion and clean ID reuse. The
three-node test additionally removes both all-active PEs until the remote FDB
entry disappears, restores them and verifies recreation of a two-member NHG
under live traffic.

The same harness can now reserve FRR's first typed L2 NH/NHG IDs as existing L3
objects. This forces Grout to reject the provider update on a forwarding-class
mismatch. Zebra reports asynchronous install and delete failures, remains
responsive with both EVPN peers established, and does not replace, corrupt or
delete the existing objects. FRR uses atomic type/origin-conditional deletes so
a rejected install cannot later remove the conflicting object's owner. The
harness also injects a one-shot `ETIMEDOUT` during Zebra replay, verifies that
unresolved FDB/NHG state is fail-closed, and proves a subsequent clean replay
repairs the two-member graph without static entries.

#### Acceptance tests

- Invalid or incomplete state fails closed without a stale pointer or crash.
- Traffic either uses the old complete state or the new complete state; it
  never observes a partially constructed group.
- Provider errors are reported to FRR and appear in actionable logs.
- Reconciliation restores the intended FDB/NHG graph without static entries.
- Sanitizer or equivalent stress runs detect no lifetime error.

## Workstream 4: FRR integration and ownership

### FRR-001: upstream the non-kernel EVPN-MH dataplane path

**Status:** Prototype

**Priority:** P0

The FRR 10.6.1 patches fix a genuine abstraction problem: EVPN-MH L2
nexthops/groups bypassed the generic dataplane queue and called Linux netlink
helpers directly. The fork now routes typed L2 objects through the dataplane
provider while preserving Linux `NHA_FDB` behavior.

The implementation also has explicit typed-L2 completion handling. The
successful path and rejected install/delete results are covered by the
three-node lab, but the changes are not upstream and remain a high-maintenance
fork surface.

#### Remaining work

- Add focused FRR provider/topotests for IPv4 and IPv6 VTEPs, group
  add/replace/delete, Linux netlink encoding and provider failure results.
- Verify the remaining typed-L2 completion cases, especially transport
  timeouts and superseded operations.
- Separate generally useful FRR fixes from Grout-specific provider work.
- Submit the generic dataplane fix upstream and respond to review.
- Document the supported FRR version and establish a rebase test for each FRR
  upgrade until the changes are accepted upstream.
- Decide who owns the fork if upstream declines the change.

#### Acceptance tests

- Existing upstream Linux EVPN-MH topotests remain green.
- A non-kernel test provider observes typed L2 NH/NHG operations.
- Failed provider results do not crash Zebra, falsely mark objects installed,
  or leave silent stale state.
- The maintained patch series applies automatically to the supported FRR
  release in CI.

## Workstream 5: reconciliation and restart

### RESTART-001: make daemon restart a gating scenario

**Status:** Prototype tested; release qualification remains

**Priority:** P0

Bridge-port policy arriving before interface bridge readiness is now handled:
desired policy is retained, activated when the interface becomes ready,
deactivated while detached and cleared on removal. An empty FRR update deletes
both active and desired state, including policy queued before interface
readiness. Unit tests cover these ordering and non-resurrection rules.

The three-node harness persists configuration and uses namespace-aware
WatchFRR process control to crash and respawn individual daemons. It exercises
bgpd-only restart and a Zebra-initiated dependency restart, requiring live
FDB-to-NHG reconstruction and carrier reachability after each case.

It also fully restarts FRR on both the remote
VM-facing PE and a carrier-facing PE. It verifies provider resubscription, BGP
EVPN peer recovery, remote L2 NHG state, carrier bridge-port policy, LACP state
and end-to-end reachability. It also removes the ES on both carrier PEs and
verifies that policy disappears while LACP remains synchronized.

#### Remaining work

- Exercise Grout restart and process-loss ordering.
- Add interface/bridge deletion-first, ES recreate and replay-order smoke tests.
- Verify FDB, L2 NH/NHG, DF policy, split-horizon filters and protodown state
  reconcile in dependency order.
- Promote the 10-cycle development storm to at least 50 cycles for release
  qualification.
- Measure packet loss, duplicate delivery and convergence time during each
  restart class.

#### Acceptance tests

- No forwarding loop or persistent blackhole after supported daemon restart.
- No static FDB workaround is required.
- Stale state is either retained safely during a graceful window or removed
  deterministically.
- FRR and Grout converge to the same intended state after replay.
- Failures produce an explicit health signal suitable for orchestration.

## Workstream 6: LACP and failure convergence

### PROTO-001: harden protodown and split-chassis LACP behavior

**Status:** Prototype

**Priority:** P1

The prototype keeps LACP control traffic alive while suppressing ordinary
traffic on a protodown member. The three-node lab verifies withdrawal and
recovery, but repeated and compound failure behavior remains unqualified.

The focused LACP test now performs three additional protodown/recovery cycles
by default. The three-node test performs repeated uplink-triggered withdrawals
and a complete two-PE withdrawal/recreation while checking the surviving path
and remote NHG state. Longer stress runs and physical-carrier coverage remain.

#### Remaining work

- Repeat carrier-member protodown/up cycles under sustained traffic.
- Combine carrier failure with underlay failure, remote PE failure and FRR
  restart.
- Verify aggregator identity, actor/partner synchronization and member
  restoration after every cycle.
- Add provider/API unit coverage for protodown transitions and invalid input.
- Measure duplication, loss and reordering during convergence.
- Test carrier implementations in GNS3 where an appropriate vendor image is
  available, then against the real carrier handoff.

## Workstream 7: migration-compatible VM dataplane

### MIG-001: implement and qualify vhost-user attachment

**Status:** Open

**Priority:** P0 for the product objective

SR-IOV passthrough cannot provide ordinary seamless live migration because the
VM owns host-specific VF state. The intended design therefore uses a
DPDK-compatible vhost-user attachment between Grout and QEMU/6WIND while the
carrier and fabric ports remain under Grout/DPDK control.

#### Remaining work

- Select client/server socket ownership and reconnect behavior compatible with
  libvirt and OpenNebula.
- Define stable interface identity across source and destination hosts.
- Pre-create and health-check destination attachment before migration
  switchover.
- Handle guest reboot, QEMU restart, socket deletion/recreation and Grout
  restart without manual cleanup.
- Validate MAC learning/mobility signaling and withdrawal timing during
  migration.
- Determine whether 6WIND requires multiqueue, packed rings, zero-copy or
  specific virtio feature negotiation.
- Automate the attachment lifecycle through OpenNebula hooks or a supported
  integration mechanism.

#### Acceptance tests

- VM migrates among SE350-1, SE350-2, SE350-3 and SE350-4 without changing its carrier
  VLAN attachment or MAC identity.
- Existing TCP sessions survive the switchover.
- UDP loss and reordering remain within a ratified threshold.
- Destination vhost queues are ready before QEMU resumes the VM.
- Source sockets and FDB state are cleaned up after successful migration.
- A failed migration leaves the VM reachable on the source host.

## Workstream 8: physical performance and productisation

### PERF-001: qualify the real SE350/X710 datapath

**Status:** Blocked by physical lab

**Priority:** P0 before release

Docker namespaces establish functional correctness only. They cannot prove
X710 queue scaling, PCIe/NUMA placement, BiDi optics, physical LACP behavior or
near-line-rate throughput.

Required qualification includes:

- AlmaLinux 9.8 x86_64 build and package installation;
- X710 VFIO/IOMMU binding and firmware/driver compatibility;
- queue/core/NUMA placement for carrier, fabric and vhost-user ports;
- 10 Gb/s single-member throughput and approximately 20 Gb/s aggregate
  throughput across sufficiently diverse flows;
- packet-size sweep, bidirectional load, latency, jitter and loss;
- link, host, underlay and daemon failure during traffic;
- carrier LACP interoperability and hashing behavior;
- migration while traffic is near the supported throughput target.

### OPER-001: OpenNebula and AlmaLinux operational integration

**Status:** Open

**Priority:** P1

Remaining product work includes reproducible packages, configuration schema,
systemd ordering, hugepages, VFIO permissions, health checks, telemetry,
upgrade/rollback procedures and OpenNebula lifecycle hooks.

The operational implementation must not schedule or migrate a carrier VM onto
a host unless Grout, FRR, the underlay, carrier bridge domain and destination
vhost-user attachment are all healthy.

## Completed review findings

The following findings are closed and should remain regression-tested:

| Finding | Resolution |
| --- | --- |
| Concurrent datapath access to `hash_by_id` | Hash created with DPDK lock-free reader/writer support; object replacement preserves explicit IDs. |
| Non-atomic NHG mutation | Complete immutable group state is published atomically and reclaimed through QSBR. |
| IPv4 first-fragment affinity | MF and fragment offset are both checked; first and later fragments use the same L3-only hash. |
| Mixed L2/L3 groups | Mixed and nested groups and invalid route/FDB uses are rejected. |
| Silent synthetic-VLAN collapse | Unsupported tagged state fails visibly at the provider boundary. General multi-VLAN support remains VLAN-001. |
| Bridge policy lifecycle | Desired state is retained and reconciled on interface add/reconfiguration; an empty FRR update deletes active and pending policy; restart replay and ES removal pass end to end. Deletion-first and storm coverage remain RESTART-001. |
| Ambiguous FRR typed-L2 completion | Explicit completion handling was added; rejected installs and conditional deletes are logged without a Zebra crash or cross-owner object corruption. Timeout and upstream work remain FRR-001. |

## Recommended implementation order

1. **LIFE-001** — make L2 NH/NHG failure and ordering behavior deterministic.
2. **FRR-001** — add upstream-quality tests and reduce the fork surface.
3. **RESTART-001** — make reconciliation a repeatable gating test.
4. **PROTO-001** — stress LACP/protodown under compound failures.
5. **MIG-001** — implement vhost-user lifecycle and simulated migration.
6. **VLAN-001** — retain the explicit constraint or generalize based on the
   carrier service model.
7. **PERF-001 / OPER-001** — qualify physical hardware and integrate with
   OpenNebula for production rollout.

HASH-001 and META-001 are complete. Upstream review should consider the
canonical metadata and its Ethernet/L3 framing contracts together.

## Definition of production-ready

The switchless design is not production-ready until all P0 items are complete
and the following evidence exists:

- canonical flow identity is correct for hardware and software ingress;
- no known lifecycle ordering produces a stale pointer, forwarding loop or
  persistent blackhole;
- supported daemon restarts reconcile automatically;
- the FRR patch ownership and supported-version policy are explicit;
- vhost-user live migration meets an agreed loss/reordering objective;
- physical SE350/X710 testing demonstrates the required throughput and
  failure behavior;
- OpenNebula admits and migrates workloads only when the complete network path
  is healthy.
