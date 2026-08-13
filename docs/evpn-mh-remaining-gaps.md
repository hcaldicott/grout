# EVPN multihoming remaining-gaps backlog

## Purpose

This document is the active engineering backlog for the switchless SE350 EVPN
multihoming project. It records work that remains after the initial Grout and
FRR prototype and the August 2026 datapath safety review.

The target deployment is three Lenovo SE350 hosts running Grout and FRR. A
carrier presents an 802.3ad LAG with one 10 Gb/s member on each of two hosts.
A 6WIND VM may run on any of the three hosts and must retain Layer-2 access to
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
| HASH-001 | Grout-owned canonical flow-hash metadata | P0 | Deferred for architecture | Removes misuse of NIC RSS metadata and guarantees one flow decision across EVPN, VXLAN, underlay ECMP and LACP. |
| LIFE-001 | L2 NH/NHG lifecycle and failure injection | P0 | Prototype with direct smoke coverage | Core ordering and type invariants pass; FRR provider failure injection remains. |
| RESTART-001 | FRR/Zebra/Grout restart reconciliation | P0 | Prototype with stack-restart coverage | Remote and carrier-facing FRR stack replay passes; daemon-specific restart storms remain. |
| FRR-001 | Upstream FRR dataplane abstraction changes | P0 | Prototype | The project carries an FRR 10.6.1 fork and rebase burden. |
| MIG-001 | Migration-compatible VM attachment | P0 | Open | Seamless migration cannot be claimed until vhost-user reconnect and switchover are validated. |
| VLAN-001 | General bridge-domain/VLAN representation | P1 | Constrained | The current single synthetic VLAN is safe but cannot represent general tagged services. |
| META-001 | Audit direct `m->hash.rss` consumers | P1 | Open | Some existing Grout nodes assume RSS is always valid even on software-only ingress. |
| PROTO-001 | Repeated protodown and LACP failure cycles | P1 | Prototype | Long-running convergence and stale-state behavior remain unqualified. |
| PERF-001 | X710/SE350 line-rate and NUMA qualification | P0 before release | Blocked by lab | Functional simulation cannot establish 10/20 Gb/s throughput or loss characteristics. |
| OPER-001 | AlmaLinux/OpenNebula packaging and lifecycle | P1 | Open | The prototype is not yet an installable, supportable edge product. |

## Workstream 1: canonical flow-hash metadata

### HASH-001: separate Grout flow identity from hardware RSS metadata

**Status:** Deferred for architecture review

**Priority:** P0

**Origin:** EVPN-MH implementation review

The project has deliberately retained the current software-RSS shim while its
packet-metadata architecture is reviewed with upstream maintainers and other
dataplane engineers. Until that decision is made, new code must not broaden
the shim beyond its existing EVPN-MH path or treat it as a general Grout API.
The existing forwarding behavior and regression coverage remain in place.

#### Problem

Upstream Grout uses `m->hash.rss` when a NIC has supplied
`RTE_MBUF_F_RX_RSS_HASH`. It also has existing datapath consumers that read
`m->hash.rss` during VXLAN and route processing. Grout did not have an
application-owned, persistent flow-hash abstraction for packets arriving from
TAP, vhost-user or other devices without hardware RSS.

The EVPN-MH prototype introduced software fallback hashing so that one tenant
flow selects a stable remote VTEP. To make downstream VXLAN and bond processing
consume that same value, `bridge_input.c` currently writes the software value
to `m->hash.rss` and sets `RTE_MBUF_F_RX_RSS_HASH`.

That behavior is functional but semantically wrong: the DPDK flag means that
the RX device supplied a valid RSS result. Software forwarding code should not
forge an RX offload result.

#### Required design

Register a Grout-owned DPDK mbuf dynamic field containing a 32-bit canonical
flow hash and a Grout-owned dynamic flag indicating validity.

The canonical hash represents the original tenant flow. It must remain stable
through bridge forwarding, EVPN NHG selection, VXLAN encapsulation, underlay
ECMP and LACP member selection.

Provide a small API, with exact names settled during review, equivalent to:

```c
bool gr_mbuf_flow_hash_is_valid(const struct rte_mbuf *m);
uint32_t gr_mbuf_flow_hash_get(struct rte_mbuf *m);
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

DPDK dynamic metadata is preferred over enlarging or repurposing Grout's fixed
mbuf private area because DPDK copies dynamic fields during mbuf copy/clone
operations and resets the associated dynamic validity flag when an mbuf is
reused.

#### Consumers to migrate

- EVPN L2 NHG/VTEP selection in `modules/l2/datapath/bridge_input.c`;
- VXLAN UDP source-port selection in `modules/l2/datapath/vxlan_output.c`;
- VXLAN underlay IPv4/IPv6 route lookup in the same node;
- RSS-mode LACP member selection in
  `modules/infra/datapath/bond_output.c`;
- any other consumer identified by META-001 for which software fallback is
  valid.

Explicit L2-only and explicit L3/L4 bond algorithms may continue to calculate
their requested hash mode independently. The canonical hash is specifically
the end-to-end flow identity used where RSS semantics are requested.

#### Correctness constraints

- A real hardware RSS value must remain intact in `m->hash.rss`.
- Software fallback must not set `RTE_MBUF_F_RX_RSS_HASH`.
- Encapsulation must not cause the canonical hash to be recalculated from the
  outer VXLAN headers.
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
- Unit test: a copied mbuf retains valid canonical metadata.
- Unit test: mbuf reset/reuse clears canonical validity.
- Datapath test: EVPN NHG, VXLAN source port, underlay ECMP and LACP consume the
  same canonical value.
- Regression: all existing unit and three-node EVPN-MH/LACP tests remain green.

#### Completion condition

No EVPN-MH path writes a software value into `m->hash.rss`, and no code sets
`RTE_MBUF_F_RX_RSS_HASH` unless the value originated from an RX device or an
explicit DPDK-compliant producer.

### META-001: audit existing direct RSS consumers

**Status:** Open

**Priority:** P1

Search all direct reads of `m->hash.rss` and classify them as:

1. hardware-RSS-only by design;
2. should consume the Grout canonical flow hash;
3. should calculate a specific L2 or L3/L4 hash;
4. locally generated traffic that must explicitly seed canonical metadata.

The initial audit must include VXLAN, IPv4/IPv6 route lookups, policy/NAT,
IP-in-IP, SRv6 and locally generated ICMP traffic. This is partly inherited
technical debt in upstream Grout and should be proposed separately from the
narrow EVPN-MH patch if that makes upstream review easier.

## Workstream 2: bridge-domain representation

### VLAN-001: replace the single synthetic VLAN constraint

**Status:** Constrained

**Priority:** P1 for the current untagged product; P0 if tagged carrier
services enter scope

#### Current behavior

FRR requires VLAN/VNI metadata for EVPN-MH ES-to-EVI association, while Grout's
bridge model is VLAN-abstracted. The prototype presents every applicable
bridge to FRR using one synthetic VLAN and translates that representation back
to Grout's untagged bridge domain.

Unsupported tagged state now fails visibly instead of silently collapsing into
VLAN 0. This makes the current untagged product safe, but it is not general
per-VLAN bridging.

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
successful path is covered by the three-node lab, but the changes are not
upstream and remain a high-maintenance fork surface.

#### Remaining work

- Add focused FRR provider/topotests for IPv4 and IPv6 VTEPs, group
  add/replace/delete, Linux netlink encoding and provider failure results.
- Verify every typed-L2 dataplane completion result, including rejected and
  failed install/delete operations.
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

**Status:** Prototype/harness gap

**Priority:** P0

Bridge-port policy arriving before interface bridge readiness is now handled:
desired policy is retained, activated when the interface becomes ready,
deactivated while detached and cleared on removal. Unit tests cover the basic
ordering behavior.

The remaining gap is end-to-end restart and replay behavior. The current
namespace-local FRR launcher cannot reliably reproduce WatchFRR's phased
dependency restart and integrated configuration replay.

The three-node harness now persists and fully restarts FRR on both the remote
VM-facing PE and a carrier-facing PE. It verifies provider resubscription, BGP
EVPN peer recovery, remote L2 NHG state, carrier bridge-port policy, LACP state
and end-to-end reachability. This closes full-stack stop/start coverage, but
does not yet replace the daemon-specific and restart-storm work below.

#### Remaining work

- Add a namespace-aware phased FRR restart wrapper.
- Exercise Zebra-only, bgpd-only, full FRR stack and Grout restarts.
- Add bridge-port delete/recreate and replay-order smoke tests.
- Verify FDB, L2 NH/NHG, DF policy, split-horizon filters and protodown state
  reconcile in dependency order.
- Run restart storms with bounded backoff and at least 50 cycles for release
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

- VM migrates among SE350-1, SE350-2 and SE350-3 without changing its carrier
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
| Bridge policy before bridge readiness | Desired state is retained and reconciled on interface add/reconfiguration. End-to-end restart coverage remains RESTART-001. |
| Ambiguous FRR typed-L2 completion | Explicit success/failure handling was added. Failure-injection and upstream work remain FRR-001. |

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

HASH-001 and implementation changes arising from META-001 remain deferred
pending architectural review. A read-only consumer audit may continue, but it
must not expand or normalize the current software-RSS shim.

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
