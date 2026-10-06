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
