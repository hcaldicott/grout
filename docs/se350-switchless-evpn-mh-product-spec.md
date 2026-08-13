# SE350 switchless EVPN multihoming platform

## Product specification and development handoff

| Field | Value |
| --- | --- |
| Document status | Draft for architecture review and continued development |
| Document version | 0.1 |
| Last updated | 2026-08-13 |
| Product repository | `https://github.com/hcaldicott/grout` |
| Development branch | `evpn-mh-lifecycle` |
| Engineering baseline before this document | `b2c6f24b` (`smoke: cover EVPN-MH MAC reconciliation`) |
| Upstream repository | `https://github.com/DPDK/grout` |
| Upstream baseline | `cd71aea5` |
| Target host OS | AlmaLinux 9.8 x86_64 |
| Current development environment | AlmaLinux 9.8 arm64 container, three isolated Grout/FRR nodes |
| Primary audience | Network architects, DPDK/Grout developers, FRR reviewers, OpenNebula integrators, SREs and hardware-validation engineers |

This document is intentionally both a product specification and an engineering
handoff. It records the required outcome, the assumptions behind it, the design
that has been selected, the limitations discovered during prototyping, the
current code state, and the work still required before production use.

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT** and **MAY** are used
as normative requirement terms. A statement marked **proposed** is not yet an
accepted product commitment. A capability marked **prototype** has been shown
in the software lab but has not passed physical hardware, scale, lifecycle or
production qualification.

---

## 1. Executive summary

The product is a compact, switchless edge-compute and routing platform built
from three Lenovo ThinkSystem SE350 servers in each datacenter. Each SE350 is
expected to provide two integrated 10 GbE ports and one Intel X710-DA4
four-port 10 GbE adapter. The three hosts form their own DPDK-forwarded fabric;
no external top-of-rack or MLAG switch pair is added.

Each carrier supplies two physical 10 GbE handoffs. The handoffs terminate on
two different SE350s and appear to the carrier as members of one ordinary IEEE
802.3ad LACP bundle. A 6WIND router VM attaches to the resulting Layer-2
service and may run on any of the three SE350s. The target is up to 20 Gb/s of
aggregate carrier bandwidth across multiple flows, while a single flow remains
limited by LAG hashing to one 10 Gb/s member.

The selected control/data-plane split is:

- FRRouting (FRR) owns BGP EVPN, Ethernet Segment state, Type-1/Type-2/Type-3/
  Type-4 route signalling, Designated Forwarder election, aliasing and mass
  withdrawal decisions.
- Grout owns the complete packet path: physical X710/X722 ports, LACP, Layer-2
  bridging, VXLAN encapsulation, flow hashing, split horizon, DF enforcement and
  the VM-facing vhost-user port.
- Carrier ports remain bound to a DPDK-compatible driver. They are not Linux
  bond members and are not simultaneously bound to `vfio-pci` and a kernel
  networking driver.
- OpenNebula owns VM scheduling and lifecycle. It is not expected to calculate
  EVPN-MH state. A Grout-specific virtual-network driver and lifecycle hooks
  will prepare identical vhost-user endpoints on every eligible host.

FRR already supports all-active Layer-2 EVPN multihoming through LACP Ethernet
Segments. The development branch has demonstrated that FRR can drive a Grout
DPDK dataplane after a limited set of FRR and Grout extensions. The current
three-node lab passes control-plane signalling, split-chassis LACP, remote MAC
ECMP, DF changes, BUM suppression, split horizon, local-bias redirection, member
withdrawal/recovery and pre-Ethernet-Segment MAC reconciliation.

This is not yet production-ready. In particular:

1. FRR-to-Grout interface protodown/uplink tracking is missing.
2. Restart, delete ordering and nexthop lifecycle require hardening tests.
3. Grout's generic DPDK vhost PMD is compiled in, but the VM attachment,
   reconnect and live-migration lifecycle is not implemented or tested.
4. Ordinary EVPN-MH local bias can limit VM egress to 10 Gb/s when the VM runs
   on a host that also owns one local carrier member. Meeting the strict
   20 Gb/s-from-any-host requirement requires a deliberate distributed-egress
   extension in Grout or a different termination model.
5. A two-port-per-host 10 GbE triangle has exactly 20 Gb/s of host fabric
   capacity before encapsulation and operational overhead. It has no spare
   line-rate capacity for migration traffic or a fabric-link failure. QoS,
   accepted degradation, additional fabric capacity, or faster links are
   required.
6. The Intel X710-DA4 is a deployment assumption, not an adapter listed in the
   Lenovo SE350 supported-adapter table reviewed for this handoff. Physical fit,
   firmware, thermals, transceiver compatibility, PCIe bandwidth, IOMMU grouping
   and vendor-support implications MUST be qualified on the actual systems.

The proposed product is achievable, but it is a network product development
effort rather than a small OpenNebula configuration exercise.

---

## 2. Background and motivation

### 2.1 Existing operational model

The existing routing deployments use SR-IOV to place high-performance NIC
functions directly into 6WIND VMs. This makes near-NIC-rate forwarding
straightforward because the VM bypasses the host kernel and most of the virtual
switch path.

The limitations of direct assignment are important at this edge footprint:

- a physical function or conventional VF is tied to one host;
- a carrier handoff attached to another chassis cannot transparently become a
  member of the same logical host-side LAG;
- normal hypervisor live migration is usually unavailable for an assigned VF
  unless the complete NIC, firmware, QEMU and orchestration stack implements a
  compatible migratable-device mechanism;
- exposing a carrier port directly to one VM prevents the host fabric from
  providing shared Layer-2 reachability to that service.

The new design attempts to retain DPDK-class forwarding while moving the
physical-port and distributed-switching functions into a host dataplane that is
independent of VM placement.

### 2.2 Why no external MLAG switch pair

An external pair of compact switches would provide mature MLAG, buffering,
failure handling and operational tooling, but it consumes rack units, power,
cabling and another hardware lifecycle. The purpose of this product is to test
whether the three compute nodes can also be the carrier-facing distributed
switch.

The absence of switches does not remove switching functions. It moves those
functions into software and makes the host platform responsible for:

- LACP interoperability;
- loop prevention and split horizon;
- BUM Designated Forwarder behavior;
- MAC learning, mobility, aliasing and withdrawal;
- inter-host transport;
- capacity planning and congestion management;
- failure detection and convergence;
- persistence and reconciliation after daemon or host restart.

### 2.3 Why EVPN multihoming rather than classical MLAG

Classical MLAG commonly relies on a vendor-specific peer protocol and peer
link. FRR implements standards-based all-active EVPN Layer-2 multihoming. The
two provider-edge nodes use the same LACP system identity toward the carrier,
advertise a common Ethernet Segment Identifier (ESI), and exchange EVPN routes
over the fabric.

To the carrier, the result is intended to look like a normal two-member LACP
bundle. The carrier does not need to run EVPN, understand the three-host
topology, or install proprietary MLAG support. Internally, the implementation
is EVPN-MH rather than ICCP-style MLAG.

FRR's current documentation explicitly describes all-active Layer-2
multihoming via LACP Ethernet Segments. That makes FRR a suitable source of
control-plane truth, but FRR's usual Linux dataplane assumptions have to be
adapted to Grout.

### 2.4 Why Grout

Grout is a DPDK graph-based router with native support for physical DPDK ports,
bridges, VXLAN, bonds/LACP, a Unix-socket control API and an FRR Zebra dataplane
provider. Its architecture already supplies most of the packet-processing
building blocks without putting carrier traffic through Linux bridging or
Linux bonding.

The work is therefore an extension of an existing FRR-to-DPDK integration, not
a new routing suite. The primary additions are EVPN-MH object translation,
multi-destination Layer-2 forwarding policy, lifecycle reconciliation, and a
migration-safe VM edge.

---

## 3. Product goals and non-goals

### 3.1 Goals

The completed product MUST:

1. Operate as three SE350 compute/network nodes without an external datacenter
   switch in the carrier datapath.
2. Terminate each carrier's two 10 GbE LACP members on two distinct hosts.
3. Present a stable LACP system identity and aggregator to the carrier.
4. Keep the carrier, fabric and VM service packet path DPDK accelerated.
5. Provide the same carrier VLAN-backed Layer-2 service to a 6WIND VM on any of
   the three hosts.
6. Make up to 20 Gb/s aggregate carrier capacity available to the VM across
   multiple suitably distributed flows in the healthy topology.
7. Preserve per-flow ordering under steady state.
8. Survive loss of one carrier member without losing the Layer-2 service.
9. Prevent persistent duplicate BUM forwarding and Layer-2 loops.
10. Support live migration through OpenNebula without resetting the guest or
    requiring manual network reconfiguration.
11. Preserve established representative routing and customer traffic through
    a planned migration within an explicitly measured interruption target.
12. Reconcile state after FRR, Zebra, Grout or host restart without static FDB
    entries or operator cleanup.
13. Expose sufficient state, counters and logs to diagnose forwarding and
    control-plane disagreements.
14. Be reproducibly packaged for AlmaLinux 9.8 x86_64.

### 3.2 Non-goals for the first production release

The first release is not required to:

- provide a general-purpose replacement for every switch feature;
- implement STP, MSTP or arbitrary Layer-2 ring protection;
- support more than three PEs in one edge cluster;
- support more than two physical carrier members per carrier LAG;
- provide hitless in-service software upgrade of Grout itself;
- live-migrate a directly assigned X710 VF;
- combine kernel Linux bonding and DPDK ownership of the same port;
- guarantee 20 Gb/s for a single flow;
- guarantee 20 Gb/s after a 10 GbE fabric or carrier-member failure;
- guarantee full carrier throughput while memory migration consumes a fully
  saturated 20 GbE fabric;
- claim zero packet loss without a measured and accepted SLO;
- expose the carrier LACP bond directly to the guest.

### 3.3 Success definition

Success is not merely BGP convergence. The release is successful only when the
physical three-node system, a real or standards-compliant carrier LACP peer,
the Grout dataplane, FRR, QEMU/libvirt, OpenNebula and the 6WIND guest pass the
end-to-end acceptance matrix in section 17.

---

## 4. Terminology and system roles

| Term | Meaning in this document |
| --- | --- |
| PE | A Grout/FRR host participating in EVPN. For a given carrier ES, the two SE350s with physical handoffs are the local PEs. |
| Remote host | The third SE350 for a particular carrier ES. It has no physical member for that carrier but can host the VM. |
| ES | EVPN Ethernet Segment representing one carrier LACP bundle. |
| ESI | Ten-byte identifier shared by the PEs attached to the same carrier segment. |
| EVI/service | One Layer-2 EVPN service, represented by a Grout bridge and VXLAN VNI. |
| DF | EVPN Designated Forwarder. Only the DF forwards specified BUM traffic from the overlay toward a multi-homed segment. |
| BUM | Broadcast, unknown-unicast and multicast traffic. |
| Local bias | EVPN behavior that prefers a PE's own attached ES for local traffic and avoids unnecessary traversal through another PE. |
| Aliasing | Installing multiple remote PE paths for a MAC or segment so traffic can use all-active members. |
| Mass withdrawal | Removing reachability through a failed ES/PE without waiting for every MAC route to age independently. |
| Underlay | Routed IP connectivity among the three VTEPs. |
| Overlay | BGP EVPN signalling and VXLAN-carried service frames. |
| Access port | VM-facing Grout port attached to a service bridge. |
| Carrier port | Physical DPDK port connected to a carrier handoff. |
| Fabric port | Physical DPDK port used for inter-SE350 underlay transport. |
| vhost-user | Unix-socket protocol between QEMU's virtio-net frontend and a userspace dataplane backend. |
| “Seamless” migration | Guest remains running; established sessions survive; any packet interruption is bounded by the accepted SLO; no operator network changes are required. It does not mean mathematically zero packet loss. |

---

## 5. Requirements catalogue

The identifiers below are stable references for design reviews, tests and pull
requests.

### 5.1 Physical and hardware requirements

- **HW-001**: Each site MUST contain three SE350 nodes with identical CPU,
  firmware, BIOS, microcode, memory topology and supported virtualization
  configuration for live migration.
- **HW-002**: Each node is assumed to provide two integrated 10 GbE ports and
  one X710-DA4 with four 10 GbE ports. The exact PCI function map MUST be
  captured from the production SKU before configuration is generated.
- **HW-003**: All carrier and fabric ports MUST be usable by the selected DPDK
  PMD with stable PCI addresses and isolated IOMMU groups.
- **HW-004**: Management access MUST remain available independently of Grout's
  DPDK ports.
- **HW-005**: Optics, BiDi wavelength direction, DOM behavior, carrier coding,
  FEC expectations and X710/X722 transceiver compatibility MUST be validated.
- **HW-006**: PCIe link width/speed, thermals and power MUST sustain all four
  X710 ports at the target traffic profile without throttling or errors.
- **HW-007**: A hardware bill of materials MUST state whether the non-Lenovo
  X710-DA4 configuration is vendor-supported or an accepted exception.

### 5.2 Topology requirements

- **TOP-001**: The inter-host topology MUST be loop-free at Layer 2. The
  recommended topology is a routed IP triangle, not a bridged Ethernet ring.
- **TOP-002**: Each host MUST have direct 10 GbE fabric connectivity to each of
  the other two hosts in the baseline layout.
- **TOP-003**: Each carrier LAG's physical members MUST terminate on two
  different hosts and failure domains.
- **TOP-004**: No single carrier optic, cable, PCI function or host failure may
  remove both members of the same carrier LAG.
- **TOP-005**: Underlay MTU MUST accommodate the service frame plus VXLAN, UDP,
  IP and Ethernet overhead without fragmentation. A jumbo underlay is strongly
  recommended.
- **TOP-006**: Migration/control traffic sharing fabric ports MUST be placed in
  a distinct traffic class or otherwise rate-limited so it cannot starve
  LACP/BGP/BFD or carrier forwarding.

### 5.3 Carrier and LACP requirements

- **LAG-001**: The carrier MUST see one stable actor system MAC and actor key
  for the two members of a service LAG.
- **LAG-002**: Both healthy members MUST reach synchronized, collecting and
  distributing state at the carrier.
- **LAG-003**: Loss of a PE's safe path to the fabric MUST suppress normal data
  collection/distribution on its carrier member while continuing the LACP
  control exchange required for recovery.
- **LAG-004**: A suppressed member MUST be removed from Grout transmit hashing
  and MUST reject ordinary ingress data; it MUST NOT black-hole carrier traffic
  while continuing to advertise itself as collecting/distributing.
- **LAG-005**: Carrier LACP timers, minimum-links policy, hashing fields, system
  priority and operational expectations MUST be recorded per carrier.
- **LAG-006**: Each carrier/service trunk MUST have an explicit allowed VLAN
  list. Untagged, native and unexpected VLAN behavior MUST be defined.

### 5.4 EVPN and Layer-2 requirements

- **EVPN-001**: Every carrier LAG MUST map to a deterministic ESI shared only by
  its two attached PEs.
- **EVPN-002**: PEs MUST advertise and consume the Type-1 and Type-4 routes
  required for all-active multihoming.
- **EVPN-003**: Local MAC/IP Type-2 advertisements MUST carry the correct ESI
  after ES attachment, including when the MAC was learned before FRR finished
  constructing the ES.
- **EVPN-004**: Remote all-active MACs MUST resolve to a nexthop group containing
  every usable PE, rather than an arbitrary single VTEP.
- **EVPN-005**: The DF policy MUST suppress non-DF overlay-to-ES BUM forwarding.
- **EVPN-006**: Split horizon MUST prevent a frame received from an ES from
  returning to that ES through another PE.
- **EVPN-007**: Local-bias and aliasing behavior MUST be deterministic and
  observable.
- **EVPN-008**: MAC moves caused by VM migration MUST converge without a
  persistent duplicate-MAC loop.
- **EVPN-009**: Configuration and daemon restart MUST reconcile, rather than
  depend on configuration order or static FDB entries.
- **EVPN-010**: All service and synthetic VLAN translation MUST remain within
  the IEEE VLAN range and be scoped so one bridge cannot collide with another.

### 5.5 Dataplane and performance requirements

- **DP-001**: Carrier and fabric ports MUST remain in the DPDK dataplane for
  ordinary service packets.
- **DP-002**: Linux control-plane TAP/TUN devices MAY carry routing protocol or
  host-originated control traffic, but MUST NOT be the bulk carrier datapath.
- **DP-003**: Grout MUST select ECMP and LACP members with a stable flow hash.
- **DP-004**: Hardware RSS SHOULD be used when present. A consistent software
  L3/L4 Toeplitz fallback MUST be used when RSS metadata is unavailable.
- **DP-005**: A single ordered flow MUST remain on one path unless that path
  fails. Rehashing after failure MAY reorder a bounded number of packets.
- **DP-006**: The healthy system MUST demonstrate aggregate use of both carrier
  members from a VM on SE350-1, SE350-2 and SE350-3 separately.
- **DP-007**: The target is 20 Gb/s nominal aggregate link capacity. Measured
  application throughput MUST be stated separately for each direction, packet
  size and flow distribution; “20 Gb/s” MUST NOT be reported as single-flow or
  guaranteed payload throughput.
- **DP-008**: No release may claim line-rate without reporting loss, latency,
  jitter, CPU use, queue use, NUMA placement and frame-size mix.
- **DP-009**: MTU, checksum, VLAN, TSO/GSO and virtio feature negotiation MUST
  be identical before and after migration.

### 5.6 6WIND VM requirements

- **VM-001**: The 6WIND VM MUST use a migration-compatible virtio-net/vhost-user
  attachment for the production migration path.
- **VM-002**: The VM MUST receive the same stable MAC addresses, PCI topology,
  queue counts and service VLAN presentation on every host.
- **VM-003**: The VM MUST NOT own the physical carrier PF or a conventional
  non-migratable VF in this product path.
- **VM-004**: Carrier VLANs MAY be presented as one guest trunk or separate
  guest NICs, but the choice MUST be consistent and captured in the service
  model.
- **VM-005**: 6WIND dataplane vCPUs, QEMU emulator threads, vhost queues, Grout
  workers and hugepage memory MUST be pinned with NUMA awareness.
- **VM-006**: Guest routing adjacencies and representative TCP/UDP flows MUST
  survive a planned live migration.
- **VM-007**: A guest reboot or virtio reset MUST not require Grout restart and
  MUST not leave a stale forwarding entry.

### 5.7 Live-migration requirements

- **MIG-001**: Source and destination MUST be in the same compatible
  OpenNebula cluster and pass a preflight check for CPU, firmware, QEMU,
  libvirt, kernel, Grout, FRR, DPDK, queue, MTU and feature compatibility.
- **MIG-002**: The destination vhost endpoint and bridge attachment MUST be
  ready before QEMU cutover.
- **MIG-003**: The source attachment MUST remain active until QEMU confirms
  destination ownership; cleanup MUST be idempotent.
- **MIG-004**: The VM MAC MUST be relearned/advertised at the destination and
  withdrawn at the source without a persistent overlap or black hole.
- **MIG-005**: Migration MUST require no carrier-side LACP change and no guest
  network reconfiguration.
- **MIG-006**: Proposed initial SLO: no TCP reset, no routing-session reset, no
  operator action, and no continuous traffic interruption greater than 100 ms.
  The stretch objective is 50 ms. These values require stakeholder ratification
  and measurement before becoming release commitments.
- **MIG-007**: Packet loss and reordering MUST be reported for UDP and small-
  packet tests; a claim of “seamless” MUST cite those results.
- **MIG-008**: A failed migration MUST leave exactly one usable attachment and
  restore normal forwarding without manual FDB or socket cleanup.
- **MIG-009**: Migration bandwidth MUST be rate-controlled when the service
  fabric does not have reserved headroom.

### 5.8 OpenNebula and operations requirements

- **ONE-001**: OpenNebula MUST schedule this VM only on hosts advertising a
  matching network-capability/version label.
- **ONE-002**: Host network setup and teardown MUST be idempotent.
- **ONE-003**: The integration MUST use supported virtual-network and VM
  lifecycle extension points rather than manual per-VM commands.
- **ONE-004**: VM create, stop, reboot, migrate, migration rollback and delete
  MUST leave no stale Unix sockets, Grout ports, bridge members or FDB state.
- **ONE-005**: Maintenance mode MUST permit VM evacuation while physical
  carrier forwarding on the host remains available when safe.
- **ONE-006**: A host whose Grout/FRR state is degraded or mismatched MUST be
  removed from the eligible migration set.
- **OPS-001**: FRR, Grout, LACP, bridge policy, FDB, NHG, queues, xstats and
  vhost state MUST be observable per service and per host.
- **OPS-002**: Configuration MUST be generated from a site data model and
  validated before apply.
- **OPS-003**: Changes MUST support staged rollout and rollback across three
  hosts without simultaneously withdrawing both carrier members.
- **OPS-004**: Persistent state MUST be minimized; authoritative configuration
  and learned state MUST be distinguishable.

---

## 6. Physical deployment design

### 6.1 SE350 network inventory assumption

The referenced SE350 product guide describes a wired module with two 10 GbE
SFP+ ports and a PCIe 3.0 x16 expansion slot. The target layout adds an Intel
X710-DA4 four-port 10 GbE SFP+ adapter in that slot, yielding the assumed six
10 GbE dataplane ports per host.

This document uses the following neutral port names so configuration is not
tied to unstable Linux device names:

| Logical name | Expected hardware | Intended use |
| --- | --- | --- |
| `fabric-a` | Integrated 10 GbE port 0 | Direct underlay link to one peer |
| `fabric-b` | Integrated 10 GbE port 1 | Direct underlay link to the other peer |
| `carrier-0` | X710-DA4 port 0 | Carrier handoff |
| `carrier-1` | X710-DA4 port 1 | Carrier handoff |
| `carrier-2` | X710-DA4 port 2 | Carrier handoff or spare |
| `carrier-3` | X710-DA4 port 3 | Carrier handoff or spare |
| `management` | Dedicated management/1 GbE path | OpenNebula, SSH, monitoring, emergency access |

The final mapping MUST be generated from PCI BDFs, not inferred from port
labels. Each node's BDF, NUMA node, IOMMU group, driver, permanent MAC, optic,
peer and cable label MUST be in the site inventory.

### 6.2 Recommended three-host fabric

The two integrated 10 GbE ports form a physical triangle:

```text
                       10 GbE
              SE350-1 ----------- SE350-2
                 \                    /
                  \                  /
             10 GbE\                /10 GbE
                    \              /
                       SE350-3
```

Each edge is an IP-routed point-to-point link. No fabric port is placed in a
common Layer-2 ring and STP is not part of the design. Each host advertises a
stable VTEP loopback through the underlay. The first implementation SHOULD use
one of these reviewed models:

- numbered `/31` links with OSPF and BFD, plus iBGP EVPN among loopbacks; or
- numbered `/31` links with eBGP underlay/overlay and an explicit routing
  policy.

Static routes MAY be used only in the first physical bring-up. They are not the
preferred production failure-detection mechanism.

### 6.3 Example carrier placement

The site has three or four external carrier constructs:

- Virtutel, carrying Transit, Intercap and NBN Aggregation services;
- Megaport;
- Opticomm;
- EdgeIX, where ordered.

The example below balances four dual handoffs as 3/3/2 X710 ports. It is a
planning example, not a carrier order.

| Host | X710 port | Assignment | Paired endpoint |
| --- | --- | --- | --- |
| SE350-1 | `carrier-0` | Virtutel member A | SE350-2 `carrier-0` |
| SE350-1 | `carrier-1` | Megaport member A | SE350-3 `carrier-0` |
| SE350-1 | `carrier-2` | EdgeIX member A | SE350-2 `carrier-2` |
| SE350-1 | `carrier-3` | Spare | — |
| SE350-2 | `carrier-0` | Virtutel member B | SE350-1 `carrier-0` |
| SE350-2 | `carrier-1` | Opticomm member A | SE350-3 `carrier-1` |
| SE350-2 | `carrier-2` | EdgeIX member B | SE350-1 `carrier-2` |
| SE350-2 | `carrier-3` | Spare | — |
| SE350-3 | `carrier-0` | Megaport member B | SE350-1 `carrier-1` |
| SE350-3 | `carrier-1` | Opticomm member B | SE350-2 `carrier-1` |
| SE350-3 | `carrier-2` | Spare | — |
| SE350-3 | `carrier-3` | Spare | — |

For each carrier, the two endpoints MUST use the same Grout LACP system MAC,
system priority and actor key, but different actor port identities. Different
carriers MUST use different ESIs and SHOULD use different LACP system MACs.

Virtutel's Transit, Intercap and NBN Aggregation may be services/VLANs on one
physical LAG or separate physical constructs. That ordering detail is not yet
captured. The implementation MUST not assume that the three service names
consume only one VLAN or one EVI until the carrier handoff document is reviewed.

### 6.4 Port and capacity budget

With four dual carrier handoffs:

- carrier endpoints consume eight X710 ports across the site;
- the fabric triangle consumes all six integrated 10 GbE ports;
- ten of eighteen assumed 10 GbE ports are occupied;
- spare ports are unevenly distributed: one on SE350-1, one on SE350-2 and two
  on SE350-3 in the example.

The triangle can deliver 20 Gb/s aggregate to a host by using both of its
10 GbE peer links. That is a no-failure theoretical ceiling. VXLAN/IP overhead,
packet-size effects and control traffic reduce usable payload capacity.

Consequences that MUST be reflected in the product promise:

- loss of one fabric link can reduce a host to 10 Gb/s direct capacity or force
  traffic through a shared two-hop path;
- a full-rate 20 Gb/s workload leaves no fabric headroom for memory migration;
- a host-to-host migration stream can contend with carrier traffic unless it is
  rate-limited or a separate/faster fabric is added;
- adding faster 25 GbE fabric adapters would improve headroom but conflicts with
  the proposed X710 port budget and requires a revised hardware design.

---

## 7. Logical architecture

### 7.1 Service packet path

For a carrier whose physical members are on SE350-1 and SE350-2, with the VM on
SE350-3, the intended path is:

```text
 Carrier LACP member A                         Carrier LACP member B
          |                                              |
   X710 / Grout PE1                               X710 / Grout PE2
          |                                              |
          +------ EVPN control + VXLAN data fabric ------+
                              |
                       Grout on SE350-3
                              |
                  DPDK vhost-user / virtio-net
                              |
                         6WIND router VM
```

The service chain is:

```text
physical carrier member
  -> Grout local LACP bond / Ethernet Segment attachment circuit
  -> Grout bridge for the carrier service
  -> local access port OR VXLAN VNI over routed underlay
  -> Grout bridge on VM host
  -> DPDK net_vhost port
  -> QEMU virtio-net PCI device
  -> 6WIND DPDK dataplane
```

Bulk frames never require a Linux bridge, Linux bond, kernel VXLAN interface or
kernel route lookup. FRR receives interface state and learned-object events
through Grout's provider and programs forwarding through the Grout API.

### 7.2 Control-plane ownership

| Object/function | Authoritative owner | Consumer/action |
| --- | --- | --- |
| Physical link and queue state | Grout/DPDK PMD | Reported to FRR and operations |
| LACP state machine | Grout | Carrier peer; exposed to FRR/operations |
| ESI and ES configuration | Generated site config/FRR | FRR calculates MH state |
| BGP EVPN routes | FRR | Other PEs and Grout provider |
| DF election | FRR | Grout bridge-port policy |
| L2 VTEP nexthops/NHGs | FRR | Installed in Grout |
| Local/remote FDB | Grout learning plus FRR external entries | Grout bridge datapath |
| VXLAN encapsulation | Grout | Physical fabric ports |
| VM network intent | OpenNebula/site data model | Grout network driver/hooks |
| VM socket and access port | Grout/OpenNebula integration | QEMU and service bridge |
| Guest VLAN/VRF/routing | 6WIND configuration | Carrier/customer protocols |

### 7.3 Linux control-plane boundary

Grout creates Linux TAP/TUN representations for control-plane interoperability.
Those devices let Zebra and routing daemons observe interfaces and exchange
host/control traffic. They do not mean the physical carrier port is owned by
Linux.

A physical X710 function cannot simultaneously be owned by a kernel network
driver/bond and by `vfio-pci` for DPDK. The selected architecture avoids the
conflict: FRR computes state and uses the dataplane provider; Grout alone owns
the carrier port and executes forwarding.

---

## 8. Carrier-facing LACP and EVPN-MH behavior

### 8.1 What the carrier sees

For each service, both attached Grout instances send LACP PDUs with the same
actor system MAC and compatible key. The carrier's two ports therefore enter
one aggregator despite terminating on different servers. Grout does not expose
the inter-host fabric or EVPN to the carrier.

Expected healthy state:

- two synchronized carrier members;
- collecting and distributing on both;
- carrier hashes different flows across both members;
- each member is limited to 10 Gb/s;
- carrier does not depend on the EVPN DF for known-unicast hashing.

### 8.2 Ethernet Segment model

Each carrier LAG is represented as one all-active Ethernet Segment on its two
attached PEs. The ESI MUST be deterministic from site/carrier identity and MUST
not be generated from transient interface IDs. A proposed allocation is:

```text
00:<site-id-2B>:<carrier-id-2B>:<service-id-2B>:<reserved-3B>
```

The final allocation needs review for collision handling and operational
readability. Secrets MUST NOT be embedded in an ESI.

Every bridged VLAN/service gets a VNI and route target. The implementation may
use VLAN-based service interfaces internally even where the current Grout
bridge API abstracts VLAN 0.

### 8.3 DF and split horizon

The DF affects overlay-to-ES BUM forwarding. It is not a general active/standby
selector for known unicast. FRR supplies these bridge-port attributes to Grout:

- non-DF flag;
- backup Layer-2 nexthop group;
- peer VTEP split-horizon filters.

Grout atomically replaces the policy under QSBR so dataplane workers cannot see
a partially updated object. The datapath:

- suppresses overlay BUM toward a non-DF carrier port;
- suppresses unicast or BUM reflected from a peer VTEP toward the same ES;
- uses a backup NHG for a local-ES hairpin where the destination may sit behind
  another PE.

### 8.4 Uplink tracking and protodown

This behavior is still missing and is release-blocking.

If a PE loses safe fabric reachability but its carrier optic remains up, the
carrier must stop sending ordinary data to that isolated PE. Simply dropping
frames in the bridge is unsafe because the carrier will continue hashing to the
apparently healthy member. Administratively dropping the DPDK port is also
insufficient because it prevents the LACP exchange needed to recover cleanly.

The required Grout member-suppression state MUST:

1. continue receiving and transmitting LACP PDUs;
2. clear synchronized/collecting/distributing advertisement as appropriate;
3. mark the member inactive for the bond redirection table;
4. reject ordinary ingress data on that physical member;
5. keep link state and the LACP state machine observable;
6. restore normal negotiation when FRR clears protodown.

FRR's relevant `DPLANE_OP_INTF_UPDATE` context must map to this explicit API,
not to the ordinary `GR_IFACE_F_UP` flag.

---

## 9. The 20 Gb/s any-host requirement

### 9.1 What standard EVPN-MH provides

When the VM is on the third, non-attached host, a carrier-side MAC advertised
with the ESI can resolve to two remote VTEPs. Grout's current prototype installs
a two-member L2 NHG and hashes different flows across both PEs. The lab proves
that both paths are used and one can be withdrawn.

Carrier-to-VM traffic can likewise enter on either carrier member and traverse
the direct fabric link from that PE to the VM host. The triangle therefore has
the topology needed for 10 + 10 Gb/s aggregate in the healthy case.

### 9.2 The local-bias gap

When the VM runs on SE350-1 and SE350-1 owns one physical member of the same
carrier ES, normal EVPN local bias forwards a carrier-side destination through
SE350-1's local member. That local member is only 10 Gb/s. The existing remote
MAC NHG test does not prove that locally sourced VM traffic can also use
SE350-2's carrier member.

Blindly sending half of those frames through the existing ES peer VTEP is not a
correct fix: SE350-2's split-horizon rule may identify SE350-1 as an ES peer and
block the frame to avoid reflection. Relaxing the filter globally could create
a loop for traffic that genuinely arrived from the carrier ES.

Therefore **DP-006 is an open product gap**, not a completed capability.

### 9.3 Recommended Grout extension: distributed ES egress

The recommended direction is an explicit mixed local/remote egress policy for
access-originated traffic:

1. Extend the bridge-port/ES policy so Grout can identify the local attachment
   circuit, remote backup NHG and a fabric transit encapsulation that is distinct
   from ES-origin traffic.
2. Extend Layer-2 forwarding groups so a group member can be either:
   - a local bridge/bond output; or
   - a remote VTEP output.
3. For a destination learned on the local carrier ES, and only when ingress is
   a VM/access attachment rather than that ES, hash eligible flows between the
   local output and the remote PE output.
4. Mark or encapsulate the remote path with unambiguous provenance. The remote
   PE must permit access-origin transit to the carrier while still rejecting
   ES-origin reflection. A dedicated transit VTEP/source address or dedicated
   internal transit VNI is preferred over weakening peer-VTEP split horizon.
5. If ingress is the carrier ES, never select a remote member of the same ES.
6. If the remote member is withdrawn, atomically collapse the group to the local
   member and preserve flow hashing as far as possible.
7. Expose counters for local selection, remote selection, provenance rejection
   and failover rehash.

This extension is intentionally described as a Grout feature rather than an
FRR protocol change. FRR already supplies the ES peers, backup NHG and failure
state. Grout needs additional forwarding semantics for the stricter product
throughput requirement.

Before implementation, reviewers MUST answer:

- what exact tunnel metadata distinguishes access-origin from ES-origin;
- whether a second VTEP/VNI is operationally acceptable;
- whether the behavior remains interoperable with future non-Grout PEs;
- how BUM traffic is handled (the first release SHOULD apply distributed egress
  only to known unicast);
- how a mixed local/remote group is represented in the stable Grout API;
- how MAC movement and group deletion are ordered under RCU/QSBR;
- whether per-flow symmetry is required by the 6WIND/carrier service.

### 9.4 Alternative: terminate LACP in the 6WIND VM

An alternative architecture is to transport each physical carrier link as an
independent DPDK Layer-2 circuit to one of two guest vNICs and let 6WIND
terminate LACP. This naturally gives one VM two 10 Gb/s logical members on any
host and makes the carrier's LACP peer the VM rather than Grout.

It may reduce the EVPN-MH forwarding work, but it changes the product model and
has its own requirements:

- 6WIND must support the required LACP and trunk behavior on virtio devices;
- Grout must transparently forward slow-protocol frames instead of consuming
  them in its LACP state machine;
- the two physical circuits must remain isolated until the guest bond;
- both guest vNIC circuits must migrate and reconnect consistently;
- a guest outage removes the carrier LACP system itself;
- the architecture no longer provides a shared host-terminated carrier bridge.

This alternative SHOULD be prototyped as a bounded feasibility test before the
custom distributed-egress design is committed. Product owners must choose the
termination model explicitly; the two models must not be mixed accidentally.

---

## 10. 6WIND VM integration

### 10.1 Selected VM attachment

The primary design presents one or more virtio-net PCI devices to the 6WIND VM.
QEMU connects each device to a DPDK `net_vhost` port owned by Grout. Grout then
attaches that port to the appropriate service bridge.

The Grout build already enables DPDK's `net/vhost` PMD and `vhost` library.
Grout's generic port creation probes arbitrary DPDK devargs, so a form such as
the following is architecturally available:

```text
interface add port vm-<vmid>-<nicid> \
  devargs net_vhost<unique>,iface=<socket>,queues=<n>,client=1 \
  domain <service-bridge>
```

This is not yet a supported product interface. It requires tests and lifecycle
wrapping. The preferred ownership is Grout/DPDK as the vhost-user client and
QEMU as the socket server because client mode supports reconnect when QEMU is
created or restarted. The final choice must match libvirt/OpenNebula behavior
on the deployed versions.

### 10.2 Guest network presentation

Two service models are acceptable for evaluation:

**Trunk model**

- one high-queue virtio-net device carries multiple carrier VLANs;
- 6WIND creates VLAN subinterfaces and maps them to guest VRFs;
- fewer virtual PCI devices and sockets;
- one queue/feature problem affects multiple services;
- requires explicit allowed-VLAN filtering in Grout.

**Per-service model**

- each carrier or service receives a dedicated virtio-net device;
- simple failure isolation and accounting;
- more guest PCI functions, sockets, queues and OpenNebula template entries;
- may be easier for phased deployment.

The first hardware test SHOULD begin with one service and one vhost-user port.
The final model should be chosen after measuring queue scaling and reviewing
the 6WIND configuration limits.

### 10.3 Queue and CPU design

To approach two-port aggregate capacity, the path MUST not depend on one busy
virtqueue or one unpinned worker. The host profile must define:

- vhost queue-pair count;
- virtio multiqueue and vector count;
- 6WIND worker count and RX/TX queue mapping;
- Grout datapath worker and physical RX queue mapping;
- QEMU emulator and I/O thread placement;
- hugepage size and NUMA node;
- X710/X722 NUMA locality;
- RSS key and supported hash fields;
- descriptor counts and mbuf pool sizing;
- checksum, VLAN and segmentation offload policy.

All three hosts MUST advertise the same effective guest feature set. A VM may
not migrate to a host that would negotiate different virtio features or fewer
queues.

### 10.4 Guest routing behavior during migration

The guest MAC and IP addresses do not change. Carrier peers and customer
devices should therefore see a Layer-2 MAC move, not a router replacement.
Existing BGP, BFD or other sessions inside 6WIND must remain established if the
measured interruption is below their timers.

Aggressive sub-100-ms guest BFD can be incompatible with a 100-ms migration
SLO. The validation matrix MUST include the actual guest protocol timers. The
product must either meet them or document a migration-safe timer profile.

---

## 11. Seamless live-migration design

### 11.1 Meaning of seamless

OpenNebula describes live migration as transferring a running VM with no
noticeable downtime. For this network product, the word must be testable.

The proposed release interpretation is:

- the guest is not shut down or rebooted;
- established TCP sessions survive without reset;
- representative guest routing adjacencies survive;
- no carrier LACP member is reconfigured because of VM placement;
- no operator runs a Grout, FRR or FDB command;
- continuous interruption is at most 100 ms, with a 50 ms stretch goal;
- UDP loss and packet reordering are measured and reported;
- source cleanup and destination activation complete automatically.

This target is ambitious but plausible with vhost-user and a pre-created
destination attachment. It is not yet demonstrated in this repository.

### 11.2 Preconditions

Before OpenNebula permits migration, the destination MUST pass all of these
checks:

1. matching CPU compatibility baseline;
2. matching BIOS, microcode, kernel, QEMU and libvirt policy;
3. matching Grout, FRR, DPDK and integration package versions;
4. healthy underlay and EVPN sessions;
5. correct service bridge/VNI/ES state;
6. available hugepages on the correct NUMA node;
7. available pinned CPU set and vhost queues;
8. no conflicting socket or Grout interface name;
9. matching MTU, MAC, queue and virtio features;
10. migration transport reachability and acceptable fabric headroom;
11. destination excluded from maintenance/degraded state;
12. source and destination storage compatible with live migration.

OpenNebula live migration does not migrate a VM into a different system
datastore. The storage design must therefore use a compatible shared/accessible
system datastore or another OpenNebula-supported arrangement selected for the
site.

### 11.3 Migration sequence

The intended orchestration sequence is:

```text
1. OpenNebula selects destination and invokes network preflight.
2. Destination hook creates/validates the QEMU vhost socket contract.
3. Destination hook creates the Grout net_vhost port in reconnecting client mode.
4. Destination port is attached to the same bridge with the same policy and MAC.
5. QEMU destination instance starts in incoming-migration state.
6. Pre-copy transfers guest memory while source VM and source vhost stay active.
7. QEMU performs the stop-and-copy cutover.
8. Destination virtio/vhost queues become active.
9. Destination Grout learns the VM MAC and FRR advertises the MAC move.
10. Test traffic confirms destination forwarding.
11. Source vhost port is detached and removed idempotently.
12. Source stale learned state is flushed or expires under bounded policy.
13. OpenNebula records completion and releases source resources.
```

The destination Grout port may exist before QEMU because the DPDK vhost PMD can
operate in client/reconnect mode. Link-down must not be treated as an error
while QEMU is not yet accepting the socket.

### 11.4 MAC mobility and overlap

During cutover, both source and destination host state may briefly exist. The
design must prevent two active guest transmitters, while accepting that control
planes converge asynchronously.

Required behavior:

- QEMU is the authority that prevents simultaneous guest execution;
- the first valid source frame at destination updates local Grout learning;
- FRR advertises the destination Type-2 path with a newer mobility sequence when
  required;
- remote PEs replace the old path without a long ageing delay;
- source learned state is removed after confirmed cutover;
- gratuitous ARP/unsolicited NA MAY accelerate peers but must not be the only
  correctness mechanism;
- a rollback keeps the source attachment usable and removes the unused
  destination object.

### 11.5 Migration transport and capacity

Memory pre-copy can be much larger than the network switchover. With a fully
loaded two-link fabric, unbounded migration traffic can increase packet loss or
latency even if vhost cutover is correct.

The production policy MUST choose at least one:

- reserve fabric bandwidth for migration and control traffic;
- rate-limit QEMU migration below measured spare capacity;
- schedule migration only below a utilization threshold;
- add separate/faster migration connectivity;
- accept and document reduced forwarding throughput during migration.

The product cannot simultaneously promise a saturated 20 Gb/s service, a
saturated migration stream and no contention on exactly 20 Gb/s of host fabric.

### 11.6 Failure and rollback cases

Tests MUST cover:

- destination socket cannot be created;
- Grout destination port creation fails;
- QEMU cannot negotiate identical virtio features;
- pre-copy times out due to dirty memory rate;
- destination loses fabric during pre-copy;
- source carrier member fails during migration;
- QEMU cutover succeeds but destination vhost link stays down;
- OpenNebula reports failure after QEMU destination starts;
- source cleanup hook is repeated;
- Grout or FRR restarts during a migration window.

Every case must end with zero or one active VM as intended by OpenNebula and no
ambiguous network attachment. Automatic rollback must not delete the still-live
source socket.

---

## 12. OpenNebula integration design

### 12.1 Scope of OpenNebula support

OpenNebula supports KVM live migration and already documents DPDK vhost-user
integration for its Open vSwitch driver. That is evidence that its VM templates
and libvirt generation can represent the necessary QEMU interface and shared
memory settings. It does not mean OpenNebula has a native Grout network driver
or understands EVPN-MH.

The project must add a Grout integration layer with behavior equivalent in
lifecycle completeness to an OpenNebula VNM driver.

### 12.2 Proposed virtual-network attributes

The exact names require review against the chosen OpenNebula version. The data
model needs at least:

| Attribute | Purpose |
| --- | --- |
| `GROUT_BRIDGE` | Stable Grout bridge name on every host |
| `GROUT_VNI` | EVPN service VNI |
| `GROUT_VLAN_MODE` | Access, trunk or per-service presentation |
| `GROUT_ALLOWED_VLANS` | Validated service VLAN set |
| `GROUT_QUEUES` | vhost/virtio queue-pair count |
| `GROUT_MTU` | Guest/service MTU |
| `GROUT_PROFILE` | Versioned host-network capability profile |
| `GROUT_SOCKET_ROOT` | Controlled runtime socket directory |
| `GROUT_NUMA_POLICY` | Required/allowed NUMA placement |

The socket name MUST be deterministic from VM ID and NIC ID, length-safe for a
Unix-domain socket, and confined to a directory with explicit ownership and
SELinux labeling.

### 12.3 Host capability advertisement

Each host probe SHOULD publish:

- Grout/FRR/DPDK package build IDs;
- expected bridge and VNI presence;
- EVPN peer health;
- physical carrier/fabric status;
- available hugepages;
- queue and pinned-core capacity;
- supported vhost/virtio features;
- network profile hash;
- degraded/maintenance flag.

VM templates use `SCHED_REQUIREMENTS` or an equivalent cluster policy to admit
only matching hosts. Compatibility must be positive and versioned; absence of a
probe value is not healthy.

### 12.4 Lifecycle operations

The integration must define and test these operations:

| Operation | Required network action |
| --- | --- |
| Deploy | Validate bridge, create vhost port/socket relationship, attach port, start QEMU, confirm link |
| Reboot | Preserve/reconnect vhost port without duplicate creation |
| Power off | Detach link safely; retain or remove port according to documented policy |
| Resume | Recreate missing port idempotently and reconnect |
| Live migrate prepare | Pre-create and validate destination attachment |
| Live migrate commit | Confirm destination, withdraw/flush source, remove source port |
| Live migrate rollback | Remove destination-only state and preserve source |
| Delete | Remove port, socket and learned state; tolerate repeated invocation |
| Host maintenance | Prevent new placements; evacuate VMs without withdrawing healthy carrier service unnecessarily |

### 12.5 Security and SELinux

AlmaLinux enforcing mode is the target. The integration MUST not require
disabling SELinux or making the socket directory world-writable. A policy must
permit only the intended QEMU/libvirt and Grout domains to access each socket.

Hooks must validate all names and paths. VM-controlled strings must not be
inserted into shell commands or DPDK devargs without strict encoding and length
checks.

---

## 13. Grout and FRR implementation design

### 13.1 Existing upstream architecture

Upstream Grout already provides:

- DPDK physical/vdev port probing;
- Layer-2 bridges and learned/external FDB entries;
- VXLAN interfaces and flood lists;
- LACP bonds;
- stable API/CLI objects;
- RCU/QSBR-aware dataplane updates;
- FRR Zebra dataplane integration;
- DPDK `net/vhost`, `net/i40e`, `net/tap` and `net/virtio` drivers in the
  bundled build.

The fork intentionally builds on these objects instead of introducing a second
virtual-switch process.

### 13.2 Synthetic bridge VLAN metadata

FRR's EVPN-MH logic expects a VLAN-aware bridge association between access
ports, VXLAN and VNI. Grout's bridge model is VLAN-abstracted and commonly uses
VLAN 0 at its FDB API boundary.

The prototype in `frr/if_grout.c` reports one bounded synthetic VLAN for a Grout
bridge and its members, then translates it back to VLAN 0 when programming
Grout. This lets FRR form the ES-to-VNI relationship and advertise per-ES and
per-EVI Type-1 routes.

Remaining requirements:

- allocate the synthetic VLAN per bridge namespace without deriving it from an
  interface ID that may exceed 4094;
- test add, update, delete and replay ordering;
- prove two or more bridges cannot collide;
- keep the translation private to the provider boundary;
- document behavior if actual guest VLAN trunks are added.

### 13.3 FRR Layer-2 nexthop dataplane patch

FRR 10.6.1's EVPN-MH code normally calls Linux netlink-specific functions
directly for FDB nexthops and MAC ECMP groups. A non-kernel provider may not
initialize the required kernel command socket, which caused Zebra failure.

`subprojects/packagefiles/frr/10.6-zebra-route-EVPN-MH-L2-nexthops-through-dplane.patch`
changes those operations to use the ordinary Zebra dataplane queue while
retaining:

- FRR's typed Layer-2 nexthop IDs;
- VTEP address and group-member data for non-kernel providers;
- Linux provider behavior, including `NHA_FDB` encoding.

The architectural principle is important: FRR should expose an implementation-
neutral dataplane object. It should not call Grout-specific code from
`zebra_evpn_mh.c`.

Before an upstream FRR PR, add provider/topotests for:

- IPv4 and IPv6 VTEPs;
- group install, update and delete;
- delete-before-member and member-before-group ordering;
- provider failure/status propagation;
- Linux netlink `NHA_FDB` encoding;
- regression of existing Linux EVPN-MH topologies.

### 13.4 Grout L2 nexthops and MAC ECMP

The fork adds:

- `GR_NH_T_L2`, representing a remote VTEP used by a Layer-2 group;
- optional `nhg_id` on an external FDB entry;
- FRR provider translation from L2 NH/NHG contexts to Grout objects;
- bridge datapath resolution of the current group by ID;
- stable flow hashing using hardware RSS when available and software Toeplitz
  otherwise.

Resolving the group by ID at packet time avoids retaining a stale FDB pointer
when FRR deletes and recreates a group. Group and policy changes use existing
Grout lifetime/RCU patterns.

Remaining work:

- focused create/replace/delete ordering tests;
- behavior when a group temporarily has zero members;
- explicit counters for invalid or missing groups;
- review of weighted-group behavior for equal carrier members;
- mixed local/remote group support if the any-host 20 Gb/s requirement remains
  mandatory.

### 13.5 Bridge-port policy

The fork adds a replace-only `GR_BRIDGE_PORT_SET` API with:

- `GR_BRIDGE_PORT_F_NON_DF`;
- backup NHG ID;
- bounded peer-VTEP split-horizon filters.

`frr/zebra_dplane_grout.c` consumes `DPLANE_OP_BR_PORT_UPDATE` and writes the
policy. `modules/l2/datapath/bridge_input.c` and `bridge_flood.c` enforce it.
`grcli bridge-port show` exposes the installed state.

Remaining work:

- reset/delete semantics when FRR removes an ES;
- replay after Zebra reconnect;
- policy cleanup when a member or bridge is deleted first;
- IPv6 VTEP functional coverage;
- capacity behavior if FRR supplies more than the current bounded filter count;
- provenance-aware transit if distributed ES egress is added.

### 13.6 MAC reconciliation patch

A MAC learned before its interface becomes an ES member is initially linked to
the access interface, not the ES. FRR's original ES lifecycle flush walks only
the ES MAC list, so the stale MAC can continue to be advertised without an ESI.
Remote PEs then cannot form the correct all-active group.

`subprojects/packagefiles/frr/10.6-zebra-reconcile-EVPN-MH-interface-MACs.patch`
also flushes local MACs linked directly to the interface on ES attach/detach.
The dataplane relearns them with current ES forwarding information.

The three-node lab deliberately learns a carrier MAC before ES configuration,
then proves it is removed and relearned with a remote two-member NHG.

Upstream review must determine whether the interface walk belongs in FRR core,
whether iteration remains safe when flush mutates lists, and which FRR branches
need the change.

### 13.7 Interface protodown API

Add a Grout API that targets an individual LACP member and separates:

- physical/admin link state;
- LACP protocol participation;
- data collecting;
- data distributing;
- operator/FRR suppression reason.

Suggested public shape, subject to API review:

```c
struct gr_bond_member_state_set_req {
    uint16_t bond_iface_id;
    uint16_t member_iface_id;
    bool protodown;
    uint32_t reason;
};
```

The internal bond active-member table must be replaced atomically. Ingress
classification must still divert LACP slow-protocol frames to the LACP control
node while rejecting ordinary data on a suppressed member.

### 13.8 Vhost-user lifecycle support

Although the generic port API can probe `net_vhost`, productization requires:

- deterministic, validated devargs construction;
- a stable API/CLI abstraction that does not make OpenNebula compose arbitrary
  DPDK strings;
- client reconnect and link-state tests;
- multiple queue support and queue-state events;
- QEMU stop/start without Grout restart;
- socket ownership and SELinux policy;
- live-migration dirty-page/logging compatibility;
- port pre-creation before the QEMU frontend exists;
- safe deletion while queues are inactive;
- metrics tying VM ID/NIC ID to Grout port without putting untrusted labels in
  high-cardinality telemetry.

A dedicated interface type may eventually be cleaner than a generic port
devarg. The first tranche may wrap the generic PMD to minimize code, but the
external OpenNebula contract should remain stable if the internal type changes.

### 13.9 Reconciliation and restart model

Grout and FRR must tolerate either process starting first. The provider already
contains synchronization machinery for replaying state, but EVPN-MH adds
ordering-sensitive objects:

1. interfaces and bridge membership;
2. synthetic VLAN/VNI metadata;
3. ES association;
4. L2 VTEP nexthops;
5. nexthop groups;
6. external FDB entries referencing groups;
7. bridge-port policy referencing backup groups;
8. local learned MACs.

Reconciliation must be dependency-aware and idempotent. A missing dependency
should defer an object or install a safe drop state, never dereference stale
memory or silently fall back to a looping path.

The current namespace-local test launcher cannot yet reproduce WatchFRR's
phased dependency restart and integrated configuration replay reliably. A
dedicated restart wrapper is needed before daemon restart becomes gating.

---

## 14. Current branch state and evidence

### 14.1 Branch history

The work is split into reviewable development branches:

| Branch/commit | Scope |
| --- | --- |
| `alma9-evpn-mh-poc` / `2df91f66` | AlmaLinux lab, FRR L2 dplane patch, L2 VTEP/NHG, MAC ECMP, initial plan |
| `evpn-mh-df-split-horizon` / `8c6ec7cd` | Bridge-port policy, DF/BUM enforcement, split horizon, local bias |
| `evpn-mh-lifecycle` / `b2c6f24b` | Pre-ES MAC reconciliation and lifecycle smoke coverage |

The active branch is published at `origin/evpn-mh-lifecycle`.

### 14.2 Lab topology

`smoke/evpn_three_node_frr_test.sh` creates:

- three independent Grout processes;
- three independent FRR stacks;
- Linux network namespaces for isolation;
- TAP-backed DPDK ports;
- a Linux bridge as the shared test underlay;
- a Linux carrier bond as the LACP peer;
- host namespaces that generate and receive service traffic.

This environment can test protocol and functional dataplane behavior entirely
inside one development machine. It cannot validate X710/X722 performance,
PCIe/IOMMU behavior, real optics, hardware queue scaling, NUMA effects or QEMU
live migration.

### 14.3 Demonstrated capabilities

| Capability | State | Evidence/qualification |
| --- | --- | --- |
| AlmaLinux 9.8 arm64 build | Pass | Grout, bundled DPDK and FRR 10.6.1 build natively with generic CPU target. |
| Unit suite | Pass | 12 Meson unit tests, including flow hash and bridge policy. |
| Three-node BGP EVPN | Pass | EVPN peers establish and exchange routes. |
| VXLAN bridge | Pass | Bidirectional host traffic crosses node 1 to node 3. |
| Split-chassis carrier LACP | Pass | Linux carrier selects both Grout links in one aggregator with a shared system MAC. |
| Local ES | Pass | FRR reports local ES up and bridge-port capable. |
| Type-4 route | Pass | ES route exchanged. |
| Type-1 routes | Prototype pass | Per-ES and per-EVI routes received without Zebra crash. |
| L2 NH/NHG provider handoff | Prototype pass | FRR typed L2 VTEPs and group installed in Grout. |
| Remote MAC ECMP | Prototype pass | 64 UDP flows use both remote PEs. |
| Member withdrawal/recovery | Prototype pass | Remote NHG collapses to one member and restores. |
| DF preference change | Prototype pass | BUM egress follows live DF change. |
| Split horizon | Prototype pass | Injected peer-VTEP traffic is suppressed toward ES. |
| Local-bias redirect | Prototype pass | ES hairpin redirects through backup NHG. |
| Pre-ES MAC reconciliation | Prototype pass | Stale local entry is flushed and remote two-member NHG forms. |
| Uplink/protodown | Missing | Provider does not implement the required interface update behavior. |
| Zebra phased restart | Harness gap | Retained state exists, but dependency restart/replay is not a gating test. |
| VM vhost attachment | Not tested | Driver is compiled; product lifecycle absent. |
| Live migration | Not tested | No QEMU/OpenNebula migration lab yet. |
| Any-host 20 Gb/s | Not proven | Remote-host path distribution passes; local-bias case remains. |
| x86 SE350/X710 | Not tested | Physical lab required. |

### 14.4 Important source locations

| Area | Files |
| --- | --- |
| Development evidence | `docs/evpn-mh-development.md` |
| AlmaLinux build environment | `devtools/alma9.sh`, `devtools/alma9/Containerfile`, `devtools/alma9/README.md` |
| Three-node functional lab | `smoke/evpn_three_node_frr_test.sh` |
| Split-chassis LACP probe | `smoke/evpn_mh_lacp_test.sh` |
| FRR interface/VLAN representation | `frr/if_grout.c` |
| FRR route/FDB/NHG translation | `frr/rt_grout.c` |
| FRR provider operations | `frr/zebra_dplane_grout.c` |
| FRR L2 dplane patch | `subprojects/packagefiles/frr/10.6-zebra-route-EVPN-MH-L2-nexthops-through-dplane.patch` |
| FRR MAC reconciliation patch | `subprojects/packagefiles/frr/10.6-zebra-reconcile-EVPN-MH-interface-MACs.patch` |
| L2 public API | `modules/l2/api/gr_l2.h` |
| Bridge-port control/API | `modules/l2/control/bridge_port.c`, `modules/l2/cli/bridge_port.c` |
| Bridge forwarding policy | `modules/l2/datapath/bridge_input.c`, `modules/l2/datapath/bridge_flood.c` |
| L2 nexthop type | `modules/infra/control/l2_nexthop.c`, `modules/infra/api/gr_nexthop.h` |
| Flow hashing | `modules/infra/datapath/flow_hash.c`, `modules/infra/datapath/flow_hash_test.c` |
| LACP/bond | `modules/infra/control/lacp.c`, `modules/infra/control/bond.c`, `modules/infra/datapath/bond_output.c` |
| DPDK port/vhost probe path | `modules/infra/control/port.c`, `meson.build` |

---

## 15. Development plan and pull-request tranches

Each tranche should remain independently reviewable. Grout changes and FRR
changes should be separated where possible.

### Tranche A: harden current EVPN representation

Deliverables:

1. bounded synthetic VLAN allocation and translation;
2. add/update/delete/replay tests for bridge metadata;
3. FRR L2 NH/NHG provider tests and Linux netlink regression tests;
4. Grout L2 NHG create/replace/delete-order unit tests;
5. bridge-port policy delete/restart tests;
6. upstream issue/PR preparation with each FRR patch rebased to a supported
   FRR release.

Exit criteria:

- no static FDB fixture required;
- no Zebra crash with the Grout provider;
- repeated add/delete cycles leave no object or reference leak;
- current three-node smoke test remains green.

### Tranche B: implement safe protodown and failure convergence

Deliverables:

1. Grout bond-member suppression API;
2. ingress/egress datapath enforcement while LACP PDUs continue;
3. provider mapping for relevant `DPLANE_OP_INTF_UPDATE` state;
4. carrier-link, fabric-link and BGP/FRR loss tests;
5. recovery tests proving the carrier member renegotiates and returns to the
   hash only when safe;
6. reason/state counters and CLI output.

Exit criteria:

- no black-hole member remains collecting/distributing;
- no loss of LACP recovery path;
- remote MAC groups withdraw and restore correctly;
- failure loops run repeatedly without stale state.

### Tranche C: daemon restart and reconciliation

Deliverables:

1. namespace-aware phased FRR restart wrapper;
2. Zebra-only, bgpd-only, FRR-stack and Grout restart tests;
3. dependency-ordered replay assertions;
4. cleanup behavior for deleted bridges, groups and ES policy;
5. restart storm/backoff test.

Exit criteria:

- retained Grout forwarding is either correct or fails closed;
- restored control plane converges without manual flush;
- no persistent duplicate BUM or loop;
- all restart scenarios produce actionable diagnostics.

### Tranche D: resolve the 20 Gb/s any-host architecture gate

Deliverables:

1. benchmark standard EVPN behavior from all three source hosts;
2. prototype the recommended provenance-aware mixed local/remote egress group;
3. in parallel or as a short spike, test transparent dual circuits with LACP
   terminated in 6WIND;
4. record complexity, interoperability, failure and performance results;
5. architecture decision record selecting one model.

Exit criteria:

- packet captures prove both carrier members are used for VM-origin known
  unicast from every host;
- ES-origin reflection is still blocked;
- a single flow remains ordered;
- member failure collapses safely;
- humans approve the non-standard behavior or select guest LACP.

This tranche is a product gate. It should precede extensive OpenNebula work so
the VM NIC model is not built around an unchosen architecture.

### Tranche E: Grout vhost-user product interface

Deliverables:

1. controlled vhost-user port API/wrapper;
2. client reconnect and multiqueue behavior;
3. QEMU/libvirt smoke environment with a DPDK or Linux virtio guest;
4. guest reboot, QEMU restart, socket deletion and recreate tests;
5. hugepage/NUMA and feature-profile validation;
6. metrics and safe socket permissions.

Exit criteria:

- VM forwards through a Grout bridge at multi-queue rates;
- QEMU restart reconnects without Grout restart;
- no stale socket/port remains after repeated lifecycle loops;
- source and destination can create identical endpoints.

### Tranche F: libvirt/OpenNebula live migration

Deliverables:

1. two-host QEMU/libvirt migration harness before OpenNebula coupling;
2. continuous TCP, UDP and routing-adjacency traffic probes;
3. migration preflight and rollback hooks;
4. Grout virtual-network driver or equivalent integration;
5. OpenNebula template/profile and scheduler labels;
6. three-way migration matrix: 1→2, 1→3, 2→1, 2→3, 3→1, 3→2;
7. repeated round-robin soak test.

Exit criteria:

- accepted interruption SLO passes in both directions for every host pair;
- no guest reset, TCP reset or manual network action;
- MAC mobility converges and old host state is cleaned;
- rollback cases leave one correct attachment.

### Tranche G: SE350/X710 physical qualification

Deliverables:

1. hardware inventory and support exception decision;
2. AlmaLinux 9.8 x86_64 packages;
3. VFIO/IOMMU, hugepage and NUMA configuration;
4. real triangle underlay and physical carrier LACP peer;
5. optical/link failure matrix;
6. line-rate and packet-size performance matrix;
7. migration under idle, moderate and near-saturation load;
8. thermal and 24-hour/longer soak tests.

Exit criteria:

- hardware meets the accepted throughput and migration SLO;
- every single-link and single-host failure is characterized;
- no unsupported optic/firmware/thermal issue remains unresolved;
- operational runbook and rollback are approved.

### Tranche H: release engineering and operations

Deliverables:

1. signed/versioned RPMs and configuration schema;
2. service ordering and health probes;
3. SELinux policy;
4. monitoring dashboards and alerts;
5. site configuration generator and validation;
6. upgrade/rollback procedure that preserves one carrier member;
7. production acceptance report.

---

## 16. Test strategy

### 16.1 Test pyramid

**Unit tests**

- flow-hash behavior and RSS precedence;
- L2 NH/NHG lifetime and reference ordering;
- mixed local/remote selection if implemented;
- bridge-port policy validation and replacement;
- protodown LACP state transitions;
- VLAN translation bounds;
- vhost devarg/path validation.

**Single-process functional tests**

- port, bond, bridge, VXLAN and FDB API operations;
- policy cleanup on interface deletion;
- vhost connect/disconnect and queue-state events.

**Three-node namespace tests**

- BGP EVPN route exchange;
- carrier LACP aggregation;
- Type-1/Type-4 and MAC aliasing;
- DF changes and split horizon;
- local/remote egress from all three host positions;
- link and daemon failure/recovery;
- configuration-order permutations.

**QEMU/libvirt tests**

- multiqueue virtio/vhost traffic;
- QEMU restart/reconnect;
- live migration and rollback;
- MAC mobility;
- guest protocol continuity.

**GNS3 tests**

GNS3 is not required for the current Grout/FRR implementation gaps. It becomes
useful for carrier/router images, unusual LACP timer behavior, vendor-specific
trunks, topology demonstrations and peer review. It does not replace DPDK
physical performance testing.

**Physical tests**

- real X710/X722 PMDs and queues;
- real LACP peer/carrier handoff;
- optic/link and PCI function failures;
- line rate, latency, loss and thermals;
- migration while forwarding.

### 16.2 Required traffic profiles

At minimum, test:

- 64-byte, 128-byte, 512-byte, 1,500-byte and maximum-service-MTU frames;
- IPv4 and IPv6;
- TCP and UDP;
- one flow, 64 flows, 1,024 flows and a realistic production distribution;
- symmetric and asymmetric direction mixes;
- tagged and untagged behavior as contracted;
- BUM at controlled rates;
- large guest routing tables if representative;
- checksum/segmentation offloads on and off where supported.

For each, record offered load, received load, packet loss, p50/p99 latency,
jitter, reorder count, Grout worker utilization, 6WIND worker utilization,
queue drops, NIC errors and migration downtime.

### 16.3 Failure matrix

| Failure | Expected outcome |
| --- | --- |
| One carrier optic/cable | LACP member withdraws; service remains on surviving 10 Gb/s member |
| One fabric link | Reachability reconverges; capacity may degrade; no loop |
| One carrier PE host | Its carrier member and EVPN paths withdraw; service remains through other PE |
| Remote VM host failure | Outside planned migration scope; OpenNebula HA policy decides restart; no false claim of live migration |
| FRR bgpd restart | Existing safe dataplane state retained/reconciled; no persistent loop |
| Zebra restart | Objects replay in dependency order |
| Grout restart | Carrier/fabric forwarding interruption measured; FRR resynchronizes |
| QEMU/guest reboot | vhost reconnects; physical carrier LACP unaffected |
| Migration abort before cutover | Source remains active; destination state cleaned |
| Migration failure after cutover | Exactly one active attachment recovered according to QEMU/OpenNebula state |
| Both carrier members lost | Service declared down; no stale advertisements suggesting usable local attachment |
| Control/management loss | Existing dataplane behavior documented; operations alert |

### 16.4 Soak and repetition

One successful convergence is insufficient. Gating tests SHOULD repeat:

- link down/up at least 100 cycles in software and 20 cycles on hardware;
- ES attach/detach and MAC relearn at least 100 cycles;
- Zebra/FRR restart at least 50 cycles;
- vhost/QEMU reconnect at least 100 cycles;
- round-robin live migration at least 50 completed migrations;
- sustained multi-flow forwarding for at least 24 hours before release.

Thresholds may be adjusted after runtime is known, but repetition must remain a
release gate.

---

## 17. Acceptance criteria

### 17.1 Functional acceptance

The system is functionally accepted only if:

1. each configured carrier forms one two-member LACP aggregator across two
   SE350s;
2. a 6WIND VM reaches every required carrier VLAN from each host;
3. Type-1, Type-2, Type-3 and Type-4 routes appear as expected;
4. both remote VTEPs are installed for an all-active MAC;
5. DF changes gate BUM correctly;
6. split horizon prevents reflection under packet-capture verification;
7. carrier and fabric link failures converge without a persistent loop;
8. restart and configuration reordering require no static FDB workaround;
9. vhost disconnect/reconnect requires no Grout restart;
10. all OpenNebula lifecycle operations clean up idempotently.

### 17.2 Performance acceptance

Final numerical payload thresholds require the SE350 CPU SKU and production
traffic profile. At minimum:

- two carrier members MUST carry meaningful traffic in both directions for a
  multi-flow workload from each possible VM host;
- aggregate throughput SHOULD approach the practical two-port limit for
  1,500-byte multi-flow traffic with zero sustained loss;
- single-flow results MUST be reported separately and are expected to be at
  most one member's capacity;
- 64-byte packet-rate limitations MUST be reported, not hidden behind a bit-rate
  headline;
- CPU or queue saturation point MUST be known before production sizing.

### 17.3 Migration acceptance

For all six source/destination pairs and the actual 6WIND image:

- migration completes without guest reboot;
- established TCP flows and designated routing sessions survive;
- interruption meets the ratified SLO;
- UDP loss/reordering is within the ratified threshold;
- traffic uses correct paths after MAC mobility convergence;
- no stale source vhost port, socket or FDB remains;
- failed/aborted migration cases restore one correct attachment;
- carrier LACP remains established throughout.

### 17.4 Operational acceptance

- dashboards expose per-host and per-service health;
- an operator can identify the DF, ES peers, LACP members, active NHG members,
  MAC location, vhost state and packet-drop reason;
- alerting detects one-member operation, EVPN peer loss, protodown, queue drops,
  migration incompatibility and configuration drift;
- a documented staged rollback has been executed in the lab;
- hardware and software bills of material are versioned.

---

## 18. Risks, constraints and open decisions

| ID | Risk/decision | Impact | Required action |
| --- | --- | --- | --- |
| R-001 | X710-DA4 is not in the reviewed Lenovo supported-adapter list | Support, fit, thermals or optics may fail | Validate actual hardware and record accepted exception or choose supported NIC |
| R-002 | Standard local bias may limit egress to 10 Gb/s on an attached PE | Violates any-host throughput goal | Complete architecture Tranche D |
| R-003 | Fabric has no headroom at nominal 20 Gb/s | Migration and failures contend/degrade | Define QoS/rate limit, add capacity, or narrow promise |
| R-004 | FRR patches are not upstream | Rebase/maintenance burden | Add FRR tests and pursue upstream review |
| R-005 | Synthetic VLAN mapping is a compatibility shim | Multi-bridge/trunk edge cases | Bound allocation and add lifecycle tests |
| R-006 | Split-horizon filter is currently peer-VTEP based | Custom transit may be blocked or unsafe | Add explicit provenance design; never broadly disable filtering |
| R-007 | Protodown missing | Isolated PE can black-hole carrier traffic | Implement before hardware pilot |
| R-008 | vhost is compiled but lifecycle unproven | Migration may fail or leak state | Build QEMU harness before OpenNebula integration |
| R-009 | “Seamless” has no ratified number | Acceptance disagreement | Approve interruption/loss/reorder SLO |
| R-010 | 6WIND exact release/features unknown | Virtio queues, offloads or LACP may differ | Record image/version and test its supported configuration |
| R-011 | Carrier handoff/VLAN details incomplete | Incorrect port/VNI/MTU design | Collect LOA/CFA and service technical schedules |
| R-012 | AlmaLinux 9.8 may age during development | Security/support and package drift | Define supported OS minor/version policy and retest upgrades |
| R-013 | Three hosts are both compute and network failure domains | Maintenance can reduce service capacity | Define drain order and minimum healthy network nodes |
| R-014 | Grout is an example/reference network function upstream | Production support burden rests on this project | Establish ownership, review and release maintenance model |

### 18.1 Decisions required before implementation proceeds too far

1. Is 20 Gb/s aggregate from a VM on either carrier-attached PE a hard
   requirement, or is 10 Gb/s acceptable in that placement?
2. If it is hard, should Grout implement provenance-aware distributed egress or
   should 6WIND terminate LACP over two transparent virtual circuits?
3. Is reduced throughput during migration/fabric failure acceptable?
4. What numerical migration interruption, UDP loss and reorder SLO is required?
5. Which exact 6WIND release/image and licensing model will be tested?
6. Are carrier services delivered as trunks, separate ports, or mixed?
7. Is the X710-DA4 hardware exception acceptable to the business and hardware
   support owner?
8. Which underlay routing design and MTU will be standardized?
9. Which OpenNebula release, storage backend and libvirt/QEMU versions are in
   scope?
10. Who owns the FRR fork if upstream does not accept the patches?

---

## 19. Operations and observability design

### 19.1 Minimum telemetry

Per physical port:

- link, speed, optic/DOM where available;
- RX/TX packets/bytes/errors/drops;
- queue-level drops and mbuf starvation;
- driver and firmware identity.

Per LACP member/bond:

- actor/partner system, key and port;
- synchronized, collecting and distributing flags;
- last PDU receive/transmit;
- active/suppressed reason;
- hash distribution.

Per EVPN service:

- ESI, VNI, route target and DF;
- Type-1/Type-2/Type-3/Type-4 counts;
- peer VTEPs and backup NHG;
- local/remote FDB entries and age;
- split-horizon and non-DF drop counters;
- local/remote distributed-egress selections if implemented.

Per VM attachment:

- OpenNebula VM/NIC identity;
- socket and Grout interface identity;
- link and queue state;
- negotiated features and queue count;
- current host/NUMA placement;
- reconnect count and last transition;
- migration phase and last result.

### 19.2 Health state

A host SHOULD expose one aggregate network profile state:

- `READY`: eligible for deploy/migrate;
- `DEGRADED`: service forwarding continues but no new VM placement;
- `DRAINING`: planned evacuation; physical network remains active as required;
- `UNSAFE`: carrier member must be suppressed/protodown;
- `INCOMPATIBLE`: package/config/feature hash differs from cluster profile.

The scheduler must treat only `READY` as eligible. Health must not be inferred
solely from the Grout process being alive.

### 19.3 Configuration source of truth

A site configuration should define:

- host IDs, management addresses and PCI BDF mapping;
- fabric links, point-to-point addresses and VTEP loopbacks;
- carriers, handoff hosts/ports and LACP attributes;
- ESIs, VNIs, route distinguishers/targets and VLANs;
- VM service attachment profiles;
- queue/CPU/NUMA allocation;
- migration and monitoring thresholds.

Generated FRR, Grout and OpenNebula configuration MUST share a schema version
and content hash. Hand-edited production drift should be detected and rejected
or deliberately imported.

---

## 20. Security considerations

- Carrier VLANs MUST be allow-listed; no service may gain access to another
  carrier trunk through an unvalidated tag.
- Grout's control Unix socket and vhost sockets MUST have least-privilege file
  ownership and SELinux labels.
- OpenNebula hooks MUST not interpolate untrusted template data into commands.
- FRR control sessions SHOULD use the site's normal authentication and control-
  plane protection policy.
- Management and migration endpoints MUST not listen on carrier VLANs.
- Debug packet capture must be access-controlled because carrier traffic may
  contain customer data.
- Core dumps and logs must not expose packet contents by default.
- Configuration changes that affect both members of one carrier LAG MUST be
  serialized with a health check between hosts.
- A compromised guest must not be able to create arbitrary vhost sockets,
  Grout interfaces, VLAN membership or DPDK devargs.

---

## 21. Handoff instructions for the next engineer or agent

### 21.1 Establish the repository state

1. Work in the `hcaldicott/grout` fork.
2. Check out `evpn-mh-lifecycle` at or after `b2c6f24b`.
3. Do not remove or overwrite the workspace's unrelated untracked `tmp/`
   directory.
4. Review `docs/evpn-mh-development.md` and this specification before editing.
5. Compare the branch to `upstream/main`; the full effort spans multiple stacked
   branches, not only the last lifecycle commits.

### 21.2 Reproduce the present evidence

Use the AlmaLinux development wrapper documented in `devtools/alma9/README.md`.
The functional lab needs privileges for network namespaces, TAP devices and
FRR. Run the existing unit suite, the split-chassis LACP probe and the
three-node EVPN-MH smoke test before changing object models.

Do not interpret arm64 TAP results as throughput results. Repeat release
candidates on `linux/amd64` before physical SE350 testing.

### 21.3 Recommended immediate next task

The next bounded implementation task is Tranche B's protodown API because it is
well-scoped, release-blocking and independent of the final VM termination
choice. In parallel at the architecture level, settle Tranche D before building
the complete OpenNebula contract.

Suggested protodown test-first sequence:

1. add a unit-testable bond member suppression state;
2. prove normal frames are excluded from ingress and egress;
3. prove LACP frames still pass;
4. prove the member leaves and rejoins the active redirection table;
5. expose state through API/CLI;
6. map the FRR interface update;
7. add three-node fabric-isolation and recovery smoke cases.

### 21.4 Review discipline

- Keep FRR patches generic and independently reviewable.
- Avoid encoding Grout-specific callbacks in FRR EVPN core.
- Add failure/delete-order tests with every new cross-object reference.
- Use RCU/QSBR patterns already present in Grout; never publish partially built
  dataplane state.
- Treat missing policy or missing NHG as a safe failure, not permission to
  forward around split horizon.
- Update the capability table in this document and
  `docs/evpn-mh-development.md` only after a repeatable test passes.
- Record exact commands, commit IDs and logs for physical acceptance.

---

## 22. Human peer-review checklist

### Architecture

- [ ] Does the selected LACP termination model satisfy 20 Gb/s from all three
  VM placements?
- [ ] Is access-origin versus ES-origin provenance unambiguous and loop-safe?
- [ ] Is the routed triangle acceptable, including degraded capacity?
- [ ] Is migration contention explicitly handled?
- [ ] Are carrier VLAN and MTU contracts complete?

### FRR

- [ ] Is the L2 NH/NHG dataplane abstraction suitable for upstream?
- [ ] Does the Linux provider retain identical behavior?
- [ ] Is interface MAC reconciliation safe and generally correct?
- [ ] Are Type-1/Type-4, DF, aliasing and mass-withdrawal cases covered?
- [ ] Is protodown mapped to correct EVPN-MH semantics?

### Grout/DPDK

- [ ] Are group and policy lifetimes safe under deletion/replay?
- [ ] Is the flow hash stable and well distributed?
- [ ] Does split horizon fail closed?
- [ ] Can vhost ports reconnect and migrate with identical features?
- [ ] Are queues, hugepages and NUMA placement sufficient for the target?

### OpenNebula/6WIND

- [ ] Is the exact OpenNebula/libvirt/QEMU/6WIND version matrix recorded?
- [ ] Are source and destination host capabilities positively matched?
- [ ] Are prepare, commit and rollback hooks idempotent?
- [ ] Does 6WIND preserve sessions and use all configured queues?
- [ ] Are guest protocol timers compatible with the migration SLO?

### Hardware and operations

- [ ] Is the X710-DA4 configuration physically and commercially accepted?
- [ ] Are optics/BiDi directions and transceiver support confirmed?
- [ ] Can an operator diagnose every single-failure case?
- [ ] Are upgrades serialized so both LAG members are never withdrawn together?
- [ ] Has the full soak, failure and migration matrix passed?

---

## 23. References

Primary external references used for platform assumptions:

1. [Lenovo ThinkSystem SE350 Edge Server Product Guide](https://lenovopress.lenovo.com/lp1168-thinksystem-se350-edge-server) — integrated network-module ports, PCIe expansion and Lenovo-listed adapter options.
2. [FRR EVPN documentation](https://docs.frrouting.org/en/latest/evpn.html) — all-active Layer-2 EVPN multihoming, LACP Ethernet Segments and EVPN service model.
3. [OpenNebula 7.0 Open vSwitch networks](https://docs.opennebula.io/7.0/product/cluster_configuration/networking_system/openvswitch/) — existing OpenNebula representation of DPDK vhost-user, virtio, hugepages and shared guest memory.
4. [OpenNebula 7.0 VM instances](https://docs.opennebula.io/7.0/product/virtual_machines_operation/virtual_machines/vm_instances/) — live-migration operation and datastore constraint.
5. [OpenNebula 7.0 clusters](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/cluster_guide/) — host compatibility expectations for live migration.
6. [DPDK 24.11 vhost-user live-migration guide](https://doc.dpdk.org/guides-24.11/howto/lm_virtio_vhost_user.html) — DPDK/virtio/vhost-user migration model.
7. [DPDK 24.11 vhost library documentation](https://doc.dpdk.org/guides-24.11/prog_guide/vhost_lib.html) — client reconnect and post-copy capabilities.
8. [6WIND Turbo Router overview](https://doc.6wind.com/turbo-router-2.x/overview.html) — virtual-machine deployment, DPDK I/O and virtio/SR-IOV attachment options.

Repository-specific references:

- `README.md`
- `docs/grout-frr.7.scdoc`
- `docs/evpn-mh-development.md`
- source and test files listed in section 14.4.

---

## Appendix A: proposed per-service configuration record

```yaml
site: dc-example
service: virtutel-transit
carrier:
  name: Virtutel
  handoff_mode: lacp-trunk
  actor_system_mac: "02:00:5e:35:00:01"
  actor_key: 101
  lacp_rate: fast
  members:
    - host: se350-1
      port: carrier-0
    - host: se350-2
      port: carrier-0
evpn:
  esi: "00:00:01:00:01:00:01:00:00:00"
  vni: 10101
  route_target: "65000:10101"
  service_vlan: 101
guest:
  presentation: trunk
  allowed_vlans: [101]
  mtu: 1500
  queues: 4
migration:
  interruption_slo_ms: 100
  max_bandwidth_mbps: 2000
```

All values above are examples. MACs, ESIs, ASNs, route targets, VLANs, VNIs,
queues and bandwidth limits MUST come from the approved site data model.

## Appendix B: known physics and protocol limits

1. Two 10 GbE members provide 20 Gb/s nominal aggregate capacity, not a 20 Gb/s
   single-flow pipe.
2. Ethernet/IP/VXLAN/virtio overhead means application payload throughput is
   below nominal line rate.
3. LACP distribution depends on both ends' hash and the available flow entropy.
4. A failed 10 GbE member normally leaves at most 10 Gb/s carrier capacity.
5. A host with exactly two 10 GbE fabric links has no line-rate headroom while
   receiving or transmitting 20 Gb/s aggregate through the fabric.
6. Live migration always has a finite switchover; “seamless” is an SLO, not a
   zero-time event.
7. DPDK acceleration removes kernel forwarding from the bulk path but does not
   remove CPU, memory-bandwidth, PCIe, queue or NUMA limits.
8. Standards-based EVPN-MH does not by itself guarantee the product-specific
   mixed local/remote egress behavior required to use both carrier members from
   a co-located access VM.

## Appendix C: current evidence versus product claim

```text
PROVEN IN SOFTWARE LAB
  FRR EVPN control plane
  split-chassis LACP interoperability with Linux peer
  remote two-VTEP MAC ECMP
  DF/BUM policy and preference change
  peer-VTEP split horizon
  local-bias backup redirection
  member withdrawal/recovery
  pre-ES MAC reconciliation

NOT YET PROVEN
  safe interface protodown/uplink tracking
  daemon restart/replay as a gating test
  20 Gb/s from a VM on either attached PE
  QEMU/6WIND vhost-user attachment
  live migration and rollback
  OpenNebula integration
  SE350/X710 hardware behavior
  physical line-rate performance
  real carrier interoperability
  production operations and upgrade safety
```

No review or status report should collapse the second list into the first.
