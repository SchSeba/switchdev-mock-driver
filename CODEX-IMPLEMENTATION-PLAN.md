# Mock SmartNIC — Complete Codex Implementation Handoff

Prepared 23 September 2026.

**This is the single-file edition of the complete implementation plan and lab
harness. The driver itself is not implemented. No VM or Kubernetes runtime test
has been executed.** See the included validation report for actual local checks.

The intended end state is a custom guest PF/VF driver on a QEMU SR-IOV-capable PCI
carrier, with devlink, representors and a real software execution engine behind
TC offload callbacks. The final integration gate uses the SR-IOV operator to
configure OVS hardware offload, a switchdev NodePolicy, an OVSNetwork-generated
NAD and two VF-consuming pods on one worker.

## How to give this to Codex

Supply this entire Markdown document, or open the extracted ZIP as a workspace.
Begin with `AGENTS.md` and `START-HERE.md`, then implement K00 through K09 in order.
The named sections below contain the complete supplied files, not just excerpts.
Markdown files are shown directly; other files are fenced and labeled with their
repository-relative paths. Reconstruct those paths when working from this file
alone. The ZIP is the preferred starting workspace because it preserves separate
files and executable permissions.

Configure the real SSH alias, exact emulated PF BDF, Kubernetes context and worker
node in `config/lab.env` (copied from its example). Read-only preflight comes first.
Do not treat example addresses, image placeholders, acknowledgements or the
future debugfs contract as discovered or validated runtime state. Driver builds
intentionally fail until Codex implements `driver/`.

## Included files

- [AGENTS.md](#file-agents-md)
- [START-HERE.md](#file-start-here-md)
- [docs/01-architecture.md](#file-docs-01-architecture-md)
- [docs/02-kernel-work-packages.md](#file-docs-02-kernel-work-packages-md)
- [docs/03-vm-runbook.md](#file-docs-03-vm-runbook-md)
- [docs/04-kubernetes-flow.md](#file-docs-04-kubernetes-flow-md)
- [docs/05-validation-and-recovery.md](#file-docs-05-validation-and-recovery-md)
- [docs/06-sources.md](#file-docs-06-sources-md)
- [IMPLEMENTATION-STATUS.md](#file-implementation-status-md)
- [VALIDATION-REPORT.md](#file-validation-report-md)
- [manifests/README.md](#file-manifests-readme-md)
- [config/images.example.yaml](#file-config-images-example-yaml)
- [config/lab.env.example](#file-config-lab-env-example)
- [scripts/bootstrap-guest.sh](#file-scripts-bootstrap-guest-sh)
- [scripts/guest.sh](#file-scripts-guest-sh)
- [scripts/install-operator.sh](#file-scripts-install-operator-sh)
- [scripts/kube.sh](#file-scripts-kube-sh)
- [scripts/lab.sh](#file-scripts-lab-sh)
- [scripts/lib/common.sh](#file-scripts-lib-common-sh)
- [scripts/render.py](#file-scripts-render-py)
- [scripts/run-local-checks.sh](#file-scripts-run-local-checks-sh)
- [scripts/tc-smoke.sh](#file-scripts-tc-smoke-sh)
- [scripts/udp-probe.py](#file-scripts-udp-probe-py)
- [scripts/verify-evidence.py](#file-scripts-verify-evidence-py)
- [tests/local-validation.log](#file-tests-local-validation-log)
- [tests/test_harness.py](#file-tests-test-harness-py)
- [manifests/kubernetes/00-namespace.yaml](#file-manifests-kubernetes-00-namespace-yaml)
- [manifests/kubernetes/05-operatorconfig-patch.json](#file-manifests-kubernetes-05-operatorconfig-patch-json)
- [manifests/kubernetes/10-poolconfig.yaml](#file-manifests-kubernetes-10-poolconfig-yaml)
- [manifests/kubernetes/20-nodepolicy.yaml](#file-manifests-kubernetes-20-nodepolicy-yaml)
- [manifests/kubernetes/30-ovsnetwork.yaml](#file-manifests-kubernetes-30-ovsnetwork-yaml)
- [manifests/kubernetes/40-pod-a.yaml](#file-manifests-kubernetes-40-pod-a-yaml)
- [manifests/kubernetes/40-pod-b.yaml](#file-manifests-kubernetes-40-pod-b-yaml)
- [manifests/openshift/00-namespace.yaml](#file-manifests-openshift-00-namespace-yaml)
- [manifests/openshift/05-operatorconfig-patch.json](#file-manifests-openshift-05-operatorconfig-patch-json)
- [manifests/openshift/10-poolconfig.yaml](#file-manifests-openshift-10-poolconfig-yaml)
- [manifests/openshift/20-nodepolicy.yaml](#file-manifests-openshift-20-nodepolicy-yaml)
- [manifests/openshift/30-ovsnetwork.yaml](#file-manifests-openshift-30-ovsnetwork-yaml)
- [manifests/openshift/40-pod-a.yaml](#file-manifests-openshift-40-pod-a-yaml)
- [manifests/openshift/40-pod-b.yaml](#file-manifests-openshift-40-pod-b-yaml)
- [.gitignore](#file-gitignore)

---

<a id="file-agents-md"></a>

## Repository file: `AGENTS.md`

<!-- BEGIN FILE: AGENTS.md -->
# Codex execution contract: mock SmartNIC

Read START-HERE.md and all docs/ files before implementation. This repository is
an implementation specification plus a lab harness, not an already working driver.
Implement the driver and tests; do not merely restate the plan.

## Scope and stopping rules

Build an out-of-tree GPL-compatible Linux module on a pinned guest kernel. Use an
attested, dedicated QEMU-emulated Intel 82576 igb PF/VF device as the PCI carrier.
Use one module, mock_smartnic.ko, with PCI driver names mock_smartnic_pf and
mock_smartnic_vf. No Mellanox impersonation, no pci-testdev, no physical hardware,
no VFIO/DPDK, no real firmware emulation. Work package K02 is a go/no-go experiment:
prove PCI VF creation before investing in devlink or TC. If it fails because of
the carrier, follow the documented QEMU-model fallback, not fabricated sysfs.

Only use the VM and cluster explicitly configured in config/lab.env. Start with
read-only preflight. Never select a PF by “first NIC”, vendor-wide matches, or
inferred pod order. Never disable SSH host-key verification. Never print/commit
keys, kubeconfigs, registry credentials, or environment secrets. Never call a
mutation when its acknowledgement is empty. Inspect hypervisor XML to confirm
emulation, not PCI passthrough. DMI/PCI IDs alone are insufficient evidence.

Do not disable existing admission webhooks, Secure Boot, SELinux, IOMMU isolation,
or production operators to get a green result. Do not use unsafe VFIO no-IOMMU.
Module-signing/immutable-host issues are explicit prerequisites, not bypasses.

## Implementation invariants

* Preserve real guest PCI PF/VF objects and their sysfs relationships.
* PF/uplink exists in legacy mode; VF endpoint and VF representor are different.
* Representor ingress rules process VF TX; redirect to rep1 delivers VF1 RX.
* A TC miss uses the representor slow path. No hidden direct VF-to-VF forwarding
  in switchdev mode, and no fake positive offload acknowledgement.
* Advertise only implemented capabilities. Reject any unsupported nonzero mask,
  action, chain, flag, or stats mode with an explanatory extack.
* Never keep callback-owned flow_rule pointers after callback return. Protect
  port/netdev references and teardown against namespace moves and concurrency.
* Keep VF/representor lifetime independent: operator unbind/rebind of a VF must
  not unexpectedly destroy its representor while PCI VF existence is unchanged.
* Use the actual pinned kernel APIs. No invented devlink API, unsupported field,
  or manually written kernel-owned in_hw bookkeeping.
* Do not manually write SriovNetworkNodeState status or create the final-stage
  VFs/bridge/NAD/representor ports on behalf of the components under test.

## Work protocol

Implement docs/02-kernel-work-packages.md in order. After every package, run the
listed tests, record the exact command, exit status, kernel/source versions and
artifacts, and update IMPLEMENTATION-STATUS.md. Separate “implemented”, “built”,
“runtime passed”, “not tested”, and “blocked”. Do not report completion when only
code inspection or syntax checking has occurred. On missing access, implement
and run local tests, record what remains unexecuted, and do not fabricate output.

The existing harness encodes the required module names, parameters and debugfs
JSON schema. Keep those interfaces, or deliberately update code, scripts, tests,
and docs together. Add tests for safety guards and clean up only owned resources.
Do not leave an agent sleeping indefinitely: all readiness checks need deadlines.

For OVS-generated flows that initially fail: collect actual match/action dumps,
identify the missing supported feature, implement it with tests, and retry. Do not
mask the failure with a software fallback and claim HWOL success. Stateful/tunnel
features are outside the initial milestone and must stay explicit failures.
<!-- END FILE: AGENTS.md -->

---

<a id="file-start-here-md"></a>

## Repository file: `START-HERE.md`

<!-- BEGIN FILE: START-HERE.md -->
# Mock SmartNIC: Codex implementation and VM integration plan

Prepared: 23 September 2026. Status: **plan and harness; driver not yet implemented**.
The scripts have local static/fixture validation only; this package does not claim
a successful compile, VM boot, operator reconciliation, or hardware-offload test.
See the [validation report](VALIDATION-REPORT.md) for the exact local checks.

## Outcome

Implement a simulated NIC that exercises this real userspace chain:

```text
SriovOperatorConfig.manageSoftwareBridges
  -> SriovNetworkPoolConfig (OVS hardware-offload configuration)
  -> SriovNetworkNodePolicy (2 VFs, switchdev, managed OVS bridge)
  -> SR-IOV device plugin advertises two PCI VFs
  -> OVSNetwork controller creates a NetworkAttachmentDefinition
  -> Multus + ovs-cni attach each allocated VF to a pod
  -> OVS installs TC flower rules on VF representors
  -> the mock driver's software engine executes those offloaded rules
```

“Offloaded” here means delegated through Linux's driver offload API to the mock
engine. It does not mean physical acceleration, line rate, or mlx5 compatibility.
The first full flow uses **two pods on one worker VM**, kernel VF netdevices and
unprivileged UDP. The management NIC remains separate and untouched.

## Deliverables and reading order

1. [Architecture and constraints](docs/01-architecture.md).
2. [Kernel implementation work packages](docs/02-kernel-work-packages.md).
3. [Running-VM access, build, binding, persistence](docs/03-vm-runbook.md).
4. [Operator, pool configuration, node policy, OVSNetwork, pods](docs/04-kubernetes-flow.md).
5. [Acceptance tests, failures and rollback](docs/05-validation-and-recovery.md).
6. [Primary-source references and pinned research](docs/06-sources.md).

AGENTS.md supplies repository-level instructions. scripts/ contains executable
starting harnesses, config/ contains example inputs, and manifests/ contains
reviewable examples. The scripts use normal SSH and a local kubectl/oc context.
No credentials or running-VM address were supplied, so access values are inputs.

## Give Codex this instruction

```text
Read AGENTS.md, START-HERE.md and docs/01 through docs/06. Implement the mock
SmartNIC project, starting with K00/K01/K02; do not skip the PCI-carrier feasibility
gate. Use config/lab.env for the explicitly authorized VM and Kubernetes context.
Implement driver/ and tests/, keep the harness interfaces and debugfs schema, and
run each milestone before advancing. The final test must have the operator create
VFs and switchdev, manage its OVS bridge, create the NAD from OVSNetwork, allocate
separate VFs to two pods, and demonstrate TC/OVS offload with increasing mock
engine counters. Record failures honestly in IMPLEMENTATION-STATUS.md. Do not
change or use the management NIC, passthrough devices, or unrelated policies.
```

## Repository shape to build

```text
driver/
  Makefile Kbuild mock_smartnic.h
  main.c pci_pf.c pci_vf.c devlink.c netdev.c eswitch.c
  tc.c flow_parse.c flow_exec.c stats.c debugfs.c
  compat.h                     # only genuinely needed target-kernel shims
tests/
  unit/                        # matcher/action tests, KUnit or equivalent
  integration/                 # lifecycle, namespaces, TC, OVS, Kubernetes
  test_harness.py              # supplied local fixtures; extend them
scripts/                       # supplied executable lab harness
config/lab.env                 # local only, ignored by Git
artifacts/                     # exact logs, source lock, kernel, evidence
IMPLEMENTATION-STATUS.md
```

## First commands

```bash
cp config/lab.env.example config/lab.env
# Edit SSH_TARGET, PF_BDF, KUBE_CONTEXT, NODE_NAME and the remaining site inputs.
# Confirm ~/.ssh/config and the SSH host key through a trusted channel.
./scripts/lab.sh preflight
./scripts/kube.sh render
```

Do not set mutation acknowledgements until the emulated PF, independent management
path, dedicated lab ownership and console recovery have been checked. The scripts
refuse to use pci-testdev or an unattested PF. **The build command intentionally
fails until Codex creates driver/Makefile and implements the module.**

## Execution ladder after implementation

```bash
# K01/K02: code exists; kernel build dependencies are installed.
./scripts/lab.sh build
# Enable the explicit PF acknowledgements in config/lab.env, after XML review.
./scripts/lab.sh bind
./scripts/lab.sh pci-vfs  # K02 gate: no devlink/TC assumption yet
./scripts/lab.sh pci-reset  # K02 only: disable VFs without requiring devlink
# K03-K06: endpoint/representor/flower/debugfs contracts are implemented.
# After a fresh bind (zero VFs), use vfs to enable VFs AND switchdev.
./scripts/lab.sh vfs
./scripts/lab.sh tc-smoke
./scripts/lab.sh reset

# K07: persist the module and binding before operator-requested reboot.
# Requires PERSISTENCE_ACK=YES. Perform the controlled reboot test in the runbook.
./scripts/lab.sh persist

# K08: install/verify Multus and the operator using docs/04 first.
./scripts/kube.sh preflight
# Set CLUSTER_MUTATION_ACK=YES and OPERATOR_REBOOT_ACK=YES in the lab only.
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
./scripts/lab.sh collect > artifacts/final-guest.txt
```

The executable apply path targets a mutable Linux Kubernetes worker with the
operator's required OVS service. OpenShift manifests can also be rendered, but
module delivery, dedicated MCP isolation and MCO reboots need the OpenShift lane
in docs/04. The runner deliberately does not install an Ubuntu-built module into
RHCOS or restart a shared OVN OVS instance.

## Completion criteria

A completed result includes the kernel sources, reproducible version lock, logs
from all milestone gates, no kernel warnings in the test window, successful
negative controls, the generated NAD and both scheduled pods, plus **new matched
flow counters in both VF directions**. “The filter was accepted”, “the pod is
Running”, and “UDP worked” are individually insufficient.
<!-- END FILE: START-HERE.md -->

---

<a id="file-docs-01-architecture-md"></a>

## Repository file: `docs/01-architecture.md`

<!-- BEGIN FILE: docs/01-architecture.md -->
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
<!-- END FILE: docs/01-architecture.md -->

---

<a id="file-docs-02-kernel-work-packages-md"></a>

## Repository file: `docs/02-kernel-work-packages.md`

<!-- BEGIN FILE: docs/02-kernel-work-packages.md -->
# 02 — Kernel implementation work packages

Implement these packages in order. Every package has artifacts and an exit gate.
Do not build devlink/OVS complexity before proving the guest PCI carrier works.
All kernel API signatures must be taken from the running target kernel's source.

## K00 — Inventory, source lock, and reversible lab setup

1. Read AGENTS.md and the complete architecture. Inspect the existing repository.
   Preserve user work and never reset/clean an unrelated checkout.
2. Copy the environment example. Run `scripts/lab.sh preflight`. Confirm that the
   VM in SSH is the same node used by kubectl (machine ID comparison is supplied).
3. Obtain hypervisor evidence: Q35/libvirt XML shows a management virtio interface
   and a separate `<model type='igb'/>`; there must be no `hostdev` corresponding
   to the selected PF. Record guest BDF after boot, not from guessed host numbers.
4. Have a serial/virt console and VM snapshot/rebuild path. Check no pod or policy
   owns this PF. Initial VF count must be zero. Record native driver's identity,
   PF IPs/routes, bridge membership, OVS settings and kernel logs.
5. Install build tools for exactly `uname -r`; make no kernel upgrade as a side
   effect. Resolve module signing properly if required. See docs/03.
6. Clone/read pinned Linux sources, operator, ovs-cni (and its sriovnet dependency),
   QEMU and OVS. Record exact commits/package versions in `artifacts/versions.json`.
   Pin the operator commit from docs/06; resolve component images explicitly.
7. Inspect whether native `igbvf` is built-in or modular. It must not bind in the
   operator lane. Check udev/module autoload, not just `lsmod` at one instant.
8. Add unit tests for config validation, shell safety gates and renderer shape.

Exit: preflight logs, VM-emulation evidence, source lock, controlled recovery and
an intentionally selected BDF. Mutations still require the explicit ACK fields.

## K01 — Module skeleton and stable lab interface

Create the file layout in START-HERE.md. The module is GPL-compatible because it
uses Linux networking APIs and may use GPL-exported symbols. Do not copy large
vendor-driver code blindly; preserve license notices for reused source.

Example build arrangement (actual object names must match your files):

```makefile
# driver/Makefile, included by the kernel external-module build
obj-m += mock_smartnic.o
mock_smartnic-y := main.o pci_pf.o pci_vf.o devlink.o netdev.o eswitch.o \
                  tc.o flow_parse.o flow_exec.o stats.o debugfs.o
```

Keep helper implementations initially minimal, but do not return fake success for
unimplemented external operations. Module entry validates both parameters, then
registers VF and PF drivers; unwind registration in reverse order on error.

Define structures roughly as follows, with explicit reference ownership:

```c
/* Conceptual fields, not an ABI or a compilable kernel-version-specific snippet. */
struct msnic_pf {
    struct pci_dev *pdev;
    struct devlink *devlink;
    struct net_device *uplink;
    enum msnic_state state;             /* READY, ENABLING, QUIESCING, REMOVING */
    enum msnic_eswitch_mode mode;
    struct msnic_port *ports;           /* initialize before VF enumeration */
    /* configuration lock, immutable RCU rule snapshot, counters, debugfs */
};
struct msnic_port {
    unsigned int vf_index;
    struct net_device __rcu *vf_endpoint;
    struct net_device *representor;
    struct devlink_port dl_port;
    /* permanent/current MAC, policy, reference/lifetime and stats state */
};
struct msnic_rule {
    unsigned long cookie;
    unsigned int ingress_port, chain, priority;
    /* normalized masked keys, owned actions, ref-held egress ports */
    /* cumulative counters, separately synchronized reported deltas */
};
```

Keep PCI netdevice ownership, devlink ownership, datapath lifetime and debugfs
read lifetime separate. An open debugfs file must not retain freed PF private data.
Do not expose writable pointers, arbitrary kernel reads, or a fake firmware API.

Build via `scripts/lab.sh build`. Inspect warnings, `modinfo`, module parameter
names and vermagic. Load with parameters only on the authorized VM. A module can
be loaded while native igb still owns the PF; explicit driver_override controls
the eventual PF handoff. A BDF guard applies even when an ID table matches.

Exit: module builds and registers its two PCI drivers; unrelated devices are not
claimed; all error paths unwind. No claim of working SR-IOV yet.

## K02 — Mandatory PCI carrier experiment

### PF probe

1. Verify target BDF, expected vendor/device, networking class, PF identity and
   SR-IOV capability. Do not call native igb register/mailbox code.
2. Enable/claim only PCI resources actually needed for the experiment. If BAR
   mapping is unnecessary, do not map/write them. Do not set bus mastering or
   create DMA queues merely because a physical NIC example does so.
3. Initialize PF state, stable switch ID, port slots and all references that VF
   probe will need. Establish `pci_set_drvdata()` before creating VFs.
4. Register a persistent PCI-parented Ethernet PF/uplink netdevice with a stable
   locally administered MAC. Its initial mode is legacy and VF count zero. Add
   minimal truthful ethtool get_drvinfo now so the bind harness can inspect it.
5. Implement `sriov_configure(pdev, num_vfs)` with actual `pci_enable_sriov()` and
   `pci_disable_sriov()` calls. Positive success returns the configured VF count;
   zero success returns zero; negative errors propagate. Never return an error
   with half-published successful state and leave the caller to guess.

### VF probe

1. Validate `pdev->is_virtfn` and the physical PF's binding/identity.
2. Acquire a supported reference to the PF object. Use the target kernel's
   `pci_iov_get_pf_drvdata()` contract or an equally safe association.
3. Obtain the VF index with the supported PCI helper. Bounds-check it.
4. Allocate one PCI-parented VF endpoint netdev with its own ndo_start_xmit,
   address, MTU, admin state and statistics. Register it once; no representor yet
   is needed to prove VF existence.
5. Keep the VF endpoint movable to other network namespaces (do not set flags
   that prohibit movement). Release references correctly on VF removal.

### Lifecycle and locking

`pci_enable_sriov()` may invoke VF probing before returning; disabling SR-IOV
invokes child removal. Do not hold a lock across these calls if child probe/remove
also takes it. Prepare state under the configuration lock, transition state,
release/arrange locks, perform PCI-core operation, then finalize or unwind. Write
and review the lock-order diagram before implementing the callbacks.

VF count changes must handle at least `0 -> 2 -> 0 -> 2`, repeated zero, invalid
counts and allocation/probe failure. Nonzero-to-different-nonzero writes normally
need zero first; rely on PCI core semantics and validate your callback too. Never
manufacture success for a missing VF. Keep `pci_disable_sriov()` paired with each
successful enable on teardown. [S04]

Test through `scripts/lab.sh bind` and `scripts/lab.sh pci-vfs`. The latter stops
after PCI/VF binding and does not require the K03 devlink interface. During K02,
use `scripts/lab.sh pci-reset`, which writes zero to this PF's sriov_numvfs and
one to sriov_drivers_autoprobe after checking for consumers. It does not change
eswitch mode; the full `lab.sh reset` becomes available in K03 and is required
before Kubernetes.
Record the real virtfn and physfn links, device IDs, driver symlinks and net dirs.
Test normal and autoprobe-disabled creation. The harness's manual binding is not
proof that automatic rebind works; add the operator-style rebind test in K07.

### Go/no-go and fallback

If the unmodified emulated igb carrier permits enumeration, continue. If it fails,
collect `lspci -vv`, kernel PCI logs, QEMU version and callback return values. Check
PCI bus-number/BAR resources, `CONFIG_PCI_IOV`, total VFs and the emulator model.
Do not replace a real error with fabricated sysfs or stub success.

If a carrier limitation is confirmed, create a small QEMU `mock-sriov-pf` /
`mock-sriov-vf` model using the current SR-IOV helper APIs. Required work:

* PCIe endpoint capability and valid networking class/identity; a documented test
  identity that does not imply real-vendor firmware compatibility.
* PF SR-IOV capability, total VF count, VF offset/stride, VF identity and BAR
  layout/resource sizing. Use `pcie_sriov_pf_init` and corresponding VF BAR helpers
  as implemented in the checked-out QEMU, not guessed historical signatures.
* VF creation/disable/config-space semantics, reset/unrealize cleanup and small
  qtests for enable/disable/re-enable and config reads. DMA is not needed for the
  in-guest software engine, but PCI address/resource semantics still are.
* A QEMU build and optional kcli `qemuextra`/custom emulator path; validate the
  resulting libvirt topology instead of hard-coding `bus=pci.0` on Q35.
* Update the test-only supported NIC mapping and parameter guards. Re-run K02.

This fallback is a separate explicit milestone, not evidence that the initial
carrier failed or an excuse to skip the feasibility experiment. [S02,S03,S14]

## K03 — Devlink, representors and netlink compatibility

Implement eswitch mode GET and SET with extack, state validation and rollback.
Validate both sequences: create VFs then switchdev; switchdev with zero VFs then
create VFs. The operator may reset counts and temporarily return to legacy. Do
not assume it follows only the manual smoke-test order.

Uplink netdev remains stable. Create/remove VF representors with mode and PCI VF
existence. A VF driver unbind alone does not remove its representor: traffic to an
unbound endpoint drops with explicit counters while control-plane identity stays
valid. A PCI VF removal does remove the corresponding representor. Handle port
creation rollback without leaving devlink/netdev garbage.

Use a physical-flavour uplink port and PCI-VF ports with pfnum=0, vfnum=index and
controller identity where required by the kernel API. Set consistent switch ID;
different mock PFs must not share it accidentally. Set port attributes and associate
netdev before netdev registration according to the target kernel's locking API.
Verify **both devlink JSON and sysfs phys_switch_id/phys_port_name**, then exercise
the exact sriovnet library version in ovs-cni. Printed interface names alone are
not enough. [S06,S07,S08]

Add a small Go helper/test using the checked-out ovs-cni dependency versions to
call: GetUplinkRepresentor(VF-BDF), GetVfIndexByPciAddress(VF-BDF),
GetVfRepresentor(uplink,index), and GetNetDevicesFromPci(VF-BDF). Run before and
after moving endpoints to namespaces; report exactly what must be discoverable
at each CNI lifecycle phase.

Netdev operations required initially:

* PF and VF: open/stop, set MAC, change MTU, get_stats64; correct carrier semantics.
* PF: ndo_get_vf_config; set VF MAC, VLAN/QoS (initially zero only if nonzero VLAN
  is outside scope), spoofchk, trust and link state as exercised by operator/CNI.
* Representors: host-local identity, open/stop, MTU, stats and TC setup.
* Ethtool: truthful driver and bus info on PCI-backed endpoints, feature support,
  feature changes and link settings required by discovery. Do not advertise real
  speed guarantees. Distinguish emulated information explicitly.

A setter must either implement the observable behavior or reject it. Merely
recording `spoofchk=true` without enforcing it is not a valid anti-spoofing test.
For any unsupported setter, collect whether the operator genuinely needs it; add
that behavior or reduce the test's stated scope without forging success.

Switchdev/TC capability: set NETIF_F_HW_TC in supported and enabled feature masks
on relevant ports and implement feature transitions consistently. Avoid advertising
TSO/GSO/checksum capabilities you have not implemented.

Exit: operator-compatible PF/VF/representor discovery, mode sequence coverage,
correct netlink VF state and safe namespace move/return.

## K04 — Slow-path virtual switch

Implement the datapath before flower offload so later tests can compare results.
Define every port direction; functions should encode those directions in names.

```text
msnic_vf_xmit(skb, VF_i)
    -> switch ingress(port_i)
    -> no offload yet
    -> deliver_rep_rx(rep_i)

msnic_rep_xmit(skb, rep_j)
    -> deliver_vf_rx(VF_j)

msnic_uplink_xmit(skb)
    -> isolated synthetic wire sink (MVP), count explicitly
```

Use a tested RX handoff helper with the exact return/ownership semantics of the
pinned kernel. Never reuse an skb after a consume/drop helper. Never sleep or take
a mutex in ndo_start_xmit. Stop/reject traffic safely while ports are quiescing.
Normalize namespace-sensitive skb metadata and checksum/header state. Test
nonlinear skb handling; do not assume skb->data contains every header contiguously.

Use RCU/reference-safe endpoint pointers across namespace moves and teardown.
Moving a VF to a namespace is not removal, so no raw namespace-local ifindex
lookup for persistent endpoint identity. When the namespace is destroyed, a live
PCI netdev should be returned/recovered safely according to normal netdev rules;
CNI DEL plus netns destruction must not leave driver dangling pointers.

Minimal tests: two isolated netns, endpoint/representor bidirectional pipe; VF0
cannot reach VF1 without switching; temporary standalone OVS bridge forwards via
representors; packet payload matches, no duplicate, no skb leak. Clear all manual
bridges before continuing. Kernel logs must contain no new WARN/Oops/refcount error.

## K05 — Flower parser, execution, lifecycle and counters

### Register the callbacks correctly

Handle TC_SETUP_BLOCK using the target kernel's flow-block helpers. Track binding
identity and release on unbind. In the bound callback handle TC_SETUP_CLSFLOWER
and FLOW_CLS_REPLACE, FLOW_CLS_DESTROY and FLOW_CLS_STATS. Return -EOPNOTSUPP with
extack for unsupported setup types. Support only ingress binding initially.
Block identity must distinguish ingress port and chain; a cookie alone is not a
universal globally unique key.

### Normalize and validate the entire rule

Parse `flow_rule` using target-kernel helpers, not user netlink message casts.
Inspect all used dissector keys **and all nonzero masks**. Zero masked fields do
not impose predicates; unknown nonzero bits do. Support for the MVP should include
Ethernet source/destination masks, ethertype, IPv4 addresses, IP protocol, L4 ports
and the fragment/control fields emitted by the pinned OVS. Add TCP flags/untagged
VLAN semantics if the actual flow dump uses them. Every accepted bit must be
matched; unknown fields must never be silently ignored.

For each action validate its order, destination, flags and terminal behavior.
First implement exactly terminal REDIRECT to a live port of the same mock switch
and terminal DROP. Redirecting to another VF representor means delivery to that
VF endpoint; an uplink redirect follows the documented sink/backend behavior.
Reject redirect to an unrelated netdevice/PF/switch. Implement VLAN push/pop only
as a separately tested extension, then use it in the optional VLAN lane.

Reject CT, NAT, tunnel, mirror, sample, police, unsupported chain/goto, unsupported
metadata or multi-action programs atomically. Include the missing action/key in
extack and a rate-limited trace. Do not accept and partially install a rule.

### Store owned, immutable rules

The callback's `flow_rule`, nested pointers and action arrays are not yours after
return. Deep-copy normalized keys/actions and take explicit output-port/netdev
references. Validate/allocate first, then publish one immutable rule. Retire old
rules under RCU. An RCU-protected sorted small rule list is acceptable for the
first VM tests; document O(n) lookup rather than presenting it as production scale.

Respect TC priority and mask semantics. Define deterministic handling of any
ambiguous tie consistent with the accepted subset; reject cases you cannot model.
Match `(packet_field & mask) == (key & mask)` in the correct byte order. Test
truncated IP/L4 headers, fragmentation, options, non-linear skbs and invalid
addresses. No out-of-bounds reads or accidental matching of non-first fragments.

Replacement failure must follow the target TC core's transaction semantics;
inspect how that kernel handles callback replace and counts. Do not assume the
old software and driver rule survive in all failure modes. Test what is actually
reported and ensure no stale rule remains undiscoverable to TC.

### Execution and statistics

On VF TX, evaluate rules belonging to that VF representor ingress. A match updates
per-flow/per-port counters and executes exactly once. A miss increments the miss
counter and is delivered to representor RX. Do not re-execute the same fast-path
program on representor TX. The initial engine excludes mirror/continue to keep
this terminal decision unambiguous.

For stats use `flow_stats_update()` / target-kernel equivalent with correct
packet/byte delta versus cumulative behavior and lastused units. Keep cumulative
engine counters separate from the 'already reported to TC' counters. Repeated
stats polls with no traffic must not inflate TC/OVS counts. Document L2 accounting:
OVS TC and software byte counts are not generally directly comparable. [S15]

The TC core maintains in_hw/offload counts based on successful callbacks. Do not
poke classifier flags manually. A successful return means the entire accepted
rule is executable, not merely stored for display. [S16]

### Required read-only debugfs schema (version 1)

Create `/sys/kernel/debug/mock_smartnic/<PF-BDF>/stats` and `/flows` as valid JSON
via safe seq_file output. File reads must be race-safe and must not reset counters.

```json
{"schema_version":1,"pf_bdf":"0000:00:06.0","eswitch_mode":"switchdev",
 "offload_hits":30,"offload_misses":4,"slowpath_packets":4,
 "redirect_packets":30,"drop_packets":0,"uplink_sink_packets":2,
 "active_flows":2}
```

```json
{"schema_version":1,"flows":[
  {"cookie":"0x1234","ingress_vf":0,"chain":0,"priority":10,
   "packets":15,"bytes":1500,
   "actions":[{"kind":"redirect","vf":1}]}
]}
```

These are example values, not test results. Add match summaries and extack/error
counters as needed. Use ingress_vf=-1 for uplink ingress if later implemented;
use an explicit uplink action kind rather than an invented VF number. Maintain
per-flow stats across ordinary stats reads and replacements as specified/tested.
Counters reset on module recreation, so compare only within a known lifetime.

Exit: unit tests cover positive and negative masks/actions, ordering, reference
release and statistics; direct TC traffic is the next independent runtime gate.

## K06 — Direct TC and standalone OVS gates

Run `scripts/lab.sh tc-smoke`. It moves real VF endpoints, installs two skip_sw
rules, tests packets, reads both TC stats and simulator hit counters, deletes the
rules and expects connectivity to fail without an alternate switching path.
Static neighbors keep ARP from hiding a broken IPv4 data path. Inspect cleanup
and dmesg after failure too.

Add a second gate using a temporary OVS bridge (not the eventual operator bridge):
configure system datapath, no external controller/CT, enable OVS HWOL with a
controlled service restart if that version requires it, attach PF+representors,
generate UDP and inspect OVS-produced flower rules. Record global OVS before/after
and restore it; never do this on a shared production/OVN instance. Use OVS OpenFlow
rules only to simplify a standalone test, not manual TC rules on OVS-owned ports.

Prove offload acceptance plus directional packet hits. Test `skip_hw` software
baseline separately and compare payload outcomes with skip_sw. Negative rule tests
must reach the driver (not fail earlier because an action module is unavailable).
Test ENOSPC/injected rule allocation failure, unsupported keys/actions and delete.

Exit: manual TC and OVS-generated flows work independently. Document any accepted
match expansions required by OVS. No bridge/qdisc/netns test leftovers.

## K07 — VF default-driver rebind and reboot persistence

1. With mock PF active, create VFs with autoprobe enabled. Each binds to mock VF
   without a shell loop fixing it after operator reconciliation.
2. Unbind one VF, clear driver_override and write its BDF to drivers_probe, exactly
   as the operator does. Verify mock VF rebinds, representor identity stays intact,
   endpoint reappears and no native igbvf grabs it. Repeat ten times. [S09]
3. Test switchdev before/after VF creation and VF deletion in switchdev, including
   debugfs readers and OVS port detach ordering. No stale references or deadlock.
4. Install persistent module for the exact running kernel and boot binding using
   `scripts/lab.sh persist`. The supplied unit runs before kubelet and the operator's
   services; it does not create VFs or configure the eventual operator bridge.
5. With the Kubernetes worker drained/authorized and console available, perform
   one explicit controlled reboot. Wait for SSH, verify kernel unchanged, mock PF
   binding, zero VFs, autoprobe=1, blocked native igbvf and kubelet service ordering.
6. If the module cannot load, kubelet must not race ahead and reconcile hardware
   through a native driver. Fix the failure using console, not security bypasses.
7. Add signed module delivery for Secure Boot and a kernel update/rebuild workflow.
   The supplied persistence unit is deliberately not a universal DKMS/KMM solution.

Exit: the operator is allowed to reboot this node without losing the mock driver.

## K08 — Full operator/CNI flow

Follow docs/04 and run `scripts/kube.sh apply`, then `verify`. Start with zero VFs
and legacy mode via `lab.sh reset`, mock module loaded persistently, and no manual
OVS bridge. Let the operator create VFs/switchdev/bridge, its network controller
create the NAD and ovs-cni attach the selected representors. Never patch rendered
NodeState status or manually compensate after a failed reconcile.

Install exact operator/daemon images compatible with the pinned CRDs. Test the
pool's otherConfig propagation, resulting OVS hw-offload=true, the NodePolicy's
specified/observed switchdev state, and the device plugin's actual resource key.
The NAD resource annotation must match the pods' explicit request/limit.

The first lane has two same-node untagged IPv4 UDP pods. Success requires their
allocated PCI IDs to map to different VFs of this PF, actual CNI-selected host
representors, correct OVS membership and new driver flow hits in both directions.
Do not confuse the pod's default interface/control-plane network with `net1`.

## K09 — Resilience, repeatability and CI

Add test cases from docs/05. Repeat pod create/delete (50 cycles), VF count changes
with pods removed, mode cycles, driver reload, worker reboot and interrupted
allocation recovery. Add KASAN/lockdep/debug-kernel runs where available, without
claiming performance equivalence to release hardware drivers.

CI layers: static/unit checks without a VM; privileged VM PCI/TC tests; full
Kubernetes smoke; optional OpenShift/MCO lane. Export bounded, reproducible logs
and machine-readable verdicts. Skip hardware-dependent lanes explicitly when
infrastructure is missing—do not silently report pass.

Commit sources, test plans and source locks, not `.ko` binaries, secrets or
machine-specific credentials. Finish with exact tested versions, known limitations,
remaining unsupported actions and replayable commands in IMPLEMENTATION-STATUS.md.
<!-- END FILE: docs/02-kernel-work-packages.md -->

---

<a id="file-docs-03-vm-runbook-md"></a>

## Repository file: `docs/03-vm-runbook.md`

<!-- BEGIN FILE: docs/03-vm-runbook.md -->
# 03 — Access a running VM, build, bind and iterate

## 1. Inputs and assumptions

The Linux/WSL controller has Bash, Python 3, rsync, GNU timeout, OpenSSH and local kubectl/oc. The DUT is a
running, disposable QEMU/KVM Linux guest with a separate management interface and
an emulated igb PF. The DUT has passwordless `sudo -n` for the explicitly authorized
lab operations, matching kernel build headers, and normal Linux networking tools.
The cluster lane also requires that this guest be a Ready worker of a real cluster.

The supplied scripts do not create SSH keys, scrape credentials, set passwords or
discover arbitrary hosts. Set a trusted alias, for example:

```sshconfig
Host mock-smartnic-dut
    HostName 192.0.2.40
    User labuser
    IdentityFile ~/.ssh/mock-lab
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

The address is an example, not a known DUT. Verify the host fingerprint against
the console/VM provisioning record; `ssh-keyscan` alone is not identity verification.
Use ProxyJump in SSH config if needed. A Codex sandbox may require authorization
for network access; without it, build local tests and explicitly record that the
VM stages were not executed.

```bash
cp config/lab.env.example config/lab.env
# Edit site inputs. Do not commit this file.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes mock-smartnic-dut 'uname -r; sudo -n true'
./scripts/lab.sh preflight | tee artifacts/preflight.txt
```

Create `artifacts/` first if using tee independently of the runner.

## 2. Check the actual PCI carrier before takeover

From the hypervisor, inspect the selected VM XML and record a snapshot identifier:

```bash
virsh dumpxml YOUR_VM > vm-before.xml
virsh domiflist YOUR_VM
```

The test NIC should be emulated `igb`; it must not be a passed-through PCI device.
QEMU guest DMI plus 8086:10c9 is not enough: a VM could have a real Intel card passed
through. Inspect the matching interface/controller and absence of relevant hostdev.
Keep a console (`virsh console YOUR_VM`, or your hypervisor's equivalent) available.

For a new VM, reuse existing kcli support rather than patching XML templates:

```yaml
mock-k8s-node:
  image: ubuntu2204       # example input; pin your actual OS/kernel separately
  machine: q35
  memory: 8192
  numcpus: 4
  nets:
    - name: default
      type: virtio
    - name: default
      type: igb
      noconf: true
```

The bridge/network names and OS image must exist in that kcli installation.
If using QEMU CLI directly, put the igb PCIe function on a suitable PCIe bus/root
port with adequate VF bus/BAR resources. Do not use `bus=pci.0` as a universal Q35
setting. The upstream virtual-test script is another provisioning reference.
[S01,S02,S14]

In the guest, inspect, do not guess, the chosen BDF:

```bash
lspci -Dnnk
sudo lspci -Dvv -s 0000:00:06.0
cat /sys/bus/pci/devices/0000:00:06.0/{vendor,device,class,sriov_totalvfs,sriov_numvfs}
ip -br addr
ip route
```

Set `PF_BDF` to that device. Start with zero VFs. If any existing workload uses it,
stop and use a fresh dedicated PF/VM rather than clearing it. Exclude the test PF
from NetworkManager/networkd auto-configuration using the distro's scoped per-NIC
method. Do not disable networking services globally.

## 3. Install build dependencies without upgrading the kernel

Copy/run the supplied optional installer only on a mutable test guest:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes mock-smartnic-dut \
  'sudo -n bash -s -- --install' < scripts/bootstrap-guest.sh
```

It installs tools and headers/devel for `uname -r`; it does not intentionally
upgrade the kernel or reboot. Package installation may start newly installed OVS
services, so run it only on the isolated lab worker. Verify:

```bash
uname -r
ls -ld /lib/modules/$(uname -r)/build
sudo modprobe sch_ingress
sudo modprobe cls_flower
sudo modprobe act_mirred
systemctl cat ovs-vswitchd.service
```

Do not copy a `.ko` from another distro/kernel. For missing old kernel headers,
use a matching supported build environment/package archive or deliberately boot a
new pinned kernel first and re-inventory. Never force vermagic/module-version checks.
For enforced module signatures, sign with an authorized enrolled key. Do not turn
off Secure Boot or lockdown automatically. For an immutable OS, see docs/04.

Required relevant kernel options include PCI/SR-IOV, namespaces/net namespaces,
network devices, devlink, TC ingress/flower/actions, OVS and DEBUG_FS. Check the
running kernel's config, not a package name. KASAN/lockdep are optional debug lanes.

## 4. Remote build

Codex writes driver sources locally, then:

```bash
./scripts/lab.sh build
```

The wrapper transfers only `driver/` to the configured remote source directory,
with derived binaries excluded and without rsync --delete. It runs the external
module build as the SSH user, using `/lib/modules/$(uname -r)/build`, saves local
build output, and prints modinfo and a SHA-256. It never builds as root by default.

Equivalent guest command:

```bash
make -C /lib/modules/$(uname -r)/build M="$PWD/driver" W=1 -j4 modules
modinfo driver/mock_smartnic.ko
```

Do not invoke runtime tests on a previous `.ko` after a failed build. Record the
source commit and binary hash together. The wrapper's build starts with module
clean so stale object files do not hide missing dependencies.

## 5. Take over the PF safely

After XML/management-path review, set:

```bash
EMULATED_PF_ACK=0000:00:06.0   # must exactly equal PF_BDF
EXCLUSIVE_PF_ACK=YES
```

Then run:

```bash
./scripts/lab.sh bind
./scripts/lab.sh vfs
./scripts/lab.sh collect > artifacts/pci-and-devlink.txt
```

The wrapper saves original driver/override/autoprobe/admin state under a root-owned
DUT state directory, refuses existing VFs/global addresses/master/upper/OVS use,
checks the SSH route, suppresses native igbvf only in this lab, loads the mock
module, and binds the exact PF through driver_override. It does not use a vendor-
wide `new_id`, unload unrelated PF drivers or silently destroy existing VFs.

Conceptual guest sequence (the script adds safety checks):

```bash
sudo insmod driver/mock_smartnic.ko target_pf="$PF_BDF" allow_igb_emulation=1
printf 'mock_smartnic_pf\n' | sudo tee /sys/bus/pci/devices/$PF_BDF/driver_override
printf '%s\n' "$PF_BDF" | sudo tee /sys/bus/pci/devices/$PF_BDF/driver/unbind
printf '%s\n' "$PF_BDF" | sudo tee /sys/bus/pci/drivers/mock_smartnic_pf/bind
```

For the manual experiment the script disables VF autoprobe, enables VFs, resolves
each virtfn symlink and explicitly binds mock_smartnic_vf. Its devlink check requires
K03. In the final operator flow, autoprobe is enabled and no external binding loop
is permitted to repair wrong VF bindings.

If bind/probe fails, collect kernel logs and the saved state. The script attempts
native PF rebind for the direct bind failure but preserves recovery information;
it cannot recover a kernel panic or lost SSH session. Use console/snapshot recovery.

## 6. Direct TC test

```bash
./scripts/lab.sh tc-smoke
```

Prerequisites: K03–K05, exactly identified VF endpoints and representors, no OVS
ownership of those representors, and required debugfs JSON files. The smoke script
uses two disposable namespaces, static neighbors, two IPv4 skip_sw redirect rules,
positive packet/counter tests and a negative control after deleting both rules.
It restores VF endpoints to the host and removes its namespaces/qdiscs on normal
exit or error. Check dmesg and no leaked interfaces even when a test fails.

This stage does **not** claim Kubernetes integration. Clean its artifacts and run:

```bash
./scripts/lab.sh reset
```

Reset refuses VFs apparently inside another namespace and representors attached
to OVS. It leaves zero VFs, legacy mode and `sriov_drivers_autoprobe=1`, ready for
the operator to do the real configuration later.

## 7. Persist through the operator's reboot

Set `PERSISTENCE_ACK=YES`, then:

```bash
./scripts/lab.sh persist
```

This installs the built module for the current kernel, modprobe options, a boot
binding unit and a kubelet dependency. It does not intentionally reboot the VM or
create VFs. Native VF suppression remains active until restore. The service must
run before kubelet, sriov-config services and ovs-vswitchd.

Perform the controlled reboot gate with console and cluster authorization:

```bash
kubectl --context YOUR_CONTEXT drain YOUR_NODE --ignore-daemonsets
# Resolve any PDB/emptyDir blockers explicitly; do not blindly add force flags.
ssh mock-smartnic-dut 'sudo -n systemctl reboot'
# Bounded reconnect/readiness polling; an SSH disconnect during reboot is expected.
ssh mock-smartnic-dut 'uname -r; sudo -n systemctl status mock-smartnic-lab.service'
kubectl --context YOUR_CONTEXT wait node/YOUR_NODE --for=condition=Ready --timeout=10m
kubectl --context YOUR_CONTEXT uncordon YOUR_NODE
```

The unit is kernel-version-specific, not automatic DKMS. Test both success and a
missing module on a disposable snapshot. If a kernel update occurs, rebuild/sign
for that exact kernel before enabling workloads; do not force-load the old binary.
The bootstrap unit intentionally does not configure the operator's VFs/bridge.

## 8. Code-change iteration

Before unloading/rebuilding a live driver: remove test pods; remove their network
and policy through the owning controllers; wait for bridge/VF cleanup; run reset;
remove persistence if installed; restore native binding. Then build, bind and test
the new module. Do not rmmod underneath pod-owned netdevices or live TC callbacks.
A faster development reload path may be added later, but must prove equivalent
teardown and preserve recovery state.

## 9. Diagnostics and limits

```bash
./scripts/lab.sh mapping
./scripts/lab.sh stats
./scripts/lab.sh flows
./scripts/lab.sh tc-json
./scripts/lab.sh ovs-evidence
./scripts/lab.sh collect > artifacts/guest-debug.txt
```

The stats/flows commands require the documented driver debugfs schema. Missing
files fail instead of returning fabricated zero counters. Capture debugfs after
reboot only once DEBUG_FS is mounted. Logs may contain operational identifiers;
review them before publishing. Never put kubeconfig/registry/SSH secrets in artifacts.

Each SSH command has a configurable local deadline (REMOTE_TIMEOUT). A killed SSH
client cannot guarantee cancellation of a stuck kernel syscall on the guest; use
console/snapshot recovery for that case rather than repeatedly launching writes.
<!-- END FILE: docs/03-vm-runbook.md -->

---

<a id="file-docs-04-kubernetes-flow-md"></a>

## Repository file: `docs/04-kubernetes-flow.md`

<!-- BEGIN FILE: docs/04-kubernetes-flow.md -->
# 04 — Full operator -> HWOL -> node policy -> OVSNetwork -> pod flow

## 1. Required environment

Use a real Kubernetes worker VM, not a kind node container pretending to own host
PCI devices. The worker has the emulated PF, persistent mock module and a separate
management NIC. Use another node for the control plane so draining/rebooting the
worker does not destroy the API service required by the test.

Before applying manifests, verify:

1. Primary CNI and cluster are healthy; Multus and the NetworkAttachmentDefinition
   CRD are installed. Multus can call the node's CNI plugins and receive allocated
   PCI device information from the SR-IOV device plugin.
2. Host OVS uses the **kernel/system** datapath, its OVSDB socket is available to
   ovs-cni and `/opt/cni/bin/ovs` (or the actual configured CNI path) exists. Also
   verify host-local and loopback binaries. A controller pod being Ready does not
   prove its CNI binary was installed in kubelet's actual directory.
3. Exactly one intended SR-IOV operator installation owns the CRDs/config. Its
   config daemon and device-plugin pods run on the selected worker. Confirm the
   actual component image IDs and the resource prefix.
4. The mock PF is already bound and in legacy with zero VFs; autoprobe is enabled,
   native igbvf is absent/blocked, and K07's reboot gate passed.
5. No existing policy selects this PF, no existing node-selected pool overlaps the
   DUT, and no production/shared OVS instance will be altered. Review the existing
   CRs; never assume the word “lab” makes a cluster disposable.

The supplied kube.sh preflight verifies VM/node machine ID, key CRDs and schema
fields, then saves policies/pools for overlap review. It does not have authority
to resolve conflicts by deleting unrelated configurations.

## 2. Source and component installation

### Existing operator installation

Prefer reusing it only if its CRDs and images provide the pinned feature set.
Inspect `kubectl explain` for `bridge.ovs` and
`ovsHardwareOffloadConfig.otherConfig`. Do not install a second operator over an
OLM-owned deployment or mix a newer CRD with an older config-daemon image.

For the lab's emulated NIC, configure the supported-NIC entry:

```yaml
# An entry in the operator-owned supported-nic-ids ConfigMap / Helm values.
Mock_igb_82576: "8086 10c9 10ca"
```

For a fresh upstream development deployment, set operator environment
`DEV_MODE="true"` as the upstream virtual-testing guide prescribes. Existing
webhooks must remain enabled unless the selected new-lab deployment deliberately
uses its documented default without them; do not disable validation to hide
incorrect CRs. No unsafe VFIO/no-IOMMU setting is needed for this kernel-netdevice
lane, even though the upstream broader virtual test guide discusses it. [S01,S18]

### Fresh upstream Kubernetes installation

Use the supplied optional Helm installer after preparing image inputs:

```bash
git clone https://github.com/k8snetworkplumbingwg/sriov-network-operator.git ../sriov-network-operator
git -C ../sriov-network-operator checkout a5588da21699fccce921cb1d4ac5894f47889399
# Set OPERATOR_SOURCE and OPERATOR_IMAGE_VALUES in config/lab.env.
./scripts/install-operator.sh
# Inspect artifacts/install/rendered.yaml before approving the installation.
APPROVE_RENDERED_OPERATOR=YES ./scripts/install-operator.sh
```

`OPERATOR_IMAGE_VALUES` is a real local YAML file of pullable compatible component
images. Do not invent image tags from the source commit. Resolve an approved
published build or build/push the operator and config-daemon from the same source
using that checkout's Makefile/Dockerfiles, then record registry digests. Resolve
ovs-cni, device-plugin and other referenced components from compatible versions.
The chart uses full image values; its source-checkout defaults are not a version
lock. A sample shape (replace every placeholder before running Helm):

```yaml
images:
  operator: REGISTRY/operator@sha256:REAL_DIGEST
  sriovConfigDaemon: REGISTRY/config-daemon@sha256:REAL_DIGEST
  ovsCni: REGISTRY/ovs-cni@sha256:REAL_DIGEST
  sriovDevicePlugin: REGISTRY/sriov-device-plugin@sha256:REAL_DIGEST
  sriovCni: REGISTRY/sriov-cni@sha256:REAL_DIGEST
  ibSriovCni: REGISTRY/ib-sriov-cni@sha256:REAL_DIGEST
  rdmaCni: REGISTRY/rdma-cni@sha256:REAL_DIGEST
  resourcesInjector: REGISTRY/resources-injector@sha256:REAL_DIGEST
  webhook: REGISTRY/webhook@sha256:REAL_DIGEST
  metricsExporter: REGISTRY/metrics-exporter@sha256:REAL_DIGEST
  metricsExporterKubeRbacProxy: REGISTRY/kube-rbac-proxy@sha256:REAL_DIGEST
```

This example is a schema, not valid image credentials or published digest data.
Use existing registry authentication via the platform; never store pull secrets in
the agent's committed config. Inspect all rendered container images and image-env
variables. Keep image lock and source lock associated in the test report. [S18]

The installer scopes config-daemon placement to `mock-smartnic.test/target=dut`.
The test scripts also scope the policy and pods with that label. Ensure exactly
one node carries it. Preserve the primary CNI; do not deploy a second default CNI.
For an absent Multus installation, use its pinned upstream deployment appropriate
to the actual CRI/CNI directories, inspect images/hostPath mounts and test a simple
secondary attachment before debugging SR-IOV. This is a prerequisite deployment,
not part of the mock kernel module. [S19]

## 3. Enable managed OVS bridges

Patch only the needed feature gate, preserving other operator configuration:

```bash
kubectl -n sriov-network-operator patch sriovoperatorconfig default --type=merge \
  -p '{"spec":{"featureGates":{"manageSoftwareBridges":true}}}'
```

There is no invented `spec.hwOffload: true` field on SriovOperatorConfig in this
plan. Bridge management, global OVS HWOL configuration, and NIC switchdev mode are
separate concerns. The next sections configure each explicitly. [S13,S17]

## 4. Hardware-offload configuration: Kubernetes lane

The researched commit added configurable OVS `other_config`. The source has an
important distinction: `findNodePoolConfig()` skips pool objects with a nonempty
`ovsHardwareOffloadConfig.name`. For a **node-scoped Kubernetes pool**, leave that
name absent and use nodeSelector plus otherConfig. The selected pool then feeds
NodeState.spec.system.ovsConfig, which the Kubernetes host plugin renders into
the OVS service configuration. This is intentionally based on the pinned source,
not an assumption that every older operator release has the same API. [S11,S12,S17]

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkPoolConfig
metadata:
  name: mock-smartnic-pool
  namespace: sriov-network-operator
spec:
  nodeSelector:
    matchLabels:
      mock-smartnic.test/target: dut
  maxUnavailable: 1
  ovsHardwareOffloadConfig:
    otherConfig:
      hw-offload: "true"
      tc-policy: "none"
```

`tc-policy: none` permits the normal software miss/fallback behavior while OVS
installs offload rules. The final verifier still requires real offloaded flows.
Direct TC skip_sw testing is a separate earlier gate. Do not set skip_sw globally
just to claim every packet is offloaded; ARP/setup/control flows and unsupported
rules need explicit treatment. [S15]

Verify the actual chain after applying the switchdev policy:

```bash
kubectl -n sriov-network-operator get sriovnetworknodestate YOUR_NODE -o json \
  | jq '.spec.system,.status.system'
# On the worker, with its actual service and OVSDB available:
sudo systemctl cat ovs-vswitchd.service
sudo ovs-vsctl get Open_vSwitch . other_config
```

The OVS map must contain hw-offload=true. If the source supports the field but
the installed image does not propagate it, fix image/source compatibility. Do not
silently run ovs-vsctl by hand and label that a passed operator HWOL test. The
Kubernetes plugin may request drain/reboot to install service changes; persistence
must already be working and the test account must explicitly allow that reboot.

## 5. Switchdev node policy and operator-owned bridge

Use the exact PF BDF, not a vendor-wide selector:

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: mock-smartnic-switchdev
  namespace: sriov-network-operator
spec:
  resourceName: mock_smartnic
  nodeSelector:
    mock-smartnic.test/target: dut
  priority: 10
  numVfs: 2
  nicSelector:
    rootDevices:
      - "0000:00:06.0"
  deviceType: netdevice
  isRdma: false
  linkType: eth
  eSwitchMode: switchdev
  mtu: 1500
  externallyManaged: false
  bridge:
    ovs: {}
```

The BDF is an example. scripts/render.py substitutes the configured actual BDF.
The operator must itself create two VFs, bind/configure endpoints, set switchdev,
create its OVS bridge and attach the PF/uplink. In the referenced implementation
bridge names derive from PF BDF (for example `br-0000_00_06.0`). Discover actual
bridge names from NodeState or OVS rather than assuming ifindex/name stability.
[S13]

Wait for both desired and observed NodeState interfaces to show the exact PF,
numVfs=2 and switchdev, plus successful sync and allocatable resources. Also inspect
node conditions, config-daemon logs and native VF-driver absence. A CR accepted
by admission is not successful device configuration.

```bash
kubectl -n sriov-network-operator get sriovnetworknodestate YOUR_NODE -o yaml
kubectl get node YOUR_NODE -o json | jq '.status.allocatable'
# Example key; use the actual configured prefix.
# "openshift.io/mock_smartnic": "2"
```

Inspect the rendered SR-IOV device-plugin resource list and selectors. It must
accept `mock_smartnic_vf`, not require `igbvf`, mlx5 or RDMA devices. Do not change
the driver-reported identity to satisfy a mistaken selector. Fix the test resource
configuration or narrowly adjust the development-only compatibility layer, with
a test demonstrating why it is needed.

## 6. OVSNetwork and generated NAD

The actual CR kind is **OVSNetwork**, with uppercase OVS. The controller should
create the NAD in the workload namespace. Do not create a parallel hand-written
NAD for this final stage; that would skip the controller under test. [S07,S13]

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mock-sriov-e2e
---
apiVersion: sriovnetwork.openshift.io/v1
kind: OVSNetwork
metadata:
  name: mock-ovs
  namespace: sriov-network-operator
spec:
  networkNamespace: mock-sriov-e2e
  resourceName: mock_smartnic
  ipam: |
    {
      "type": "host-local",
      "subnet": "198.19.0.0/24",
      "rangeStart": "198.19.0.10",
      "rangeEnd": "198.19.0.50"
    }
```

No bridge name is required in this CR: ovs-cni can select the bridge using the
allocated VF and its PF/uplink membership. No gateway/default route is configured;
we do not want to redirect pod default traffic onto a nonexistent external wire.
The IP range is an example reserved for this isolated lab. Check for overlap with
cluster/pod/service/underlay ranges before use. host-local is suitable for this
single-worker pair, not a claim of cluster-wide address allocation. [S07,S13]

Inspect:

```bash
kubectl -n mock-sriov-e2e get network-attachment-definition mock-ovs -o json \
  | jq '.metadata.annotations, (.spec.config|fromjson)'
```

The `k8s.v1.cni.cncf.io/resourceName` annotation must be the real extended resource
key. Confirm the plugin type/config and host-local IPAM. Do not infer that a NAD
exists because OVSNetwork creation returned successfully.

## 7. Two pods consuming allocated VFs

One pod can prove CNI ADD. Two pods are needed for the same-node forwarding/offload
proof. The renderer creates both `mock-ovs-a` and `mock-ovs-b`, each with one VF,
using the same node selector. Normal scheduling and resource accounting remain
active; do not bypass allocation by hard-coding a VF BDF in the pod.

Representative pod (the renderer adds full security/resource details):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mock-ovs-a
  namespace: mock-sriov-e2e
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"mock-ovs","namespace":"mock-sriov-e2e","interface":"net1"}]'
spec:
  nodeSelector:
    mock-smartnic.test/target: dut
  containers:
    - name: echo
      image: python:3.12-slim  # resolve/pin your actual image digest
      command:
        - python3
        - -u
        - -c
        - |
          import socket
          s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
          s.bind(('0.0.0.0',9000))
          while True:
              data,peer=s.recvfrom(65535)
              s.sendto(data,peer)
      resources:
        requests:
          openshift.io/mock_smartnic: "1"
        limits:
          openshift.io/mock_smartnic: "1"
```

The executable rendered pods run unprivileged UDP with all capabilities dropped,
no privileged host mount and no host networking. Vanilla Kubernetes uses explicit
nonroot UID 10000; the OpenShift renderer leaves UID assignment to the admitted
SCC. Do not grant privileged SCC merely to make an ordinary UDP test work.

Discover net1 IPs and allocated BDFs, not assumed pod order:

```bash
kubectl -n mock-sriov-e2e get pod mock-ovs-a -o json \
  | jq -r '.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson'
kubectl -n mock-sriov-e2e exec mock-ovs-a -- python3 -c \
  'import os; print(os.getenv("PCIDEVICE_OPENSHIFT_IO_MOCK_SMARTNIC", ""))'
```

The helper uses the actual resource prefix to construct that environment name. If
the device-plugin configuration uses a different allocation delivery method, use
its pod-resources/device-info API and adapt the verifier explicitly. Missing device
identity must fail, not fall back to guessing VF0 for the first pod.

## 8. Execute the supplied Kubernetes workflow

```bash
./scripts/kube.sh render
./scripts/kube.sh preflight
# After confirming independent worker, reboot-safe binding and exclusive lab use:
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
```

Apply uses server-side dry-run, patches only bridge management, creates pool/policy,
waits for real resources, creates OVSNetwork, checks the generated NAD's resource
key, creates the two pods and waits for readiness. It does not touch PF/VF counts
or OVS bridge ports itself. Existing same-name unowned resources are rejected.

Verify sends address-bound UDP on net1, correlates distinct allocated BDFs with
PF virtfn indexes, checks TC in_hw, OVS offloaded datapath evidence, simulator
hit growth and **directional per-flow packet growth for this exact VF pair**.
It is intentionally stronger than “a packet went through” or “some unrelated
flow was offloaded”. Collect component logs separately if the stage fails.

An OVS rule may initially fall back because the mock driver rejects a mask/action.
Collect the actual rule/extack, implement the missing in-scope behavior and retry.
Do not make the verifier accept software-only forwarding to hide the missing work.

## 9. OpenShift / RHCOS lane

This lane uses the same driver behavior but different deployment ownership.
The scripts render its manifests but intentionally refuse automatic apply until
Codex implements and validates a matching immutable-node module-delivery path.

Required steps:

1. Use a dedicated emulated-igb worker, never the control plane. Record OpenShift
   release, RHCOS boot image, actual kernel and supported module-signing policy.
2. Build/sign the module against that exact kernel using a matching build image.
   Package/deliver it through the cluster's approved kernel-module mechanism, such
   as a version-matched KMM installation, or an explicitly managed test image.
   Inspect installed CRDs for the delivery API; do not invent a generic KMM YAML.
3. Ensure PF binding/native-VF suppression happens before config-daemon and kubelet
   reconciliation after reboot. The Ubuntu-style persistence script does not run
   on OSTree; implement/test the equivalent owned configuration via the approved
   node-management path. Do not install Ubuntu headers on RHCOS.
4. Create or use a **dedicated MachineConfigPool** selecting only this worker.
   Its MachineConfig selector normally includes worker and its dedicated role.
   Inspect the MCO's actual pool membership and rendered config before changes.
5. Render with CLUSTER_TYPE=openshift, OPERATOR_NAMESPACE set to the actual operator
   namespace, and MCP_NAME set to the dedicated MCP. Do not use `worker` or `master`.
6. Apply the named HWOL pool object below. Do not include nodeSelector/maxUnavailable
   in the same object: the pinned webhook rejects that combination. Those are
   separate node-pool/parallel-configuration concerns. [S17]
7. Wait for the dedicated MCP update/reboot and worker Ready; verify module binding
   survived. Preserve OLM ownership and do not replace platform-managed components
   with unrelated upstream master images.
8. Apply the node policy/OVSNetwork/pods as above, adapted to the operator schema
   shipped with this OpenShift release. Run the same evidence checks. A missing
   new otherConfig field is a version compatibility issue to resolve, not a reason
   to turn off webhook validation.

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkPoolConfig
metadata:
  name: mock-smartnic-hwol
  namespace: openshift-sriov-network-operator
spec:
  ovsHardwareOffloadConfig:
    name: mock-smartnic      # existing dedicated MCP, not a node label
    otherConfig:
      hw-offload: "true"
      tc-policy: "none"
```

This path can affect the node's shared OVS service, including primary OVN networking.
Do not run generic `systemctl restart openvswitch` from the lab harness on such a
node. Use the approved MCO/operator rollout and its readiness conditions. Reboot,
module, OVN and MCP failures require console/cluster recovery, not blind retries.
[S12,S17]

## 10. Optional VLAN and broader tests

Only after untagged IPv4 passes, add a separate OVSNetwork with vlan=200 and extend
the mock engine for the actual VLAN matches/actions OVS emits. Test isolation and
push/pop/masked matching; do not declare VLAN supported because the CR was accepted.
Separate later lanes cover IPv6, external uplink, cross-worker traffic and stateful
features. Each must explicitly extend the capability contract and negative tests.
<!-- END FILE: docs/04-kubernetes-flow.md -->

---

<a id="file-docs-05-validation-and-recovery-md"></a>

## Repository file: `docs/05-validation-and-recovery.md`

<!-- BEGIN FILE: docs/05-validation-and-recovery.md -->
# 05 — Acceptance matrix, observability and recovery

## 1. Test evidence hierarchy

A successful module build proves compile compatibility only. PCI enumeration
proves topology only. devlink/TC acceptance proves API compatibility only. Pod
Running proves scheduling/CNI progress only. Traffic proves connectivity only.
The final acceptance combines topology, ownership, flow status and **new packet
execution in the driver's offload engine**. No layer may substitute for another.

All results need the exact command, exit status, kernel/source/image versions and
a timestamped artifact. Save the baseline kernel log timestamp before a test;
compare new warnings rather than blaming the module for unrelated old boot logs.

## 2. Mandatory test matrix

| ID | Exercise | Pass condition |
|---|---|---|
| S01 | Missing ACK, malformed BDF, wrong context | Refuse before hardware/cluster mutation. |
| S02 | PF has management route/IP/master/OVS membership | Refuse takeover. |
| S03 | VM is PCI passthrough, not emulated | Human XML gate rejects; no kernel mutation. |
| P01 | Native -> mock PF bind | Exact BDF changes driver; management survives. |
| P02 | 0 -> 2 -> 0 -> 2 VFs | Correct guest PCI objects, physfn/virtfn, no orphan. |
| P03 | VF default-driver reprobe | Mock driver binds after override cleared. |
| P04 | Wrong/other-PF VF probe | Refused without affecting another device. |
| D01 | Legacy/switchdev GET/SET, before/after VFs | Correct state, stable PF, correct rep count. |
| D02 | PF/VF/rep metadata | Exact sriovnet functions resolve the expected relationships. |
| D03 | VF netns move/delete/return | No endpoint/representor conflation or stale references. |
| N01 | VF-to-rep and rep-to-VF slow pipe | Correct direction, packet contents, no duplicates. |
| N02 | No switch/rules | VF-to-VF traffic fails (no hidden bypass). |
| T01 | Two skip_sw redirect rules | Real receive, in_hw, TC packet counts, driver hit growth. |
| T02 | Delete the rules | Traffic stops without an alternate software switch. |
| T03 | Unsupported nonzero match/action | Fails with driver extack; no partial install. |
| T04 | Masking, priority, protocol, fragments | Rule behavior matches its declared predicates. |
| T05 | Repeated stats reads with no traffic | TC/OVS counters do not increase artificially. |
| T06 | Replace/delete under traffic | No UAF, old stale rule, double delivery or lost references. |
| O01 | OVS-generated flower, no hand-installed TC | OVS reports offloaded flows, proper pair hits grow. |
| O02 | Unsupported OVS flow/fallback lane | Explicitly identified fallback, not reported as HWOL pass. |
| B01 | Controlled worker reboot | Mock PF ready before reconciliation; no native VF takeover. |
| K01 | Operator pool otherConfig propagation | Actual host OVS has hw-offload=true via operator. |
| K02 | NodePolicy creates VFs/switchdev/bridge | Spec/status agree; bridge is operator-owned. |
| K03 | OVSNetwork controller | Generated NAD has correct CNI config/resource annotation. |
| K04 | Pod allocation/CNI | Separate BDFs; VF in pod; correct rep attached by ovs-cni. |
| K05 | net1 two-way UDP plus offload evidence | All supplied evidence assertions pass. |
| K06 | Pod deletion/recreation | CNI DEL cleans host ports; VF can be allocated again. |
| R01 | 50 pod cycles; 10 mode/VF cycles | No leaks, warnings, stale ports, inaccurate resource counts. |
| R02 | Module teardown/debugfs readers | No invalid refs or unload deadlock. |
| R03 | Insufficient resources | Third pod pending on two exhausted VFs, then allocates after release. |
| R04 | Invalid/injected allocation failure | Clear errors and recovery, not forged success. |

Numbering here is a test taxonomy, not the implementation-package numbering.

## 3. Unit tests to implement

Use KUnit where suitable for pure matcher/action normalization; a userspace mirror
may supplement it but is not a substitute for the actual compiled kernel code.
Cover byte order, all accepted mask bits, IPv4 options/truncation, fragments,
non-linear headers, disabled/down destinations, wrong-switch redirects, unsupported
chains/actions and deterministic rule selection. Include deliberate allocation
failures and replacement rollback consistent with the pinned TC core.

Test reference release: every acquired netdev/port reference has a matching release
on add failure, successful delete, block unbind, VF removal and module unload.
Test stats accumulation/delta reporting, concurrent reads and lastused semantics.

The supplied tests/test_harness.py covers config/rendering and synthetic evidence
accept/reject cases, not a kernel implementation. Expand shell runner tests with
mocked ssh/rsync/kubectl tools to verify refusal before mutation and proper quoting.

## 4. Kernel concurrency and lifecycle stress

Run a debug kernel with lockdep/KASAN where feasible, with exact build match.
Concurrently generate VF traffic, add/replace/delete flower rules and read stats.
Then detach OVS ports, remove pods/namespaces, remove VFs and unload the module in
the documented order. Ensure teardown stops ingress producers, makes endpoints
unreachable under RCU, flushes queues, unregisters netdevices/devlink and only then
releases shared state. Never hold RTNL/config locks across recursive remove/probe
paths that take the same locks.

Do not intentionally remove assigned VFs under a production pod. In an isolated
negative test, verify controlled failure/refusal or the documented exceptional
recovery behavior. An out-of-tree simulator should not make the guest kernel
crash simply because a cleanup call arrived in an unexpected order.

## 5. Failure diagnosis

| Symptom | First checks / likely boundary |
|---|---|
| No sriov_numvfs | Wrong device model, no SR-IOV capability or CONFIG_PCI_IOV; pci-testdev cannot fix this. |
| pci_enable_sriov fails | Capture PCI resource/bus/BAR and emulator logs; investigate K02, not devlink. |
| VFs exist but no netdev | Mock VF probe failed, wrong parent association or native igbvf won. |
| CNI cannot find representor | Compare phys_switch_id, port attrs, VF index and exact sriovnet library behavior. |
| Operator stuck rebooting | Persistent binding/service dependency, kernel version change, repeated OVS drop-in diff. |
| NodeState doesn't show PF | PF netdev missing in legacy, discovery NIC whitelist/DEV_MODE or wrong worker selector. |
| Resource allocatable remains zero | Device-plugin selectors, actual driver name, link state, PF roots or namespace. |
| Pod Pending | Requested resource prefix/name, two-VF exhaustion, node selector or taints. |
| Pod ContainerCreating | Multus/CNI invocation, missing ovs binary/socket, PCI resolution, VF setters or netns move. |
| tc skip_sw rejected | Inspect extack; feature bit, block binding, unsupported mask/action or stats mode. |
| in_hw true but packets fail | Direction bug, incomplete matcher/action implementation, RX skb/header state. |
| Packets pass but driver hits do not | Software OVS fallback, hidden switch bypass or wrong-interface test. |
| Counters grow without traffic | Reporting cumulative stats as repeated deltas, duplicate execution or unrelated flows. |
| VLAN lane fails only | Untagged/tagged match masks, VLAN metadata vs inline headers, push/pop semantics. |

Do not resolve a failure by modifying expected output or disabling a verifier.
Record any necessary design change and add a regression test for the real defect.

## 6. Cleanup after a successful or failed final flow

Do not unload the module first. Ordered cleanup:

```bash
./scripts/kube.sh collect
./scripts/lab.sh collect > artifacts/before-cleanup.txt
./scripts/kube.sh cleanup
```

The cleanup command deletes only owned pods, OVSNetwork and NodePolicy. It leaves
the DUT label and hardware-offload pool temporarily so the responsible controllers
can finish restoring state. Wait for CNI DEL, NAD/controller finalizers, policy
removal from NodeState and operator-owned bridge cleanup. Inspect any finalizer
failure; do not strip finalizers blindly.

Once NodeState no longer requests the mock interface/bridge, verify on the DUT that
the PF/representors are no longer OVS ports and no VF remains in another namespace.
Then delete the owned pool object and wait for its controller. On OpenShift, pool
removal can trigger MCO changes/reboot; keep module delivery active until complete.

```bash
kubectl --context YOUR_CONTEXT -n YOUR_OPERATOR_NAMESPACE \
  delete sriovnetworkpoolconfig YOUR_OWNED_POOL --wait=true --timeout=10m
# Only when ownership reconciliation is finished:
./scripts/lab.sh reset
./scripts/lab.sh unpersist     # only if persistence was installed
./scripts/lab.sh restore
```

`restore` recovers the native PF driver and saved override/autoprobe/admin state
from the initial zero-VF baseline. It does not restore arbitrary pod IPs or global
OVS state, because takeover was prohibited when the PF had such configuration.
It removes the harness-owned native-VF blacklist. A kernel panic needs console or
snapshot recovery; shell cleanup cannot guarantee recovery from a dead kernel.

## 7. Restore operator/global OVS configuration deliberately

The operator may leave OVS service configuration after policy deletion. Preserve
before/after copies of the OVSDB other_config map and unit/drop-ins. Inspect the
pinned operator's removal behavior, remove/revert **only its test-owned changes**
through the proper owner and perform any service restart via a safe lab rollout.
Never assume deleting a CR automatically restores every host service setting.

The saved `artifacts/kubernetes/original-operatorconfig.json` is a reference for
restoring just the test's manageSoftwareBridges change. Do not replace the entire
old spec over concurrent legitimate edits. Restore that single field to its old
value, or remove it if it was absent, after checking current ownership/changes.
Leave unrelated feature gates and daemon selectors intact.

Remove `mock-smartnic.test/target` from the node only after teardown completed.
Delete the workload namespace only after proving it contains no unrelated objects.
If the test installed its own Helm release, uninstall that release deliberately;
do not uninstall an existing/OLM-owned operator. Keep a final rollback log.

## 8. What the final implementation report must say

Report the real tested matrix: QEMU/machine, kernel/ABI/config, module source/hash,
OVS/iproute2, operator/daemon/ovs-cni/device-plugin image IDs, primary CNI/Multus,
cluster/node versions and tested feature subset. Include K02 outcome, direct TC
negative control, reboot result and final pair-specific evidence.

Use these distinct states: NOT IMPLEMENTED; IMPLEMENTED NOT BUILT; BUILT NOT RUN;
RUNTIME FAILED; RUNTIME PASSED. This delivered planning package only has local
harness tests. Codex must not turn that into a claim that the driver was validated.
<!-- END FILE: docs/05-validation-and-recovery.md -->

---

<a id="file-docs-06-sources-md"></a>

## Repository file: `docs/06-sources.md`

<!-- BEGIN FILE: docs/06-sources.md -->
# 06 — Primary-source references and version notes

Research refreshed 23 September 2026. The source links support the existing API
contracts and infrastructure, **not a claim that the proposed mock driver exists**.
The kernel and runtime package versions must be locked by the implementing agent.
Documentation URLs and unpinned master URLs can change; record actual revisions.

The operator default branch inspected resolves to
`a5588da21699fccce921cb1d4ac5894f47889399` (16 September 2026), whose merge includes
configurable ovs-vswitchd other_config. All operator implementation references below
use that immutable commit. The project must verify feature compatibility again if
it uses an older OpenShift/OLM release or newer upstream source.

## References

**[S01] Existing virtual operator tests.**
[Virtual-machine test guide](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/doc/testing-virtual-machine.md)
and its linked virtual-cluster script. Establishes emulated igb testing, DEV_MODE
and supported-NIC setup. Its VFIO/no-IOMMU discussion is deliberately not used in
this kernel-netdevice-only project.

**[S02] kcli existing provider support.**
[KVM provider](https://github.com/karmab/kcli/blob/c77c75380bf3efa70ba977327d562a0dce69c61d/kvirt/providers/kvm/__init__.py).
Contains native igb model handling and qemuextra/namespace/commandline generation;
no new dummy_pcidevices option is required for the baseline.

**[S03] QEMU emulated SR-IOV NIC and helpers.**
[igb.c](https://github.com/qemu/qemu/blob/master/hw/net/igb.c),
[PCIe SR-IOV helpers](https://github.com/qemu/qemu/blob/master/hw/pci/pcie_sriov.c),
[pci-testdev.c](https://github.com/qemu/qemu/blob/master/hw/misc/pci-testdev.c).
Inspect exact checkout for PF helper signatures, VF device ID/offset/stride/BARs.
The proposal reuses PCI semantics, not the native igb networking engine.

**[S04] Linux SR-IOV core.**
[PCI IOV howto](https://docs.kernel.org/PCI/pci-iov-howto.html) and
[drivers/pci/iov.c](https://github.com/torvalds/linux/blob/master/drivers/pci/iov.c).
Documents actual PF/VF creation, configure return values and VF autoprobe control.

**[S05] Vendor-specific firmware expectations.**
[Mellanox plugin](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/plugins/mellanox/mellanox_plugin.go).
Reason not to impersonate Mellanox in a generic in-guest simulator.

**[S06] Representor contract.**
[Network Function Representors](https://docs.kernel.org/networking/representors.html).
Defines slow-path directions, VF TX vs representor ingress, redirect-to-representee,
modern devlink identity and the distinction from a PCI endpoint.

**[S07] ovs-cni SR-IOV discovery and configuration.**
[sriov.go](https://github.com/k8snetworkplumbingwg/ovs-cni/blob/19262a0c9f304dc9cb04454afeed77e6ca77950b/pkg/sriov/sriov.go).
Explains VF BDF -> uplink/index/representor, endpoint movement, MAC/MTU setup and
bridge resolution. Use that checkout's actual sriovnet dependency version.

**[S08] Devlink port flavors and associations.**
[Devlink port documentation](https://docs.kernel.org/networking/devlink/devlink-port.html).
Distinguishes physical uplink and PCI PF/VF flavors. API usage must match the target
kernel rather than an unversioned copied example.

**[S09] Operator default-driver rebinding behavior.**
[kernel.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/host/internal/kernel/kernel.go),
[sriov.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/host/internal/sriov/sriov.go).
BindDefaultDriver accepts already-bound non-DPDK drivers and clears override before
probing an unbound default driver; manual per-VF overrides alone are insufficient.

**[S10] Existing simulation reference.**
[netdevsim bus](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/bus.c),
[netdevsim networking](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/netdev.c),
[netdevsim TC](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/tc.c).
Reference patterns, not a drop-in PCI SR-IOV SmartNIC implementation.

**[S11] Resolved operator revision.**
[Commit a5588da](https://github.com/k8snetworkplumbingwg/sriov-network-operator/commit/a5588da21699fccce921cb1d4ac5894f47889399).
Includes the configurable OVS other_config API/runtime change relied upon here.

**[S12] Kubernetes OVS service integration.**
[k8s_plugin.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/plugins/k8s/k8s_plugin.go).
Checks ovs-vswitchd.service, renders OVS service options and can request a reboot.

**[S13] End-to-end bridge/network APIs.**
[OVS HWOL guide](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/doc/ovs-hw-offload.md),
[NodePolicy types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/sriovnetworknodepolicy_types.go),
[OVSNetwork types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/ovsnetwork_types.go).
Source for manageSoftwareBridges, bridge.ovs, switchdev policy and uppercase OVSNetwork.

**[S14] Libvirt commandline passthrough boundaries.**
[QEMU passthrough security](https://libvirt.org/kbase/qemu-passthrough-security.html).
Opaque extra devices need explicit topology/security/resource handling.

**[S15] OVS TC offload.**
[TC flower offload guide](https://docs.openvswitch.org/en/latest/howto/tc-offload/).
Source for hw-offload configuration and caveats including TC/software byte-count
differences. Pin OVS version and inspect its tc-policy behavior.

**[S16] TC core offload bookkeeping.**
[net/sched/cls_api.c](https://github.com/torvalds/linux/blob/master/net/sched/cls_api.c).
Successful callbacks are accounted by the core; drivers should not fabricate
classifier in_hw flags. Replace semantics must be checked against the target kernel.

**[S17] Pool configuration distinction and propagation.**
[Pool types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/sriovnetworkpoolconfig_types.go),
[findNodePoolConfig](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/helper.go),
[NodePolicy controller](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/sriovnetworknodepolicy_controller.go),
[HWOL/MCP controller](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/sriovnetworkpoolconfig_controller.go),
[webhook validation](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/webhook/validate.go).
Named HWOL configurations and node-selected pools have different code paths;
combining nonempty HWOL name with nodeSelector/maxUnavailable is rejected.

**[S18] Fresh-install chart inputs.**
[values.yaml](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/deployment/sriov-network-operator-chart/values.yaml),
[operator template](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/deployment/sriov-network-operator-chart/templates/operator.yaml).
Contains full image inputs, DEV_MODE extra-env support, resource prefix, CNI path,
config-daemon node selector and supportedExtraNICs.

**[S19] Additional implementation-time prerequisite reference.**
[Multus CNI upstream](https://github.com/k8snetworkplumbingwg/multus-cni).
Select and pin a deployment matching the target cluster. No particular Multus
release or manifest was runtime validated for this package.

## Version-lock template the agent must fill

```json
{
  "operator_source": "a5588da21699fccce921cb1d4ac5894f47889399",
  "qemu_version": "RECORD_FROM_HYPERVISOR",
  "qemu_machine": "RECORD_EXACT_Q35_VERSION",
  "guest_kernel": "RECORD_UNAME_R",
  "kernel_config_sha256": "RECORD",
  "driver_source_commit": "RECORD",
  "driver_module_sha256": "RECORD",
  "ovs_version": "RECORD",
  "iproute2_version": "RECORD",
  "kubernetes_version": "RECORD",
  "operator_image_digest": "RECORD",
  "daemon_image_digest": "RECORD",
  "ovs_cni_image_digest": "RECORD",
  "sriov_device_plugin_image_digest": "RECORD",
  "multus_image_digest": "RECORD",
  "workload_image_digest": "RECORD"
}
```

The RECORD placeholders are intentionally not measurements. The implementing
agent must replace them from the real lab before claiming reproducible results.
<!-- END FILE: docs/06-sources.md -->

---

<a id="file-implementation-status-md"></a>

## Repository file: `IMPLEMENTATION-STATUS.md`

<!-- BEGIN FILE: IMPLEMENTATION-STATUS.md -->
# Implementation status

## Package delivery

- Architecture and work packages: specified.
- VM and Kubernetes harness: supplied as a starting implementation.
- Local shell/Python/manifest/evidence-fixture checks: see VALIDATION-REPORT.md.
- Driver sources: not implemented in this planning package.
- Kernel module compilation: not run.
- VM connection / PCI PF takeover: not run; no VM access supplied.
- Manual TC / OVS / Kubernetes runtime tests: not run.

## Agent progress table

| Gate | Implemented | Built | Runtime passed | Evidence / blocker |
|---|---|---|---|---|
| K00 inventory and source lock | no | n/a | no | |
| K01 module scaffold | no | no | no | |
| K02 PCI carrier and VF lifecycle | no | no | no | mandatory go/no-go |
| K03 devlink/netdev discovery | no | no | no | |
| K04 slow-path datapath | no | no | no | |
| K05 TC parse/execute/stats | no | no | no | |
| K06 direct TC and standalone OVS | no | no | no | |
| K07 reboot-safe deployment | no | no | no | |
| K08 operator full flow | no | no | no | |
| K09 resilience and CI | no | no | no | |

Append a dated entry per attempt with source SHA, running kernel, commands,
exit codes, evidence paths, and next action. Never replace unknown with pass.
<!-- END FILE: IMPLEMENTATION-STATUS.md -->

---

<a id="file-validation-report-md"></a>

## Repository file: `VALIDATION-REPORT.md`

<!-- BEGIN FILE: VALIDATION-REPORT.md -->
# Validation report

Validation date: 23 September 2026.

## What was delivered

A Codex implementation specification, kernel-driver work packages, remote-VM
build/bind/recovery harness, Kubernetes resource renderer and integration runner,
platform-specific example manifests, synthetic evidence-verification tests, and
primary-source references. **There is no implemented driver in this package.**
The supplied runtime scripts are starting harnesses for that implementation, not
an assertion that any of the planned kernel interfaces already exist.

## Checks executed locally

From the package root:

```bash
./scripts/run-local-checks.sh
```

| Check | Result | Scope |
|---|---|---|
| Bash syntax (`bash -n`) | Passed | All supplied shell scripts, including shared helpers |
| Python compilation (`py_compile`) | Passed | Renderer, UDP probe, evidence verifier and fixture tests |
| Fixture tests (`unittest`) | 14 passed | Manifest construction and simulated evidence validation |
| YAML round-trip | Passed | Renderer output round-tripped through PyYAML in the fixture test |
| Both platform example manifest sets | Parsed | Additional packaging check; not API-server admission |
| JSON examples | Parsed | Operator feature-gate patches |
| Relative document links | Checked | Package-local Markdown links; remote source URLs were not re-fetched by this checker |
| ShellCheck | Not run | ShellCheck is not installed in the validation environment |

The exact latest local test output is in `tests/local-validation.log`.
`test_yaml_roundtrip_if_parser_available` passed, rather than being skipped, in
this environment. The test suite can skip it on a machine without PyYAML.

The evidence fixtures test that connectivity alone is insufficient: the verifier
rejects missing driver-hit deltas, stale directional flows, missing TC `in_hw`,
disabled OVS offload and mismatched allocated PCI identities. A passing synthetic
fixture proves only that the verifier accepts that fixture, **not** that a driver
implements forwarding or that OVS reports real runtime offload.

## Checks not executed

No SSH connection to a user VM, hypervisor XML inspection, kernel-module build,
module insertion/signing, PF takeover, VF enumeration, devlink operation, TC
packet test, OVS packet test, Kubernetes admission test, operator reconciliation,
pod creation, node reboot, OpenShift MachineConfig rollout, or live recovery was
performed. No runtime throughput, hardware compatibility, or success rate is
claimed. No VM credentials, SSH keys or kubeconfig were provided or embedded.

The `igb`-carrier experiment remains the mandatory K02 feasibility gate. It must
be demonstrated with the actual guest kernel and QEMU configuration. Do not
interpret a code outline as a verified replacement for the native NIC driver.

## Platform coverage

The executable remote-build and automated cluster-apply route targets a mutable
Linux Kubernetes worker VM with the required OVS service. The OpenShift lane has
renderable CRs and a detailed implementation/runbook path, but automatic apply
intentionally refuses OpenShift until immutable-host kernel-module delivery,
dedicated MCP scope and reboot integration are implemented and verified.

## Inputs and approvals still required

Supply a trusted SSH alias, the exact emulated PF BDF, local cluster context and
matching node name, component image references and the site-specific registry /
CNI prerequisites. Confirm a separate management NIC and console recovery. The
separate PF, persistent-install and cluster/reboot acknowledgements must only be
set for the explicitly authorized lab. Example addresses, BDFs and image digest
placeholders are not discovered user infrastructure.

## Agent reporting rule

Update `IMPLEMENTATION-STATUS.md` after each gate with real source/binary hashes,
commands, exit statuses and evidence. Distinguish code implemented, module built,
runtime test passed, blocked and not tested. A kernel warning, failed rollback,
software fallback or rejected unsupported rule must not be hidden by changing
expected results merely to make the test green.
<!-- END FILE: VALIDATION-REPORT.md -->

---

<a id="file-manifests-readme-md"></a>

## Repository file: `manifests/README.md`

<!-- BEGIN FILE: manifests/README.md -->
# Example manifests

These are reviewable examples with a sample PF BDF, namespace and workload image.
Use `scripts/kube.sh render` to generate your real lab inputs. Do not apply these
examples blindly. Both lanes include operator bridge-management patch, a hardware-
offload pool, switchdev node policy, OVSNetwork and two resource-requesting pods.

Kubernetes uses a node-selected pool with no nonempty HWOL name. OpenShift uses an
existing dedicated MCP name and omits nodeSelector/maxUnavailable in that object.
Read docs/04-kubernetes-flow.md before applying. These schemas were rendered and
parsed locally, but no live Kubernetes admission or reconciliation was exercised.
<!-- END FILE: manifests/README.md -->

---

<a id="file-config-images-example-yaml"></a>

## Repository file: `config/images.example.yaml`

<!-- BEGIN FILE: config/images.example.yaml -->
```yaml
# Input shape only. Replace each REQUIRED_* with a REAL compatible digest.
# Copy to a local images.lock.yaml; set OPERATOR_IMAGE_VALUES to its absolute path.
# Never invent tags/digests from source commit hashes.
images:
  operator: REGISTRY/operator@sha256:REQUIRED_OPERATOR_DIGEST
  sriovConfigDaemon: REGISTRY/config-daemon@sha256:REQUIRED_DAEMON_DIGEST
  ovsCni: REGISTRY/ovs-cni@sha256:REQUIRED_OVS_CNI_DIGEST
  sriovDevicePlugin: REGISTRY/device-plugin@sha256:REQUIRED_DEVICE_PLUGIN_DIGEST
  sriovCni: REGISTRY/sriov-cni@sha256:REQUIRED_SRIOV_CNI_DIGEST
  ibSriovCni: REGISTRY/ib-sriov-cni@sha256:REQUIRED_IB_CNI_DIGEST
  rdmaCni: REGISTRY/rdma-cni@sha256:REQUIRED_RDMA_CNI_DIGEST
  resourcesInjector: REGISTRY/resources-injector@sha256:REQUIRED_INJECTOR_DIGEST
  webhook: REGISTRY/webhook@sha256:REQUIRED_WEBHOOK_DIGEST
  metricsExporter: REGISTRY/metrics-exporter@sha256:REQUIRED_EXPORTER_DIGEST
  metricsExporterKubeRbacProxy: REGISTRY/kube-rbac-proxy@sha256:REQUIRED_PROXY_DIGEST
```
<!-- END FILE: config/images.example.yaml -->

---

<a id="file-config-lab-env-example"></a>

## Repository file: `config/lab.env.example`

<!-- BEGIN FILE: config/lab.env.example -->
```bash
# Copy to config/lab.env. This is trusted shell input; do not commit credentials.
# Use ~/.ssh/config for HostName/User/IdentityFile/ProxyJump and verify its host key.
SSH_TARGET=mock-smartnic-dut
REMOTE_DIR=/var/tmp/mock-smartnic-lab
# Directory containing driver/Makefile and, after implementation, the driver sources.
# Leave empty to use this bundle/repository root.
SRC_ROOT=
PF_BDF=0000:00:06.0
NUM_VFS=2
EXPECTED_PF_VENDOR=0x8086
EXPECTED_PF_DEVICE=0x10c9
EXPECTED_VF_DEVICE=0x10ca
# Mandatory before ANY networking/module mutation. Set to the exact PF_BDF only after
# verifying the hypervisor XML: this is an emulated igb NIC, NOT a hostdev/passthrough.
EMULATED_PF_ACK=
# Set YES only after stopping conflicting policies/workloads on the dedicated PF.
EXCLUSIVE_PF_ACK=
# Cluster-wide / persistent changes have separate opt-ins.
CLUSTER_MUTATION_ACK=
PERSISTENCE_ACK=
# The operator may restart OVS and reboot the DUT. Never use a production node.
OPERATOR_REBOOT_ACK=
# Local CLI access. KUBE_CONTEXT must match the current intended lab context.
KUBECTL=kubectl
KUBE_CONTEXT=
NODE_NAME=
CLUSTER_TYPE=kubernetes
OPERATOR_NAMESPACE=sriov-network-operator
WORKLOAD_NAMESPACE=mock-sriov-e2e
RESOURCE_PREFIX=openshift.io
RESOURCE_NAME=mock_smartnic
POLICY_NAME=mock-smartnic-switchdev
NETWORK_NAME=mock-ovs
POOL_NAME=mock-smartnic-pool
# For OpenShift only: pre-existing dedicated MachineConfigPool, never master/worker.
MCP_NAME=
# Inspect and pin to a pullable digest for repeatable CI. This tag is a starting input.
# Must contain python3; the workload uses unprivileged UDP sockets, not ping.
WORKLOAD_IMAGE=python:3.12-slim
# Used by the optional upstream Helm installation, not by an existing OLM install.
OPERATOR_SOURCE=
OPERATOR_REF=a5588da21699fccce921cb1d4ac5894f47889399
# Required explicit file of compatible, pullable component image overrides.
OPERATOR_IMAGE_VALUES=
# Increase for rebooting nodes; all polls are bounded.
WAIT_SECONDS=900

# Local SSH command deadline; a hung kernel syscall may still require console recovery.
REMOTE_TIMEOUT=600
```
<!-- END FILE: config/lab.env.example -->

---

<a id="file-scripts-bootstrap-guest-sh"></a>

## Repository file: `scripts/bootstrap-guest.sh`

<!-- BEGIN FILE: scripts/bootstrap-guest.sh -->
```bash
#!/usr/bin/env bash
# Optional mutable-guest dependency install. Explicit --install required.
set -Eeuo pipefail
[[ ${1:-} == --install && $EUID == 0 ]] || { echo 'Usage: sudo bootstrap-guest.sh --install' >&2; exit 1; }
[[ ! -e /run/ostree-booted ]] || { echo 'Immutable OS: use kernel-matched build/module delivery; do not install host build packages.' >&2; exit 1; }
source /etc/os-release
case "$ID" in
  ubuntu|debian)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential "linux-headers-$(uname -r)" \
      iproute2 ethtool pciutils kmod jq python3 rsync openvswitch-switch iputils-ping
    ;;
  fedora|rhel|centos|rocky|almalinux)
    dnf install -y gcc make elfutils-libelf-devel "kernel-devel-$(uname -r)" \
      iproute ethtool pciutils kmod jq python3 rsync openvswitch iputils
    ;;
  *) echo "Unsupported automatic package mapping for $ID; install the listed dependencies manually." >&2; exit 1 ;;
esac
[[ -d /lib/modules/$(uname -r)/build ]]
echo 'Installed build/network tools. Inspect and explicitly start the appropriate OVS service in the dedicated lab.'
echo 'No kernel upgrade, security bypass, PF rebind, or intentional reboot was performed.'
```
<!-- END FILE: scripts/bootstrap-guest.sh -->

---

<a id="file-scripts-guest-sh"></a>

## Repository file: `scripts/guest.sh`

<!-- BEGIN FILE: scripts/guest.sh -->
```bash
#!/usr/bin/env bash
# DUT-side harness. Driver interfaces below are implementation requirements, NOT
# claims that mock_smartnic.ko already exists. Run through scripts/lab.sh.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/lab.env"
ACTION=${1:-preflight}
SSH_PEER=${2:-}
P=/sys/bus/pci/devices/$PF_BDF
STATE=/var/lib/mock-smartnic-lab/$PF_BDF
PF_DRIVER=mock_smartnic_pf
VF_DRIVER=mock_smartnic_vf
MODULE=mock_smartnic
MODULE_FILE=$SOURCE_DIR/driver/mock_smartnic.ko
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null || fail "Missing command: $1"; }
current_driver() { [[ ! -L "$1/driver" ]] || basename "$(readlink -f "$1/driver")"; }
pf_netdev() {
  local names=()
  mapfile -t names < <(find "$P/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
  ((${#names[@]} == 1)) || fail 'The PF must have exactly one PCI-parented uplink netdev.'
  printf '%s\n' "${names[0]}"
}
identity() {
  [[ -d "$P" ]] || fail "PCI function absent: $PF_BDF"
  [[ $(cat "$P/vendor") == "$EXPECTED_PF_VENDOR" && $(cat "$P/device") == "$EXPECTED_PF_DEVICE" ]] || fail 'Unexpected PCI identity.'
  [[ -r "$P/sriov_totalvfs" ]] || fail 'Missing SR-IOV capability; pci-testdev is not sufficient.'
  (($(cat "$P/sriov_totalvfs") >= NUM_VFS)) || fail 'Not enough VFs exposed by the emulator.'
}
mutation() {
  [[ $EUID == 0 ]] || fail 'This action needs root.'
  [[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || fail 'Require exact EMULATED_PF_ACK and EXCLUSIVE_PF_ACK=YES.'
  identity
  require systemd-detect-virt
  case "$(systemd-detect-virt --vm || true)" in qemu|kvm) ;; *) fail 'This harness only mutates an attested QEMU/KVM guest.';; esac
}
not_used() {
  local dev=$1
  [[ ! -L /sys/class/net/$dev/master ]] || fail "$dev belongs to a bridge/bond/VRF."
  ! compgen -G "/sys/class/net/$dev/upper_*" >/dev/null || fail "$dev has an upper device."
  [[ -z $(ip -o addr show dev "$dev" scope global) ]] || fail "$dev has a global IP address."
  [[ -z $(ip route show default dev "$dev") && -z $(ip -6 route show default dev "$dev") ]] || fail "$dev carries a default route."
  if [[ -n $SSH_PEER ]]; then
    local route
    route=$(ip route get "$SSH_PEER" 2>/dev/null || ip -6 route get "$SSH_PEER" 2>/dev/null || true)
    [[ " $route " != *" dev $dev "* ]] || fail "$dev carries the SSH connection."
  fi
  if command -v ovs-vsctl >/dev/null; then
    local br
    ovs-vsctl --timeout=3 show >/dev/null 2>&1 || fail "Cannot verify OVS ownership of $dev: OVSDB is unavailable."
    br=$(ovs-vsctl --timeout=3 iface-to-br "$dev" 2>/dev/null || true)
    [[ -z $br ]] || fail "$dev belongs to OVS bridge $br. Clean up its owner first."
  fi
}
reps() {
  devlink -j port show | jq -r --arg p "pci/$PF_BDF/" '
    (.port // {}) | to_entries[] | select(.key|startswith($p)) |
    select(.value.flavour == "pcivf") | .value.netdev // empty'
}
assert_idle_vfs() {
  local vf drv names d
  shopt -s nullglob
  for vf in "$P"/virtfn*; do
    vf=$(readlink -f "$vf"); drv=$(current_driver "$vf")
    [[ -n $drv ]] || continue
    [[ $drv == "$VF_DRIVER" ]] || fail "VF bound to unexpected driver $drv; refusing reset."
    names=$(find "$vf/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true)
    [[ -n $names ]] || fail 'VF netdev absent from host namespace; remove its pod/netns first.'
    while read -r d; do not_used "$d"; done <<< "$names"
  done
  while read -r d; do [[ -z $d ]] || not_used "$d"; done < <(reps)
}
case "$ACTION" in
  build)
    require make; require gcc
    [[ -d /lib/modules/$(uname -r)/build ]] || fail 'Install headers/devel for the RUNNING kernel, not merely the newest kernel.'
    [[ -f $SOURCE_DIR/driver/Makefile ]] || fail 'Implement driver/Makefile before building.'
    jobs=$(getconf _NPROCESSORS_ONLN); ((jobs <= 8)) || jobs=8
    make -C "/lib/modules/$(uname -r)/build" M="$SOURCE_DIR/driver" clean
    make -C "/lib/modules/$(uname -r)/build" M="$SOURCE_DIR/driver" W=1 -j"$jobs" modules
    test -s "$MODULE_FILE"
    modinfo "$MODULE_FILE"
    sha256sum "$MODULE_FILE"
    exit ;;
esac
[[ $EUID == 0 ]] || fail 'Use sudo -n for DUT inspection and mutation.'
require ip; require lspci; require ethtool; require devlink; require jq
case "$ACTION" in
  preflight)
    identity
    uname -a; cat /etc/os-release
    systemd-detect-virt --vm || true
    printf '\nPCI\n'; lspci -Dnnk -s "$PF_BDF"; lspci -Dvv -s "$PF_BDF"
    printf '\nSR-IOV\n'; cat "$P/sriov_totalvfs" "$P/sriov_numvfs" "$P/sriov_drivers_autoprobe"
    printf '\nNETWORK\n'; ip -br link; ip -br addr; ip route; ip -6 route
    printf '\nKERNEL BUILD\n'; ls -ld "/lib/modules/$(uname -r)/build" || true
    [[ ! -f /sys/kernel/security/lockdown ]] || cat /sys/kernel/security/lockdown
    command -v mokutil >/dev/null && mokutil --sb-state || true
    printf '\nOVS\n'; ovs-vsctl --version 2>/dev/null || true
    systemctl cat ovs-vswitchd.service 2>/dev/null || true
    printf '\nNOTE: DMI + PCI IDs do not prove emulation. Inspect hypervisor XML before ACK.\n'
    ;;
  bind)
    mutation
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Start with zero VFs; do not destroy existing allocations.'
    [[ $(current_driver "$P") != "$PF_DRIVER" ]] || fail 'Already bound. Use reset/restore before replacing a loaded module.'
    old=$(current_driver "$P"); [[ $old == igb ]] || fail 'The initial carrier must be bound to native igb.'
    dev=$(pf_netdev); not_used "$dev"
    [[ -f $MODULE_FILE ]] || fail 'Build the driver first.'
    [[ $(modinfo -F vermagic "$MODULE_FILE") == "$(uname -r) "* ]] || fail 'Module vermagic differs from running kernel.'
    [[ ! -e /sys/module/$MODULE ]] || fail 'Module already loaded; restore/unload it before another bind.'
    [[ ! -e $STATE/original.env ]] || fail 'Existing recovery state found; restore it instead of overwriting.'
    # Do not displace any unrelated native VF driver users.
    if [[ -d /sys/bus/pci/drivers/igbvf ]]; then
      [[ -z $(find /sys/bus/pci/drivers/igbvf -maxdepth 1 -type l -name '????:??:??.?' -print) ]] || fail 'Other native igbvf devices are bound.'
    fi
    if [[ -d /sys/module/igbvf ]]; then modprobe -r igbvf || fail 'Cannot unload igbvf (possibly built-in).'; fi
    block=/etc/modprobe.d/mock-smartnic-lab-igbvf.conf
    [[ ! -e $block ]] || fail "Refusing to overwrite $block. Recover the earlier run."
    install -d -m 700 "$STATE"
    {
      printf 'ORIGINAL_DRIVER=%q\n' "$old"
      printf 'ORIGINAL_OVERRIDE=%q\n' "$(cat "$P/driver_override")"
      printf 'ORIGINAL_AUTOPROBE=%q\n' "$(cat "$P/sriov_drivers_autoprobe")"
      printf 'ORIGINAL_IFNAME=%q\n' "$dev"
      printf 'ORIGINAL_ADMIN_UP=%q\n' "$(ip -j link show "$dev" | jq -r '.[0].flags|index("UP") != null')"
    } > "$STATE/original.env"
    # Lab-only temporary native-VF suppression. Remove during restore.
    printf '# mock-smartnic-lab owned\nblacklist igbvf\ninstall igbvf /bin/false\n' > "$block"
    modprobe sch_ingress; modprobe cls_flower; modprobe act_mirred
    insmod "$MODULE_FILE" target_pf="$PF_BDF" allow_igb_emulation=1
    printf '%s\n' "$PF_DRIVER" > "$P/driver_override"
    printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
    if ! printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$PF_DRIVER/bind"; then
      printf '%s\n' "$old" > "$P/driver_override"
      printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$old/bind" || true
      fail "Mock probe failed; native rebind attempted. Inspect state in $STATE and run restore."
    fi
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'PF did not bind to mock driver.'
    mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
    dev=$(pf_netdev)
    ethtool -i "$dev"; devlink dev show; ip -d link show "$dev"
    ;;
  vfs|pci-vfs)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Bind the mock PF first.'
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Use reset before another manual VF test.'
    # Manual test intentionally suppresses autoprobe; Kubernetes test restores it.
    printf '0\n' > "$P/sriov_drivers_autoprobe"
    printf '%s\n' "$NUM_VFS" > "$P/sriov_numvfs"
    for ((i=0;i<NUM_VFS;i++)); do
      vf=$(readlink -f "$P/virtfn$i"); bdf=${vf##*/}
      [[ $(cat "$vf/device") == "$EXPECTED_VF_DEVICE" ]] || fail "Unexpected VF identity $bdf"
      printf '%s\n' "$VF_DRIVER" > "$vf/driver_override"
      printf '%s\n' "$bdf" > "/sys/bus/pci/drivers/$VF_DRIVER/bind"
      [[ $(current_driver "$vf") == "$VF_DRIVER" ]] || fail "VF $bdf did not bind."
      [[ $(find "$vf/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]] || fail "VF $bdf needs exactly one endpoint."
    done
    if [[ $ACTION == pci-vfs ]]; then
      lspci -Dnnk
      exit 0
    fi
    devlink dev eswitch set "pci/$PF_BDF" mode switchdev
    [[ $(reps | wc -l) == "$NUM_VFS" ]] || fail 'Representor count differs from VF count.'
    devlink -j port show | jq .; ip -d link show
    ;;
  tc-smoke)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF is not bound.'
    assert_idle_vfs
    exec bash "$HERE/tc-smoke.sh" ;;
  reset|pci-reset)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF is not bound.'
    assert_idle_vfs
    printf '0\n' > "$P/sriov_numvfs"
    if [[ $ACTION == reset ]]; then
      devlink dev eswitch set "pci/$PF_BDF" mode legacy
    fi
    printf '1\n' > "$P/sriov_drivers_autoprobe"
    if [[ $ACTION == reset ]]; then
      printf 'Reset complete: zero VFs, legacy, autoprobe enabled. Operator now owns creation.\n'
    else
      printf 'PCI-only reset complete: zero VFs, autoprobe enabled; eswitch mode was NOT changed. Use full reset before Kubernetes.\n'
    fi
    ;;
  persist)
    mutation
    [[ ${PERSISTENCE_ACK:-} == YES ]] || fail 'Set PERSISTENCE_ACK=YES.'
    [[ $(current_driver "$P") == "$PF_DRIVER" && -f $STATE/original.env ]] || fail 'Bind successfully first.'
    [[ ! -e /etc/systemd/system/mock-smartnic-lab.service ]] || fail 'Persistence already exists; unpersist before replacing it.'
    [[ ! -e /run/ostree-booted ]] || fail 'Use the documented kernel-matched module image/KMM path on immutable nodes.'
    install -d /usr/local/libexec/mock-smartnic-lab /etc/mock-smartnic-lab "/lib/modules/$(uname -r)/extra"
    install -m 0644 "$MODULE_FILE" "/lib/modules/$(uname -r)/extra/mock_smartnic.ko"
    printf '%s\n' "$(uname -r)" > "$STATE/installed-kernel"
    printf 'options mock_smartnic target_pf=%s allow_igb_emulation=1\n' "$PF_BDF" > /etc/modprobe.d/mock-smartnic-lab.conf
    printf 'PF_BDF=%q\n' "$PF_BDF" > /etc/mock-smartnic-lab/boot.env
    cat > /usr/local/libexec/mock-smartnic-lab/boot-bind <<'BOOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/mock-smartnic-lab/boot.env
P=/sys/bus/pci/devices/$PF_BDF
[[ $(cat "$P/vendor") == 0x8086 && $(cat "$P/device") == 0x10c9 ]]
case "$(systemd-detect-virt --vm)" in qemu|kvm) ;; *) exit 1;; esac
[[ $(cat "$P/sriov_numvfs") == 0 ]]
# A built-in/early-bound native VF driver is not an acceptable test configuration.
[[ ! -e /sys/module/igbvf ]]
modprobe sch_ingress; modprobe cls_flower; modprobe act_mirred
modprobe mock_smartnic
if [[ -L $P/driver && $(basename "$(readlink -f "$P/driver")") == mock_smartnic_pf ]]; then
  printf '1\n' > "$P/sriov_drivers_autoprobe"
  exit 0
fi
printf 'mock_smartnic_pf\n' > "$P/driver_override"
[[ ! -L $P/driver ]] || printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
printf '%s\n' "$PF_BDF" > /sys/bus/pci/drivers/mock_smartnic_pf/bind
printf '1\n' > "$P/sriov_drivers_autoprobe"
BOOT
    chmod 0755 /usr/local/libexec/mock-smartnic-lab/boot-bind
    cat > /etc/systemd/system/mock-smartnic-lab.service <<'UNIT'
[Unit]
Description=Bind the dedicated emulated SmartNIC before Kubernetes reconciliation
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service
Before=kubelet.service sriov-config.service sriov-config-post-network.service ovs-vswitchd.service
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mock-smartnic-lab/boot-bind
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
    install -d /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/30-mock-smartnic-lab.conf <<'UNIT'
[Unit]
Requires=mock-smartnic-lab.service
After=mock-smartnic-lab.service
UNIT
    depmod -a
    systemctl daemon-reload
    systemctl enable mock-smartnic-lab.service
    touch "$STATE/persisted"
    printf 'Persistence installed for this kernel only. No reboot was performed.\n'
    ;;
  unpersist)
    mutation
    [[ ${PERSISTENCE_ACK:-} == YES && -e $STATE/persisted ]] || fail 'No owned persistence state, or PERSISTENCE_ACK missing.'
    systemctl disable mock-smartnic-lab.service
    rm -f /etc/systemd/system/mock-smartnic-lab.service /etc/systemd/system/kubelet.service.d/30-mock-smartnic-lab.conf
    rm -f /etc/modprobe.d/mock-smartnic-lab.conf /usr/local/libexec/mock-smartnic-lab/boot-bind /etc/mock-smartnic-lab/boot.env
    ver=$(cat "$STATE/installed-kernel")
    [[ $ver =~ ^[a-zA-Z0-9_.+-]+$ ]] || fail 'Invalid recorded kernel version.'
    rm -f "/lib/modules/$ver/extra/mock_smartnic.ko"
    depmod -a "$ver"; systemctl daemon-reload
    rm -f "$STATE/persisted"
    ;;
  restore)
    mutation
    [[ -f $STATE/original.env ]] || fail 'No original state exists.'
    [[ ! -e $STATE/persisted ]] || fail 'Run unpersist first.'
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Remove pods/policies/bridges and run reset first.'
    # A failed probe can leave the PF unbound with no netdev. Still permit
    # recovery using the original state; check ownership whenever a netdev exists.
    if [[ -d $P/net ]]; then
      while read -r dev; do [[ -z $dev ]] || not_used "$dev"; done < <(find "$P/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
    fi
    # shellcheck disable=SC1090
    source "$STATE/original.env"
    [[ ! -L $P/driver ]] || printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
    [[ ! -e /sys/module/$MODULE ]] || rmmod "$MODULE"
    rm -f /etc/modprobe.d/mock-smartnic-lab-igbvf.conf
    modprobe "$ORIGINAL_DRIVER"
    printf '%s\n' "$ORIGINAL_DRIVER" > "$P/driver_override"
    printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$ORIGINAL_DRIVER/bind"
    if [[ $ORIGINAL_OVERRIDE == '(null)' || -z $ORIGINAL_OVERRIDE ]]; then
      printf '\n' > "$P/driver_override"
    else printf '%s\n' "$ORIGINAL_OVERRIDE" > "$P/driver_override"; fi
    printf '%s\n' "$ORIGINAL_AUTOPROBE" > "$P/sriov_drivers_autoprobe"
    dev=$(pf_netdev)
    if [[ $ORIGINAL_ADMIN_UP == true ]]; then ip link set "$dev" up; else ip link set "$dev" down; fi
    mv "$STATE/original.env" "$STATE/restored-$(date +%s).env"
    printf 'Native driver restored. Global OVS/operator changes are handled separately.\n'
    ;;
  operator-preflight)
    identity
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF must already be bound.'
    [[ $(cat "$P/sriov_numvfs") == 0 && $(cat "$P/sriov_drivers_autoprobe") == 1 ]] || fail 'Run reset before applying the node policy.'
    [[ -e $STATE/persisted && -f /etc/systemd/system/mock-smartnic-lab.service ]] || fail 'Install and test reboot-safe binding before enabling operator HWOL.'
    [[ -e /usr/lib/systemd/system/ovs-vswitchd.service ]] || fail 'Pinned Kubernetes operator requires /usr/lib/systemd/system/ovs-vswitchd.service; adapt distro integration explicitly.'
    systemctl is-enabled mock-smartnic-lab.service
    ovs-vsctl --timeout=5 show
    ;;
  mapping|tc-json)
    python3 - "$PF_BDF" "$ACTION" <<'PYGUEST'
import json, pathlib, subprocess, sys
bdf, action = sys.argv[1:]
ports = json.loads(subprocess.check_output(["devlink", "-j", "port", "show"]))["port"]
reps = {int(v["vfnum"]): v["netdev"] for k,v in ports.items()
        if k.startswith("pci/"+bdf+"/") and v.get("flavour")=="pcivf" and "netdev" in v}
if action == "mapping":
    result=[]
    for path in sorted(pathlib.Path("/sys/bus/pci/devices", bdf).glob("virtfn*")):
        idx=int(path.name[6:]); vf=path.resolve()
        result.append({"vf":idx, "pci":vf.name, "representor":reps.get(idx),
                       "host_netdevs":[p.name for p in (vf/"net").glob("*")]})
    print(json.dumps({"pf":bdf,"vfs":result}))
else:
    result={str(idx):{"representor":rep,"filters":json.loads(subprocess.check_output(
        ["tc","-s","-d","-j","filter","show","dev",rep,"ingress"]))} for idx,rep in reps.items()}
    print(json.dumps(result))
PYGUEST
    ;;
  stats|flows)
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/$ACTION"
    ;;
  ovs-evidence)
    dev=$(pf_netdev)
    printf 'HWOL='; ovs-vsctl --timeout=5 get Open_vSwitch . other_config:hw-offload
    ovs-vsctl --timeout=5 show
    ovs-appctl dpctl/dump-flows --names type=offloaded
    while read -r d; do [[ -z $d ]] || tc -s -d -j filter show dev "$d" ingress; done < <(reps)
    ;;
  collect)
    date -Is; uname -a; lspci -Dnnk -s "$PF_BDF"
    ip -d link; devlink -j port show; devlink dev eswitch show "pci/$PF_BDF" || true
    ovs-vsctl --timeout=5 show 2>/dev/null || true
    ovs-appctl dpctl/dump-flows --names type=offloaded 2>/dev/null || true
    while read -r d; do [[ -z $d ]] || tc -s -d -j filter show dev "$d" ingress; done < <(reps)
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/stats" 2>/dev/null || true
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/flows" 2>/dev/null || true
    dmesg --level=emerg,alert,crit,err,warn | tail -n 150
    ;;
  *) fail "Unknown guest action: $ACTION" ;;
esac
```
<!-- END FILE: scripts/guest.sh -->

---

<a id="file-scripts-install-operator-sh"></a>

## Repository file: `scripts/install-operator.sh`

<!-- BEGIN FILE: scripts/install-operator.sh -->
```bash
#!/usr/bin/env bash
# Optional fresh upstream Kubernetes Helm installation. Not for OLM/OpenShift.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
cluster_guard; mutation_guard
need helm; need git
[[ $CLUSTER_TYPE == kubernetes ]] || die 'Use the documented OpenShift/OLM-compatible deployment path.'
[[ -d ${OPERATOR_SOURCE:-}/.git && -f ${OPERATOR_IMAGE_VALUES:-} ]] || die 'Set OPERATOR_SOURCE and an explicit OPERATOR_IMAGE_VALUES file.'
[[ $(git -C "$OPERATOR_SOURCE" rev-parse HEAD) == "$OPERATOR_REF" ]] || die 'Operator checkout does not match OPERATOR_REF.'
CHART=$OPERATOR_SOURCE/deployment/sriov-network-operator-chart
[[ -f $CHART/Chart.yaml ]] || die 'Pinned chart path missing.'
# No implicit adoption of an existing operator installation.
if k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default >/dev/null 2>&1; then
  die 'An operator configuration already exists. Inspect/upgrade its owner rather than installing another operator.'
fi
if grep -Eq 'REQUIRED_DIGEST|REAL_DIGEST|REGISTRY/' "$OPERATOR_IMAGE_VALUES"; then
  die 'Resolve every placeholder image to an actual compatible pullable image before installation.'
fi
machine=$(k get node "$NODE_NAME" -o json | jq -r '.status.nodeInfo.machineID' | tr -d '-')
vm=$(remote cat /etc/machine-id | tr -d '\r\n-')
[[ -n $vm && $machine == "$vm" ]] || die 'SSH VM and selected Kubernetes node differ.'
other=$(k get nodes -l mock-smartnic.test/target=dut -o json | jq -r --arg n "$NODE_NAME" '.items[]|select(.metadata.name!=$n)|.metadata.name')
[[ -z $other ]] || die 'Another node already has the DUT label; do not broaden operator placement.'
mkdir -p "$ROOT/artifacts/install"
k label node "$NODE_NAME" mock-smartnic.test/target=dut --overwrite
cat > "$ROOT/artifacts/install/lab-values.yaml" <<EOF_VALUES
operator:
  clusterType: kubernetes
  resourcePrefix: "$RESOURCE_PREFIX"
  cniBinPath: /opt/cni/bin
  extraEnv:
    DEV_MODE: "true"
sriovOperatorConfig:
  deploy: true
  configurationMode: daemon
  configDaemonNodeSelector:
    mock-smartnic.test/target: dut
  featureGates:
    manageSoftwareBridges: true
supportedExtraNICs:
  - 'Mock_igb_82576: "8086 10c9 10ca"'
EOF_VALUES
# Default chart admission settings are retained for a new isolated install.
# Existing clusters: preserve existing webhooks; do not disable them as a workaround.
helm template mock-sriov "$CHART" --namespace "$OPERATOR_NAMESPACE" \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  > "$ROOT/artifacts/install/rendered.yaml"
# Review rendered.yaml, including all controller/daemon images and CNI paths.
[[ ${APPROVE_RENDERED_OPERATOR:-} == YES ]] || die 'Rendered manifests saved. Inspect them, then run with APPROVE_RENDERED_OPERATOR=YES.'
helm upgrade --install mock-sriov "$CHART" --kube-context "$KUBE_CONTEXT" \
  --namespace "$OPERATOR_NAMESPACE" --create-namespace \
  -f "$ROOT/artifacts/install/lab-values.yaml" -f "$OPERATOR_IMAGE_VALUES" \
  --wait --timeout "${WAIT_SECONDS}s"
k -n "$OPERATOR_NAMESPACE" get pods -o wide
```
<!-- END FILE: scripts/install-operator.sh -->

---

<a id="file-scripts-kube-sh"></a>

## Repository file: `scripts/kube.sh`

<!-- BEGIN FILE: scripts/kube.sh -->
```bash
#!/usr/bin/env bash
# Existing-cluster integration. Installation is a separate, explicit operation.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need python3
ACTION=${1:-preflight}
if [[ $ACTION == render ]]; then python3 "$ROOT/scripts/render.py"; exit; fi
cluster_guard
A="$ROOT/artifacts/kubernetes"
mkdir -p "$A"
OWN=mock-smartnic-lab
ensure_owned() {
  local kind=$1 name=$2 ns=$3 owner
  if k -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    owner=$(k -n "$ns" get "$kind" "$name" -o json | jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""')
    [[ $owner == "$OWN" ]] || die "Refuse to overwrite unowned $kind/$name in $ns"
  fi
}
preflight() {
  local machine vm others
  machine=$(k get node "$NODE_NAME" -o json | jq -r '.status.nodeInfo.machineID' | tr -d '-')
  vm=$(remote cat /etc/machine-id | tr -d '\r\n-')
  [[ -n $vm && $machine == "$vm" ]] || die 'SSH VM and selected Kubernetes node have different machine IDs.'
  others=$(k get nodes -l mock-smartnic.test/target=dut -o json | jq -r --arg n "$NODE_NAME" '.items[]|select(.metadata.name!=$n)|.metadata.name')
  [[ -z $others ]] || die "More than one DUT-labelled node: $others"
  k get crd sriovnetworknodepolicies.sriovnetwork.openshift.io \
    sriovnetworkpoolconfigs.sriovnetwork.openshift.io ovsnetworks.sriovnetwork.openshift.io \
    network-attachment-definitions.k8s.cni.cncf.io >/dev/null
  k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default >/dev/null
  k explain sriovnetworkpoolconfig.spec.ovsHardwareOffloadConfig.otherConfig >/dev/null
  k explain sriovnetworknodepolicy.spec.bridge.ovs >/dev/null
  k get node "$NODE_NAME" -o json > "$A/node-preflight.json"
  k -n "$OPERATOR_NAMESPACE" get sriovnetworknodepolicies,sriovnetworkpoolconfigs -o yaml > "$A/existing-policy-pools.yaml"
  k -n "$OPERATOR_NAMESPACE" get pods -o wide
  echo 'Inspect existing-policy-pools.yaml: no overlapping NIC policy or node-selected pool may include the DUT.'
}
wait_policy() {
  local end=$((SECONDS+WAIT_SECONDS)) state
  while ((SECONDS<end)); do
    state=$(k -n "$OPERATOR_NAMESPACE" get sriovnetworknodestate "$NODE_NAME" -o json 2>/dev/null || echo '{}')
    if jq -e --arg p "$PF_BDF" --argjson n "$NUM_VFS" '
      (.status.syncStatus=="Succeeded") and
      any(.spec.interfaces[]?; .pciAddress==$p and .numVfs==$n and .eSwitchMode=="switchdev") and
      any(.status.interfaces[]?; .pciAddress==$p and .numVfs==$n and .eSwitchMode=="switchdev")' <<< "$state" >/dev/null; then
      printf '%s\n' "$state" > "$A/node-state.json"
      if k get node "$NODE_NAME" -o json | jq -e --arg r "$RESOURCE_PREFIX/$RESOURCE_NAME" \
          --argjson n "$NUM_VFS" '(.status.allocatable[$r] // "0" | tonumber) >= $n' >/dev/null; then return; fi
    fi
    sleep 5
  done
  die 'Policy/resource reconciliation timed out. Run kube.sh collect and lab.sh collect; do not fake NodeState status.'
}
pod_ip() {
  k -n "$WORKLOAD_NAMESPACE" get pod "$1" -o json | jq -er '
    .metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson|
    .[]|select(.interface=="net1")|.ips[]|select(contains(":")|not)'
}
pod_pci() {
  local key
  key=$(printf '%s' "PCIDEVICE_$RESOURCE_PREFIX/$RESOURCE_NAME" | tr '[:lower:]./-' '[:upper:]___')
  k -n "$WORKLOAD_NAMESPACE" exec "$1" -- python3 -c \
    'import os,sys; print(os.environ.get(sys.argv[1],""))' "$key"
}
case "$ACTION" in
  preflight) preflight ;;
  apply)
    mutation_guard
    [[ ${OPERATOR_REBOOT_ACK:-} == YES ]] || die 'Set OPERATOR_REBOOT_ACK=YES; the operator may reboot this lab worker.'
    [[ $CLUSTER_TYPE == kubernetes ]] || die 'OpenShift: render manifests, then follow the dedicated MCP/KMM runbook; automatic apply is intentionally gated.'
    preflight
    "$ROOT/scripts/lab.sh" operator-preflight
    ensure_owned sriovnetworknodepolicy "$POLICY_NAME" "$OPERATOR_NAMESPACE"
    ensure_owned sriovnetworkpoolconfig "$POOL_NAME" "$OPERATOR_NAMESPACE"
    ensure_owned ovsnetwork "$NETWORK_NAME" "$OPERATOR_NAMESPACE"
    if k get ns "$WORKLOAD_NAMESPACE" >/dev/null 2>&1; then
      owner=$(k get ns "$WORKLOAD_NAMESPACE" -o json | jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""')
      [[ $owner == "$OWN" ]] || die 'Workload namespace exists and is not owned by this harness.'
    fi
    # Keep the first baseline. Do not overwrite recovery information on retries.
    [[ -f "$A/original-operatorconfig.json" ]] || k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig default -o json > "$A/original-operatorconfig.json"
    k label node "$NODE_NAME" mock-smartnic.test/target=dut --overwrite
    python3 "$ROOT/scripts/render.py"
    k apply -f "$ROOT/rendered/00-namespace.yaml"
    k -n "$OPERATOR_NAMESPACE" patch sriovoperatorconfig default --type=merge \
      --patch-file "$ROOT/rendered/05-operatorconfig-patch.json" --dry-run=server >/dev/null
    for f in 10-poolconfig.yaml 20-nodepolicy.yaml 30-ovsnetwork.yaml; do
      k apply --dry-run=server -f "$ROOT/rendered/$f" >/dev/null
    done
    k -n "$OPERATOR_NAMESPACE" patch sriovoperatorconfig default --type=merge --patch-file "$ROOT/rendered/05-operatorconfig-patch.json"
    k apply -f "$ROOT/rendered/10-poolconfig.yaml"
    k apply -f "$ROOT/rendered/20-nodepolicy.yaml"
    wait_policy
    k wait node/"$NODE_NAME" --for=condition=Ready --timeout="${WAIT_SECONDS}s"
    k apply -f "$ROOT/rendered/30-ovsnetwork.yaml"
    end=$((SECONDS+WAIT_SECONDS))
    until k -n "$WORKLOAD_NAMESPACE" get network-attachment-definition "$NETWORK_NAME" -o json > "$A/nad.json" 2>/dev/null; do
      ((SECONDS<end)) || die 'Generated NetworkAttachmentDefinition did not appear.'
      sleep 3
    done
    actual=$(jq -r '.metadata.annotations["k8s.v1.cni.cncf.io/resourceName"]' "$A/nad.json")
    [[ $actual == "$RESOURCE_PREFIX/$RESOURCE_NAME" ]] || die "NAD resource $actual differs from configured prefix/resource."
    for suffix in a b; do
      ensure_owned pod "mock-ovs-$suffix" "$WORKLOAD_NAMESPACE"
      k apply --dry-run=server -f "$ROOT/rendered/40-pod-$suffix.yaml" >/dev/null
      k apply -f "$ROOT/rendered/40-pod-$suffix.yaml"
    done
    k -n "$WORKLOAD_NAMESPACE" wait pod/mock-ovs-a pod/mock-ovs-b --for=condition=Ready --timeout="${WAIT_SECONDS}s"
    echo 'Pods are ready. Run kube.sh verify to test traffic and offload execution.'
    ;;
  verify)
    preflight
    ia=$(pod_ip mock-ovs-a); ib=$(pod_ip mock-ovs-b)
    [[ -n $ia && -n $ib && $ia != "$ib" ]] || die 'Missing or duplicate net1 addresses.'
    pa=$(pod_pci mock-ovs-a); pb=$(pod_pci mock-ovs-b)
    [[ $pa =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ && $pb =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ && $pa != "$pb" ]] || die 'Resolve distinct allocated PCI BDFs via device-plugin env or pod-resources; do not infer them from pod ordering.'
    "$ROOT/scripts/lab.sh" mapping > "$A/mapping.json"
    # Warm up neighbor discovery and OVS megaflow installation; bounded retries.
    for attempt in 1 2 3; do
      if k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- python3 - "$ia" "$ib" --count 30 < "$ROOT/scripts/udp-probe.py"; then break; fi
      [[ $attempt != 3 ]] || die 'Warm-up connectivity failed.'
      sleep 2
    done
    sleep 3
    "$ROOT/scripts/lab.sh" stats > "$A/stats-before.json"
    "$ROOT/scripts/lab.sh" flows > "$A/flows-before.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-a -- python3 - "$ia" "$ib" < "$ROOT/scripts/udp-probe.py" | tee "$A/a-to-b.json"
    k -n "$WORKLOAD_NAMESPACE" exec -i mock-ovs-b -- python3 - "$ib" "$ia" < "$ROOT/scripts/udp-probe.py" | tee "$A/b-to-a.json"
    sleep 2
    "$ROOT/scripts/lab.sh" stats > "$A/stats-after.json"
    "$ROOT/scripts/lab.sh" flows > "$A/flows-after.json"
    "$ROOT/scripts/lab.sh" tc-json > "$A/tc.json"
    "$ROOT/scripts/lab.sh" ovs-evidence > "$A/ovs.txt"
    python3 "$ROOT/scripts/verify-evidence.py" "$A" "$pa" "$pb"
    k -n "$WORKLOAD_NAMESPACE" get pods mock-ovs-a mock-ovs-b -o json > "$A/pods.json"
    ;;
  collect)
    k -n "$OPERATOR_NAMESPACE" get sriovoperatorconfig,sriovnetworkpoolconfig,sriovnetworknodepolicy,sriovnetworknodestate,ovsnetwork -o yaml > "$A/objects.yaml"
    k -n "$WORKLOAD_NAMESPACE" get pods,network-attachment-definitions -o yaml > "$A/workloads.yaml" || true
    k -n "$WORKLOAD_NAMESPACE" get events --sort-by=.lastTimestamp > "$A/events.txt" || true
    k -n "$OPERATOR_NAMESPACE" get pods -o wide > "$A/operator-pods.txt"
    "$ROOT/scripts/lab.sh" collect > "$A/guest.txt"
    echo "$A"
    ;;
  cleanup)
    mutation_guard
    [[ ${OPERATOR_REBOOT_ACK:-} == YES ]] || die 'Deleting HWOL configuration can also alter/reboot the node.'
    for suffix in a b; do
      ensure_owned pod "mock-ovs-$suffix" "$WORKLOAD_NAMESPACE"
      k -n "$WORKLOAD_NAMESPACE" delete pod "mock-ovs-$suffix" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    done
    ensure_owned ovsnetwork "$NETWORK_NAME" "$OPERATOR_NAMESPACE"
    k -n "$OPERATOR_NAMESPACE" delete ovsnetwork "$NETWORK_NAME" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    ensure_owned sriovnetworknodepolicy "$POLICY_NAME" "$OPERATOR_NAMESPACE"
    k -n "$OPERATOR_NAMESPACE" delete sriovnetworknodepolicy "$POLICY_NAME" --ignore-not-found --wait=true --timeout="${WAIT_SECONDS}s"
    echo 'Keep the DUT label until NodeState and the managed bridge are cleaned up. Follow the recovery runbook before deleting the pool or restoring the driver.'
    ;;
  *) die 'Usage: kube.sh render|preflight|apply|verify|collect|cleanup' ;;
esac
```
<!-- END FILE: scripts/kube.sh -->

---

<a id="file-scripts-lab-sh"></a>

## Repository file: `scripts/lab.sh`

<!-- BEGIN FILE: scripts/lab.sh -->
```bash
#!/usr/bin/env bash
# Controller-side SSH harness; never disables host-key checking or transfers keys.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need ssh; need rsync; need python3
ACTION=${1:-preflight}
case "$ACTION" in
  preflight|build|bind|vfs|pci-vfs|tc-smoke|reset|pci-reset|persist|unpersist|restore|collect|stats|flows|mapping|tc-json|ovs-evidence|operator-preflight) ;;
  *) die 'Usage: scripts/lab.sh preflight|build|bind|vfs|pci-vfs|tc-smoke|reset|pci-reset|persist|unpersist|restore|collect|stats|flows|mapping|tc-json|ovs-evidence|operator-preflight' ;;
esac
mkdir -p "$ROOT/artifacts"
RSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10"
remote mkdir -p "$REMOTE_DIR/harness" "$REMOTE_DIR/src"
rsync -a --timeout=60 -e "$RSH" "$ROOT/scripts/guest.sh" "$ROOT/scripts/tc-smoke.sh" "$SSH_TARGET:$REMOTE_DIR/harness/"
# Transfer only non-secret lab configuration; no kubeconfig or SSH credentials.
CFG=$(mktemp)
trap 'rm -f "$CFG"' EXIT
{
  for key in PF_BDF NUM_VFS EXPECTED_PF_VENDOR EXPECTED_PF_DEVICE EXPECTED_VF_DEVICE EMULATED_PF_ACK EXCLUSIVE_PF_ACK PERSISTENCE_ACK; do
    printf '%s=%q\n' "$key" "${!key:-}"
  done
  printf 'SOURCE_DIR=%q\n' "$REMOTE_DIR/src"
} > "$CFG"
rsync -a --timeout=60 -e "$RSH" "$CFG" "$SSH_TARGET:$REMOTE_DIR/harness/lab.env"
if [[ "$ACTION" == build ]]; then
  [[ -f "$SRC_ROOT/driver/Makefile" ]] || die 'driver/Makefile is missing: implement work package K01 first.'
  # No --delete. Exclude private local configuration and derived binaries.
  rsync -a --timeout=60 -e "$RSH" --exclude='.git/' --exclude='config/lab.env' --exclude='artifacts/' \
    --exclude='rendered/' --exclude='*.ko' --exclude='*.o' --exclude='*.cmd' \
    --exclude='*.mod*' --exclude='Module.symvers' --exclude='modules.order' \
    "$SRC_ROOT/driver/" "$SSH_TARGET:$REMOTE_DIR/src/driver/"
  remote bash "$REMOTE_DIR/harness/guest.sh" build | tee "$ROOT/artifacts/build.log"
else
  # The peer address lets the guest reject a PF carrying this SSH connection.
  CONN=$(remote bash -c 'printf "%s" "${SSH_CONNECTION:-}"')
  PEER=${CONN%% *}
  remote sudo -n bash "$REMOTE_DIR/harness/guest.sh" "$ACTION" "$PEER"
fi
```
<!-- END FILE: scripts/lab.sh -->

---

<a id="file-scripts-lib-common-sh"></a>

## Repository file: `scripts/lib/common.sh`

<!-- BEGIN FILE: scripts/lib/common.sh -->
```bash
#!/usr/bin/env bash
# Local helpers. Configuration is an explicitly user-maintained, trusted shell file.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Required command missing: $1"; }
CONFIG=${LAB_CONFIG:-"$ROOT/config/lab.env"}
[[ -f "$CONFIG" ]] || die "Copy config/lab.env.example to config/lab.env first."
set -a
# shellcheck disable=SC1090
source "$CONFIG"
set +a
SRC_ROOT=${SRC_ROOT:-$ROOT}
WAIT_SECONDS=${WAIT_SECONDS:-900}
REMOTE_TIMEOUT=${REMOTE_TIMEOUT:-600}
[[ ${PF_BDF:-} =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || die 'Invalid PF_BDF'
[[ ${NUM_VFS:-} =~ ^[0-9]+$ ]] && ((NUM_VFS >= 2 && NUM_VFS <= 7)) || die 'Use 2..7 VFs for the igb prototype.'
[[ ${REMOTE_DIR:-} =~ ^/[a-zA-Z0-9_./-]+$ && $REMOTE_DIR != / && $REMOTE_DIR != /var && $REMOTE_DIR != /var/tmp && $REMOTE_DIR != *..* ]] || die 'Use a dedicated absolute REMOTE_DIR without spaces or ..'
[[ ${SSH_TARGET:-} =~ ^[a-zA-Z0-9_@.:-]+$ && $SSH_TARGET != -* ]] || die 'Use an SSH config alias or user@host.'
[[ $WAIT_SECONDS =~ ^[0-9]+$ ]] || die 'WAIT_SECONDS must be an integer.'
[[ $REMOTE_TIMEOUT =~ ^[0-9]+$ ]] || die 'REMOTE_TIMEOUT must be an integer.'
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
remote() {
    local cmd
    printf -v cmd '%q ' "$@"
    need timeout
    timeout --foreground --kill-after=10 "$REMOTE_TIMEOUT" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
}
cluster_guard() {
    need "$KUBECTL"; need jq
    [[ -n ${KUBE_CONTEXT:-} && -n ${NODE_NAME:-} ]] || die 'Set KUBE_CONTEXT and NODE_NAME.'
    local active
    active=$("$KUBECTL" config current-context)
    [[ "$active" == "$KUBE_CONTEXT" ]] || die "Wrong Kubernetes context: $active"
    "$KUBECTL" --context "$KUBE_CONTEXT" get node "$NODE_NAME" >/dev/null
}
k() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; }
mutation_guard() {
    [[ ${CLUSTER_MUTATION_ACK:-} == YES ]] || die 'Set CLUSTER_MUTATION_ACK=YES for the dedicated test cluster.'
}
```
<!-- END FILE: scripts/lib/common.sh -->

---

<a id="file-scripts-render-py"></a>

## Repository file: `scripts/render.py`

<!-- BEGIN FILE: scripts/render.py -->
```python
#!/usr/bin/env python3
"""Render Kubernetes YAML using only the Python standard library.

Every string is JSON-quoted, which is valid YAML. No shell/eval or arbitrary YAML
loader is used. kubectl server-side dry-run is still required against the target.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def value(key: str, default: str = "") -> str:
    result = os.environ.get(key, default)
    if not result:
        raise ValueError(f"Set {key} in config/lab.env")
    return result

def scalar(x: object) -> str:
    return json.dumps(x, ensure_ascii=False)

def yaml(x: object, level: int = 0) -> str:
    pad = " " * level
    if isinstance(x, dict):
        if not x:
            return pad + "{}\n"
        out = ""
        for key, val in x.items():
            out += pad + scalar(key) + ":"
            if isinstance(val, (dict, list)) and val:
                out += "\n" + yaml(val, level + 2)
            else:
                out += " " + scalar(val) + "\n"
        return out
    if isinstance(x, list):
        out = ""
        for val in x:
            if isinstance(val, (dict, list)) and val:
                out += pad + "-\n" + yaml(val, level + 2)
            else:
                out += pad + "- " + scalar(val) + "\n"
        return out
    return pad + scalar(x) + "\n"

def build() -> dict[str, dict]:
    ns = value("OPERATOR_NAMESPACE", "sriov-network-operator")
    wns = value("WORKLOAD_NAMESPACE", "mock-sriov-e2e")
    resource = value("RESOURCE_NAME", "mock_smartnic")
    prefix = value("RESOURCE_PREFIX", "openshift.io")
    policy = value("POLICY_NAME", "mock-smartnic-switchdev")
    network = value("NETWORK_NAME", "mock-ovs")
    pool = value("POOL_NAME", "mock-smartnic-pool")
    bdf = value("PF_BDF")
    count = int(value("NUM_VFS", "2"))
    platform = value("CLUSTER_TYPE", "kubernetes")
    image = value("WORKLOAD_IMAGE", "python:3.12-slim")
    if platform not in {"kubernetes", "openshift"}:
        raise ValueError("CLUSTER_TYPE must be kubernetes or openshift")
    if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", bdf):
        raise ValueError("PF_BDF must be a lower-case, full-domain PCI BDF")
    if not 2 <= count <= 7:
        raise ValueError("The initial igb laboratory contract supports 2..7 VFs")
    for key in (ns, wns, policy, network, pool):
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", key):
            raise ValueError(f"Invalid lab object name: {key}")
    if not re.fullmatch(r"[A-Za-z0-9_]+", resource):
        raise ValueError("Invalid SR-IOV resourceName")
    if not re.fullmatch(r"[a-z0-9.-]+", prefix):
        raise ValueError("Invalid resource prefix")
    labels = {"mock-smartnic.test/target": "dut"}
    api = "sriovnetwork.openshift.io/v1"
    def obj(kind: str, name: str, spec: dict) -> dict:
        return {"apiVersion": api, "kind": kind, "metadata": {"name": name, "namespace": ns,
                "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"}}, "spec": spec}
    poolspec: dict = {"ovsHardwareOffloadConfig": {"otherConfig": {"hw-offload": "true", "tc-policy": "none"}}}
    if platform == "kubernetes":
        # At the pinned revision, named HWOL objects are skipped by findNodePoolConfig.
        # Leave name absent so this scoped pool feeds NodeState.spec.system.ovsConfig.
        poolspec["nodeSelector"] = {"matchLabels": labels}
        poolspec["maxUnavailable"] = 1
    else:
        mcp = value("MCP_NAME")
        if mcp in {"master", "worker"}:
            raise ValueError("Use an existing dedicated OpenShift MachineConfigPool, not master/worker")
        poolspec["ovsHardwareOffloadConfig"]["name"] = mcp
        # Do not combine this with nodeSelector/maxUnavailable: upstream webhook rejects it.
    files = {
        "00-namespace.yaml": {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": wns,
            "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"}}},
        "10-poolconfig.yaml": obj("SriovNetworkPoolConfig", pool, poolspec),
        "20-nodepolicy.yaml": obj("SriovNetworkNodePolicy", policy, {
            "resourceName": resource, "nodeSelector": labels, "priority": 10,
            "numVfs": count, "nicSelector": {"rootDevices": [bdf]},
            "deviceType": "netdevice", "isRdma": False, "linkType": "eth",
            "eSwitchMode": "switchdev", "mtu": 1500, "externallyManaged": False,
            "bridge": {"ovs": {}}}),
        "30-ovsnetwork.yaml": obj("OVSNetwork", network, {
            "networkNamespace": wns, "resourceName": resource,
            "ipam": json.dumps({"type": "host-local", "subnet": "198.19.0.0/24",
                    "rangeStart": "198.19.0.10", "rangeEnd": "198.19.0.50"})})}
    echo = "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
    for suffix in ("a", "b"):
        security: dict = {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]},
                          "runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}}
        if platform == "kubernetes":
            security["runAsUser"] = 10000
            security["runAsGroup"] = 10000
        files[f"40-pod-{suffix}.yaml"] = {
            "apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": f"mock-ovs-{suffix}", "namespace": wns,
                "labels": {"app.kubernetes.io/part-of": "mock-smartnic-lab"},
                "annotations": {"k8s.v1.cni.cncf.io/networks": json.dumps([
                    {"name": network, "namespace": wns, "interface": "net1"}])}},
            "spec": {"nodeSelector": labels, "terminationGracePeriodSeconds": 5,
                "containers": [{"name": "echo", "image": image, "imagePullPolicy": "IfNotPresent",
                    "command": ["python3", "-u", "-c", echo], "securityContext": security,
                    "resources": {"requests": {f"{prefix}/{resource}": "1", "cpu": "50m", "memory": "32Mi"},
                                  "limits": {f"{prefix}/{resource}": "1", "memory": "128Mi"}}}]}}
    return files

def main() -> None:
    dest = ROOT / "rendered"
    dest.mkdir(exist_ok=True)
    for filename, doc in build().items():
        (dest / filename).write_text("# Generated by scripts/render.py; verify with server-side dry-run.\n" + yaml(doc))
    patch = {"spec": {"featureGates": {"manageSoftwareBridges": True}}}
    (dest / "05-operatorconfig-patch.json").write_text(json.dumps(patch, indent=2) + "\n")
    print(dest)

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
```
<!-- END FILE: scripts/render.py -->

---

<a id="file-scripts-run-local-checks-sh"></a>

## Repository file: `scripts/run-local-checks.sh`

<!-- BEGIN FILE: scripts/run-local-checks.sh -->
```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh; do bash -n "$f"; done
python3 -m py_compile "$ROOT"/scripts/*.py "$ROOT"/tests/test_harness.py
python3 -m unittest discover -s "$ROOT/tests" -v
echo 'Local harness checks passed; this does not validate a kernel module or VM.'
```
<!-- END FILE: scripts/run-local-checks.sh -->

---

<a id="file-scripts-tc-smoke-sh"></a>

## Repository file: `scripts/tc-smoke.sh`

<!-- BEGIN FILE: scripts/tc-smoke.sh -->
```bash
#!/usr/bin/env bash
# Direct TC-only test. Refuses to mix manual TC ownership with OVS ownership.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/lab.env"
P=/sys/bus/pci/devices/$PF_BDF
NS0=msnic-vf0; NS1=msnic-vf1
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 && $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || fail 'Missing lab authorization.'
[[ $(cat "$P/sriov_numvfs") -ge 2 ]] || fail 'Create VFs first.'
PORTS=$(devlink -j port show)
rep() { jq -er --arg p "pci/$PF_BDF/" --argjson n "$1" '.port|to_entries[]|select(.key|startswith($p))|select(.value.flavour=="pcivf" and .value.vfnum==$n)|.value.netdev' <<< "$PORTS"; }
R0=$(rep 0); R1=$(rep 1)
V0=$(find "$(readlink -f "$P/virtfn0")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
V1=$(find "$(readlink -f "$P/virtfn1")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
[[ -n $V0 && -n $V1 && $V0 != *$'\n'* && $V1 != *$'\n'* ]] || fail 'Expected one host-side netdev per VF.'
for d in "$R0" "$R1"; do
  [[ -z $(ovs-vsctl --timeout=3 iface-to-br "$d" 2>/dev/null || true) ]] || fail "$d is managed by OVS."
  [[ ! -L /sys/class/net/$d/master ]] || fail "$d has a master."
  [[ -z $(tc filter show dev "$d" ingress 2>/dev/null) ]] || fail "$d already has ingress filters."
  if tc -j qdisc show dev "$d" | jq -e 'any(.[]; .kind=="clsact" or .kind=="ingress")' >/dev/null; then
    fail "$d already has an ingress/clsact qdisc; do not take over another owner."
  fi
done
for n in "$NS0" "$NS1"; do
  [[ ! -e /run/netns/$n ]] || fail "Namespace $n already exists."
done
# Preserve PF/VF identities and original VF names; avoid touching arbitrary netns.
created0=0; created1=0; moved0=0; moved1=0; q0=0; q1=0
cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  if ((q0)); then tc qdisc del dev "$R0" clsact || cleanup_rc=1; fi
  if ((q1)); then tc qdisc del dev "$R1" clsact || cleanup_rc=1; fi
  if ((moved0)); then
    ip -n "$NS0" addr flush dev "$V0" || cleanup_rc=1
    ip -n "$NS0" link set "$V0" down || cleanup_rc=1
    ip -n "$NS0" link set "$V0" netns 1 || cleanup_rc=1
  fi
  if ((moved1)); then
    ip -n "$NS1" addr flush dev "$V1" || cleanup_rc=1
    ip -n "$NS1" link set "$V1" down || cleanup_rc=1
    ip -n "$NS1" link set "$V1" netns 1 || cleanup_rc=1
  fi
  if ((created0)); then ip netns del "$NS0" || cleanup_rc=1; fi
  if ((created1)); then ip netns del "$NS1" || cleanup_rc=1; fi
  if ((cleanup_rc)); then echo 'ERROR: cleanup incomplete; inspect namespaces/VF location.' >&2; ((rc!=0)) || rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
ip netns add "$NS0"; created0=1
ip netns add "$NS1"; created1=1
ip link set "$R0" up; ip link set "$R1" up
ip link set "$V0" netns "$NS0"; moved0=1
ip link set "$V1" netns "$NS1"; moved1=1
ip -n "$NS0" link set lo up; ip -n "$NS1" link set lo up
ip -n "$NS0" link set "$V0" up; ip -n "$NS1" link set "$V1" up
ip -n "$NS0" addr add 198.18.0.1/24 dev "$V0"
ip -n "$NS1" addr add 198.18.0.2/24 dev "$V1"
M0=$(ip -n "$NS0" -j link show "$V0" | jq -r '.[0].address')
M1=$(ip -n "$NS1" -j link show "$V1" | jq -r '.[0].address')
ip -n "$NS0" neigh replace 198.18.0.2 lladdr "$M1" nud permanent dev "$V0"
ip -n "$NS1" neigh replace 198.18.0.1 lladdr "$M0" nud permanent dev "$V1"
ethtool -K "$R0" hw-tc-offload on; ethtool -K "$R1" hw-tc-offload on
tc qdisc add dev "$R0" clsact; q0=1
tc qdisc add dev "$R1" clsact; q1=1
tc filter add dev "$R0" ingress protocol ip pref 10 flower skip_sw dst_ip 198.18.0.2 action mirred egress redirect dev "$R1"
tc filter add dev "$R1" ingress protocol ip pref 10 flower skip_sw dst_ip 198.18.0.1 action mirred egress redirect dev "$R0"
STATS=/sys/kernel/debug/mock_smartnic/$PF_BDF/stats
before=$(jq -er '.offload_hits' "$STATS")
ip netns exec "$NS0" ping -I "$V0" -c 10 -W 2 198.18.0.2
for d in "$R0" "$R1"; do
  dump=$(tc -s -d -j filter show dev "$d" ingress)
  jq . <<< "$dump"
  jq -e 'any(.[]; .options.in_hw == true)' <<< "$dump" >/dev/null || fail "$d has no in_hw filter."
  jq -e '[..|objects|.packets? // empty|numbers]|add > 0' <<< "$dump" >/dev/null || fail "$d has no packet stats."
done
after=$(jq -er '.offload_hits' "$STATS")
((after > before)) || fail 'Connectivity succeeded without increasing simulator offload hits.'
# Negative control: no OVS/bridge/software rule remains to deliver this traffic.
tc filter del dev "$R0" ingress pref 10
tc filter del dev "$R1" ingress pref 10
if ip netns exec "$NS0" ping -I "$V0" -c 2 -W 1 198.18.0.2; then
  fail 'Traffic still succeeds with rules removed: hidden VF-to-VF bypass exists.'
fi
echo 'PASS: TC in_hw, packet counters, driver hits, and negative-control isolation.'
```
<!-- END FILE: scripts/tc-smoke.sh -->

---

<a id="file-scripts-udp-probe-py"></a>

## Repository file: `scripts/udp-probe.py`

<!-- BEGIN FILE: scripts/udp-probe.py -->
```python
#!/usr/bin/env python3
"""Unprivileged, interface-address-bound echo test; executed inside a test pod."""
import argparse
import json
import os
import socket
import time

p = argparse.ArgumentParser()
p.add_argument("source")
p.add_argument("destination")
p.add_argument("--count", type=int, default=400)
p.add_argument("--interval", type=float, default=0.01)
a = p.parse_args()
if not 1 <= a.count <= 100000 or not 0 <= a.interval <= 10:
    p.error("invalid test bounds")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((a.source, 0))
s.settimeout(2)
nonce = os.urandom(16)
received = 0
start = time.monotonic()
for seq in range(a.count):
    msg = nonce + seq.to_bytes(8, "big") + b"mock-smartnic-validation" * 4
    s.sendto(msg, (a.destination, 9000))
    try:
        reply, peer = s.recvfrom(65535)
        if reply == msg and peer == (a.destination, 9000):
            received += 1
    except socket.timeout:
        pass
    time.sleep(a.interval)
print(json.dumps({"source": a.source, "destination": a.destination,
                  "sent": a.count, "received": received, "lost": a.count-received,
                  "seconds": round(time.monotonic()-start, 3)}))
raise SystemExit(0 if received == a.count else 1)
```
<!-- END FILE: scripts/udp-probe.py -->

---

<a id="file-scripts-verify-evidence-py"></a>

## Repository file: `scripts/verify-evidence.py`

<!-- BEGIN FILE: scripts/verify-evidence.py -->
```python
#!/usr/bin/env python3
"""Reject connectivity-only and stale/unrelated offload evidence."""
import json
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
pa, pb = sys.argv[2:4]
def load(name):
    return json.loads((p/name).read_text())
def require(ok, msg):
    if not ok:
        raise SystemExit("FAIL: " + msg)

mapping = {v["pci"]: v for v in load("mapping.json")["vfs"]}
require(pa in mapping and pb in mapping, "Allocated VFs do not belong to the selected mock PF")
a, b = mapping[pa]["vf"], mapping[pb]["vf"]
require(a != b, "Pods allocated the same VF")
for n in ("a-to-b.json", "b-to-a.json"):
    result = load(n)
    require(result["received"] == result["sent"] > 0, "UDP loss or mismatched payloads")
before, after = load("stats-before.json"), load("stats-after.json")
require(after.get("schema_version") == 1, "Unexpected debugfs stats schema")
require(after["offload_hits"] > before["offload_hits"], "No new simulator offload hits")
f0, f1 = load("flows-before.json"), load("flows-after.json")
require(f0.get("schema_version") == f1.get("schema_version") == 1, "Unexpected flow evidence schema")
def packets(doc, source, dest):
    return sum(f["packets"] for f in doc["flows"] if f["ingress_vf"] == source
               and any(x.get("kind")=="redirect" and x.get("vf")==dest for x in f["actions"]))
for source,dest in ((a,b),(b,a)):
    require(packets(f1,source,dest)>packets(f0,source,dest), f"No new directional flow hits VF{source}->VF{dest}")
tc=load("tc.json")
for v in (a,b):
    require(str(v) in tc, f"No representor TC evidence for VF{v}")
    require(any(f.get("options",{}).get("in_hw") is True for f in tc[str(v)]["filters"]),
            f"No in_hw flower filter for VF{v}")
ovs=(p/"ovs.txt").read_text()
require(re.search(r'^HWOL="?true"?\s*$',ovs,re.M), "OVS hw-offload is not true")
for pci in (pa,pb):
    require(mapping[pci]["representor"] in ovs, "OVS evidence is missing a selected representor")
require("packets:" in ovs, "No OVS offloaded datapath flow with packet accounting")
print("PASS: distinct allocated PCI VFs, net1 UDP payloads, TC in_hw, OVS offload, and new driver hits in both directions")
```
<!-- END FILE: scripts/verify-evidence.py -->

---

<a id="file-tests-local-validation-log"></a>

## Repository file: `tests/local-validation.log`

<!-- BEGIN FILE: tests/local-validation.log -->
```text
test_complete_synthetic_evidence_passes (test_harness.EvidenceTests.test_complete_synthetic_evidence_passes) ... ok
test_connectivity_without_driver_hits_fails (test_harness.EvidenceTests.test_connectivity_without_driver_hits_fails) ... ok
test_disabled_ovs_offload_fails (test_harness.EvidenceTests.test_disabled_ovs_offload_fails) ... ok
test_missing_in_hw_fails (test_harness.EvidenceTests.test_missing_in_hw_fails) ... ok
test_stale_directional_flows_fail (test_harness.EvidenceTests.test_stale_directional_flows_fail) ... ok
test_wrong_allocated_pci_fails (test_harness.EvidenceTests.test_wrong_allocated_pci_fails) ... ok
test_invalid_bdf_refused (test_harness.RenderTests.test_invalid_bdf_refused) ... ok
test_kubernetes_pool_is_scoped_without_name (test_harness.RenderTests.test_kubernetes_pool_is_scoped_without_name) ... ok
test_network_no_default_route_or_explicit_bridge (test_harness.RenderTests.test_network_no_default_route_or_explicit_bridge) ... ok
test_openshift_broad_pool_refused (test_harness.RenderTests.test_openshift_broad_pool_refused) ... ok
test_openshift_named_pool_has_no_node_selector (test_harness.RenderTests.test_openshift_named_pool_has_no_node_selector) ... ok
test_pods_have_resources_and_nonprivileged_udp (test_harness.RenderTests.test_pods_have_resources_and_nonprivileged_udp) ... ok
test_policy_leaves_creation_to_operator (test_harness.RenderTests.test_policy_leaves_creation_to_operator) ... ok
test_yaml_roundtrip_if_parser_available (test_harness.RenderTests.test_yaml_roundtrip_if_parser_available) ... ok

----------------------------------------------------------------------
Ran 14 tests in 3.783s

OK
Local harness checks passed; this does not validate a kernel module or VM.
```
<!-- END FILE: tests/local-validation.log -->

---

<a id="file-tests-test-harness-py"></a>

## Repository file: `tests/test_harness.py`

<!-- BEGIN FILE: tests/test_harness.py -->
```python
#!/usr/bin/env python3
"""Local fixtures only: these do not exercise a kernel, VM, CNI or cluster."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("renderer",ROOT/"scripts/render.py")
renderer=importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

class RenderTests(unittest.TestCase):
    def documents(self, **extra):
        env={"PF_BDF":"0000:00:06.0","CLUSTER_TYPE":"kubernetes",**extra}
        with patch.dict(os.environ,env,clear=True):
            return renderer.build()
    def test_kubernetes_pool_is_scoped_without_name(self):
        doc=self.documents()["10-poolconfig.yaml"]
        self.assertIn("nodeSelector",doc["spec"])
        self.assertNotIn("name",doc["spec"]["ovsHardwareOffloadConfig"])
        self.assertEqual("true",doc["spec"]["ovsHardwareOffloadConfig"]["otherConfig"]["hw-offload"])
    def test_openshift_named_pool_has_no_node_selector(self):
        doc=self.documents(CLUSTER_TYPE="openshift",MCP_NAME="mock-smartnic")["10-poolconfig.yaml"]
        self.assertEqual("mock-smartnic",doc["spec"]["ovsHardwareOffloadConfig"]["name"])
        self.assertNotIn("nodeSelector",doc["spec"])
        self.assertNotIn("maxUnavailable",doc["spec"])
    def test_openshift_broad_pool_refused(self):
        with self.assertRaises(ValueError):
            self.documents(CLUSTER_TYPE="openshift",MCP_NAME="worker")
    def test_invalid_bdf_refused(self):
        with self.assertRaises(ValueError): self.documents(PF_BDF="../../etc")
    def test_policy_leaves_creation_to_operator(self):
        doc=self.documents()["20-nodepolicy.yaml"]["spec"]
        self.assertFalse(doc["externallyManaged"])
        self.assertEqual("switchdev",doc["eSwitchMode"])
        self.assertEqual({"ovs":{}},doc["bridge"])
    def test_network_no_default_route_or_explicit_bridge(self):
        doc=self.documents()["30-ovsnetwork.yaml"]
        self.assertEqual("OVSNetwork",doc["kind"])
        self.assertNotIn("bridge",doc["spec"])
        ipam=json.loads(doc["spec"]["ipam"])
        self.assertNotIn("routes",ipam); self.assertNotIn("gateway",ipam)
    def test_pods_have_resources_and_nonprivileged_udp(self):
        docs=self.documents()
        for suffix in ("a","b"):
            p=docs[f"40-pod-{suffix}.yaml"]
            self.assertNotIn("nodeName",p["spec"])
            c=p["spec"]["containers"][0]
            self.assertEqual("1",c["resources"]["requests"]["openshift.io/mock_smartnic"])
            self.assertEqual(["ALL"],c["securityContext"]["capabilities"]["drop"])
            self.assertFalse(c["securityContext"]["allowPrivilegeEscalation"])
    def test_yaml_roundtrip_if_parser_available(self):
        try: import yaml
        except ImportError: self.skipTest("PyYAML is optional for local validation")
        for doc in self.documents().values():
            self.assertEqual(doc,yaml.safe_load(renderer.yaml(doc)))

class EvidenceTests(unittest.TestCase):
    def fixture(self):
        flow=lambda n:{"schema_version":1,"flows":[
            {"cookie":"a","ingress_vf":0,"packets":n,"actions":[{"kind":"redirect","vf":1}]},
            {"cookie":"b","ingress_vf":1,"packets":n,"actions":[{"kind":"redirect","vf":0}]}]}
        return {
            "mapping.json":{"vfs":[{"pci":"0000:00:10.0","vf":0,"representor":"rep0"},
                                       {"pci":"0000:00:10.2","vf":1,"representor":"rep1"}]},
            "a-to-b.json":{"sent":10,"received":10},"b-to-a.json":{"sent":10,"received":10},
            "stats-before.json":{"schema_version":1,"offload_hits":2},
            "stats-after.json":{"schema_version":1,"offload_hits":20},
            "flows-before.json":flow(1),"flows-after.json":flow(10),
            "tc.json":{str(v):{"filters":[{"options":{"in_hw":True}}]} for v in (0,1)},
            "ovs.txt":'HWOL="true"\nrep0 rep1 packets:20\n'}
    def verify(self, data):
        with tempfile.TemporaryDirectory() as d:
            for name,content in data.items():
                Path(d,name).write_text(content if isinstance(content,str) else json.dumps(content))
            return subprocess.run([sys.executable,str(ROOT/"scripts/verify-evidence.py"),d,
                "0000:00:10.0","0000:00:10.2"],capture_output=True,text=True)
    def test_complete_synthetic_evidence_passes(self):
        result=self.verify(self.fixture()); self.assertEqual(0,result.returncode,result.stderr)
    def test_connectivity_without_driver_hits_fails(self):
        data=self.fixture();data["stats-after.json"]["offload_hits"]=2
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_stale_directional_flows_fail(self):
        data=self.fixture();data["flows-after.json"]=data["flows-before.json"]
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_missing_in_hw_fails(self):
        data=self.fixture();data["tc.json"]["0"]["filters"][0]["options"]["in_hw"]=False
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_disabled_ovs_offload_fails(self):
        data=self.fixture();data["ovs.txt"]='HWOL="false"\nrep0 rep1 packets:20\n'
        self.assertNotEqual(0,self.verify(data).returncode)
    def test_wrong_allocated_pci_fails(self):
        data=self.fixture();data["mapping.json"]["vfs"][0]["pci"]="0000:ff:00.0"
        self.assertNotEqual(0,self.verify(data).returncode)

if __name__=="__main__": unittest.main(verbosity=2)
```
<!-- END FILE: tests/test_harness.py -->

---

<a id="file-manifests-kubernetes-00-namespace-yaml"></a>

## Repository file: `manifests/kubernetes/00-namespace.yaml`

<!-- BEGIN FILE: manifests/kubernetes/00-namespace.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Namespace"
"metadata":
  "name": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
```
<!-- END FILE: manifests/kubernetes/00-namespace.yaml -->

---

<a id="file-manifests-kubernetes-05-operatorconfig-patch-json"></a>

## Repository file: `manifests/kubernetes/05-operatorconfig-patch.json`

<!-- BEGIN FILE: manifests/kubernetes/05-operatorconfig-patch.json -->
```json
{
  "spec": {
    "featureGates": {
      "manageSoftwareBridges": true
    }
  }
}
```
<!-- END FILE: manifests/kubernetes/05-operatorconfig-patch.json -->

---

<a id="file-manifests-kubernetes-10-poolconfig-yaml"></a>

## Repository file: `manifests/kubernetes/10-poolconfig.yaml`

<!-- BEGIN FILE: manifests/kubernetes/10-poolconfig.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "SriovNetworkPoolConfig"
"metadata":
  "name": "mock-smartnic-pool"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "ovsHardwareOffloadConfig":
    "otherConfig":
      "hw-offload": "true"
      "tc-policy": "none"
  "nodeSelector":
    "matchLabels":
      "mock-smartnic.test/target": "dut"
  "maxUnavailable": 1
```
<!-- END FILE: manifests/kubernetes/10-poolconfig.yaml -->

---

<a id="file-manifests-kubernetes-20-nodepolicy-yaml"></a>

## Repository file: `manifests/kubernetes/20-nodepolicy.yaml`

<!-- BEGIN FILE: manifests/kubernetes/20-nodepolicy.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "SriovNetworkNodePolicy"
"metadata":
  "name": "mock-smartnic-switchdev"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "resourceName": "mock_smartnic"
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "priority": 10
  "numVfs": 2
  "nicSelector":
    "rootDevices":
      - "0000:00:06.0"
  "deviceType": "netdevice"
  "isRdma": false
  "linkType": "eth"
  "eSwitchMode": "switchdev"
  "mtu": 1500
  "externallyManaged": false
  "bridge":
    "ovs": {}
```
<!-- END FILE: manifests/kubernetes/20-nodepolicy.yaml -->

---

<a id="file-manifests-kubernetes-30-ovsnetwork-yaml"></a>

## Repository file: `manifests/kubernetes/30-ovsnetwork.yaml`

<!-- BEGIN FILE: manifests/kubernetes/30-ovsnetwork.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "OVSNetwork"
"metadata":
  "name": "mock-ovs"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "networkNamespace": "mock-sriov-e2e"
  "resourceName": "mock_smartnic"
  "ipam": "{\"type\": \"host-local\", \"subnet\": \"198.19.0.0/24\", \"rangeStart\": \"198.19.0.10\", \"rangeEnd\": \"198.19.0.50\"}"
```
<!-- END FILE: manifests/kubernetes/30-ovsnetwork.yaml -->

---

<a id="file-manifests-kubernetes-40-pod-a-yaml"></a>

## Repository file: `manifests/kubernetes/40-pod-a.yaml`

<!-- BEGIN FILE: manifests/kubernetes/40-pod-a.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Pod"
"metadata":
  "name": "mock-ovs-a"
  "namespace": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
  "annotations":
    "k8s.v1.cni.cncf.io/networks": "[{\"name\": \"mock-ovs\", \"namespace\": \"mock-sriov-e2e\", \"interface\": \"net1\"}]"
"spec":
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "terminationGracePeriodSeconds": 5
  "containers":
    -
      "name": "echo"
      "image": "python:3.12-slim"
      "imagePullPolicy": "IfNotPresent"
      "command":
        - "python3"
        - "-u"
        - "-c"
        - "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
      "securityContext":
        "allowPrivilegeEscalation": false
        "capabilities":
          "drop":
            - "ALL"
        "runAsNonRoot": true
        "seccompProfile":
          "type": "RuntimeDefault"
        "runAsUser": 10000
        "runAsGroup": 10000
      "resources":
        "requests":
          "openshift.io/mock_smartnic": "1"
          "cpu": "50m"
          "memory": "32Mi"
        "limits":
          "openshift.io/mock_smartnic": "1"
          "memory": "128Mi"
```
<!-- END FILE: manifests/kubernetes/40-pod-a.yaml -->

---

<a id="file-manifests-kubernetes-40-pod-b-yaml"></a>

## Repository file: `manifests/kubernetes/40-pod-b.yaml`

<!-- BEGIN FILE: manifests/kubernetes/40-pod-b.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Pod"
"metadata":
  "name": "mock-ovs-b"
  "namespace": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
  "annotations":
    "k8s.v1.cni.cncf.io/networks": "[{\"name\": \"mock-ovs\", \"namespace\": \"mock-sriov-e2e\", \"interface\": \"net1\"}]"
"spec":
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "terminationGracePeriodSeconds": 5
  "containers":
    -
      "name": "echo"
      "image": "python:3.12-slim"
      "imagePullPolicy": "IfNotPresent"
      "command":
        - "python3"
        - "-u"
        - "-c"
        - "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
      "securityContext":
        "allowPrivilegeEscalation": false
        "capabilities":
          "drop":
            - "ALL"
        "runAsNonRoot": true
        "seccompProfile":
          "type": "RuntimeDefault"
        "runAsUser": 10000
        "runAsGroup": 10000
      "resources":
        "requests":
          "openshift.io/mock_smartnic": "1"
          "cpu": "50m"
          "memory": "32Mi"
        "limits":
          "openshift.io/mock_smartnic": "1"
          "memory": "128Mi"
```
<!-- END FILE: manifests/kubernetes/40-pod-b.yaml -->

---

<a id="file-manifests-openshift-00-namespace-yaml"></a>

## Repository file: `manifests/openshift/00-namespace.yaml`

<!-- BEGIN FILE: manifests/openshift/00-namespace.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Namespace"
"metadata":
  "name": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
```
<!-- END FILE: manifests/openshift/00-namespace.yaml -->

---

<a id="file-manifests-openshift-05-operatorconfig-patch-json"></a>

## Repository file: `manifests/openshift/05-operatorconfig-patch.json`

<!-- BEGIN FILE: manifests/openshift/05-operatorconfig-patch.json -->
```json
{
  "spec": {
    "featureGates": {
      "manageSoftwareBridges": true
    }
  }
}
```
<!-- END FILE: manifests/openshift/05-operatorconfig-patch.json -->

---

<a id="file-manifests-openshift-10-poolconfig-yaml"></a>

## Repository file: `manifests/openshift/10-poolconfig.yaml`

<!-- BEGIN FILE: manifests/openshift/10-poolconfig.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "SriovNetworkPoolConfig"
"metadata":
  "name": "mock-smartnic-pool"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "ovsHardwareOffloadConfig":
    "otherConfig":
      "hw-offload": "true"
      "tc-policy": "none"
    "name": "mock-smartnic"
```
<!-- END FILE: manifests/openshift/10-poolconfig.yaml -->

---

<a id="file-manifests-openshift-20-nodepolicy-yaml"></a>

## Repository file: `manifests/openshift/20-nodepolicy.yaml`

<!-- BEGIN FILE: manifests/openshift/20-nodepolicy.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "SriovNetworkNodePolicy"
"metadata":
  "name": "mock-smartnic-switchdev"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "resourceName": "mock_smartnic"
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "priority": 10
  "numVfs": 2
  "nicSelector":
    "rootDevices":
      - "0000:00:06.0"
  "deviceType": "netdevice"
  "isRdma": false
  "linkType": "eth"
  "eSwitchMode": "switchdev"
  "mtu": 1500
  "externallyManaged": false
  "bridge":
    "ovs": {}
```
<!-- END FILE: manifests/openshift/20-nodepolicy.yaml -->

---

<a id="file-manifests-openshift-30-ovsnetwork-yaml"></a>

## Repository file: `manifests/openshift/30-ovsnetwork.yaml`

<!-- BEGIN FILE: manifests/openshift/30-ovsnetwork.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "sriovnetwork.openshift.io/v1"
"kind": "OVSNetwork"
"metadata":
  "name": "mock-ovs"
  "namespace": "sriov-network-operator"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
"spec":
  "networkNamespace": "mock-sriov-e2e"
  "resourceName": "mock_smartnic"
  "ipam": "{\"type\": \"host-local\", \"subnet\": \"198.19.0.0/24\", \"rangeStart\": \"198.19.0.10\", \"rangeEnd\": \"198.19.0.50\"}"
```
<!-- END FILE: manifests/openshift/30-ovsnetwork.yaml -->

---

<a id="file-manifests-openshift-40-pod-a-yaml"></a>

## Repository file: `manifests/openshift/40-pod-a.yaml`

<!-- BEGIN FILE: manifests/openshift/40-pod-a.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Pod"
"metadata":
  "name": "mock-ovs-a"
  "namespace": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
  "annotations":
    "k8s.v1.cni.cncf.io/networks": "[{\"name\": \"mock-ovs\", \"namespace\": \"mock-sriov-e2e\", \"interface\": \"net1\"}]"
"spec":
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "terminationGracePeriodSeconds": 5
  "containers":
    -
      "name": "echo"
      "image": "python:3.12-slim"
      "imagePullPolicy": "IfNotPresent"
      "command":
        - "python3"
        - "-u"
        - "-c"
        - "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
      "securityContext":
        "allowPrivilegeEscalation": false
        "capabilities":
          "drop":
            - "ALL"
        "runAsNonRoot": true
        "seccompProfile":
          "type": "RuntimeDefault"
      "resources":
        "requests":
          "openshift.io/mock_smartnic": "1"
          "cpu": "50m"
          "memory": "32Mi"
        "limits":
          "openshift.io/mock_smartnic": "1"
          "memory": "128Mi"
```
<!-- END FILE: manifests/openshift/40-pod-a.yaml -->

---

<a id="file-manifests-openshift-40-pod-b-yaml"></a>

## Repository file: `manifests/openshift/40-pod-b.yaml`

<!-- BEGIN FILE: manifests/openshift/40-pod-b.yaml -->
```yaml
# EXAMPLE ONLY. Render actual lab values with scripts/kube.sh render.
"apiVersion": "v1"
"kind": "Pod"
"metadata":
  "name": "mock-ovs-b"
  "namespace": "mock-sriov-e2e"
  "labels":
    "app.kubernetes.io/part-of": "mock-smartnic-lab"
  "annotations":
    "k8s.v1.cni.cncf.io/networks": "[{\"name\": \"mock-ovs\", \"namespace\": \"mock-sriov-e2e\", \"interface\": \"net1\"}]"
"spec":
  "nodeSelector":
    "mock-smartnic.test/target": "dut"
  "terminationGracePeriodSeconds": 5
  "containers":
    -
      "name": "echo"
      "image": "python:3.12-slim"
      "imagePullPolicy": "IfNotPresent"
      "command":
        - "python3"
        - "-u"
        - "-c"
        - "import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('0.0.0.0',9000))\nprint('udp echo ready',flush=True)\nwhile True:\n data,peer=s.recvfrom(65535)\n s.sendto(data,peer)\n"
      "securityContext":
        "allowPrivilegeEscalation": false
        "capabilities":
          "drop":
            - "ALL"
        "runAsNonRoot": true
        "seccompProfile":
          "type": "RuntimeDefault"
      "resources":
        "requests":
          "openshift.io/mock_smartnic": "1"
          "cpu": "50m"
          "memory": "32Mi"
        "limits":
          "openshift.io/mock_smartnic": "1"
          "memory": "128Mi"
```
<!-- END FILE: manifests/openshift/40-pod-b.yaml -->

---

<a id="file-gitignore"></a>

## Repository file: `.gitignore`

<!-- BEGIN FILE: .gitignore -->
```text
config/lab.env
config/images.lock.yaml
artifacts/
rendered/
*.ko
*.o
*.mod
*.mod.c
*.cmd
Module.symvers
modules.order
.tmp_versions/
__pycache__/
```
<!-- END FILE: .gitignore -->

---

