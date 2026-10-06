# 06 — Primary-source references and version notes

Research refreshed 23 September 2026. The source links support the existing API
contracts and infrastructure, **not a claim that the proposed mock driver exists**.
The kernel and runtime package versions must be locked by the implementing agent.
Documentation URLs and unpinned master URLs can change; record actual revisions.

The operator default branch inspected resolves to
`a5588da21699fccce921cb1d4ac5894f47889399` (16 September 2026), whose merge includes
configurable ovs-vswitchd other_config. All operator implementation references below
use that immutable commit. The project must verify feature compatibility again if
it uses an older OpenShift/OLM release or newer upstream source.

## References

**[S01] Existing virtual operator tests.**
[Virtual-machine test guide](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/doc/testing-virtual-machine.md)
and its linked virtual-cluster script. Establishes emulated igb testing, DEV_MODE
and supported-NIC setup. Its VFIO/no-IOMMU discussion is deliberately not used in
this kernel-netdevice-only project.

**[S02] kcli existing provider support.**
[KVM provider](https://github.com/karmab/kcli/blob/c77c75380bf3efa70ba977327d562a0dce69c61d/kvirt/providers/kvm/__init__.py).
Contains native igb model handling and qemuextra/namespace/commandline generation;
no new dummy_pcidevices option is required for the baseline.

**[S03] QEMU emulated SR-IOV NIC and helpers.**
[igb.c](https://github.com/qemu/qemu/blob/master/hw/net/igb.c),
[PCIe SR-IOV helpers](https://github.com/qemu/qemu/blob/master/hw/pci/pcie_sriov.c),
[pci-testdev.c](https://github.com/qemu/qemu/blob/master/hw/misc/pci-testdev.c).
Inspect exact checkout for PF helper signatures, VF device ID/offset/stride/BARs.
The proposal reuses PCI semantics, not the native igb networking engine.

**[S04] Linux SR-IOV core.**
[PCI IOV howto](https://docs.kernel.org/PCI/pci-iov-howto.html) and
[drivers/pci/iov.c](https://github.com/torvalds/linux/blob/master/drivers/pci/iov.c).
Documents actual PF/VF creation, configure return values and VF autoprobe control.

**[S05] Vendor-specific firmware expectations.**
[Mellanox plugin](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/plugins/mellanox/mellanox_plugin.go).
Reason not to impersonate Mellanox in a generic in-guest simulator.

**[S06] Representor contract.**
[Network Function Representors](https://docs.kernel.org/networking/representors.html).
Defines slow-path directions, VF TX vs representor ingress, redirect-to-representee,
modern devlink identity and the distinction from a PCI endpoint.

**[S07] ovs-cni SR-IOV discovery and configuration.**
[sriov.go](https://github.com/k8snetworkplumbingwg/ovs-cni/blob/19262a0c9f304dc9cb04454afeed77e6ca77950b/pkg/sriov/sriov.go).
Explains VF BDF -> uplink/index/representor, endpoint movement, MAC/MTU setup and
bridge resolution. Use that checkout's actual sriovnet dependency version.

**[S08] Devlink port flavors and associations.**
[Devlink port documentation](https://docs.kernel.org/networking/devlink/devlink-port.html).
Distinguishes physical uplink and PCI PF/VF flavors. API usage must match the target
kernel rather than an unversioned copied example.

**[S09] Operator default-driver rebinding behavior.**
[kernel.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/host/internal/kernel/kernel.go),
[sriov.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/host/internal/sriov/sriov.go).
BindDefaultDriver accepts already-bound non-DPDK drivers and clears override before
probing an unbound default driver; manual per-VF overrides alone are insufficient.

**[S10] Existing simulation reference.**
[netdevsim bus](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/bus.c),
[netdevsim networking](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/netdev.c),
[netdevsim TC](https://github.com/torvalds/linux/blob/master/drivers/net/netdevsim/tc.c).
Reference patterns, not a drop-in PCI SR-IOV SmartNIC implementation.

**[S11] Resolved operator revision.**
[Commit a5588da](https://github.com/k8snetworkplumbingwg/sriov-network-operator/commit/a5588da21699fccce921cb1d4ac5894f47889399).
Includes the configurable OVS other_config API/runtime change relied upon here.

**[S12] Kubernetes OVS service integration.**
[k8s_plugin.go](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/plugins/k8s/k8s_plugin.go).
Checks ovs-vswitchd.service, renders OVS service options and can request a reboot.

**[S13] End-to-end bridge/network APIs.**
[OVS HWOL guide](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/doc/ovs-hw-offload.md),
[NodePolicy types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/sriovnetworknodepolicy_types.go),
[OVSNetwork types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/ovsnetwork_types.go).
Source for manageSoftwareBridges, bridge.ovs, switchdev policy and uppercase OVSNetwork.

**[S14] Libvirt commandline passthrough boundaries.**
[QEMU passthrough security](https://libvirt.org/kbase/qemu-passthrough-security.html).
Opaque extra devices need explicit topology/security/resource handling.

**[S15] OVS TC offload.**
[TC flower offload guide](https://docs.openvswitch.org/en/latest/howto/tc-offload/).
Source for hw-offload configuration and caveats including TC/software byte-count
differences. Pin OVS version and inspect its tc-policy behavior.

**[S16] TC core offload bookkeeping.**
[net/sched/cls_api.c](https://github.com/torvalds/linux/blob/master/net/sched/cls_api.c).
Successful callbacks are accounted by the core; drivers should not fabricate
classifier in_hw flags. Replace semantics must be checked against the target kernel.

**[S17] Pool configuration distinction and propagation.**
[Pool types](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/api/v1/sriovnetworkpoolconfig_types.go),
[findNodePoolConfig](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/helper.go),
[NodePolicy controller](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/sriovnetworknodepolicy_controller.go),
[HWOL/MCP controller](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/controllers/sriovnetworkpoolconfig_controller.go),
[webhook validation](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/pkg/webhook/validate.go).
Named HWOL configurations and node-selected pools have different code paths;
combining nonempty HWOL name with nodeSelector/maxUnavailable is rejected.

**[S18] Fresh-install chart inputs.**
[values.yaml](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/deployment/sriov-network-operator-chart/values.yaml),
[operator template](https://github.com/k8snetworkplumbingwg/sriov-network-operator/blob/a5588da21699fccce921cb1d4ac5894f47889399/deployment/sriov-network-operator-chart/templates/operator.yaml).
Contains full image inputs, DEV_MODE extra-env support, resource prefix, CNI path,
config-daemon node selector and supportedExtraNICs.

**[S19] Additional implementation-time prerequisite reference.**
[Multus CNI upstream](https://github.com/k8snetworkplumbingwg/multus-cni).
Select and pin a deployment matching the target cluster. No particular Multus
release or manifest was runtime validated for this package.

## Version-lock template the agent must fill

```json
{
  "operator_source": "a5588da21699fccce921cb1d4ac5894f47889399",
  "qemu_version": "RECORD_FROM_HYPERVISOR",
  "qemu_machine": "RECORD_EXACT_Q35_VERSION",
  "guest_kernel": "RECORD_UNAME_R",
  "kernel_config_sha256": "RECORD",
  "driver_source_commit": "RECORD",
  "driver_module_sha256": "RECORD",
  "ovs_version": "RECORD",
  "iproute2_version": "RECORD",
  "kubernetes_version": "RECORD",
  "operator_image_digest": "RECORD",
  "daemon_image_digest": "RECORD",
  "ovs_cni_image_digest": "RECORD",
  "sriov_device_plugin_image_digest": "RECORD",
  "multus_image_digest": "RECORD",
  "workload_image_digest": "RECORD"
}
```

The RECORD placeholders are intentionally not measurements. The implementing
agent must replace them from the real lab before claiming reproducible results.
