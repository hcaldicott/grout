# EVPN multihoming development plan

The active unresolved engineering backlog is maintained in
`docs/evpn-mh-remaining-gaps.md`. Use that document to select and close work;
use this document as the implementation plan and evidence record.

## Objective

Build an all-active, DPDK-accelerated EVPN multihoming dataplane for four
switchless hosts. A carrier presents one 802.3ad LAG with one 10 Gb/s member on
each of two hosts. A VM attached to the carrier bridge may run on any of the
four hosts and use up to 20 Gb/s of aggregate bandwidth across multiple
flows. A single flow remains limited to one LAG member by the carrier's hash.

FRR owns BGP EVPN, Ethernet Segment state, Designated Forwarder election and
route signalling. Grout owns LACP, VXLAN, bridging and packet forwarding. The
carrier-facing ports remain bound to DPDK for the complete datapath.

## Evidence collected

The initial three-node functional lab uses three independent Grout and FRR
instances, Linux network namespaces for isolation, TAP-backed DPDK ports and a
Linux bridge as the underlay. It is sufficient for control-plane and functional
dataplane development; it does not represent physical NIC performance.

| Capability | Result | Evidence |
| --- | --- | --- |
| AlmaLinux 9.8 build | Pass | Grout, bundled DPDK and FRR 10.6.1 build for the AlmaLinux 9.8 target. |
| Unit suite | Pass | All 12 Meson unit tests pass, including RSS/software flow-hash and bridge-port policy coverage. |
| Three-node BGP EVPN | Pass | All peers establish and exchange EVPN routes. |
| Three-node VXLAN bridge | Pass | Host traffic crosses node 1 to node 3 in both directions. |
| Split-chassis carrier LACP | Pass | A Linux carrier bond selects both Grout links in one aggregator when both chassis advertise the same LACP system MAC. |
| Local Ethernet Segment | Pass | FRR reports the local ES up, bridge-port capable and ready for BGP. |
| EVPN Type-4 route | Pass | The Ethernet Segment route is exchanged between PEs. |
| ES-to-VNI association | Prototype | Synthetic bridge VLAN metadata gives FRR the VLAN/VNI relationship absent from Grout's VLAN-abstracted bridge model. |
| EVPN Type-1 routes | Pass with FRR prototype | Both PEs advertise per-ES and per-EVI routes; the remote PE receives all four paths without a zebra crash. |
| FRR L2 NH/NHG handoff | Prototype pass | The provider installs FRR's typed L2 VTEPs and two-member MAC-ECMP group in Grout. |
| Datapath/NHG concurrency | Pass | Nexthop ID hashing is concurrent-reader/writer safe; live group replacements publish an immutable state and pass traffic-churn smoke coverage. |
| IPv4 fragment affinity | Pass | DF-only packets use L4 ports; first and later fragments share the L3-only hash. |
| MAC ECMP | Prototype pass | The remote carrier MAC references an L2 NHG; 64 UDP flows use both remote PEs and retain connectivity when one member is withdrawn. |
| IPv6 EVPN-MH | Prototype pass | Three IPv6 BGP/VXLAN endpoints exchange Type-1/Type-4 routes; IPv6 guest traffic crosses the carrier ES and 64 flows use both IPv6 VTEPs. |
| DF and split-horizon enforcement | Prototype pass | The provider consumes `DPLANE_OP_BR_PORT_UPDATE`; Grout atomically applies non-DF, backup-NHG and peer-VTEP state. BUM DF gating, a live DF preference change, peer-VTEP filtering and local-bias redirect pass in the three-node lab. |
| L2 NH/NHG lifecycle | Smoke pass | Missing dependencies fail closed; forced member deletion preserves a typed group; nested/class-changing updates are rejected; delete/recreate and ID reuse complete cleanly. |
| Bridge-port ordering | Unit and restart pass | Policy can arrive before bridge readiness, becomes active on interface reconciliation and is replayed after a carrier-facing FRR stack restart. |
| Uplink tracking/protodown | Prototype pass | FRR `DPLANE_OP_INTF_UPDATE` drives explicit Grout LACP-member protodown. Ordinary ingress and egress are suppressed, LACP remains live, remote NHGs withdraw, and both the carrier member and NHG recover in the three-node lab. |
| Startup MAC reconciliation | Prototype pass | FRR now flushes interface-linked local MACs when an ES is attached or detached. The lab deliberately learns the carrier MAC before ES configuration, verifies the stale entry is removed, and then obtains the two-member remote MAC NHG without static FDB entries. |
| FRR provider failure result | Prototype pass | The lab covers typed-ID rejection plus a one-shot provider timeout during replay. Partial state fails closed, Zebra reports the error, and a clean replay restores the complete FDB/NHG graph. |
| FRR daemon/stack restart | Prototype pass | bgpd-only, Zebra-triggered dependency restart, and full stop/start on remote and carrier-facing PEs restore EVPN peers, provider subscription, FDB/NHG state, bridge policy and reachability. |
| Live migration | Untested | Requires the completed all-active dataplane and a migration-compatible VM attachment, normally vhost-user rather than a directly assigned VF. |

FRR 10.6.1 already calculates the EVPN-MH control-plane state. The bundled
prototype closes a narrow but important FRR gap: `zebra_evpn_mh.c` normally calls
`kernel_upd_mac_nh()`, `kernel_del_mac_nh()`, `kernel_upd_mac_nhg()` and
`kernel_del_mac_nhg()` directly for L2 nexthops and groups. The patch queues
those objects through the dataplane abstraction while retaining Linux
`NHA_FDB` encoding.

## Development phases

### 0. Reproducible development environment

Status: complete.

Keep the unit suite, three-node EVPN smoke test and split-chassis LACP probe
green. Validate release candidates through the OBS AlmaLinux 9 staging build
before SE350 testing.

Acceptance criteria:

- A clean OBS staging build succeeds for the AlmaLinux 9.8 x86_64 target.
- Existing unit tests pass.
- The three-node non-MH EVPN test passes in both directions.
- The carrier simulator selects both split-chassis LACP members.

### 1. Bridge-domain metadata for FRR

Status: prototype tested, implementation incomplete.

Present each VLAN-abstracted Grout bridge domain to FRR as a VLAN-aware bridge
with one synthetic access VLAN. Report that VLAN on its VXLAN and bridge-member
interfaces, and translate it back to VLAN 0 at the Grout FDB API boundary.
Use one constant synthetic VLAN per bridge namespace rather than deriving a
VLAN from the Grout interface ID, which may exceed 4094.

Acceptance criteria:

- Adding, changing and deleting a bridge member updates FRR's VLAN bitmap.
- A local ES reports the expected VNI and ES-EVI.
- Type-1 per-ES and per-EVI routes are advertised.
- Ordinary EVPN MAC learning and traffic continue to pass.

### 2. Route EVPN L2 nexthops through the FRR dataplane API

Status: prototype tested; upstream-quality tests and review required.

Patch FRR so L2 FDB nexthop and MAC-ECMP group install/delete operations are
queued to dataplane providers instead of calling netlink directly. Preserve
the Linux provider behaviour, including `NHA_FDB`, and expose the L2 nexthop
ID, VTEP address and group members to non-kernel providers.

The working prototype reuses ordinary `DPLANE_OP_NH_*`, preserves FRR's
L2-typed IDs, and adds `NHA_FDB` in the Linux encoder. It deliberately avoids a
Grout-only callback inside FRR. Before proposing it upstream, add focused FRR
tests for IPv4 and IPv6 VTEPs, groups, deletes and the Linux netlink encoding.
The Grout integration harness now covers rejected typed-L2 install/delete
results and a timed-out L2 install during partial replay. An FRR-native
mock-provider topotest and superseded-operation coverage remain.

Acceptance criteria:

- The existing FRR Linux EVPN-MH topotests remain green.
- A provider-level test observes L2 NH and NHG add/delete contexts.
- The three-node Grout probe receives Type-1 and Type-4 routes without a zebra
  crash or a kernel netlink call.
- Provider failures are reported cleanly and do not corrupt ES state.

### 3. Add Grout L2 nexthop groups and MAC ECMP

Status: prototype tested; direct lifecycle smoke coverage passes, while
concurrent FDB/NHG stress and review remain.

Extend the Grout L2 API and control-plane model so an external FDB entry can
refer either to one interface/VTEP or to an L2 nexthop group. Add group members
that resolve to VXLAN VTEPs, manage their lifetime through RCU-safe updates and
select a member using a stable packet-flow hash in the bridge datapath.

The working implementation adds a dedicated L2-VTEP nexthop type, reuses the
existing RCU-safe weighted group representation, adds an optional NHG ID to
external FDB entries and resolves the current group by ID in the bridge
datapath. Hardware RSS is used when present. TAP and other devices without RSS
use the same software L3/L4 Toeplitz fallback as Grout bonds. A Grout-owned
dynamic mbuf field now carries that canonical flow identity through EVPN NHG,
VXLAN, underlay ECMP and RSS-mode LACP selection without forging NIC RSS
metadata. VXLAN decapsulation rebases canonical metadata on the exposed inner
frame. Resolving by ID avoids a stale FDB pointer if FRR deletes and recreates
a group during convergence.

FRR deletes are type/origin-conditional inside the Grout API. If an L2 install
was rejected because its ID belongs to another object, the later withdrawal
cannot delete that conflicting object by ID alone.

Acceptance criteria:

- Unit tests cover stable per-flow hashing, distinct UDP flows, hardware RSS
  import, software fallback ownership, reset/reuse and VXLAN decapsulation;
  direct smoke covers flood-copy affinity, missing members, member/group
  deletion order, type preservation and ID reuse.
- A remote all-active MAC is installed against an L2 NHG, not one arbitrary
  VTEP.
- Multiple flows use both remote PEs while packets from one flow remain
  ordered.
- Removing one PE causes surviving flows to continue without stale FDB or NHG
  references.

### 4. Enforce DF state and split horizon

Status: prototype tested; bridge-policy unit, dataplane and restart coverage
pass, while longer repeated stress and upstream-quality tests remain.

Implement `DPLANE_OP_BR_PORT_UPDATE` in the Grout FRR provider and corresponding
Grout APIs. Apply non-DF filtering for BUM traffic, the backup NHG reference and
the peer-VTEP split-horizon filter in the accelerated bridge/VXLAN graph.

The working implementation replaces each bridge-member policy atomically under
QSBR, exposes the installed state through `grcli bridge-port show`, suppresses
overlay BUM on a non-DF port, and blocks both unicast and BUM received from an
ES peer VTEP. It also redirects a local-ES hairpin through FRR's backup L2 NHG.
The lab verifies that only the elected DF emits carrier-facing BUM, changes the
DF with `es-df-pref`, and proves the peer-VTEP filter with directly injected
VXLAN traffic. It also teaches a MAC on a local ES and verifies that a hairpin
frame is redirected through the backup NHG. Carrier-facing FRR restart replays
the complete policy, and removing the ES deletes both active and pending policy
without disturbing LACP. Interface/bridge deletion-first ordering remains.

Acceptance criteria:

- Exactly the elected DF forwards BUM traffic toward the carrier segment.
- Traffic received from an ES is not reflected to the same ES through a remote
  PE.
- DF changes converge without duplicate persistent forwarding or a loop.
- Local-bias and all-active aliasing tests pass with two PEs and one remote PE.

### 5. Uplink tracking and failure convergence

Status: prototype tested; repeated protodown, daemon-specific restart and full
FRR-stack restart coverage pass. Release-duration storms, convergence metrics
and physical-carrier stress remain.

Implement the interface-state part of `DPLANE_OP_INTF_UPDATE` needed by FRR
EVPN-MH. Map protodown and uplink state to Grout bond forwarding state without
disrupting LACP control packets required for recovery.

Local FDB reconciliation is now prototyped. FRR flushes both ES-linked MACs and
ordinary local MACs linked to the access interface when the ES is attached or
detached. The dataplane relearns those MACs with the current ESI instead of
retaining a stale non-ESI Type-2 route.

Protodown is implemented as LACP member suppression, not as ordinary interface
administrative-down. FRR applies `DPLANE_OP_INTF_UPDATE` to the physical bond
member. Grout keeps the member physically up and continues receiving and
transmitting LACP PDUs while clearing synchronized, collecting and distributing
state, removing the member from the transmit hash and rejecting ordinary
ingress data. Clearing protodown restarts LACP negotiation; the member returns
to the hash only after the peer again advertises synchronized and collecting.

The split-LACP smoke test exercises the API directly and verifies ordinary
ingress suppression through the FDB, fail-closed egress through the
`bond_no_member` graph edge, continued LACP transmission and complete recovery.
The three-node smoke test then lowers PE1's configured EVPN-MH uplink without
lowering its carrier port. It observes FRR-driven protodown, carrier LACP
withdrawal, remote two-to-one NHG convergence, uninterrupted traffic through
PE2 and automatic restoration. A separate physical carrier-member failure and
recovery passes the same remote-NHG and traffic checks.

Acceptance criteria:

- Underlay loss withdraws or de-preferences the affected ES path.
- Carrier-link loss removes one LACP member and triggers the correct EVPN mass
  withdrawal.
- Grout or FRR restart resynchronizes state without a forwarding loop.
- Failure and recovery are tested at each PE and on the inter-host underlay.

### 6. VM attachment and migration

Status: pending the functional dataplane.

Attach 6WIND/QEMU VMs to the same logical bridge on every host using a
DPDK-accelerated, migration-compatible interface. Validate vhost-user socket
reconnection and identical queue, MTU, MAC and feature negotiation on source
and destination. Direct X710 VF assignment remains a separate path unless the
chosen QEMU, NIC firmware and orchestration stack demonstrably support
migratable SR-IOV.

Acceptance criteria:

- A VM reaches the carrier from each of the four hosts without reconfiguration.
- Live migration preserves established representative TCP and UDP traffic.
- MAC mobility converges without a duplicate-MAC loop.
- Loss and packet reordering are measured during pre-copy, switchover and
  post-copy recovery; “seamless” receives an explicit numerical target.

### 7. x86 hardware and performance qualification

Status: requires SE350/X710 access.

Repeat the suite on AlmaLinux 9.8 x86_64 with the X710 ports bound to the DPDK
driver. Pin queues, workers, memory and VM vCPUs to the correct NUMA node, then
test throughput and failure behaviour with physical LACP handoffs.

Acceptance criteria:

- Carrier interoperability is validated against at least one real handoff or
  a standards-compliant hardware peer.
- Aggregate bidirectional traffic approaches the two-port line-rate target for
  a realistic multi-flow packet-size mix.
- Per-core utilisation, drops, latency and jitter are recorded.
- Link, host, FRR and Grout failure matrices pass without loops.

### 8. OpenNebula integration

Status: pending stable host networking.

Package the Grout/FRR configuration, expose an idempotent host-network setup
interface and add the OpenNebula virtual-network and VM lifecycle hooks needed
to create vhost-user endpoints on every eligible host. Schedule migration only
between hosts with matching bridge, queue and CPU compatibility.

Acceptance criteria:

- Deployment and rollback are repeatable on a clean AlmaLinux host.
- VM create, stop, restart and migration leave no stale sockets or FDB state.
- Host maintenance mode evacuates VMs while carrier forwarding remains live.
- Configuration drift is detected before scheduling or migration.

## Test environments

Docker network namespaces remain the primary environment through phases 1-5.
They can generate LACP, BGP EVPN, VXLAN, host traffic, link failures and daemon
restarts entirely on one development machine. GNS3 is useful later for vendor
images, unusual carrier LACP behaviour and topology demonstrations, but it is
not required to implement the current gaps. Physical SE350/X710 systems are
required for VFIO/IOMMU, queue scaling, NUMA, live-migration timing and line-rate
qualification.

## Immediate work queue

1. Extend the passing L2 lifecycle smoke coverage with FDB/NHG concurrent
   replacement and sanitizer stress.
2. Add FRR-native tests for typed L2 NH/NHG add/replace/delete, delete-failure
   results and Linux netlink encoding, then prepare the patch for upstream
   review. The Grout integration harness already covers rejected installs.
3. Add bridge-port restart and delete-ordering smoke tests, then prepare the API
   and dataplane changes for upstream review.
4. Harden the protodown prototype with repeated failure loops and provider/API
   unit coverage suitable for upstream review.
5. Add a namespace-aware FRR phased-restart wrapper, then extend convergence
   through carrier-link, underlay and daemon restart cases before beginning the
   VM migration phase.
6. Add synthetic bridge-VLAN add/update/delete tests and complete bounded
   allocation beyond the current fail-closed single synthetic VLAN.

HASH-001 and META-001 are complete. Ethernet-framed EVPN, VXLAN and RSS-mode
bond paths use the canonical Ethernet getter; IPv4/IPv6 route, policy, tunnel
and local ICMP paths use explicit L3-safe lookup or canonical seeding.
