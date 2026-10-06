# 01 — Architecture, contracts and scope

## 1. Chosen design and what is still hypothetical

Use QEMU's existing `igb` PCI PF/VF model as a **PCI carrier**, not its native
network datapath. Bind custom guest PF and VF drivers. Linux sees genuine emulated
PCI functions; packets are switched in guest kernel memory. QEMU already exposes
SR-IOV in this device model, and upstream operator/kcli virtual test infrastructure
uses it. The combination with these custom drivers is a design proposal until
K02 proves it. [S01, S02, S03]

An unchanged `pci-testdev` lacks the needed SR-IOV device model. Adding a driver
`sriov_configure` callback cannot manufacture it. Do not create imitation PCI
sysfs directories or change `struct pci_dev` flags to pretend capability exists.
`pci_enable_sriov()` relies on real PCI-core state and device config-space behavior.
[S03, S04]

Use Intel-emulation identity as-is (`8086:10c9` PF, `8086:10ca` VF, verified in the
DUT). The module must not claim to implement the Intel register datapath or Mellanox
firmware. Vendor masquerading is unnecessary and can activate unrelated firmware
management. The generic operator path, the supported-NIC test configuration and
the driver's truthful PCI/netlink/devlink behavior are the compatibility targets.
[S01, S05]

## 2. Devices and topology

Single PF, two VFs initially. More VFs are a later repeat of the same contracts.

```text
QEMU/KVM VM
  management virtio NIC -------- SSH, Kubernetes control traffic (untouched)
  emulated igb PCI PF ---------- mock_smartnic_pf
      virtfn0 PCI VF ----------- mock_smartnic_vf -> VF0 netdev -> pod A/net1
      virtfn1 PCI VF ----------- mock_smartnic_vf -> VF1 netdev -> pod B/net1

  mock PF/uplink netdev -------- operator-created OVS bridge
  VF0 representor -------------- ovs-cni-created OVS port
  VF1 representor -------------- ovs-cni-created OVS port

  OVS -> TC flower -> driver match/action engine -> peer VF receive
```

There are five netdevs for this topology: PF/uplink, two VF endpoints and two
representors. VF endpoints have their VF PCI device as parent; representors are
software netdevices associated with devlink ports, not fake VF PCI endpoints.
Keep exactly one PCI-parented netdev per PF/VF so `/sys/bus/pci/devices/BDF/net`
and `ovs-cni` discovery remain unambiguous. [S06, S07]

The PF/uplink exists in legacy and switchdev mode. A physical-flavour devlink port
represents the single synthetic uplink, not a separate PF representor. PCI-VF ports
use pfnum=0 and vfnum=0..N-1, a common per-PF switch ID, unique indexes and stable
identity across unbind/rebind. Use the target kernel's devlink association API;
modern upstream identifies representors through `SET_NETDEV_DEVLINK_PORT`.
Do not implement deprecated callbacks just because an old example uses them.
[S06, S08]

## 3. Packet semantics — non-negotiable

In switchdev mode:

| Origin / event | Required behavior |
|---|---|
| VF0 transmit; no rule | Deliver once to rep0 RX (slow path). |
| OVS/software transmits rep1 | Deliver to VF1 RX. Do not inject rep1 RX. |
| rep0-ingress offload rule redirects to rep1 | Match VF0 TX and deliver directly to VF1 RX. |
| Supported drop rule | Consume once, update counters, no slow-path copy. |
| Unsupported rule | Reject installation with extack; normal fallback is then userspace/TC policy's decision. |
| No rule and no OVS/software forwarding | VF0 cannot silently reach VF1. |

These semantics follow the representor contract. A blanket `skb->dev=rep1;
netif_rx(skb)` has the wrong direction for an offloaded redirect. [S06]

Make a small `msnic_deliver_endpoint()` abstraction that handles RX preparation,
namespace metadata, Ethernet protocol/header normalization and ownership. Study
`veth`/`netdevsim` handoff helpers in the **pinned kernel** rather than hand-waving
away checksum/header state. Document whether the skb arrives before or after
`eth_type_trans()` at each function boundary. Never double-pull the L2 header.

A TC miss on VF TX becomes rep RX and may traverse ordinary software TC and OVS.
A terminal fast-path hit must not also enter that slow path. Reject mirror/trap/
continue until duplicate-delivery and continuation semantics are implemented.

## 4. What happens to the physical-looking uplink?

There is no external wire in the same-worker MVP. The mock PF driver does not use
native igb DMA rings; therefore it does not magically reach the QEMU `-netdev`
backend. Give the synthetic uplink a defined isolated-terminal TX behavior: count
and consume frames headed out of the test switch. Unknown/broadcast OVS copies
may reach it. Document this explicit virtual topology; do not claim external
reachability or expose a false tested external-link capability.

The PF remains attachable to OVS for bridge auto-selection. Bringing it UP can
indicate a connected synthetic local switch; distinguish that from a physical
external link in logs/capability documentation. VF-to-VF unicast is the mandatory
traffic test, so it needs no external wire.

An optional later uplink back end uses a **separate test-only** TAP/veth/virtio
path with explicit loop prevention and lifetime handling, never the management
interface. It must implement uplink ingress offload too. Cross-worker reachability
and actual igb register/queue emulation are separate projects.

## 5. Driver identity and VF binding

One module: `mock_smartnic.ko`.

Two PCI drivers:

```text
mock_smartnic_pf: match the selected emulated PF only
mock_smartnic_vf: match only VFs whose pci_physfn() is that selected mock PF
```

Module parameters (read-only after load):

```text
target_pf=0000:00:06.0         # mandatory full BDF; no wildcard default
allow_igb_emulation=1          # explicit lab opt-in, not proof of emulation
```

Reject loading/claiming without the opt-in and BDF; reject VF probe outside this
PF. Register the VF driver first, then the PF driver. Initialize shared PF state
before calling `pci_enable_sriov()` because VF probes can happen during creation.
Use `pci_iov_vf_id()` where supported; do not derive VF index by subtracting BDFs.
The igb model's VF routing offset/stride is not necessarily contiguous. [S03,S04]

The initial manual test sets `sriov_drivers_autoprobe=0`, then binds VFs explicitly.
The operator lane needs `sriov_drivers_autoprobe=1`, the mock VF driver already
registered and native `igbvf` absent/blocked in this dedicated VM. Otherwise the
native VF driver can win and talk to a mock PF that lacks its mailbox protocol.
Do not rely only on a per-VF `driver_override`: the operator's default-driver
binding helper clears it when probing an unbound VF. Test that exact rebind path.
[S04, S09]

The harness uses a reversible, lab-owned blacklist/install override for `igbvf`
and refuses to displace unrelated bound native VFs. If `igbvf` is built in, select
a test kernel with it modular/disabled or move to the distinct-ID QEMU fallback.
Do not blacklist unrelated Intel drivers system-wide on a real host.

## 6. Public feature boundary

Mandatory: PCI SR-IOV lifecycle, PF/VF netdevs, devlink eswitch GET/SET, representor
identity, namespace moves, MTU/MAC/admin state, netlink VF GET and exercised VF
setters, ethtool driver/features, flower block bind/unbind, replace/delete/stats,
a restricted but honest match/action engine and useful diagnostics.

First final-flow workload: IPv4 unicast UDP on untagged VF endpoints, standard
kernel OVS datapath, no bridge controller, no CT rules, no network-policy service
chain. Support OVS's actual flower masks for that flow; inspect the real output.
Expand Ethernet/IP/ports/fragment/TCP-flags parsing as dictated by the pinned OVS
rules. “VLAN omitted” does not guarantee OVS omits VLAN-related match masks: inspect
them and implement untagged matching faithfully or reject them visibly.

Out of scope initially: CT/NAT, tunnel encapsulation, mirroring, metering, complex
chains/recirculation, Linux-bridge FDB offload, VFIO/DPDK datapaths, RDMA, IPsec,
vDPA, physical rate limits, cross-worker links and performance claims. Software
fallback for unsupported features is a useful separate test, not a substitute
for the final positive offload test.

## 7. Why not just netdevsim?

`netdevsim` is useful reference code for netlink/devlink and simulated networking,
but its simulated bus is not a PCI SR-IOV topology. Port creation and flower
acceptance alone do not establish the PCI contracts used by operator/CNI code.
Reuse patterns, not an assumption that it is a complete drop-in. [S10]

## 8. Version/OS boundary

Develop against the **running guest kernel** and its matching headers. Record
QEMU, machine type, kernel package/config, OVS, iproute2, operator source and
component image digests. Use one initial mutable Linux worker with an independent
control plane; a distro name alone does not pin the kernel ABI.

The researched operator commit is
`a5588da21699fccce921cb1d4ac5894f47889399`. Its Kubernetes service integration checks
`/usr/lib/systemd/system/ovs-vswitchd.service` and can request a reboot when
configuring switchdev. This is why persistent binding is a gate, not optional.
An OpenShift/RHCOS worker needs a kernel-matched module deployment method and
MachineConfigPool-aware changes; copying Ubuntu's `.ko` is not a solution.
[S11,S12,S13]
