# 04 — Full operator -> HWOL -> node policy -> OVSNetwork -> pod flow

## 1. Required environment

Use a real Kubernetes worker VM, not a kind node container pretending to own host
PCI devices. The worker has the emulated PF, persistent mock module and a separate
management NIC. Use another node for the control plane so draining/rebooting the
worker does not destroy the API service required by the test.

Before applying manifests, verify:

1. Primary CNI and cluster are healthy; Multus and the NetworkAttachmentDefinition
   CRD are installed. Multus can call the node's CNI plugins and receive allocated
   PCI device information from the SR-IOV device plugin.
2. Host OVS uses the **kernel/system** datapath, its OVSDB socket is available to
   ovs-cni and `/opt/cni/bin/ovs` (or the actual configured CNI path) exists. Also
   verify host-local and loopback binaries. A controller pod being Ready does not
   prove its CNI binary was installed in kubelet's actual directory.
3. Exactly one intended SR-IOV operator installation owns the CRDs/config. Its
   config daemon and device-plugin pods run on the selected worker. Confirm the
   actual component image IDs and the resource prefix.
4. The mock PF is already bound and in legacy with zero VFs; autoprobe is enabled,
   native igbvf is absent/blocked, and K07's reboot gate passed.
5. No existing policy selects this PF, no existing node-selected pool overlaps the
   DUT, and no production/shared OVS instance will be altered. Review the existing
   CRs; never assume the word “lab” makes a cluster disposable.

The supplied kube.sh preflight verifies VM/node machine ID, key CRDs and schema
fields, then saves policies/pools for overlap review. It does not have authority
to resolve conflicts by deleting unrelated configurations.

## 2. Source and component installation

### Existing operator installation

Prefer reusing it only if its CRDs and images provide the pinned feature set.
Inspect `kubectl explain` for `bridge.ovs` and
`ovsHardwareOffloadConfig.otherConfig`. Do not install a second operator over an
OLM-owned deployment or mix a newer CRD with an older config-daemon image.

For the lab's emulated NIC, configure the supported-NIC entry:

```yaml
# An entry in the operator-owned supported-nic-ids ConfigMap / Helm values.
Mock_igb_82576: "8086 10c9 10ca"
```

For a fresh upstream development deployment, set operator environment
`DEV_MODE="true"` as the upstream virtual-testing guide prescribes. Existing
webhooks must remain enabled unless the selected new-lab deployment deliberately
uses its documented default without them; do not disable validation to hide
incorrect CRs. No unsafe VFIO/no-IOMMU setting is needed for this kernel-netdevice
lane, even though the upstream broader virtual test guide discusses it. [S01,S18]

### Fresh upstream Kubernetes installation

Use the supplied optional Helm installer after preparing image inputs:

```bash
git clone https://github.com/k8snetworkplumbingwg/sriov-network-operator.git ../sriov-network-operator
git -C ../sriov-network-operator checkout a5588da21699fccce921cb1d4ac5894f47889399
# Set OPERATOR_SOURCE and OPERATOR_IMAGE_VALUES in config/lab.env.
./scripts/install-operator.sh
# Inspect artifacts/install/rendered.yaml before approving the installation.
APPROVE_RENDERED_OPERATOR=YES ./scripts/install-operator.sh
```

For an existing Helm owner, use `./scripts/install-operator.sh upgrade RELEASE`
and inspect the render before rerunning with `APPROVE_RENDERED_OPERATOR=YES`.
The release must match the operator configuration's Helm ownership annotation.
Upgrade preserves existing release values, admission/cert-manager settings and
feature gates, scopes the daemon to the DUT, and applies the source-pinned SR-IOV
CRDs because Helm does not update `crds/` during upgrade. It leaves Multus's
shared NAD CRD with its existing owner. OLM installations use their owner instead.

`OPERATOR_IMAGE_VALUES` is a real local YAML file of pullable compatible component
images. Do not invent image tags from the source commit. Resolve an approved
published build or build/push the operator and config-daemon from the same source
using that checkout's Makefile/Dockerfiles, then record registry digests. Resolve
ovs-cni, device-plugin and other referenced components from compatible versions.
The chart uses full image values; its source-checkout defaults are not a version
lock. A sample shape (replace every placeholder before running Helm):

```yaml
images:
  operator: REGISTRY/operator@sha256:REAL_DIGEST
  sriovConfigDaemon: REGISTRY/config-daemon@sha256:REAL_DIGEST
  ovsCni: REGISTRY/ovs-cni@sha256:REAL_DIGEST
  sriovDevicePlugin: REGISTRY/sriov-device-plugin@sha256:REAL_DIGEST
  sriovCni: REGISTRY/sriov-cni@sha256:REAL_DIGEST
  ibSriovCni: REGISTRY/ib-sriov-cni@sha256:REAL_DIGEST
  rdmaCni: REGISTRY/rdma-cni@sha256:REAL_DIGEST
  resourcesInjector: REGISTRY/resources-injector@sha256:REAL_DIGEST
  webhook: REGISTRY/webhook@sha256:REAL_DIGEST
  metricsExporter: REGISTRY/metrics-exporter@sha256:REAL_DIGEST
  metricsExporterKubeRbacProxy: REGISTRY/kube-rbac-proxy@sha256:REAL_DIGEST
```

This example is a schema, not valid image credentials or published digest data.
Use existing registry authentication via the platform; never store pull secrets in
the agent's committed config. Inspect all rendered container images and image-env
variables. Keep image lock and source lock associated in the test report. [S18]

The tested source pins need two reproducible corrections in `patches/`:
`operator-systemd-ovs.patch` fixes the OVS unit's quoting and uses direct systemd
arguments for config values; `ovs-cni-vf-info.patch` restores VF metadata in the
vendored netlink default handle and guards an empty VF list. Both were observed
at runtime; neither changes device identity or fabricates topology/status.

`scripts/build-components.sh` applies those patches to dedicated pinned checkouts,
runs their renderer checks, builds static amd64 programs, and builds the four
images using `containers/Containerfile.*`. Set `OVS_CNI_SOURCE` and
`RUNTIME_IMAGE_OPERATOR`, `RUNTIME_IMAGE_DAEMON`, `RUNTIME_IMAGE_WEBHOOK` in the
local lab config. Each runtime parent must be an inspected immutable image digest
or local `sha256:` image ID, already available to Podman. The tested lab reused
existing runtime libraries and replaced all active binaries/bindata; record both
the parent and patch hashes. Published source-built parents are also usable.

```bash
./scripts/build-components.sh
./tests/integration/ovs-unit.sh  # actual renderer through guest systemd; no OVS mutation
# Archive each resulting localhost/mock-smartnic-ROLE:REV image with podman save.
# Push the archive to the authorized lab registry with skopeo copy --preserve-digests.
# Record the returned digest in OPERATOR_IMAGE_VALUES before the owner upgrade.
```

The installer scopes config-daemon placement to `mock-smartnic.test/target=dut`.
The test scripts also scope the policy and pods with that label. Ensure exactly
one node carries it. Preserve the primary CNI; do not deploy a second default CNI.
For an absent Multus installation, use its pinned upstream deployment appropriate
to the actual CRI/CNI directories, inspect images/hostPath mounts and test a simple
secondary attachment before debugging SR-IOV. This is a prerequisite deployment,
not part of the mock kernel module. [S19]

## 3. Enable managed OVS bridges

Patch only the needed feature gate, preserving other operator configuration:

```bash
kubectl -n sriov-network-operator patch sriovoperatorconfig default --type=merge \
  -p '{"spec":{"featureGates":{"manageSoftwareBridges":true}}}'
```

There is no invented `spec.hwOffload: true` field on SriovOperatorConfig in this
plan. Bridge management, global OVS HWOL configuration, and NIC switchdev mode are
separate concerns. The next sections configure each explicitly. [S13,S17]

## 4. Hardware-offload configuration: Kubernetes lane

The researched commit added configurable OVS `other_config`. The source has an
important distinction: `findNodePoolConfig()` skips pool objects with a nonempty
`ovsHardwareOffloadConfig.name`. For a **node-scoped Kubernetes pool**, leave that
name absent and use nodeSelector plus otherConfig. The selected pool then feeds
NodeState.spec.system.ovsConfig, which the Kubernetes host plugin renders into
the OVS service configuration. This is intentionally based on the pinned source,
not an assumption that every older operator release has the same API. [S11,S12,S17]

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkPoolConfig
metadata:
  name: mock-smartnic-pool
  namespace: sriov-network-operator
spec:
  nodeSelector:
    matchLabels:
      mock-smartnic.test/target: dut
  maxUnavailable: 1
  ovsHardwareOffloadConfig:
    otherConfig:
      hw-offload: "true"
      tc-policy: "none"
```

`tc-policy: none` permits the normal software miss/fallback behavior while OVS
installs offload rules. The final verifier still requires real offloaded flows.
Direct TC skip_sw testing is a separate earlier gate. Do not set skip_sw globally
just to claim every packet is offloaded; ARP/setup/control flows and unsupported
rules need explicit treatment. [S15]

Verify the actual chain after applying the switchdev policy:

```bash
kubectl -n sriov-network-operator get sriovnetworknodestate YOUR_NODE -o json \
  | jq '.spec.system,.status.system'
# On the worker, with its actual service and OVSDB available:
sudo systemctl cat ovs-vswitchd.service
sudo ovs-vsctl get Open_vSwitch . other_config
```

The OVS map must contain hw-offload=true. If the source supports the field but
the installed image does not propagate it, fix image/source compatibility. Do not
silently run ovs-vsctl by hand and label that a passed operator HWOL test. The
Kubernetes plugin may request drain/reboot to install service changes; persistence
must already be working and the test account must explicitly allow that reboot.

## 5. Switchdev node policy and operator-owned bridge

Use the exact PF BDF, not a vendor-wide selector:

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: mock-smartnic-switchdev
  namespace: sriov-network-operator
spec:
  resourceName: mock_smartnic
  nodeSelector:
    mock-smartnic.test/target: dut
  priority: 10
  numVfs: 2
  nicSelector:
    rootDevices:
      - "0000:00:06.0"
  deviceType: netdevice
  isRdma: false
  linkType: eth
  eSwitchMode: switchdev
  mtu: 1500
  externallyManaged: false
  bridge:
    ovs: {}
```

The BDF is an example. scripts/render.py substitutes the configured actual BDF.
The operator must itself create two VFs, bind/configure endpoints, set switchdev,
create its OVS bridge and attach the PF/uplink. In the referenced implementation
bridge names derive from PF BDF (for example `br-0000_00_06.0`). Discover actual
bridge names from NodeState or OVS rather than assuming ifindex/name stability.
[S13]

Wait for both desired and observed NodeState interfaces to show the exact PF,
numVfs=2 and switchdev, plus successful sync and allocatable resources. Also inspect
node conditions, config-daemon logs and native VF-driver absence. A CR accepted
by admission is not successful device configuration.

```bash
kubectl -n sriov-network-operator get sriovnetworknodestate YOUR_NODE -o yaml
kubectl get node YOUR_NODE -o json | jq '.status.allocatable'
# Example key; use the actual configured prefix.
# "openshift.io/mock_smartnic": "2"
```

Inspect the rendered SR-IOV device-plugin resource list and selectors. It must
accept `mock_smartnic_vf`, not require `igbvf`, mlx5 or RDMA devices. Do not change
the driver-reported identity to satisfy a mistaken selector. Fix the test resource
configuration or narrowly adjust the development-only compatibility layer, with
a test demonstrating why it is needed.

## 6. OVSNetwork and generated NAD

The actual CR kind is **OVSNetwork**, with uppercase OVS. The controller should
create the NAD in the workload namespace. Do not create a parallel hand-written
NAD for this final stage; that would skip the controller under test. [S07,S13]

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mock-sriov-e2e
---
apiVersion: sriovnetwork.openshift.io/v1
kind: OVSNetwork
metadata:
  name: mock-ovs
  namespace: sriov-network-operator
spec:
  networkNamespace: mock-sriov-e2e
  resourceName: mock_smartnic
  ipam: |
    {
      "type": "host-local",
      "subnet": "198.19.0.0/24",
      "rangeStart": "198.19.0.10",
      "rangeEnd": "198.19.0.50"
    }
```

No bridge name is required in this CR: ovs-cni can select the bridge using the
allocated VF and its PF/uplink membership. No gateway/default route is configured;
we do not want to redirect pod default traffic onto a nonexistent external wire.
The IP range is an example reserved for this isolated lab. Check for overlap with
cluster/pod/service/underlay ranges before use. host-local is suitable for this
single-worker pair, not a claim of cluster-wide address allocation. [S07,S13]

Inspect:

```bash
kubectl -n mock-sriov-e2e get network-attachment-definition mock-ovs -o json \
  | jq '.metadata.annotations, (.spec.config|fromjson)'
```

The `k8s.v1.cni.cncf.io/resourceName` annotation must be the real extended resource
key. Confirm the plugin type/config and host-local IPAM. Do not infer that a NAD
exists because OVSNetwork creation returned successfully.

## 7. Two pods consuming allocated VFs

One pod can prove CNI ADD. Two pods are needed for the same-node forwarding/offload
proof. The renderer creates both `mock-ovs-a` and `mock-ovs-b`, each with one VF,
using the same node selector. Normal scheduling and resource accounting remain
active; do not bypass allocation by hard-coding a VF BDF in the pod.

Representative pod (the renderer adds full security/resource details):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mock-ovs-a
  namespace: mock-sriov-e2e
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"mock-ovs","namespace":"mock-sriov-e2e","interface":"net1"}]'
spec:
  nodeSelector:
    mock-smartnic.test/target: dut
  containers:
    - name: echo
      image: python:3.12-slim  # resolve/pin your actual image digest
      command:
        - python3
        - -u
        - -c
        - |
          import socket
          s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
          s.bind(('0.0.0.0',9000))
          while True:
              data,peer=s.recvfrom(65535)
              s.sendto(data,peer)
      resources:
        requests:
          openshift.io/mock_smartnic: "1"
        limits:
          openshift.io/mock_smartnic: "1"
```

The executable rendered pods run unprivileged UDP and ICMP with all capabilities dropped,
no privileged host mount and no host networking. Vanilla Kubernetes uses explicit
nonroot UID 10000; the OpenShift renderer leaves UID assignment to the admitted
SCC. ICMP uses Linux ping datagram sockets with the pod's safe
`net.ipv4.ping_group_range` sysctl; no NET_RAW capability is needed.

Discover net1 IPs and allocated BDFs, not assumed pod order:

```bash
kubectl -n mock-sriov-e2e get pod mock-ovs-a -o json \
  | jq -r '.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]|fromjson'
kubectl -n mock-sriov-e2e exec mock-ovs-a -- python3 -c \
  'import os; print(os.getenv("PCIDEVICE_OPENSHIFT_IO_MOCK_SMARTNIC", ""))'
```

The helper uses the actual resource prefix to construct that environment name. If
the device-plugin configuration uses a different allocation delivery method, use
its pod-resources/device-info API and adapt the verifier explicitly. Missing device
identity must fail, not fall back to guessing VF0 for the first pod.

## 8. Execute the supplied Kubernetes workflow

```bash
./scripts/kube.sh render
./scripts/kube.sh preflight
# After confirming independent worker, reboot-safe binding and exclusive lab use:
./scripts/kube.sh apply
./scripts/kube.sh verify
./scripts/kube.sh collect
```

Apply uses server-side dry-run, patches only bridge management, creates pool/policy,
waits for real resources, creates OVSNetwork, checks the generated NAD's resource
key, creates the two pods and waits for readiness. It does not touch PF/VF counts
or OVS bridge ports itself. Existing same-name unowned resources are rejected.

Verify sends address-bound ICMP and UDP on net1, correlates distinct allocated BDFs with
PF virtfn indexes, checks TC in_hw, OVS offloaded datapath evidence, simulator
hit growth and **directional per-flow packet growth for this exact VF pair**.
It is intentionally stronger than “a packet went through” or “some unrelated
flow was offloaded”. Collect component logs separately if the stage fails.

Evidence collection keeps this pair's flows active with a bounded UDP exchange
(180-second deadline, 190-second client timeout). This prevents normal OVS idle
eviction between SSH snapshots; it does not install rules or alter OVS timeouts.
The verifier requires successful ICMP in both directions, successful UDP payload
checks and increasing counters while the OVS-generated flows are present.

An OVS rule may initially fall back because the mock driver rejects a mask/action.
Collect the actual rule/extack, implement the missing in-scope behavior and retry.
Do not make the verifier accept software-only forwarding to hide the missing work.

## 9. OpenShift / RHCOS lane

This lane uses the same driver behavior but different deployment ownership.
The scripts render its manifests but intentionally refuse automatic apply until
Codex implements and validates a matching immutable-node module-delivery path.

Required steps:

1. Use a dedicated emulated-igb worker, never the control plane. Record OpenShift
   release, RHCOS boot image, actual kernel and supported module-signing policy.
2. Build/sign the module against that exact kernel using a matching build image.
   Package/deliver it through the cluster's approved kernel-module mechanism, such
   as a version-matched KMM installation, or an explicitly managed test image.
   Inspect installed CRDs for the delivery API; do not invent a generic KMM YAML.
3. Ensure PF binding/native-VF suppression happens before config-daemon and kubelet
   reconciliation after reboot. The Ubuntu-style persistence script does not run
   on OSTree; implement/test the equivalent owned configuration via the approved
   node-management path. Do not install Ubuntu headers on RHCOS.
4. Create or use a **dedicated MachineConfigPool** selecting only this worker.
   Its MachineConfig selector normally includes worker and its dedicated role.
   Inspect the MCO's actual pool membership and rendered config before changes.
5. Render with CLUSTER_TYPE=openshift, OPERATOR_NAMESPACE set to the actual operator
   namespace, and MCP_NAME set to the dedicated MCP. Do not use `worker` or `master`.
6. Apply the named HWOL pool object below. Do not include nodeSelector/maxUnavailable
   in the same object: the pinned webhook rejects that combination. Those are
   separate node-pool/parallel-configuration concerns. [S17]
7. Wait for the dedicated MCP update/reboot and worker Ready; verify module binding
   survived. Preserve OLM ownership and do not replace platform-managed components
   with unrelated upstream master images.
8. Apply the node policy/OVSNetwork/pods as above, adapted to the operator schema
   shipped with this OpenShift release. Run the same evidence checks. A missing
   new otherConfig field is a version compatibility issue to resolve, not a reason
   to turn off webhook validation.

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkPoolConfig
metadata:
  name: mock-smartnic-hwol
  namespace: openshift-sriov-network-operator
spec:
  ovsHardwareOffloadConfig:
    name: mock-smartnic      # existing dedicated MCP, not a node label
    otherConfig:
      hw-offload: "true"
      tc-policy: "none"
```

This path can affect the node's shared OVS service, including primary OVN networking.
Do not run generic `systemctl restart openvswitch` from the lab harness on such a
node. Use the approved MCO/operator rollout and its readiness conditions. Reboot,
module, OVN and MCP failures require console/cluster recovery, not blind retries.
[S12,S17]

## 10. Optional VLAN and broader tests

Only after untagged IPv4 passes, add a separate OVSNetwork with vlan=200 and extend
the mock engine for the actual VLAN matches/actions OVS emits. Test isolation and
push/pop/masked matching; do not declare VLAN supported because the CR was accepted.
Separate later lanes cover IPv6, external uplink, cross-worker traffic and stateful
features. Each must explicitly extend the capability contract and negative tests.
