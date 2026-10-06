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
