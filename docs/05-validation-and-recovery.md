# Validation and recovery

[IMPLEMENTATION-STATUS.md](../IMPLEMENTATION-STATUS.md) records actual commands,
failures, revisions and evidence from the completed pinned-kernel lab run. Local
checks exercise rendering, evidence interpretation and safety guards; they do
not prove a module works. Downloaded sources, modules and runtime logs are ignored.

Run `scripts/ci.sh local` for local checks, `scripts/ci.sh vm` for an exclusively
owned prepared PF, and `scripts/ci.sh kubernetes` for the operator/pod path.
`ci.sh openshift` still skips this repository's unconfigured immutable-host
runtime lane. The operator repository has a separate virtual OpenShift runner
with Driver Toolkit and worker MachineConfig delivery; that path is implemented
but has not been runtime validated.

Useful focused runtime checks under `tests/integration/`:

| Check | Exercises |
| --- | --- |
| module-parameters.sh | Mandatory exact target and emulation opt-in |
| pci-lifecycle.sh | Real VF creation/removal, native-driver ownership |
| devlink-lifecycle.sh | Modes, port identity, VF rebind independence |
| vf-netlink.sh | VF metadata and sriovnet discovery |
| slowpath.sh | Namespace/direction/packet semantics without offloads |
| flower-engine.sh | Match/action execution, rejection, stats and teardown |
| ovs-offload.sh | Standalone OVS TC offload and negative control |
| pod-cycles.sh | Repeated CNI allocation/teardown |
| allocation-recovery.sh | Allocation/policy recovery |
| kernel-stress.sh | Concurrent TC churn, traffic and module lifetime |
| reboot.sh | Persistent binding and pod offloads after reboot |

These checks mutate only explicitly acknowledged lab resources. Read each check's
prerequisites; avoid manual VF/OVS tests during operator ownership. Use console or
snapshot recovery for a hung kernel, rather than unbounded readiness waits.

Positive evidence must include actual ping/UDP delivery, kernel-owned TC `in_hw`,
OVS offloaded-flow dumps and increased mock-engine counters. Negative controls
remove rules/disallow fallback and establish that an absent rule cannot secretly
forward between VFs. Hardware-offload settings or accepted callbacks alone do not
establish execution.

For an OVS rule rejected by the driver, collect actual match/action dumps and
extack, implement only the missing supported feature with packet tests, then
retry. Never hide a rejected feature behind software fallback and claim success.

Delete owned pods/policies/ports through their components first. Reset requires
host-visible, idle VFs/representors. Restore requires zero VFs and removal of
persistence; it uses saved native driver/override/autoprobe/admin state. Keep
original recovery state until native connectivity is verified. Preserve modified
or unowned configuration files for review.

Kernel build/runtime coverage is recorded in README and IMPLEMENTATION-STATUS;
no fixed release is required by installation. Enforced module signing,
mock-driver deployment through the virtual OpenShift/MCO lane, cross-worker
forwarding and KASAN/lockdep kernels are not validated.
