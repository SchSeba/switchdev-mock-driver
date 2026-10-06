# Mock SmartNIC: driver and VM integration lab

Implemented and tested on the dedicated emulated igb worker. K00–K09 runtime
passed, including real PCI VFs, devlink, TC execution, persistence/reboots and
operator-managed OVS-CNI pods with bidirectional ping and mock offload counters.
Resilience tests include 50 pod cycles, allocation recovery, kernel stress,
module reload and reboot. See [implementation status](IMPLEMENTATION-STATUS.md)
for exact commands, versions, failures and evidence; the original
[validation report](VALIDATION-REPORT.md) describes the starting harness only.

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
unprivileged ICMP and UDP. The management NIC remains separate and untouched.

## Deliverables and reading order

1. [Architecture and constraints](docs/01-architecture.md).
2. [Kernel implementation work packages](docs/02-kernel-work-packages.md).
3. [Running-VM access, build, binding, persistence](docs/03-vm-runbook.md).
4. [Operator, pool configuration, node policy, OVSNetwork, pods](docs/04-kubernetes-flow.md).
5. [Acceptance tests, failures and rollback](docs/05-validation-and-recovery.md).
6. [Primary-source references and pinned research](docs/06-sources.md).

AGENTS.md supplies repository-level instructions. scripts/ contains executable
lab harnesses, config/ contains example inputs, and manifests/ contains
reviewable examples. The scripts use normal SSH and a local kubectl/oc context.
Site values live in ignored config/lab.env; keys and kubeconfigs remain outside the repository.

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

## Repository shape

```text
driver/
  Makefile mock_smartnic.h LOCKING.md
  main.c pci_pf.c pci_vf.c devlink.c netdev.c eswitch.c tc.c
tests/
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
refuse to use pci-testdev or an unattested PF. The build uses the guest running kernel and requires its matching kernel-devel.
The tested pin is 5.14.0-427.el9.x86_64.

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
