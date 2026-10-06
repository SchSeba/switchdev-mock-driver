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
| K05 | net1 two-way ICMP/UDP plus offload evidence | All supplied evidence assertions pass. |
| K06 | Pod deletion/recreation | CNI DEL cleans host ports; VF can be allocated again. |
| R01 | 50 pod cycles; 10 mode/VF cycles | No leaks, warnings, stale ports, inaccurate resource counts. |
| R02 | Module teardown/debugfs readers | No invalid refs or unload deadlock. |
| R03 | Insufficient resources | Third pod pending on two exhausted VFs, then allocates after release. |
| R04 | Invalid/injected allocation failure | Clear errors and recovery, not forged success. |

Numbering here is a test taxonomy, not the implementation-package numbering.

## 3. Matcher and harness tests

Use KUnit where suitable for pure matcher/action normalization; a userspace mirror
may supplement it but is not a substitute for the actual compiled kernel code.
Cover byte order, all accepted mask bits, IPv4 options/truncation, fragments,
non-linear headers, disabled/down destinations, wrong-switch redirects, unsupported
chains/actions and deterministic rule selection. Include deliberate allocation
failures and replacement rollback consistent with the pinned TC core.

Test reference release: every acquired netdev/port reference has a matching release
on add failure, successful delete, block unbind, VF removal and module unload.
Test stats accumulation/delta reporting, concurrent reads and lastused semantics.

`tests/integration/flower-engine.sh` exercises the actual compiled kernel matcher,
actions, extacks, failed replacements, capacity and counter stability. Module
probe also checks linear and page-fragment packet parsing. These are runtime
tests, not KUnit coverage. `tests/test_harness.py` separately checks configuration,
refusal before mutation and synthetic evidence acceptance/rejection, including
missing ping. `ovs-unit.sh` passes the real source renderer through guest systemd
and checks literal arguments. See IMPLEMENTATION-STATUS.md for executed results.

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
RUNTIME FAILED; RUNTIME PASSED. The original VALIDATION-REPORT.md describes the
starting harness. Current driver/runtime results belong in IMPLEMENTATION-STATUS.md,
with portable versions and hashes in config/source-lock.json.

## 9. Replay resilience and CI

Start with the proven two-pod flow and the configured dedicated lab:

```bash
./tests/integration/pod-cycles.sh 50
./tests/integration/allocation-recovery.sh
```

The first test proves two-VF scheduler exhaustion and recovery, then checks
bidirectional ping, actual PCI allocation, new mock offload hits and clean CNI DEL
in every cycle. It finishes with no workload pods. The second asks the network
controller for a separately owned network with one valid host-local address.
Its second sandbox must report real IPAM exhaustion; deleting the first pod must
allow that same second pod to recover. It deletes its own pods/network/NAD.

Follow sections 6–7 to clean up the main network/policy, wait for empty NodeState
interfaces/bridges, delete the owned pool, and verify that the operator removed
`/etc/sriov-operator/pci/PF_BDF`. Only then run the isolated kernel lane:

```bash
./scripts/lab.sh reset
./scripts/lab.sh vfs
./tests/integration/kernel-stress.sh
./tests/integration/reboot.sh  # stress leaves zero VFs and legacy mode
```

Kernel stress replaces redirect/drop rules under real VF traffic and concurrent
debugfs reads, checks duplicate delivery and the rule-deletion negative control,
cycles real VF counts/modes ten times, and holds a debugfs file across PF removal.
It verifies module-owner pinning, closes the file, then unloads/reloads the module.
All waits have deadlines. This manual VF creation belongs only to the isolated
kernel test, after operator ownership cleanup. Restore the final demonstration
with `kube.sh apply` and `kube.sh verify`; let the controllers recreate everything.

```bash
./scripts/ci.sh local
./scripts/ci.sh vm          # clean operator state, zero VFs, dedicated empty OVS
./scripts/ci.sh kubernetes  # persistent module and installed pinned components
./scripts/ci.sh openshift   # explicit SKIP/77 until its separate lab exists
```

Before the standalone VM lane, remove only the completed test's OVS drop-in and
owned other_config keys as described in section 7. Otherwise its startup hook
would override the standalone test's skip_hw/skip_sw controls. Missing explicit
lab configuration is SKIP/77, never a runtime pass. CI verdicts are JSON under
artifacts/ci; the GitHub workflow runs only the local lane. The tested release
kernel has DEBUG_LIST enabled but no KASAN/PROVE_LOCKING. Debug-kernel, enforced
signing and OpenShift/MCO coverage remain explicitly NOT TESTED.
