# Switchdev mock driver

A Linux kernel module for testing SR-IOV switchdev and OVS TC offload inside
QEMU/KVM workers, without a physical SmartNIC. It uses a dedicated, emulated
Intel 82576 (`igb`) PCI PF as the carrier and preserves real PCI VFs and their
sysfs relationships.

`mock_smartnic.ko` registers `mock_smartnic_pf` and `mock_smartnic_vf`. It provides
PF/VF netdevs, VF representors, devlink switchdev mode, and a TC flower match/action
engine. Supported offloaded packets execute in the mock engine in guest memory;
a TC miss goes through the representor/OVS slow path. This tests the hardware
offload integration contract, not physical acceleration or NIC performance.

The validated topology is **two pods on the same worker**. Cross-worker forwarding,
external uplink traffic, CT/NAT, tunnels and VFIO/DPDK are outside its scope.
See [architecture](docs/01-architecture.md) and [validation history](IMPLEMENTATION-STATUS.md).

## Tested environment

- QEMU 8.2.0, `pc-q35-8.2`, emulated PF `8086:10c9`, VFs `8086:10ca`.
- CentOS Stream 9, kernel **`5.14.0-427.el9.x86_64`**, matching kernel-devel.
- OVS 3.5.3, Kubernetes 1.34.2, standard kernel OVS datapath.

The unpinned installer and PCI/VF, TC, OVS offload and reboot checks also pass on
CentOS Stream 9 `5.14.0-754.el9.x86_64`.

A fresh cluster cloning `main` passed the complete operator conformance suite:
**47 passed, 0 failed, 17 skipped**, including the shared five-VF switchdev test,
on `5.14.0-427.el9.x86_64`. Two Ready pods passed bidirectional ping with increasing
OVS offloaded IPv4 counters and matching TC `in_hw` hardware packet counters.
See [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md) for commands and evidence.

The shared operator switchdev test also passed a focused run on OpenShift
5.0.0-rc.1/RHCOS 10.2 with real `mlx5` hardware; that run did not load this mock
module. The operator repository also has a virtual OpenShift conformance runner
that builds the mock module with Driver Toolkit and deploys it through a worker
MachineConfig. This mock-driver delivery path is implemented but has not been
runtime validated.

Installation builds for the worker's running kernel using its matching headers;
no fixed release is required. The environment above records the original runtime
validation. Portability builds also pass on CentOS Stream 10
`6.12.0-273.el10.x86_64` and Fedora 44 `7.2.8-200.fc44.x86_64`; those two
releases have not been runtime tested. Additional releases need API validation. The
[version record](config/source-lock.json) includes the original end-to-end component
revisions and image digests. That run required fixes in the operator and ovs-cni;
use compatible upstream versions or those fixes in their own repositories. This
repository does not build or patch those components.

## Install on a worker

Use a disposable mutable QEMU/KVM guest with console/snapshot recovery. Keep its
management interface on the native driver. Before running the installer:

1. Inspect `virsh dumpxml YOUR_WORKER` on the hypervisor. Confirm the selected test
   NIC is emulated `igb`, with no PCI passthrough. Map its **exact MAC** to the guest
   netdev and PCI BDF. PCI IDs and guest DMI alone do not prove emulation.
2. Confirm that PF has zero VFs, uses native `igb`, and carries no addresses,
   default/SSH routes, bridge/bond/upper device or OVS ports. Never select the first
   NIC or all devices matching a vendor ID.
3. Provide headers/devel for the running kernel. For enforced module signing,
   provide an authorized signed module delivery process first; this installer
   does not bypass signing, Secure Boot, SELinux or IOMMU settings. This direct
   installer does not support immutable hosts; use the operator repository's
   virtual OpenShift runner for its separate Driver Toolkit/MachineConfig path,
   which is not yet runtime validated.

Clone the published repository's `main` branch. Replace the example URL and BDF
with your own attested values; record `git rev-parse HEAD` with the test results:

```bash
git clone --depth 1 --single-branch --branch main https://github.com/SchSeba/switchdev-mock-driver.git
cd switchdev-mock-driver
git rev-parse HEAD
sudo --preserve-env=SSH_CONNECTION ./scripts/setup-worker.sh \
  --pf 0000:29:00.0 --emulated-pf
```

The script checks the PF before installing anything. It installs missing build
prerequisites and OVS, starts/enables OVS, builds against the running kernel, and
binds **only that PF**. Existing OVS is not reinstalled or restarted. CentOS Stream
9 uses the NFV `openvswitch3.5` package; the tested old kernel-devel is fetched from
the signed CentOS archive when needed.

It saves native binding state in `/var/lib/mock-smartnic-lab/BDF`, installs scoped
NetworkManager rules for the test PF/mock ports, and persists the module/binding
before kubelet and OVS start. It brings up only the selected PF's PCI-parented
uplink so carrier-based discovery works after reboot. Boot binding also checks the saved native PF MAC
to detect a changed PCI topology. A reversible `softdep igbvf pre: mock_smartnic`
loads the mock VF driver before native `igbvf`. The mock probe accepts only VFs of
the selected PF; native VFs on another test PF still bind to `igbvf`. Initial setup
refuses to unload `igbvf` if unrelated VFs are already bound. The management PF
driver is unchanged.
Persistence and boot setup preload native igbvf while the mock PF has zero VFs,
so its first registration cannot claim VFs temporarily unbound by the operator.
Boot checks module compatibility before rebinding the PF. Rebuild and install
the module for a new kernel before booting it; old binaries are never reused.
The optional `--kernel RELEASE` argument only asserts an expected release for
existing callers; it is not needed by the installer or operator runner.

Setup ends with **zero VFs, legacy mode and VF autoprobe enabled**. It creates no
OVS bridge, representor ports, NAD, node policy or pod. The operator/CNI own those
resources. Reinstalling an active driver is refused: clean up its owner and restore
first. A partial installation preserves recovery state rather than destroying
live resources.

## Use from the operator conformance runner

The `sriov-network-operator` runner
`hack/run-e2e-conformance-virtual-cluster.sh` prepares the worker test NICs.
Its optional mock setup runs after worker preparation and before operator deploy:

```bash
# Run from the sriov-network-operator checkout, on its test hypervisor.
export MOCK_SMARTNIC_REPO=https://github.com/SchSeba/switchdev-mock-driver.git
export OVS_CNI_IMAGE=quay.io/schseba/ovs-cni-plugin:latest
./hack/run-e2e-conformance-virtual-cluster.sh
```

Publish this repository first. Setup uses each worker's running kernel and does
not upgrade or downgrade it. Its normal cluster
provisioning still applies. **The conformance runner deletes/recreates its named
cluster**, so use its disposable test environment.

The runner gives each worker three emulated `igb` NICs: management, a native
secondary PF for regular conformance, and a third PF for mock switchdev. Both test
NICs attach to the same dedicated network. It attests their explicitly configured
MACs in libvirt XML, resolves the third NIC to an exact guest PF,
clones `main`, records the installed commit, and calls `setup-worker.sh`. It enables the
operator's existing `DEV_MODE` for emulated NICs. SSH waits and setup have deadlines.
Regular tests select the attested native `sriovtest0`. Switchdev tests require carrier, exclude
default-route interfaces and OVS ports, then select supported switchdev drivers
(`mlx5_core`, `ice`, `mock_smartnic_pf`). All use the same five-VF policy, managed
OVS bridge, pod traffic and standard TC/OVS offload checks. Without
`MOCK_SMARTNIC_REPO`, no mock driver is installed.

### OpenShift virtual cluster

The OpenShift runner is `hack/run-e2e-conformance-virtual-ocp.sh` in the
`sriov-network-operator` repository. It recreates its named cluster, so run it
on the test hypervisor with a disposable cluster and an OpenShift pull secret at
`$HOME/openshift_pull.json`:

```bash
# From the sriov-network-operator checkout
SKIP_DELETE=TRUE make test-e2e-conformance-virtual-ocp-cluster
```

The mock driver is enabled by default. The runner uses the sibling
`switchdev-mock-driver` checkout when present; set `MOCK_DRIVER_SOURCE` to
select another local checkout. If no local checkout is available, it clones
`MOCK_SMARTNIC_REPO` (the default is this repository's public URL). The runner
requires at least three workers. Set `SKIP_TEST=TRUE` to provision the cluster
and driver without running conformance. `SKIP_DELETE=TRUE` leaves the created
cluster for inspection; the runner still deletes any cluster with the same
name before it starts.

Each worker has management virtio, two native emulated `igb` test PFs, and a
third emulated `igb` PF for the mock driver. The runner builds a kernel-matched
image in a privileged pod using the cluster's Driver Toolkit, pushes it to the
internal registry, caches it on every worker, and applies a worker-only
MachineConfig that starts the module before kubelet. It verifies switchdev,
real VFs, OVS representors and bidirectional traffic, then restores zero VFs
and legacy mode before operator conformance. RHCOS receives no development
packages. This delivery and test path is implemented, but OpenShift/MCO runtime
validation of the mock driver remains pending; see [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md).

## Test the driver and the full pod path

Local checks do not need root, a VM, or Kubernetes:

```bash
./scripts/ci.sh local
```

For the existing development harness, copy `config/lab.env.example` to
`config/lab.env`, fill in the explicitly authorized SSH alias, PF, node and cluster
context, and set the acknowledgements only after checking their prerequisites.
Verify SSH host keys; keep credentials and kubeconfigs outside this repository.

```bash
./scripts/lab.sh preflight
# Once setup-worker.sh has installed the driver:
./scripts/lab.sh operator-preflight
./scripts/ci.sh vm
```

The VM lane exercises actual PCI VFs, devlink, TC redirects and standalone OVS,
then returns to zero VFs. See [worker development](docs/03-vm-runbook.md).
For an already installed compatible operator with Multus and ovs-cni:

```bash
./scripts/kube.sh render
# Review rendered/ and the scoped node/PF settings, then:
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
```

The harness applies a scoped `SriovNetworkPoolConfig`, `SriovNetworkNodePolicy`,
`OVSNetwork`, and two pods. The operator creates the VFs/switchdev/bridge; ovs-cni
moves VF endpoints into pods and attaches their representors. Verification checks
bidirectional ping/UDP, actual TC `in_hw` rules, OVS offloaded flows, and increasing
mock-engine counters. See [Kubernetes flow](docs/04-kubernetes-flow.md).

## Cleanup

First remove the owned workloads/network/policy:

```bash
./scripts/kube.sh cleanup
```

Wait for operator reconciliation and remove only its owned pool configuration if
retiring the lab. The harness does not delete a shared operator installation.
After the owner has removed bridges/ports and VFs, run on the worker:

```bash
sudo --preserve-env=SSH_CONNECTION ./scripts/setup-worker.sh \
  --pf 0000:29:00.0 --emulated-pf --restore
```

This removes the owned persistence/module/VF suppression, restores the saved
native PF binding, and removes its unchanged NetworkManager configuration. It
refuses live VFs and used netdevs. For a deployment made with the older lab harness,
use `lab.sh reset`, `unpersist`, and `restore` instead. Keep saved state and console
recovery if installation failed; inspect it before manual cleanup.

The GPL-2.0-only driver and runnable tests are tracked. Site configuration, modules,
rendered manifests, downloaded sources/images and runtime evidence are ignored.
