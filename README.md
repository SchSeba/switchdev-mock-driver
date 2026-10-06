# Switchdev mock driver

A GPL Linux module for a dedicated QEMU-emulated Intel 82576 igb PF. It keeps
real PCI PF/VF objects and executes Linux TC offload rules in a software mock
switch. Offload here exercises the driver API; it provides no physical acceleration.

The tested Kubernetes flow runs two pods on one worker with separate PCI VFs,
OVS-CNI, bidirectional ICMP/UDP and increasing counters for OVS-generated TC rules.
Read [START-HERE.md](START-HERE.md) for the architecture and prerequisites,
[implementation status](IMPLEMENTATION-STATUS.md) for actual results, and
[source locks](config/source-lock.json) for the tested versions.

## Run the demo

Use only a dedicated, attested emulated PF, a separate management NIC and the
explicit VM/cluster in ignored `config/lab.env`. Complete the
[VM build/persistence runbook](docs/03-vm-runbook.md) and
[pinned operator/CNI installation](docs/04-kubernetes-flow.md) first.

```bash
./scripts/kube.sh render
./scripts/kube.sh preflight
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
```

The pool config reaches NodeState and the host OVS service; the node policy
creates VFs, switchdev mode and the bridge; the device plugin advertises the PCI
VFs as an extended resource. OVSNetwork creates the NAD, Multus supplies the
allocated PCI device to OVS-CNI, and OVS programs the mock representors through TC.
These manifests use the device-plugin allocation path and create no DeviceClass
or ResourceSlice objects.

## Cleanup and tests

```bash
./scripts/kube.sh collect
./scripts/kube.sh cleanup
```

Then follow the [ordered cleanup and resilience runbook](docs/05-validation-and-recovery.md)
to wait for controller cleanup, remove the owned pool and restore native binding.
Do not unload the module while pods or controllers own its VFs.
`./scripts/ci.sh local` runs local checks; privileged VM/Kubernetes lanes require
the configured lab. OpenShift, enforced module signing and KASAN/lockdep are untested.
