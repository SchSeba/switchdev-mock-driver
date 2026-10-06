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
