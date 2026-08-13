# EVPN multihoming development plan

## Objective

Build an all-active, DPDK-accelerated EVPN multihoming dataplane for three
switchless hosts. A carrier presents one 802.3ad LAG with one 10 Gb/s member on
each of two hosts. A VM attached to the carrier bridge may run on any of the
three hosts and use up to 20 Gb/s of aggregate bandwidth across multiple
flows. A single flow remains limited to one LAG member by the carrier's hash.

FRR owns BGP EVPN, Ethernet Segment state, Designated Forwarder election and
route signalling. Grout owns LACP, VXLAN, bridging and packet forwarding. The
carrier-facing ports remain bound to DPDK for the complete datapath.

## Evidence collected

The initial AlmaLinux 9.8 arm64 Docker lab uses three independent Grout and FRR
instances, Linux network namespaces for isolation, TAP-backed DPDK ports and a
Linux bridge as the underlay. It is sufficient for control-plane and functional
dataplane development; it does not represent physical NIC performance.

| Capability | Result | Evidence |
| --- | --- | --- |
| AlmaLinux 9.8 build | Pass | Grout, bundled DPDK and FRR 10.6.1 build natively on arm64. |
| Unit suite | Pass | All 11 Meson unit tests pass, including RSS/software flow-hash coverage. |
| Three-node BGP EVPN | Pass | All peers establish and exchange EVPN routes. |
| Three-node VXLAN bridge | Pass | Host traffic crosses node 1 to node 3 in both directions. |
| Split-chassis carrier LACP | Pass | A Linux carrier bond selects both Grout links in one aggregator when both chassis advertise the same LACP system MAC. |
| Local Ethernet Segment | Pass | FRR reports the local ES up, bridge-port capable and ready for BGP. |
| EVPN Type-4 route | Pass | The Ethernet Segment route is exchanged between PEs. |
| ES-to-VNI association | Prototype | Synthetic bridge VLAN metadata gives FRR the VLAN/VNI relationship absent from Grout's VLAN-abstracted bridge model. |
| EVPN Type-1 routes | Pass with FRR prototype | Both PEs advertise per-ES and per-EVI routes; the remote PE receives all four paths without a zebra crash. |
| FRR L2 NH/NHG handoff | Prototype pass | The provider installs FRR's typed L2 VTEPs and two-member MAC-ECMP group in Grout. |
| MAC ECMP | Prototype pass | The remote carrier MAC references an L2 NHG; 64 UDP flows use both remote PEs and retain connectivity when one member is withdrawn. |
| DF and split-horizon enforcement | Missing | The Grout provider does not implement `DPLANE_OP_BR_PORT_UPDATE`; the bridge datapath has no non-DF gate or ES peer-VTEP filter. |
| Uplink tracking/protodown | Missing | The Grout provider does not implement the relevant `DPLANE_OP_INTF_UPDATE` state. |
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

Keep the AlmaLinux container, unit suite, three-node EVPN smoke test and
split-chassis LACP probe green. Run arm64 for fast iteration and repeat release
candidates under `linux/amd64` before SE350 testing.

Acceptance criteria:

- A clean container build succeeds without host dependencies.
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
tests for IPv4 and IPv6 VTEPs, groups, deletes, provider failure and the Linux
netlink encoding.

Acceptance criteria:

- The existing FRR Linux EVPN-MH topotests remain green.
- A provider-level test observes L2 NH and NHG add/delete contexts.
- The three-node Grout probe receives Type-1 and Type-4 routes without a zebra
  crash or a kernel netlink call.
- Provider failures are reported cleanly and do not corrupt ES state.

### 3. Add Grout L2 nexthop groups and MAC ECMP

Status: prototype tested; focused lifecycle unit coverage and review required.

Extend the Grout L2 API and control-plane model so an external FDB entry can
refer either to one interface/VTEP or to an L2 nexthop group. Add group members
that resolve to VXLAN VTEPs, manage their lifetime through RCU-safe updates and
select a member using a stable packet-flow hash in the bridge datapath.

The working implementation adds a dedicated L2-VTEP nexthop type, reuses the
existing RCU-safe weighted group representation, adds an optional NHG ID to
external FDB entries and resolves the current group by ID in the bridge
datapath. Hardware RSS is used when present. TAP and other devices without RSS
use the same software L3/L4 Toeplitz fallback as Grout bonds. Resolving by ID
avoids a stale FDB pointer if FRR deletes and recreates a group during
convergence.

Acceptance criteria:

- Unit tests cover stable per-flow hashing, distinct UDP flows and hardware RSS
  precedence; focused group deletion-order tests remain to be added.
- A remote all-active MAC is installed against an L2 NHG, not one arbitrary
  VTEP.
- Multiple flows use both remote PEs while packets from one flow remain
  ordered.
- Removing one PE causes surviving flows to continue without stale FDB or NHG
  references.

### 4. Enforce DF state and split horizon

Status: missing.

Implement `DPLANE_OP_BR_PORT_UPDATE` in the Grout FRR provider and corresponding
Grout APIs. Apply non-DF filtering for BUM traffic, the backup NHG reference and
the peer-VTEP split-horizon filter in the accelerated bridge/VXLAN graph.

Acceptance criteria:

- Exactly the elected DF forwards BUM traffic toward the carrier segment.
- Traffic received from an ES is not reflected to the same ES through a remote
  PE.
- DF changes converge without duplicate persistent forwarding or a loop.
- Local-bias and all-active aliasing tests pass with two PEs and one remote PE.

### 5. Uplink tracking and failure convergence

Status: missing.

Implement the interface-state part of `DPLANE_OP_INTF_UPDATE` needed by FRR
EVPN-MH. Map protodown and uplink state to Grout bond forwarding state without
disrupting LACP control packets required for recovery.

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

- A VM reaches the carrier from each of the three hosts without reconfiguration.
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

1. Turn the synthetic bridge-VLAN prototype into a bounded translation with
   add/update/delete tests.
2. Add FRR tests for the working L2 NH/NHG dataplane representation and prepare
   it for upstream review.
3. Add focused Grout L2 NH/NHG create, replace and deletion-order unit tests.
4. Implement the bridge-port update API and DF/split-horizon enforcement.
5. Extend failure convergence through carrier-link, underlay and daemon restart
   cases before beginning the VM migration phase.
