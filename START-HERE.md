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
