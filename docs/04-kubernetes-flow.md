# Kubernetes flow

The worker installer prepares the module, OVS and exact selected test PF. A compatible
SR-IOV Network Operator, Multus, SR-IOV device plugin and ovs-cni must already be
installed by their own deployment tooling. This repo does not patch/install them.
The initial successful lab used two external fixes recorded in
[IMPLEMENTATION-STATUS.md](../IMPLEMENTATION-STATUS.md); preserve those fixes in
compatible component versions rather than silently falling back to software.

Configure the ignored `config/lab.env` for one dedicated Ready node/PF. Keep all
admission webhooks/operators enabled. Set cluster/persistence/reboot acknowledgements
only after checking context, exclusive ownership, and recovery prerequisites.

```bash
./scripts/lab.sh operator-preflight
./scripts/kube.sh preflight
./scripts/kube.sh render
```

Review generated `rendered/` manifests. The Kubernetes pool has a scoped
`nodeSelector` and unnamed `ovsHardwareOffloadConfig` with `hw-offload=true` and
`tc-policy=none`; a named HWOL config is an OpenShift/MachineConfigPool path. The
optional OpenShift renderer is retained. This `kube.sh` flow targets mutable
Kubernetes workers. The operator repository has a separate virtual OpenShift
runner that builds with Driver Toolkit and deploys the module through a
worker-only MachineConfig before kubelet. Mock-driver delivery through that
OpenShift/MCO path remains untested; see
[README](../README.md#openshift-virtual-cluster).

The operator config enables `manageSoftwareBridges`. `SriovNetworkNodePolicy`
selects the exact `rootDevices` BDF with two netdevice VFs, switchdev, and
`bridge.ovs={}`. It leaves `externallyManaged=false`. The device plugin exposes
`openshift.io/mock_smartnic`. `OVSNetwork` creates the NAD; it leaves bridge
selection to the PF/device mapping and gives the secondary network no default
route. Each pod requests one VF and gets `net1` through Multus/ovs-cni.

```bash
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
```

The operator owns VF creation and switchdev/bridge reconciliation. ovs-cni owns
endpoint namespace moves and representor OVS ports. Do not precreate their final
resources or write NodeState status. The harness uses bounded waits and captures
actual allocated BDFs, devlink representors, TC/OVS flows and engine counters.

Success needs two Ready pods with bidirectional ping and UDP plus executed
mock-engine offloads: TC `in_hw`, OVS offloaded flows and increasing counters.
`hw-offload=true` alone proves configuration, not execution. Unsupported CT,
tunnels and stateful features remain explicit failures.

Cleanup deletes only the owned pods/network/policy:

```bash
./scripts/kube.sh cleanup
```

Wait for the operator to release interfaces/bridges and return zero VFs/legacy.
Delete the owned pool only when retiring the lab; avoid shared global OVS edits
while another pool owns them. Then restore the worker using README's commands.
