# 03 — Access a running VM, build, bind and iterate

## 1. Inputs and assumptions

The Linux/WSL controller has Bash, Python 3, rsync, GNU timeout, OpenSSH and local kubectl/oc. The DUT is a
running, disposable QEMU/KVM Linux guest with a separate management interface and
an emulated igb PF. The DUT has passwordless `sudo -n` for the explicitly authorized
lab operations, matching kernel build headers, and normal Linux networking tools.
The cluster lane also requires that this guest be a Ready worker of a real cluster.

The supplied scripts do not create SSH keys, scrape credentials, set passwords or
discover arbitrary hosts. Set a trusted alias, for example:

```sshconfig
Host mock-smartnic-dut
    HostName 192.0.2.40
    User labuser
    IdentityFile ~/.ssh/mock-lab
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

The address is an example, not a known DUT. Verify the host fingerprint against
the console/VM provisioning record; `ssh-keyscan` alone is not identity verification.
Use ProxyJump in SSH config if needed. A Codex sandbox may require authorization
for network access; without it, build local tests and explicitly record that the
VM stages were not executed.

```bash
cp config/lab.env.example config/lab.env
# Edit site inputs. Do not commit this file.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes mock-smartnic-dut 'uname -r; sudo -n true'
./scripts/lab.sh preflight | tee artifacts/preflight.txt
```

Create `artifacts/` first if using tee independently of the runner.

## 2. Check the actual PCI carrier before takeover

From the hypervisor, inspect the selected VM XML and record a snapshot identifier:

```bash
virsh dumpxml YOUR_VM > vm-before.xml
virsh domiflist YOUR_VM
```

The test NIC should be emulated `igb`; it must not be a passed-through PCI device.
QEMU guest DMI plus 8086:10c9 is not enough: a VM could have a real Intel card passed
through. Inspect the matching interface/controller and absence of relevant hostdev.
Keep a console (`virsh console YOUR_VM`, or your hypervisor's equivalent) available.

For a new VM, reuse existing kcli support rather than patching XML templates:

```yaml
mock-k8s-node:
  image: ubuntu2204       # example input; pin your actual OS/kernel separately
  machine: q35
  memory: 8192
  numcpus: 4
  nets:
    - name: default
      type: virtio
    - name: default
      type: igb
      noconf: true
```

The bridge/network names and OS image must exist in that kcli installation.
If using QEMU CLI directly, put the igb PCIe function on a suitable PCIe bus/root
port with adequate VF bus/BAR resources. Do not use `bus=pci.0` as a universal Q35
setting. The upstream virtual-test script is another provisioning reference.
[S01,S02,S14]

In the guest, inspect, do not guess, the chosen BDF:

```bash
lspci -Dnnk
sudo lspci -Dvv -s 0000:00:06.0
cat /sys/bus/pci/devices/0000:00:06.0/{vendor,device,class,sriov_totalvfs,sriov_numvfs}
ip -br addr
ip route
```

Set `PF_BDF` to that device. Start with zero VFs. If any existing workload uses it,
stop and use a fresh dedicated PF/VM rather than clearing it. Exclude the test PF
from NetworkManager/networkd auto-configuration using the distro's scoped per-NIC
method. Do not disable networking services globally.

## 3. Install build dependencies without upgrading the kernel

Copy/run the supplied optional installer only on a mutable test guest:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes mock-smartnic-dut \
  'sudo -n bash -s -- --install' < scripts/bootstrap-guest.sh
```

It installs tools and headers/devel for `uname -r`; it does not intentionally
upgrade the kernel or reboot. Package installation may start newly installed OVS
services, so run it only on the isolated lab worker. Verify:

```bash
uname -r
ls -ld /lib/modules/$(uname -r)/build
sudo modprobe sch_ingress
sudo modprobe cls_flower
sudo modprobe act_mirred
systemctl cat ovs-vswitchd.service
```

Do not copy a `.ko` from another distro/kernel. For missing old kernel headers,
use a matching supported build environment/package archive or deliberately boot a
new pinned kernel first and re-inventory. Never force vermagic/module-version checks.
For enforced module signatures, sign with an authorized enrolled key. Do not turn
off Secure Boot or lockdown automatically. For an immutable OS, see docs/04.

Required relevant kernel options include PCI/SR-IOV, namespaces/net namespaces,
network devices, devlink, TC ingress/flower/actions, OVS and DEBUG_FS. Check the
running kernel's config, not a package name. KASAN/lockdep are optional debug lanes.

## 4. Remote build

Codex writes driver sources locally, then:

```bash
./scripts/lab.sh build
```

The wrapper transfers only `driver/` to the configured remote source directory,
with derived binaries excluded and without rsync --delete. It runs the external
module build as the SSH user, using `/lib/modules/$(uname -r)/build`, saves local
build output, and prints modinfo and a SHA-256. It never builds as root by default.

Equivalent guest command:

```bash
make -C /lib/modules/$(uname -r)/build M="$PWD/driver" W=1 -j4 modules
modinfo driver/mock_smartnic.ko
```

Do not invoke runtime tests on a previous `.ko` after a failed build. Record the
source commit and binary hash together. The wrapper's build starts with module
clean so stale object files do not hide missing dependencies.

## 5. Take over the PF safely

After XML/management-path review, set:

```bash
EMULATED_PF_ACK=0000:00:06.0   # must exactly equal PF_BDF
EXCLUSIVE_PF_ACK=YES
```

Then run:

```bash
./scripts/lab.sh bind
./scripts/lab.sh vfs
./scripts/lab.sh collect > artifacts/pci-and-devlink.txt
```

The wrapper saves original driver/override/autoprobe/admin state under a root-owned
DUT state directory, refuses existing VFs/global addresses/master/upper/OVS use,
checks the SSH route, suppresses native igbvf only in this lab, loads the mock
module, and binds the exact PF through driver_override. It does not use a vendor-
wide `new_id`, unload unrelated PF drivers or silently destroy existing VFs.

Conceptual guest sequence (the script adds safety checks):

```bash
sudo insmod driver/mock_smartnic.ko target_pf="$PF_BDF" allow_igb_emulation=1
printf 'mock_smartnic_pf\n' | sudo tee /sys/bus/pci/devices/$PF_BDF/driver_override
printf '%s\n' "$PF_BDF" | sudo tee /sys/bus/pci/devices/$PF_BDF/driver/unbind
printf '%s\n' "$PF_BDF" | sudo tee /sys/bus/pci/drivers/mock_smartnic_pf/bind
```

For the manual experiment the script disables VF autoprobe, enables VFs, resolves
each virtfn symlink and explicitly binds mock_smartnic_vf. Its devlink check requires
K03. In the final operator flow, autoprobe is enabled and no external binding loop
is permitted to repair wrong VF bindings.

If bind/probe fails, collect kernel logs and the saved state. The script attempts
native PF rebind for the direct bind failure but preserves recovery information;
it cannot recover a kernel panic or lost SSH session. Use console/snapshot recovery.

## 6. Direct TC test

```bash
./scripts/lab.sh tc-smoke
```

Prerequisites: K03–K05, exactly identified VF endpoints and representors, no OVS
ownership of those representors, and required debugfs JSON files. The smoke script
uses two disposable namespaces, static neighbors, two IPv4 skip_sw redirect rules,
positive packet/counter tests and a negative control after deleting both rules.
It restores VF endpoints to the host and removes its namespaces/qdiscs on normal
exit or error. Check dmesg and no leaked interfaces even when a test fails.

This stage does **not** claim Kubernetes integration. Clean its artifacts and run:

```bash
./scripts/lab.sh reset
```

Reset refuses VFs apparently inside another namespace and representors attached
to OVS. It leaves zero VFs, legacy mode and `sriov_drivers_autoprobe=1`, ready for
the operator to do the real configuration later.

## 7. Persist through the operator's reboot

Set `PERSISTENCE_ACK=YES`, then:

```bash
./scripts/lab.sh persist
```

This installs the built module for the current kernel, modprobe options, a boot
binding unit and a kubelet dependency. It does not intentionally reboot the VM or
create VFs. Native VF suppression remains active until restore. The service must
run before kubelet, sriov-config services and ovs-vswitchd.

Perform the controlled reboot gate with console and cluster authorization:

```bash
kubectl --context YOUR_CONTEXT drain YOUR_NODE --ignore-daemonsets
# Resolve any PDB/emptyDir blockers explicitly; do not blindly add force flags.
ssh mock-smartnic-dut 'sudo -n systemctl reboot'
# Bounded reconnect/readiness polling; an SSH disconnect during reboot is expected.
ssh mock-smartnic-dut 'uname -r; sudo -n systemctl status mock-smartnic-lab.service'
kubectl --context YOUR_CONTEXT wait node/YOUR_NODE --for=condition=Ready --timeout=10m
kubectl --context YOUR_CONTEXT uncordon YOUR_NODE
```

The unit is kernel-version-specific, not automatic DKMS. Test both success and a
missing module on a disposable snapshot. If a kernel update occurs, rebuild/sign
for that exact kernel before enabling workloads; do not force-load the old binary.
The bootstrap unit intentionally does not configure the operator's VFs/bridge.

The executable gate `tests/integration/reboot.sh` verifies machine identity,
zero VFs, enabled persistent binding, kernel identity, a changed boot ID and
monotonic startup ordering. It drains only the configured DUT, uses bounded SSH
polls, and restores scheduling only after the checks pass. It requires populated
`PERSISTENCE_ACK`, `OPERATOR_REBOOT_ACK` and `VM_RECOVERY_ACK`; inspect the recovery
snapshot and console first. A failed gate leaves the DUT cordoned for recovery.

### Signed delivery and kernel changes

On a guest that enforces signatures, provision a matching private key and trusted
certificate through that guest's existing enrollment process. Keep the private
key outside this repository and its transfer directory. Sign the already-built
guest module with the pinned kernel's native tool, then persist that same file:

```bash
# Run on the guest. These are paths to provisioned files, not key contents.
sudo /lib/modules/$(uname -r)/build/scripts/sign-file sha256 \
  /secure/module-signing.key /secure/module-signing.der \
  /var/tmp/mock-smartnic-lab/src/driver/mock_smartnic.ko
modinfo -F signer /var/tmp/mock-smartnic-lab/src/driver/mock_smartnic.ko
sha256sum /var/tmp/mock-smartnic-lab/src/driver/mock_smartnic.ko
# From the controller, install the signed artifact without rebuilding it:
./scripts/lab.sh persist
```

Signer metadata alone does not prove trust. Require actual module load on the
enforcing guest and retain its kernel log; missing enrollment is a prerequisite
failure. The CentOS lab tested unsigned loading with lockdown disabled by its
existing configuration; no enforcement setting was changed. The signed lane is
not runtime tested there.

For a kernel change, first remove workloads through their owners and drain the
DUT. Remove persistence and restore the native carrier. Boot the explicitly
selected new kernel with console recovery available; kubelet must remain stopped
until a matching module is rebuilt, signed if required, bound, tested and installed.
Use matching kernel-devel/source, record their identities and the new module hash,
rerun PCI/devlink/flower/direct-TC/OVS gates, install persistence, and repeat the
reboot gate before uncordoning. Never force-load an old module, delete the kubelet
dependency to bypass a failed bind, or assume a kernel upgrade preserves APIs.

## 8. Code-change iteration

Before unloading/rebuilding a live driver: remove test pods; remove their network
and policy through the owning controllers; wait for bridge/VF cleanup; run reset;
remove persistence if installed; restore native binding. Then build, bind and test
the new module. Do not rmmod underneath pod-owned netdevices or live TC callbacks.
A faster development reload path may be added later, but must prove equivalent
teardown and preserve recovery state.

## 9. Diagnostics and limits

```bash
./scripts/lab.sh mapping
./scripts/lab.sh stats
./scripts/lab.sh flows
./scripts/lab.sh tc-json
./scripts/lab.sh ovs-evidence
./scripts/lab.sh collect > artifacts/guest-debug.txt
```

The stats/flows commands require the documented driver debugfs schema. Missing
files fail instead of returning fabricated zero counters. Capture debugfs after
reboot only once DEBUG_FS is mounted. Logs may contain operational identifiers;
review them before publishing. Never put kubeconfig/registry/SSH secrets in artifacts.

Each SSH command has a configurable local deadline (REMOTE_TIMEOUT). A killed SSH
client cannot guarantee cancellation of a stuck kernel syscall on the guest; use
console/snapshot recovery for that case rather than repeatedly launching writes.
