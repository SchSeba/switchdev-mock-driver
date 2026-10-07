# Implementation status

## Package delivery

- Architecture and driver: implemented; original K00–K09 plan completed.
- VM and Kubernetes harness: implemented and replayed against the configured lab.
- Operator virtual OpenShift mock-driver delivery: implemented with Driver Toolkit and a worker MachineConfig; runtime not tested.
- Local checks and runtime evidence: recorded below; commands in dated entries are historical.
- Driver sources: PCI, devlink, slow path and TC engine implemented and tested.
- Kernel module compilation: W=1 build passed on the exact guest kernel.
- VM connection / exact PCI PF takeover: passed on virtual-worker-0.virtual.lab.
- Runtime: K00–K09 passed on the pinned release kernel, including operator/CNI ping,
  offload execution, resilience, CI replay and final restoration of two Ready pods.

## Agent progress table

| Gate | Implemented | Built | Runtime passed | Evidence / blocker |
|---|---|---|---|---|
| K00 inventory and source lock | yes | n/a | yes | artifacts/preflight-k00-final.log, versions.json, config/source-lock.json; final K08 components verified |
| K01 module scaffold | yes | yes | yes | artifacts/build-k01.log, bind-k01-k02.log, module-parameters-k01.log |
| K02 PCI carrier and VF lifecycle | yes | yes | yes | artifacts/pci-vfs-k02.log, pci-lifecycle-k02.log; no QEMU fallback required |
| K03 devlink/netdev discovery | yes | yes | yes | devlink-lifecycle-k03-attempt2.log, vf-netlink-k03.log, slowpath-k04-attempt1.log |
| K04 slow-path datapath | yes | yes | yes | artifacts/slowpath-k04-attempt1.log; exact payload/direction/policy checks and software OVS ping |
| K05 TC parse/execute/stats | yes | yes | yes | flower-engine-k05-attempt12.log; nonlinear probe check; real extack/packet/stats/capacity/teardown checks |
| K06 direct TC and standalone OVS | yes | n/a | yes | tc-smoke-k06-attempt1.log, ovs-offload-k06-attempt1.log |
| K07 reboot-safe deployment | yes | yes | yes | devlink-lifecycle-k07.log, persist-unit-k07.log, reboot-k07-attempt1.log; signing/other kernels not tested |
| K08 operator full flow | yes | yes | yes | kube-apply-k08-attempt3.log, kube-verify-k08-attempt2.log, k08-verdict-with-icmp.log |
| K09 resilience and CI | yes | checks pass | yes | 50 pod cycles, allocation recovery, kernel stress/reload/reboot; local/VM/Kubernetes CI passed; mock-driver OpenShift/debug/signing lanes untested |

Append a dated entry per attempt with source SHA, running kernel, commands,
exit codes, evidence paths, and next action. Never replace unknown with pass.

## 2026-10-06 — K00/K01/K02

Authorized cluster: kubeconfig supplied by user, context `kubernetes-admin@virtual`.
DUT: `virtual-worker-0.virtual.lab`, VM `virtual-worker-0`, hypervisor accessed
through the user-supplied root SSH endpoint. Guest machine ID matches the node.
No password was changed. Verified the worker host public key through the existing
node-specific config-daemon host mount; added the existing controller public SSH
key to cloud-user's authorized keys. SSH host-key checking remains enabled.

Live sysfs proved `0000:15:00.0` carries SSH/default traffic; it remains native igb.
Use only `0000:29:00.0` (XML net1 MAC `52:54:00:c3:17:c1`) as the dedicated carrier.
Both existing NICs are emulated igb, not virtio; management and test PFs are
independent. XML contains no hostdev. Snapshot
`mock-smartnic-baseline-20261006` provides disk recovery, and virsh console is
available. The selected PF is scoped unmanaged by NetworkManager through
`/etc/NetworkManager/conf.d/90-mock-smartnic-lab.conf`; remove this owned file
during final native restoration if appropriate.

Running kernel and matching devel: `5.14.0-427.el9.x86_64`, source SRPM
`kernel-5.14.0-427.el9.src.rpm`; actual PCI-core source and devel headers read.
QEMU `8.2.0`, machine `pc-q35-8.2`; OVS `3.5.3-6.el9s`; Kubernetes `v1.34.2`.
Native igbvf is modular and suppressed only through the owned harness override.
Lockdown reports `[none] integrity confidentiality`; unsigned external-module
loading is allowed, with the expected external/unsigned module taint messages.
No module-signing enforcement or SELinux setting was disabled.

Exact commands and exit statuses (artifacts are local, Git-ignored):

| Command | Exit | Evidence / interpretation |
|---|---|---|
| `./scripts/lab.sh preflight` before tool installation | 1 | `preflight-k00.log`, missing lspci; rerun later succeeded |
| `sudo dnf install -y gcc make elfutils-libelf-devel iproute ethtool pciutils kmod jq python3 rsync iputils centos-release-nfv-openvswitch` over DUT SSH | 0 | `install-tools-k00.log`; running kernel unchanged |
| `sudo dnf install -y --setopt=localpkg_gpgcheck=1 https://kojihub.stream.centos.org/kojifiles/packages/kernel/5.14.0/427.el9/x86_64/kernel-devel-5.14.0-427.el9.x86_64.rpm` | 1 | `install-headers-k00.log`; unsigned build RPM correctly refused |
| Same command with signed URL `.../427.el9/data/signed/8483c65d/x86_64/kernel-devel-5.14.0-427.el9.x86_64.rpm` | 0 | `install-headers-signed-k00.log`, signature checking enabled |
| `sudo dnf install -y openvswitch` | 1 | Distribution uses versioned package names; no security bypass |
| `sudo dnf install -y openvswitch3.5-3.5.3-6.el9s` | 0 | `install-ovs-k00.log` |
| `sudo systemctl enable --now openvswitch` | 0 | `ovs-start-k00.log`; OVSDB empty, no shared OVS bridge |
| `virsh snapshot-create-as virtual-worker-0 mock-smartnic-baseline-20261006 --disk-only --atomic --diskspec hdd,snapshot=no` | 0 | `recovery-snapshot-k00.log` |
| `./scripts/run-local-checks.sh` | 0 | `local-k00.log`, 16 tests, optional PyYAML test skipped |
| `./scripts/lab.sh preflight` after tools/devel/OVS | 0 | `preflight-k00-final.log` |
| `./scripts/kube.sh preflight` | 0 | `kube-preflight-k00.log`, no existing policies/pools overlap DUT |
| `./scripts/lab.sh build` | 0 | `build-k01.log`, W=1, correct vermagic; BTF omitted because vmlinux absent |
| `./scripts/lab.sh bind` | 0 | `bind-k01-k02.log`, exact PF claimed, native management intact |
| `./scripts/lab.sh pci-vfs` | 0 | `pci-vfs-k02.log`, actual 8086:10ca objects at 29:10.0 and 29:10.2 |
| `./scripts/lab.sh pci-reset` | 0 | `pci-reset-k02.log`, real VFs removed |
| `./tests/integration/pci-lifecycle.sh` first attempt | 1 | Test compared a canonical physfn path with a symlink path; corrected test, not driver |
| `./scripts/lab.sh pci-reset && ./tests/integration/pci-lifecycle.sh` retry | 0 | `pci-lifecycle-k02.log`, 0→2→0→2 with autoprobe off/on, stable PF, repeated zero, rejected counts |

Driver source base commit: `1cb9785f64603d82253ad9ea2269c05c6640df73` with uncommitted implementation.
K01/K02 source tree SHA-256: `ba41e21f867ac266fc238f21122957ab9cf345a95af0895d11af6b933b7acfdf`.
Module SHA-256: `bf6b7fbc1210ea0f8170e5e335dff6d828aafa5cf8713c76b56dbc99c7f5e7ef`.
Full source/version lock: `artifacts/versions.json`.

K02 is RUNTIME PASSED. K03–K09 are NOT IMPLEMENTED / NOT TESTED.
No switching/offload capability is advertised yet; VF TX is explicitly dropped
and the PF is an isolated sink. Final operator bridge/pods/ping/TC evidence remains
unexecuted. Next: devlink/representor discovery, VF netlink setters, exact sriovnet
lookup tests, then the slow-path and TC engine.

## 2026-10-06 — K03 in progress

- `./scripts/lab.sh pci-reset && ./scripts/lab.sh restore` exit 0; native carrier
  restored before replacing the module (`restore-before-k03.log`).
- `./scripts/lab.sh build` initial devlink build exit 0
  (`build-k03-attempt1.log`); VF setter expansion exit 2 for missing explicit
  if_arp/rtnetlink includes (`build-k03-attempt2.log`); corrected build exit 0
  (`build-k03-attempt3.log`), no compiler warnings. Exact guest kernel unchanged.
- `./tests/integration/module-parameters.sh` exit 0
  (`module-parameters-k01.log`): missing opt-in/BDF, invalid slot and trailing
  suffix refused; positive registration preserved native PF ownership.
- `./scripts/lab.sh bind && ./scripts/lab.sh vfs` exit 0
  (`bind-k03.log`, `vfs-switchdev-k03.log`): real switchdev GET/SET, one physical
  uplink and two PCI-VF devlink ports with common switch ID and pf0vfN identities.
- `./tests/integration/devlink-lifecycle.sh` initial exit 1
  (`devlink-lifecycle-k03-attempt1.log`): namespace teardown returns PCI netdevs
  asynchronously; immediate assertion was premature. Added a 30-second deadline.
- `./scripts/lab.sh reset && ./tests/integration/devlink-lifecycle.sh` retry exit 0
  (`reset-k03-retry.log`, `devlink-lifecycle-k03-attempt2.log`): both mode-before-VFs
  and VFs-before-mode sequences, correct metadata, actual sriovnet v1.3.0 lookup
  calls, VF default-driver reprobe preserving representor ifindex, and namespace
  deletion/return. Only one PCI-parented netdev remains per PF/VF.
- `./scripts/run-local-checks.sh` exit 0 (`local-k03.log`), 16 tests, one optional
  YAML-parser skip.

Current K03 module SHA-256:
`1171a7642d2515e8bde9cc268862ec954e65194c56423fc4af0f33711f0bec5e`.
Getter/setter state checks are being run next. Spoof-check packet enforcement,
slow-path traffic and TC execution remain untested; no HW_TC bit is advertised.
Nonzero VLAN/QoS, rate limiting and trusted-VF receive policy are explicit
unsupported settings. These are not silent successes.

K03 VF state validation: `./scripts/lab.sh vfs &&
./tests/integration/vf-netlink.sh` exit 0 (`vfs-k03-setters.log`,
`vf-netlink-k03.log`). MAC updates affect the live endpoint, MTU changes round-trip,
link disable/enable changes carrier, and nonzero VLAN, trust-on and nonzero rates
are rejected by the actual driver. Spoof-check netlink state round-trips; its
packet enforcement is the next datapath test. The K03 interface gate passed.

K04 implementation is in progress: the datapath uses the pinned kernel's
`dev_forward_skb` for namespace scrubbing and exactly one Ethernet RX conversion.
The new actual-packet gate checks both directions, payload/duplicate counts,
spoof/link policies, isolation, and a temporary software OVS bridge. No TC offload
result is claimed by this gate.

K04 build: `./scripts/lab.sh reset && ./scripts/lab.sh restore &&
./scripts/lab.sh build` exit 0 (`reset-before-k04.log`,
`restore-before-k04.log`, `build-k04.log`), W=1 on the same exact guest kernel.
Module SHA-256: `e42b04976ce1d27efdc8473051b45a6e9918cb87f8e3588bea3c458a3a97a281`.
No runtime forwarding pass is claimed until the new packet gate finishes.

## 2026-10-06 — K04 runtime passed

`./scripts/lab.sh bind && ./scripts/lab.sh vfs &&
./tests/integration/slowpath.sh` exit 0 (`bind-k04.log`, `vfs-k04.log`,
`slowpath-k04-attempt1.log`) on kernel `5.14.0-427.el9.x86_64`, module
`e42b04976ce1d27efdc8473051b45a6e9918cb87f8e3588bea3c458a3a97a281`.
The raw Ethernet checks received exactly one matching frame for VF→rep and
rep→VF, with intact payload, and zero matching frames for unswitched VF→VF.
Correct-MAC frames passed with spoof checking enabled; changed-MAC frames were
dropped. Link-disable stopped rep→VF delivery. A temporary owned system-datapath
OVS bridge forwarded 5/5 ICMP replies in each direction; removing it restored
100% packet loss. The bridge and both namespaces were cleaned up, and endpoints
returned to the host. This is a SOFTWARE forwarding baseline, not TC offload.

`./scripts/run-local-checks.sh` exit 0 (`local-k04.log`), 16 checks, one optional
YAML-parser skip; the packet helper additionally passed Python compilation and
was exercised on the actual guest. Source lock refreshed in `artifacts/versions.json`.
K05 parser/execution/counters and K06 positive offload remain NOT IMPLEMENTED.

## 2026-10-06 — K05 implemented and built; runtime checks pending

Added ingress flow-block callbacks, owned normalized predicates and terminal
redirect/drop programs, a 256-rule RCU list, output-device references, per-flow
cumulative counters and delayed TC deltas, and read-only debugfs JSON. Nonzero
unsupported keys/flags/actions/chains/stats modes fail with extack. IPv4/L4
predicates check packet lengths; non-first fragments cannot match L4 predicates.
The pinned native skb dissector handles options and nonlinear header access.
VLAN actions and tagged VLAN predicates remain explicit unsupported features.
Representors advertise HW_TC only now that callbacks and execution exist.

`./scripts/lab.sh build` initial exit 2 (`build-k05-attempt1.log`): the pinned
kernel has no netdev_warn_ratelimited API. Replaced it with net_ratelimit plus
netdev_warn. Retry exit 0 (`build-k05-attempt2.log`), W=1, kernel
`5.14.0-427.el9.x86_64`, module SHA-256
`9f5e4b87d984f02091f89039baf3142c96f1de78b9f49dc20a396eae707fe8d2`.
`./scripts/run-local-checks.sh` exit 0 (`local-k05-initial.log`), 16 checks, one
optional YAML-parser skip. These build/local results do not establish HWOL.

K05 runtime attempts and fixes (all on `5.14.0-427.el9.x86_64`):

- Reset/restore/bind/VFs for the first K05 image: exit 0
  (`reset-before-k05.log`, `restore-before-k05.log`, `bind-k05.log`, `vfs-k05.log`).
- `flower-engine.sh` attempts 1–3 exit 1: test started before the sequential
  VF setup finished; corrected OVS CLI error wording; then actual IPv4 acceptance
  failed because native flower registers both aliases of its IPv4/IPv6 union.
  Logs `flower-engine-k05-attempt{1,2,3}.log` preserve each result.
- Build attempt 3 exit 0, SHA `6ebceceee72551e529c70cee01fbfee0598c170fec3fd5f94e3edd75765ac37d`;
  runtime attempt 4 exit 1: native TC always fills action miss_cookie, even for
  terminal redirects. Removed rejection of this core-generated identity. Accepted
  programs never resume after an action; CT/metadata/action programs still fail.
- Build attempt 4 exit 0, SHA `23c51a0182d655c7e2b0d2999b9521fcc53a38720864ef173c685a126aeaaafb`;
  runtime attempt 5 exit 1: TC JSON has a header entry without options; changed
  the assertion to inspect actual filter entries. Attempt 6 exit 1: priority
  debug output wrongly shifted the already-normalized native common.prio. Actual
  stats nevertheless showed one offload hit, not a failed packet parser.
- Build attempt 5 exit 0, SHA `b127ea910cb88fadeddc9030231b0dbc59969fce5eb37e2774e486bddacafb54`;
  first bind transport exit 255 before mutation; inspected native igb/zero VFs/
  absent module/recovery state, retried bind exit 0 (`bind-k05-priority-retry.log`).
  Attempts 7–9 exit 1: replacement test changed the mask and failed before driver;
  ICMP CLI uses type/code; an add test reused an existing handle. Corrected these
  tests so unsupported actions and overlapping predicates reach driver extack.
- Attempt 10 exit 1 after packet/rejection/stats/ENOSPC tests passed: native
  wanted_features retains the rejected off request. Restore requested on before
  testing a fresh successful off request; no kernel-owned state is overwritten.
- Added actual nonlinear/linear IPv4-options/UDP comparison at PF probe and
  counters for redirects to disabled/missing endpoints. Build attempt 6 exit 0,
  SHA `67e6dea187d7d0006437124331e22721d1a23bae975b0ade134759b292544bdb`.
- `./scripts/lab.sh reset && ./scripts/lab.sh restore && ./scripts/lab.sh build &&
  ./scripts/lab.sh bind && ./scripts/lab.sh vfs &&
  ./tests/integration/flower-engine.sh` exit 0, logs `reset-k05-drops.log`,
  `restore-k05-drops.log`, `build-k05-attempt6.log`, `bind-k05-drops.log`,
  `vfs-k05-drops.log`, **`flower-engine-k05-attempt11.log`**. Actual packet matches,
  MAC/IP masks, nofrag, untagged VLAN count, IPv4 options, first/non-first fragment
  behavior, malformed/truncated packets, ICMP/TCP flags, terminal drop/priority,
  successful/failed replacement, stable repeated stats, active-flow feature guard,
  256-entry capacity/ENOSPC, and qdisc teardown all passed.

Scoped owned NetworkManager config now excludes msnicp*/msnicr*/msnicv* so it
cannot initiate DHCP on the mock ports (`nm-ports-k05.log`, exit 0). Management
remains native igb on 15:00.0. An initial controller command sourced bash helpers
from zsh and exited 1 before any mutation; rerun using bash succeeded.

Final K05 race fix is awaiting a rebuilt rerun: mode teardown quiesces first,
then publication rechecks state under flow_lock. This closes publication-after-
flush and cross-port unregister reference races; locking rationale is documented
in driver/LOCKING.md. No K06 or Kubernetes HWOL pass is claimed yet.

K05 final rebuild/rerun: reset, restore, build, bind, VFs, flower-engine.sh all
exit 0 (`reset-k05-final.log`, `restore-k05-final.log`,
`build-k05-attempt7.log`, `bind-k05-final.log`, `vfs-k05-final.log`,
`flower-engine-k05-attempt12.log`). Kernel unchanged; module SHA-256
`2c8da0b31713b78cd6a4ab3c89e209e3ebe3761e5f5a0320cec56c69cc6d6bc5`.
K05 is RUNTIME PASSED. Kernel/source lock refreshed in artifacts/versions.json.
Concurrent teardown stress remains a separate K09 check; the final Kubernetes
flow is still unexecuted.

## 2026-10-06 — K06 direct TC runtime passed; standalone OVS pending

`./scripts/lab.sh collect` exit 0 (`collect-k05.log`): actual nonlinear parser
probe check passed; rejection traces contain their extack reasons, and expected
feature-guard/ENOSPC errors. No new WARN/Oops/refcount report was observed.
`./scripts/lab.sh tc-smoke` exit 0 (`tc-smoke-k06-attempt1.log`), pinned kernel
`5.14.0-427.el9.x86_64`, module
`2c8da0b31713b78cd6a4ab3c89e209e3ebe3761e5f5a0320cec56c69cc6d6bc5`.
10/10 ping replies; both real skip_sw TC filters in_hw, 10 HW packets/980 bytes
per direction, delayed stats and increasing driver hits. Removal gives 2/2 lost
pings. Owned qdiscs and namespaces were cleaned; endpoints returned to host.
Standalone OVS-generated flow acceptance is still pending, so K06 is partial.

K06 standalone OVS: `./tests/integration/ovs-offload.sh` exit 0
(`ovs-offload-k06-attempt1.log`). OVS 3.5.3 system datapath, same module/kernel.
Software skip_hw baseline: 30/30 identical UDP echoes, 2/2 ping, zero additional
driver hits. Separate skip_sw lane: 600/600 identical UDP echoes and 10/10 ping;
OVS-generated TC rules show in_hw, OVS offloaded:yes/dp:tc, 599 UDP HW packets
per direction and nine ICMP HW packets per direction (initial packets use upcall).
Actual emitted IPv4/no-fragment masks needed no further parser extension.
Removing the owned bridge leaves zero active flows and 2/2 lost pings. Cleanup
removed owned namespaces/qdiscs and restored global OVS other_config exactly `{}`.
IPv6 control-packet drop flows remained explicitly software; the supported
IPv4 lane is what passed. `run-local-checks.sh` exit 0 (`local-k06-final.log`).
K06 is RUNTIME PASSED. K07 persistence/reboot and K08 Kubernetes remain pending.

## 2026-10-06 — K07 persistence and reboot runtime passed

`lab.sh reset && tests/integration/devlink-lifecycle.sh` exit 0
(`reset-before-k07.log`, `devlink-lifecycle-k07.log`): ten default-driver rebinds
in each creation order, persistent representor ifindex, namespace return and
switchdev VF removal. `lab.sh persist` exit 0 (`persist-k07.log`). Native
`systemd-analyze verify` and service start passed; kubelet Requires/After the
owned binding unit (`persist-unit-k07.log`). Only DaemonSet pods were present.
Recovery snapshot and console availability rechecked before setting persistence
and reboot acknowledgements under the user's authorized lab-deployment goal.

`tests/integration/reboot.sh` exit 0 (`reboot-k07-attempt1.log`): drained only
virtual-worker-0.virtual.lab, changed boot ID, same kernel 5.14.0-427.el9.x86_64,
same module SHA 2c8da0b31713b78cd6a4ab3c89e209e3ebe3761e5f5a0320cec56c69cc6d6bc5,
PF mock binding, zero VFs, legacy mode, autoprobe=1 and mock VF driver registered.
Native igbvf absent. Binding became active at 6499795 us, kubelet at 10011812 us;
node returned Ready and was uncordoned. No passwords or hypervisor boot settings
changed. `run-local-checks.sh` exit 0 (`local-k07.log`).

Native sign-file delivery and kernel-update/rebuild procedure documented in
docs/03-vm-runbook.md. Trusted-signature enforcement and a different kernel are
NOT TESTED; this existing lab allows unsigned loading. No enforcement bypass was
performed. Further concurrent debugfs/teardown stress belongs to K09.

K08 starts with persistent mock PF, zero VFs, legacy, empty OVS, no manual NAD or
bridge. Final VF/bridge/NAD/representor attachment will be owned by operator/CNI.

## 2026-10-06 — K08 PF programming gate and component preparation

Pinned operator source unconditionally enables PF HW_TC before configuring
switchdev. Implemented the PF shared programming gate, with active-flow EBUSY
and explicit rejection of PF ingress blocks (the uplink has no external RX).
Representor ingress remains the only offloaded ingress engine. Added actual
flower checks for disabled PF rejection, enabled acceptance and busy disable.

Commands `lab.sh unpersist`, `restore`, `build`, `bind`, `vfs`,
`tests/integration/flower-engine.sh`, `lab.sh tc-smoke`,
`tests/integration/ovs-offload.sh`, `lab.sh reset`, `persist` each exit 0;
logs are the corresponding `*-k08-pf-gate.log` files. Module SHA-256
198d28fe17afcd259c62eff281ce9244273020c9a83cb5ed3bdb78ef7edef498,
kernel 5.14.0-427.el9.x86_64. `tests/integration/reboot.sh` exit 0
(`reboot-k08-pf-gate.log`): binding active at 5923766 us, kubelet 9094214 us,
changed boot ID, Ready/uncordoned, legacy and zero VFs, management unchanged.

Built operator, daemon, webhook and cleanup binaries with Go 1.26.8,
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 from a5588da21699fccce921cb1d4ac5894f47889399:
`BIN_PATH=build/_output/cmd make _build-manager _build-sriov-network-config-daemon
_build-webhook _build-sriov-network-operator-config-cleanup`, exit 0
(`build-operator-k08.log`). OVS/marker/mirror binaries built from
19262a0c9f304dc9cb04454afeed77e6ca77950b using its vendored dependencies,
CGO_ENABLED=0 and -tags no_openssl, exit 0. Runtime parents from the existing
registry were inspected and archived; all active programs and bindata replaced
with pinned builds. Four `podman build --platform linux/amd64 --pull=never
--network=none` commands exit 0 (`build-image-*-k08.log`).
`podman save --format oci-archive` and `skopeo copy --preserve-digests` for each
image exit 0 (`push-*-image-k08.log`, `*-image-k08.digest`). Fresh repository
paths were used; old tags were not overwritten. Existing published auxiliary
components resolved to actual digests (`component-digests-k08.json`).

Registry direct downloads timed out (three exit 124), and a stalled remote
Podman client was stopped (143). An authenticated, host-key-verified SSH local
forward through the hypervisor delivered the images without host/network changes.
Helm 3.17.3 checksum verified, Skopeo 1.18.0 installed (apt logs exit 0).

`ping-probe.py` uses nonroot ICMP datagram sockets, source-IP binding, sequence,
nonce and peer verification. Actual loopback probe 2/2, exit 0
(`ping-helper-loopback-k08.log`); Kubernetes ICMP remains NOT TESTED.
`run-local-checks.sh` exit 0 (`local-k08-upgrade.log`), 16 checks, optional
PyYAML validation skipped. Added the safe ping_group_range pod sysctl and
bidirectional ICMP to the final verifier without relaxing offload assertions.

Existing release sriov-network-operator has enabled admission/cert-manager and
newer conditions-based NodeState CRDs. Added explicit owner-checked upgrade using
existing values and source-aligned SR-IOV CRDs; the shared NAD CRD is untouched.
Review renders exit 1 by design until APPROVE_RENDERED_OPERATOR is supplied.
First authorized install attempt exit 1 due to a CRD field-manager conflict,
after two unchanged CRDs applied; no image rollout occurred. Changed to the
existing native client-side apply manager for the schema update; retry in progress.
No manual VF, bridge, NAD, representor port or NodeState status was created.

K08 first component rollout: `APPROVE_RENDERED_OPERATOR=YES
scripts/install-operator.sh upgrade sriov-network-operator` exit 0
(`install-operator-k08-attempt2.log`). Matching native schemas, controller,
daemon, enabled admission/injector and CNI init containers rolled out. Installed
/opt/cni/bin/ovs SHA-256 matches the compiled binary
0dd1f25256a380e32366de52f79bd5499cb59de01f56f4798b94eea8206a03c5.
`kube.sh apply` exit 1 (owned readiness client stopped after diagnosis;
`kube-apply-k08-attempt1.log`): real pool/policy, VFs, switchdev, bridge and NAD
reconciled; pods could not become ready. Operator reboot preserved pinned kernel,
mock binding and IOMMU arguments (iommu=pt intel_iommu=on). Native systemd showed
OVS ExecStartPre syntax error/status 2, so no HWOL pass is claimed.

Fixed pinned operator template quoting and used native direct systemd arguments
for OVS key/value setters. This avoids shell/environment/specifier interpretation
of config values. `go test ./pkg/utils -run '^TestRenderOtherOvsConfigOption$'
-count=1` exit 0 (`operator-ovs-render-test-k08.log`). Initial invocation from
our repo instead of the operator directory exit 1 before running any tests.
`tests/integration/ovs-unit.sh` exit 0 (`ovs-unit-native-k08-attempt1.log`):
the actual Go renderer and guest systemd parser executed an owned temporary stub,
with exact old-key cleanup and literal dollar/backtick/percent/quote/backslash
arguments. The stub never alters the OVS database or hardware. Saved reproducible
patch and native test in patches/operator-systemd-ovs.patch.

Second actual defect: ovs-cni's vendored netlink global handle defaults to
collectVFInfo=false while NewHandle defaults to true. Native PF VF attributes
were present, but package LinkByName omitted the requested VF extension. Patched
the shared default and incorrect bounds check that panicked for VF0 when empty;
patches/ovs-cni-vf-info.patch. Built the actual pinned-vendor discovery helper and
ran against both real PCI VFs, exit 0 (`sriovnet-vfinfo-k08-patched.log`). It now
asserts the default lookup returns real VF metadata as well as sriovnet mapping.
CNI panic/event and unit failure artifacts are retained.

Removed owned failed pods/network/policy with `kube.sh cleanup` exit 0
(`kube-cleanup-k08-failed-attempt1.log`); waited for operator Succeeded, no desired
interfaces or observed bridge, then `lab.sh reset` exit 0
(`reset-k08-failed-attempt1.log`). Empty/legacy baseline restored. The owned pool
remains for the retry. Added active OVS service and actual OVSDB other_config
checks before future pod creation. Patched component builds exit 0
(`build-operator-k08-patched.log`, `build-image-*-k08-patched.log`);
patched registry delivery/retry is in progress.

Patched image archives/pushes each exit 0 (`push-*-image-k08-patched.log`),
source/patch/image hashes saved in artifacts/versions.json. Owner upgrade and
daemon/webhook rollout exit 0 (`install-operator-k08-patched.log`,
`rollout-daemon-k08-patched.log`). Component rebuild recipe and four native
Containerfiles are now in the repo. `scripts/build-components.sh` actual replay
exit 0 (`build-components-replay-k08.log`); registry delivery is a separate action.

Second policy apply triggered a real operator reboot. New boot ID
91d977e8-efc9-4be6-b959-df2081da597a; binding active at 6120831 us, kubelet
13375484 us. OVS service is ACTIVE, actual other_config hw-offload=true and
tc-policy=none (`ovs-config-after-fix-k08.json`). NodeState Succeeded, two VFs,
switchdev, correct bridge; device-plugin Ready. Apply attempt 2 exit 1 before
creating NAD/pods because our new jq checker treated OVSDB pair arrays as objects;
corrected map parsing and verified against the actual saved OVSDB JSON (exit 0).
Apply now permits retry only for an owned policy with exact PF, VF count,
resource/mode and DUT selector, plus persistent mock binding. Initial apply still
requires the zero-VF baseline. `run-local-checks.sh` exit 0
(`local-k08-retry.log`); apply attempt 3 and traffic verification in progress.

`kube.sh apply` attempt 3 exit 0 (`kube-apply-k08-attempt3.log`): both pods
Running/Ready, source-matched corrected ovs-cni. Network-status maps
198.19.0.10 to 0000:29:10.0 and 198.19.0.11 to 0000:29:10.2 on net1.
`kube.sh verify` attempt 1 exit 1 (`kube-verify-k08-attempt1.log`): actual
bidirectional ICMP 10/10 and UDP 400/400 each, driver hits 99 -> 1697. Its
per-flow assertions correctly refused a pass: normal OVS idle eviction removed
flows between slow separate SSH evidence reads (stats saw four flows, subsequent
flow dump was empty). No unsupported flower rejection was observed.
Added bounded, payload-verified background UDP on the tested pair during evidence
collection to keep actual OVS flows alive, preserving all directional/in_hw checks.
The helper now has an overall deadline and reports actual attempts separately
from requested count; timeout cannot report an incomplete batch as successful.
Second verification is in progress. One parallel read-only SSH inspection failed
255 after a stale mux connection; no mutation was retried blindly.

## 2026-10-06 — K08 full operator/CNI/offload runtime passed

`./scripts/kube.sh verify` exit 0 (`kube-verify-k08-attempt2.log`). Both Running
pods: net1 198.19.0.10/198.19.0.11, distinct 0000:29:10.0/0000:29:10.2,
operator-renamed host representors msnicp0_0/msnicp0_1 on br-0000_29_00.0.
Actual ICMP 10/10 in each direction; foreground UDP 400/400 each, bounded
background 15000/15000 identical echoes (`keepalive.json`, 156.334 seconds).
Native TC in_hw, OVS offloaded datapath entries with exact representor actions,
same directional IPv4 rule cookies increased 1142 -> 4114 packets each.
Driver offload_hits increased; no helper installed TC rules or a manual final
bridge/port/VF/NAD. All were owned by operator, ovs-cni and OVS.

`python3 scripts/verify-evidence.py artifacts/kubernetes 0000:29:10.0
0000:29:10.2` exit 0 (`k08-verdict-with-icmp.log`); verdict now explicitly requires
both ICMP files and rejects a UDP-only success. `run-local-checks.sh` exit 0
(`local-k08-verdict.log`), 17 checks, optional PyYAML roundtrip skipped.
Actual bounded negative UDP deadline check exit 1 as expected, enclosing assertion
exit 0 (`udp-deadline-local-k08.log`). The installed ovs-cni SHA-256 matches
66e9dc66b64607300d72e7bc7cf053cfb366cd85cffb2a94a45b2df9c87c7c87.
Real source/patch/image IDs, daemon-owned NodeState, NAD, policy selector,
OVS service journal and kernel log saved; K08 artifacts copied to k08-passed/
before resilience tests. K08 is RUNTIME PASSED. K09 remains pending.

## 2026-10-06 — K09 resilience in progress

Added `tests/integration/pod-cycles.sh`: two-VF scheduler exhaustion, release and
successful allocation recovery, then 50 real CNI ADD/DEL cycles. Each checks
actual net1 PCI IDs against the proven PF mapping, both 5/5 ICMP directions,
new driver hits and return of both endpoints with zero stale representor OVS
ports/active rules. All polls have deadlines. `pod-cycles.sh 50` exit 0;
pod-cycles-k09-attempt1.log and pod-cycles/verdict.json record all 50 passes,
scheduler exhaustion/recovery and zero remaining test pods. Last cycle recorded
34370 cumulative driver hits. Kernel/module versions are unchanged from K08.

Added bounded kernel-stress tests for TC replacement/drop/redirect under traffic,
concurrent debugfs reads, duplicate delivery, no forwarding after rule deletion,
ten VF-count/mode cycles, open-file removal safety and module unload/reload.
Operator ownership and assigned pods must be cleaned up first. The pinned operator's real cleanup
RemovePfAppliedStatus removes its ownership record, so no daemon disablement
or fabricated state is needed for the offline kernel lane.

CI layers added through `scripts/ci.sh` and a local-check GitHub workflow.
`ci.sh local` exit 0 (`ci-local-k09.log`, ci-local-k09-final-syntax.log);
17 harness tests with optional PyYAML skip. Invoking VM with a nonexistent
explicit config returns SKIP/77 (`ci-vm-skip-k09.log`, null verdict), and optional
OpenShift lane returns SKIP/77 (`ci-openshift-skip-k09.log`). The online GitHub
job itself is NOT RUN; the same local command ran here. Privileged runtime
results remain separate from static CI. All integration Python scripts now
receive syntax checks. Native CONFIG_KASAN and PROVE_LOCKING are not set on the
pinned kernel; CONFIG_DEBUG_LIST=y. KASAN/lockdep coverage is NOT TESTED.

Portable source lock added at config/source-lock.json (no site credentials).
Compared actual guest/local handwritten C/header/Makefile trees: both SHA-256
4b0ef9f0cbe3c044eba363b3c83a0f3d6f87042b9c5f632ec7a2fe7be4c4c1c9.
Initial comparison included guest-generated *.mod.c and failed an assertion;
corrected the documented hash input to exclude generated artifacts.

Added an actual allocation-failure recovery test using a controller-generated
OVSNetwork/NAD with a valid one-address host-local range.
`allocation-recovery.sh` exit 0 (allocation-recovery-k09-attempt1.log and
allocation-recovery/verdict.json): the second sandbox failed with the real
host-local exhaustion error, then the same pod became Ready after the first
released its address. Its recovered PCI VF belonged to the configured PF.
No NAD was hand-created; both negative-test pods and the controller-owned test
network/NAD were cleaned up. K09 offline kernel tests are next.

`kube.sh cleanup` exit 0 (kube-cleanup-k09.log); actual NodeState Succeeded with
empty interfaces/bridges, PF zero VFs/legacy and its applied-ownership file absent.
Deleted only the owned pool. `lab.sh reset` and `lab.sh vfs` exit 0 in this offline
kernel lane (reset-before-kernel-stress-k09.log, vfs-kernel-stress-k09.log).
`kernel-stress.sh` exit 0 (kernel-stress-k09-attempt1.log): 200 TC replacements
under concurrent traffic/debugfs reads; no duplicate RX or forwarding after rule
deletion; ten real 2→0→3→0 VF/mode cycles; held debugfs read safely returns EIO after
PF unbind; module unload refuses while its file is open, succeeds after close;
reload binds only the configured PF and leaves zero VFs/legacy.

`reboot.sh` exit 0 (reboot-k09-attempt1.log): binding active at 6433795 us, kubelet
at 9681061 us; kernel and module SHA-256 unchanged. A preliminary journal search
used unavailable guest rg; reran with grep successfully (kernel-health-k09.log),
finding no warning/oops/UAF/refcount/list corruption signatures. The optional
debug-kernel/signing lanes remain NOT TESTED.

For the standalone CI replay, verified that no pool/policy/OVSNetwork remained,
NodeState interfaces/bridges were empty, no PF ownership record remained, zero
VFs existed, and OVS had no bridge. Matched the exact test drop-in SHA-256 before
removing it, removed only hw-offload/tc-policy and the operator-owned-key marker,
preserved unrelated external_ids, reloaded systemd and restarted the empty OVS.
Exit 0 (ovs-owned-cleanup-k09.log), global other_config returned to `{}`.

`ci.sh vm` exit 0 (ci-vm-k09-attempt1.log; artifacts/ci/vm.json passed=true):
the entire privileged PCI/devlink/default-rebind/flower/direct-TC/standalone-OVS
lane replayed on the same module. OVS skip_hw baseline and skip_sw offload each
passed actual UDP/ping; 599 UDP and 9 ICMP offloaded packets per direction were
reported, then bridge deletion stopped traffic and cleanup restored empty OVS.
The lane finished zero VFs/legacy. `ci.sh kubernetes` is now restoring/retesting
the final controller-created pair from that clean baseline.

## 2026-10-06 — Final restored demonstration: RUNTIME PASSED

`./scripts/ci.sh kubernetes` exit 0 (ci-kubernetes-k09-attempt1.log,
artifacts/ci/kubernetes.json passed=true). Starting from zero VFs/legacy and empty
OVS, the operator recreated the pool/policy, requested its OVS configuration
reboot, created two real VFs/switchdev/bridge and reached Succeeded. Its controller
created the NAD and OVS-CNI attached the representors. No final-stage VF, bridge,
NAD, representor port or NodeState status was created manually.

The final worker is Ready and uncordoned. Both pods remain Running/Ready in
mock-sriov-e2e on virtual-worker-0.virtual.lab:

| Pod | net1 IPv4 | Allocated real PCI VF | ICMP | UDP |
|---|---|---|---|---|
| mock-ovs-a | 198.19.0.31 | 0000:29:10.0 | 10/10 to b | 400/400 to b |
| mock-ovs-b | 198.19.0.32 | 0000:29:10.2 | 10/10 to a | 400/400 to a |

Actual TC in_hw and OVS offloaded flows were captured. Within the same module
lifetime, driver offload_hits rose 1345→7299. The same IPv4 redirect cookies on
each VF rose 1142→4119 packets. The bounded flow-keeping exchange completed
15000/15000 payload-verified packets in 156.133 seconds. Final immutable evidence
is copied under artifacts/k09-final-passed; the earlier K08 baseline remains
under artifacts/k08-passed. artifacts/final-verdict.json records the actual results.

Final host inspection exit 0 (final-host-health-k09.log): kernel
5.14.0-427.el9.x86_64, iproute2 6.17.0/libbpf 1.3.0, OVS 3.5.3-6.el9s;
module SHA-256 198d28fe17afcd259c62eff281ce9244273020c9a83cb5ed3bdb78ef7edef498;
installed ovs-cni binary SHA-256
66e9dc66b64607300d72e7bc7cf053cfb366cd85cffb2a94a45b2df9c87c7c87.
The final operator-requested boot ID is 7ae0290d-3f88-4566-81a9-7b33660af180:
binding at 6043222 us preceded kubelet at 13130333 us. IOMMU kernel arguments
remain enabled. Management 0000:15:00.0 remains native igb with the same IP and
zero VFs. Current boot has no warning/oops/UAF/refcount/list corruption signatures.
No password, SSH verification, SELinux or signature enforcement setting changed.

Kubernetes v1.34.2 / CRI-O 1.34.11; existing primary CNI Flannel v0.28.9 and thick
Multus image IDs are recorded in config/source-lock.json and
k09-node-{system,flannel}-images.json. Running operator/daemon/webhook/device-plugin
image IDs are in component-imageids-final-k09.json. Compiled handwritten source
and patch hashes match config/source-lock.json (source-lock-check-k09.log).
`ci.sh local` exit 0 (ci-local-k09-final.log): 17 tests, one optional PyYAML skip;
shell/Python syntax and staged diff checks passed. Unified patch files keep their
literal context whitespace via .gitattributes; the actual applied Go source
diffs separately pass git diff --check. No binaries, site config or credentials
are included in the source commit.

The supported milestone is two untagged IPv4 pods on one dedicated emulated
worker. The CPU mock engine is Linux driver offload, not physical acceleration;
the uplink is an explicit sink with no external wire. Rules are capped at 256.
VLAN actions/tagged predicates, stateful/CT, tunnels, IPv6 address and ARP-specific
matches, shared blocks, nonzero chains and unsupported masks/actions/stats remain
explicit failures. Basic Ethernet ARP forwarding is supported. The operator
virtual OpenShift mock-driver path is implemented, but its runtime, enforced
signing, other kernels, KASAN/lockdep and online GitHub execution remain NOT
TESTED. A separate focused switchdev test passed on real OpenShift/Mellanox
hardware without this mock module. These results do not validate the virtual
mock-driver path.

README.md provides the demo entry point, CR-to-device-plugin flow and cleanup
links. docs/05 gives the 50-cycle/failure/stress/CI replay and ordered cleanup.
The final operator-managed pair is intentionally left available for inspection.

## 2026-10-06 — First-push cleanup and worker installer

Implemented and runtime passed: `scripts/setup-worker.sh` reuses the existing
build/bind/persistence/recovery harness, installs missing OVS/build dependencies,
and scopes binding and NetworkManager exclusion to an explicitly attested
secondary PF. Setup leaves zero VFs/legacy/autoprobe enabled. The boot unit now
checks the saved native PF MAC before rebinding and shares the live-interface
safety guard. Restore removes only owned persistence and unchanged NM rules.
No handwritten driver source changed: SHA-256 remains
`4b0ef9f0cbe3c044eba363b3c83a0f3d6f87042b9c5f632ec7a2fe7be4c4c1c9`.

Removed the obsolete handoff bundle, stale checksums/baseline validation report,
duplicate static manifests, completed work-package plan, external patch/image
builders and their obsolete renderer test. Kept driver, runtime checks and exact
historical evidence; rewrote README/runbooks and added GPLv2 LICENSE. Moved 2.3 GB
of ignored source/image/tool caches outside the project to
`/var/tmp/mock-smartnic-build-cache-20261006`; 12 MB of runtime evidence remains in
`artifacts/`. Site configs and credentials were preserved and remain ignored.
Historical commands above may name removed tooling; they describe the original
run rather than current installation instructions.

Tested installer source: Git commit `93b98c6` (before the final documentation and
version-record update), genuinely cloned from a local Git bundle because the
repository's first remote push is still pending. Worker checkout:
`/var/tmp/mock-worker-setup-src-20261006`. The actual W=1 build and module load ran
on `virtual-worker-0.virtual.lab`, kernel `5.14.0-427.el9.x86_64`, OVS
`openvswitch3.5-3.5.3-6.el9s.x86_64`. New installed module SHA-256:
`45425eb18787078e1936350a32a9ac65d63335699da17117de9058f78266c1d4`.
The byte hash differs from the original build because the build directory changed;
the handwritten source hash is identical.

The supplied API endpoint was temporarily unreachable from the controller.
Read-only node checks succeeded through an authenticated SSH local forward to
that same configured cluster, with a private kubeconfig copy and TLS server-name
verification retained. The original kubeconfig was not modified. Subsequent lab
commands used `LAB_CONFIG=/tmp/mock-worker-setup-lab.env` to select that copy.
Hypervisor XML again confirmed two emulated igb interfaces and no hostdev; only
MAC `52:54:00:c3:17:c1`, PF `0000:29:00.0`, belongs to the dedicated test network.

| Exact command / action | Exit | Evidence |
| --- | --- | --- |
| `./scripts/ci.sh local` | 0 | worker-setup-local.log; 19 tests, one optional PyYAML skip |
| `python3 ../sriov-network-operator/hack/test-virtual-mock-setup.py` | 0 | worker-setup-runner-checks.log; 3 checks for input, XML and new-boot ordering |
| `bash -n ../sriov-network-operator/hack/run-e2e-conformance-virtual-cluster.sh` | 0 | syntax passed; no cluster recreation invoked |
| `scripts/kube.sh cleanup`, bounded NodeState wait | 0 | worker-setup-cleanup.log; Succeeded, no owned interfaces/bridges |
| `scripts/lab.sh unpersist`, `scripts/lab.sh restore` | 0 | worker-setup-unpersist-old.log, worker-setup-restore-old.log; native secondary PF recovered |
| Worker `scripts/setup-worker.sh --pf 0000:15:00.0 --kernel 5.14.0-427.el9.x86_64 --emulated-pf` | 1, expected | worker-setup-runtime.log; eth1 has a global IP, refused before installation |
| Worker `scripts/setup-worker.sh --pf 0000:29:00.0 --kernel 5.14.0-427.el9.x86_64 --emulated-pf` | 0 | worker-setup-runtime.log; actual build/bind, persisted, zero VFs/legacy |
| Installed boot script with private test config pointing to management PF but saved test-PF MAC | 1, expected | worker-setup-restore-reinstall.log; MAC mismatch refused, live boot config unchanged |
| Worker same setup command with `--restore`, then install again | 0 | worker-setup-restore-reinstall.log; native binding restored, owned files removed, reinstall passed |
| `scripts/lab.sh vfs`, `scripts/lab.sh tc-smoke`, `scripts/lab.sh reset` | 0 | worker-setup-vfs.log, worker-setup-tc.log, worker-setup-reset.log; real VFs, TC in_hw/counters/ping, negative control, then zero VFs |
| `tests/integration/reboot.sh` | 0 | worker-setup-reboot.log; actual new boot, module before kubelet, zero VFs/legacy |
| `scripts/kube.sh apply`, `scripts/kube.sh verify` | 0 | worker-setup-kube-apply.log, worker-setup-kube-verify.log; operator/CNI independently recreated two Ready pods, ping/UDP, TC/OVS/engine evidence passed |

Final boot ID `142a8e67-9bac-44d5-837c-15df6a03c6f1`. Management PF
`0000:15:00.0` / MAC `52:54:00:13:e5:fe` / `eth1` stayed on native `igb`, with
`192.168.124.128/24` and its original default route. No password or security
setting was changed. Final owned demo PF has two real VFs/switchdev; pods
`mock-ovs-a` and `mock-ovs-b` are Running/Ready, net1 `198.19.0.33` and `.34`.
Bidirectional ICMP was 10/10, UDP 400/400 each direction; the evidence keepalive
also completed 15000/15000. See worker-setup-final-state.log and artifacts/kubernetes/.

Companion operator commit `2716a0d4c`, branch `add_mock_hwoffload_driver`, changes
only the virtual conformance shell runner and its runnable Python checks. It
accepts an HTTPS mock repo/full commit SHA/kernel pin, attests the dedicated NIC
from XML, resolves its exact MAC, waits for a new boot, clones and invokes setup,
and propagates DEV_MODE to the actual operator deployment. No operator Go or
ovs-cni implementation was changed in this task. Review text is in the ignored
`artifacts/operator-pr.md`.

Not tested in this replay: full destructive cluster-recreation conformance runner,
HTTPS clone before first publication, fresh package installation (OVS/tools/devel
already existed; their original signed-package installation is recorded above),
other kernels, immutable hosts, enforced signing, or a second DUT. The runner PR
is prepared for that fresh test after the mock repository is pushed and its
immutable revision and pinned-kernel guest image are supplied.


## Fresh virtual operator conformance replay — 2026-10-06 (runtime passed)

Recreated the authorized `virtual` Kubernetes cluster on `root@10.46.97.14`
with the companion operator runner. Both workers cloned public mock revision
`724d8984696f9124f777776e45d2108cec60c214`, built and persisted the module on
`5.14.0-427.el9.x86_64`, and installed OVS `3.5.3-6.el9s`. No driver C source
changed in this replay. Fresh module SHA256:
`2bfd510468054e10e3d9a40fb4a563c74213c20334961b5af74cfe1823c4111e`.
Kubernetes is `v1.34.2`; the test controller uses Go `1.26.8`, linux/arm64 and
Ginkgo `2.32.0`; images were built with Go `1.26.5` for linux/amd64.

Operator base `2716a0d4c9894428fa0cdeb233dd61a8f734315e` plus the companion
working diff now recognizes the mock PF/VF in conformance discovery, excludes
the management PF, renders OVS systemd arguments correctly, and removes empty
bridge status through SSA. Readiness checks require current-generation status
and ready config-daemon/device-plugin DaemonSets. Reboot checks require a new
boot ID rather than a potentially absent `NodeReady=Unknown` transition.
The fixed ovs-cni source is
`fdd16b8ed495519ca79122d60b298743603dea4d`; its locally built image was deployed
through Helm's OVS CNI override. Unsupported mock capabilities remain explicit
skips; no software fallback is counted as IPv4 offload success.

The complete requested suite exited 0: **37 passed, 0 failed, 27 skipped** in
28m35s. Switchdev executed and passed inside that full run, with bidirectional
5/5 ping, executed IPv4 redirects, native TC `in_hw` and OVS IPv4 offloaded
packet counters 79/79. A separate focused run also passed on worker 1.

Retained evidence is under `artifacts/conformance-20261006/`; `RUN.md` records
commands, failures and retries. `conformance-retry3/unit_report.xml` is the
complete passing report. Operator diff SHA256:
`55120bf1c082f02bfe576c52cfd6c77f176042cfdef4a58ae2313c0dc113304b`.
Deployment copies remain under `/var/tmp/sriov-mock-conformance-20261006/`
on the hypervisor. Retained provisioning logs redact bootstrap tokens;
credentials, keys and kubeconfigs are excluded.

| Command/action | Exit | Result/artifact |
| --- | --- | --- |
| Runner with `SKIP_DELETE=TRUE SKIP_TEST=TRUE MOCK_SMARTNIC_REPO=https://github.com/SchSeba/switchdev-mock-driver.git MOCK_SMARTNIC_REF=724d8984696f9124f777776e45d2108cec60c214 MOCK_SMARTNIC_KERNEL=5.14.0-427.el9.x86_64 CLUSTER_TYPE=kubernetes LOCAL_OVS_CNI_IMAGE=localhost/ovs-cni:mock-switchdev-20261006` | 2 initially | Cluster recreated and both installations passed; initial image build lacked copied Git metadata (`cluster-recreate.log`). |
| Restore source Git metadata and resume unchanged deployment tail | 0 | Fresh operator/daemon/webhook and fixed CNI deployed; validation 6/6 passed (`resume-deploy.log`). |
| Worker installer targeting management PF `0000:15:00.0` | 1, expected | Rejected before changes (`primary-guard.log`). |
| `GOARCH=arm64 GOOS=linux go test ./pkg/utils ./pkg/host/internal/service ./pkg/plugins/k8s ./test/util/cluster` | 0 | `unit.log`; later readiness regression also passed (`readiness-unit.log`). |
| `KUBEBUILDER_ASSETS=/tmp/k8s/1.35.0-linux-arm64 go test ./pkg/daemon` | 0 | `daemon-unit.log`; actual last-bridge-removal regression passed, and fails without its fix (`daemon-bridge-regression.log`, `daemon-bridge-regression-red.log`). |
| Focused conformance `bin/ginkgo --focus=Switchdev --timeout=45m ... ./test/conformance` with requested Kubernetes/emulated-PF environment | 0 on retry2 | Bidirectional 5/5 ping, executed IPv4 redirects, native TC `in_hw`, OVS offloaded flows with packet counters, and cleanup all passed (`switchdev-retry2.log`, JUnit). |
| Focused `--focus='Daemon reset with shutdown'` with requested environment | 0 | New boot ID, Ready and host-file cleanup passed (`reboot-reset.log`, JUnit). |
| Focused `--focus=Switchdev` with `SRIOV_NODE_AND_DEVICE_NAME_FILTER=virtual-worker-1.virtual.lab:msnicp0` | 0 | Worker 1 also passed bidirectional 5/5 ping, executed IPv4 redirects, native TC `in_hw`, OVS IPv4 offloaded packets 77/78 and cleanup (`switchdev-worker1.log`, JUnit, Running/Ready pod snapshot). |
| `make lint` | 0 | Zero issues (`lint-final.log`). |
| Requested `SUITE=./test/conformance hack/run-e2e-conformance.sh` with `OPERATOR_NAMESPACE=sriov-network-operator KUBECONFIG=/home/vscode/kubeconfig/virt-cluster-k8s GOARCH=arm64 GOOS=linux CLUSTER_TYPE=kubernetes CLUSTER_HAS_EMULATED_PF=TRUE` | 0 | 37 passed, 0 failed, 27 skipped; switchdev and reboot/reset passed (`conformance-retry3.log`, JUnit). Earlier partial runs diagnosed rollout/admission and transient reboot-condition assumptions. |
| Final read-only API, worker binding and libvirt XML checks | 0 | Both workers Ready/schedulable, NodeStates Succeeded/current-generation; test resources removed, webhook/injector restored; native primary PFs unchanged; mock PFs legacy/zero VFs/empty engine flows (`final-*.json`, `final-worker-bindings.txt`, `hypervisor-attestation.json`). |

The supplied kubeconfig was refreshed for the recreated cluster. API TLS
verification is retained through an authenticated SSH local forward. VM host
keys were attested by read-only libguestfs reads from the explicitly named VM
disks. Initial kcli provisioning had implicitly disabled SSH host-key checking;
a scoped native SSH wrapper now forces verification for all subsequent calls.
No password or guest security mode was changed. A live conformance check shows
management PF `0000:15:00.0` / `eth1` still on native `igb`, zero VFs, with its
default route intact on both workers (`primary-both-during-conformance.txt`).
Final worker checks confirm the same primary driver, zero VFs and default
gateway/interface after all reboots. Both mock modules retain the recorded
SHA256; OVS `hw-offload=true` remains configured for subsequent tests.

Not tested here: GitHub Actions execution, other kernels, immutable or
enforced-signing hosts, physical hardware acceleration, or unsupported mock
capabilities. The 27 skips include absent platforms/devices/services and
explicit mock limits; switchdev was not skipped. The opt-in CI runner still
requires the documented pinned-kernel image and fixed ovs-cni image.

## 2026-10-06: native conformance beside the third mock PF

Implemented: the worker binding harness now uses owned
`softdep igbvf pre: mock_smartnic` instead of blocking native igbvf. The exact-PF
mock probe rejects other PFs' VFs. Initial binding still refuses to unload an
igbvf driver with unrelated users; boot MAC/usage checks remain before loading
and binding. README/architecture and reboot/local safety checks were updated.
The operator runner adds a third emulated igb NIC on the same test network,
attests the two configured test MACs, names the native secondary `sriovtest0`,
and filters regular tests to it. Only emulated switchdev selection chooses
`mock_smartnic_pf`; the trust, VLAN/QoS, IPv6 and jumbo mock-specific skips are gone.
The existing primary checksum workaround resolves the default-route interface,
since adding a PCI NIC changed kernel interface enumeration. Its driver is igb.

Built: both workers built the e5f680ae3f1a745f580383ef832b9659096f4d39 C sources
with the local binding-script overlay on kernel 5.14.0-427.el9.x86_64. Module
SHA256 c03d917f27938821ec9fc806531563150a826ebf4c974b9d1d61000dea972ae1.
This installer change is not yet published; the runner refuses old blocking
installers. No C-driver or ovs-cni source changes were needed for this follow-up.

Runtime passed: actual libvirt MAC/model/no-passthrough attestation on both named
workers; worker0 reboot with native name and exact third-PF binding before kubelet;
23 guest IOMMU groups per worker; native VFIO allocation/partitioning and native
jumbo frames. Full-suite switchdev passed on PCI 0000:2a:00.0 with native igbvf
loaded: seven mock VFs, two Running/Ready allocated pods, bidirectional 5/5 ping,
increasing directional IPv4 engine hits, kernel TC in_hw and OVS offloaded IPv4
packet counters 68/68. All seven secondary VFs were separately observed using
igbvf while the management PF retained zero VFs.

Local passed (exit 0): `./scripts/ci.sh local` (20 checks, one optional PyYAML
skip); operator `python3 hack/test-virtual-mock-setup.py` (five checks),
`go test ./test/util/cluster`, conformance package compilation,
`bash -n hack/run-e2e-conformance-virtual-cluster.sh`, and `make lint` (zero issues).

Full conformance passed: exit 0, **47 passed / 0 failed / 17 skipped**,
39m27s, including switchdev, trust, VLAN/QoS, IPv6 ping, jumbo traffic and
reboot cleanup. No focus/skip filters were used. Exact
commands, installation logs, binding snapshots and reports are retained in
`artifacts/three-nic-20261006/RUN.md` and its sibling files. The authorized
virtual cluster alone was modified; no passwords or SSH verification settings
were changed. Native management MACs, addresses, routes and PF drivers were
preserved; its netdev name changed from eth1 to eth2 after PCI enumeration.

Worker1 reboot also passed (new BootID and Ready required before verification):
the stable native name and all three PF roles survived; mock binding became
active at 7.18 seconds, before kubelet at 70.45 seconds. With native igbvf
explicitly loaded, a focused switchdev run selected worker1 through
`NODES_SELECTOR=kubernetes.io/hostname=virtual-worker-1.virtual.lab` and passed:
exit 0, one executed test, bidirectional 5/5 ping, increasing IPv4 engine hits,
both TC representors in_hw, and OVS offloaded IPv4 packet counters 73/73.
The other 63 specs were excluded by this focused run, not capability skips.

Final read-only verification passed on both workers: Ready/schedulable nodes,
Succeeded/current-generation clean NodeStates, native management and secondary
drivers retained, mock PF legacy/zero VFs/empty flows, and no test policies,
pools, OVS networks or pods. Injector/webhook stayed enabled and the bridge
feature gate was restored. See `artifacts/three-nic-20261006/final-*.json`,
`worker*-final-verified.txt`, and `switchdev-worker1.log`.

## 2026-10-06: shared switchdev conformance flow

Implemented: `FindSwitchdevDevicesAndNode` reuses the shared unused-device
check before filtering `mlx5_core`, `ice` and `mock_smartnic_pf`. Default routes
in both IP families and OVS ports are excluded. Regular conformance keeps its
native device filter; switchdev respects the discovered node selector. The
test now requests exactly **five VFs**, with no advertised-capacity check, and
uses the same pool/policy/managed-bridge/two-pod flow for all supported drivers.
Mock conditionals and debugfs reads were removed from this operator test;
allocated PCI VFs map to real devlink representors, and standard TC/OVS counters
are matched to the selected VF pair's MACs and redirect ports.

The focused run also exposed first-time native igbvf registration claiming
temporarily unbound mock VFs. Persistence/boot now preloads igbvf with zero mock
VFs after mock registration; initial native-user refusal and boot MAC/usage
guards remain. Both owned worker boot scripts were updated. The runner rejects
installers missing either softdep or native preload. No kernel C sources or
operator production Go sources changed in this follow-up. Module SHA256 remains
c03d917f27938821ec9fc806531563150a826ebf4c974b9d1d61000dea972ae1 on kernel
5.14.0-427.el9.x86_64; worker guest script SHA256 is
4ea722fa8ffe1ecf76b4f3880685d36584466e74c473707ac792e618eb5f8140.

Runtime passed: final focused switchdev command exit 0, **1 passed / 0 failed**,
158.783 seconds; the other 63 specs were excluded by focus. Worker1 had five
mock VFs alongside live native igbvf, two Running/Ready pods, bidirectional
5/5 ping, OVS IPv4 packet counts increasing 0→4 and 4→9, and matching TC in_hw
redirect hardware counters 32/46. No full-suite rerun was requested or performed.
Both workers subsequently passed exact-PF/primary/native binding verification,
legacy/zero-VF/empty-flow cleanup, Ready/schedulable and current-generation
NodeState checks. Injector/webhook remained enabled; the bridge gate was restored.

Local passed: `go test ./test/util/cluster ./test/util/network` (10 checks),
`make lint` (zero issues), runner syntax/Python checks (five checks), and
`./scripts/ci.sh local` (20 checks, one optional PyYAML skip), all exit 0.
An existing network utility error-message argument order was corrected to make
its existing regression pass. The initial eight-VF and native-autoload attempts
were interrupted by the agent after diagnosis and are retained as failures;
the final five-VF result supersedes them. A cold-load check's `modprobe -r igbvf`
also removed its mock soft dependency; the owned zero-VF binding was restored
and the cold native registration path verified before the final run.

Exact commands, source pins and artifacts: `artifacts/shared-switchdev-20261006/RUN.md`.
Not tested yet: the unchanged shared flow on real OpenShift/Mellanox hardware,
a new reboot with the preload change, or GitHub Actions. Publish the updated
mock installer and pin its new SHA before using a fresh public clone.

## 2026-10-06 — Running-kernel builds without a fixed release

At the user's request, the in-progress fresh-cluster deployment was stopped
(exit 143) before mock setup/operator deployment. No suite result is claimed
for that interrupted attempt. Setup now defaults to `uname -r`, installs matching
headers and checks the build tree's release. The optional `--kernel` assertion
is retained for existing callers; the operator runner no longer supplies or
requires a kernel pin. Workers clone `main`, log its SHA, and no longer inspect
installer text with greps. `DEV_MODE=TRUE` remains enabled.

Implemented portability changes: detect the target headers' `netns_immutable`
field instead of relying on release numbers, retain the old NETNS_LOCAL and
netns_local forms, and use a storage-sized MAC address buffer for old/new
dev_set_mac_address argument types. VF-index validation removes newer GCC's
format-truncation warning. Boot checks module vermagic before rebinding;
another kernel still requires a module compiled for that kernel.

Baseline mock source: public main `c323b3a011228eb4c348438de1d9e9dfa2402986`
plus the working changes. Final `driver/netdev.c` SHA256:
`fa696185d02461762b2db9a34cb68274ffcd2c5731963db455dda67239d570da`;
`driver/Makefile`: `4db28e2d58dc82732e77820e5b796f0092fc67c9c60a0355bf357fefc5f6e448`.

Built with `make -C HEADERS M=DRIVER W=1 -j2 modules` in isolated builders:

| Target headers | Build | Runtime |
| --- | --- | --- |
| CentOS Stream 9 `5.14.0-754.el9.x86_64` | exit 0 via setup-worker.sh | passed below |
| CentOS Stream 10 `6.12.0-273.el10.x86_64` | exit 0 | not tested |
| Fedora 44 `7.2.8-200.fc44.x86_64` | exit 0 | not tested |

The two container builds skip BTF because vmlinux is absent; Fedora also reports
the missing builder pahole version. No C compiler warnings remain. Initial
compile failures exposed the netns-field and MAC-argument API changes and are
superseded by the final successful builds.

Runtime on the explicitly authorized virtual-worker-0: installed the current
signed CentOS kernel/devel packages and rebooted to `5.14.0-754.el9.x86_64`.
Ran `sudo --preserve-env=SSH_CONNECTION ./scripts/setup-worker.sh
--pf 0000:2a:00.0 --emulated-pf`, exit 0, with no kernel argument. The management
PF `0000:15:00.0` and native secondary `0000:29:00.0` remain igb/zero VFs; only
the XML/MAC-attested third PF uses mock_smartnic_pf. Final module SHA256:
`cd452983cf2f40962e74d40babf3037c4e626fb5c9e1ae85259425a7ba7c6d60`.

All exit 0: `tests/integration/pci-lifecycle.sh`,
`tests/integration/devlink-lifecycle.sh`, `scripts/lab.sh vfs`,
`tests/integration/vf-netlink.sh`, `tests/integration/flower-engine.sh`,
`scripts/lab.sh tc-smoke`, `tests/integration/ovs-offload.sh`,
`scripts/lab.sh reset`, and `tests/integration/reboot.sh`. Tests prove actual
VF lifetimes/default rebind, namespace return, MAC updates, TC rejection/stats,
OVS in_hw execution/traffic and isolation after rule removal. A helper initially
built against the operator's older netlink dependency failed its VF-info
assertion; rebuilding that helper in the documented ovs-cni checkout fixed it.

Reboot changed ID, retained the kernel-matched mock module and native igbvf,
returned legacy/zero-VF/empty-flow state, started binding before kubelet,
and returned the node Ready/schedulable. `scripts/ci.sh local`: exit 0,
22 checks with one optional PyYAML skip. Operator runner Python safety checks:
exit 0, five checks; shell syntax and git diff checks: exit 0.

Artifacts/commands: `artifacts/main-cluster-e2e-20261006/`. Full fresh-cluster
conformance is pending publication of these changes to main and redeployment;
no general-kernel full-suite pass or runtime pass on 6.12/7.2 is claimed yet.

## 2026-10-06 — Fresh main-branch cluster: full conformance passed

The user published the running-kernel changes as public main
`0e2e1ab6ad592c3591f3442821d3db5d33551718`. The operator virtual-cluster runner
recreated only the authorized `virtual` cluster. Both workers cloned main and ran
`scripts/setup-worker.sh --pf 0000:2a:00.0 --emulated-pf` without a kernel argument.
The cached CentOS Stream 9 image runs `5.14.0-427.el9.x86_64`; matching headers
were used automatically. Module SHA256 on both workers:
`f2937a3be81c9a1d917fd74b9b1863d423795b13ed5f16e3ad0ab70b807a3779`.
Management PF `0000:15:00.0` and native secondary `0000:29:00.0` retained igb;
only the XML/MAC-attested third PF uses mock_smartnic_pf.

The operator retains DEV_MODE=TRUE. Both workers directly pulled
`quay.io/schseba/ovs-cni-plugin:latest`, digest
`sha256:9910316ae01cbfc6219a7fa30ba83913fd25374c15a32d47056958f0505f6f29`,
after the user made the repository public. No local OVS-CNI replacement was used.
Kubernetes is 1.34.2, CRI-O 1.34.15, OVS 3.5.3. Operator base is
`2716a0d4c9894428fa0cdeb233dd61a8f734315e` plus the recorded working changes;
runner SHA256 is `72793c692d9bc3faaeaa9f9c09d3d60674fe4a73e5823846fdd13fcde91cfc81`.
Deployment validation: exit 0, six checks passed.

Actual full-suite command from the ARM64 controller's operator checkout:

```sh
OPERATOR_NAMESPACE=sriov-network-operator \
KUBECONFIG=/home/vscode/kubeconfig/virt-cluster-k8s \
GOARCH=arm64 GOOS=linux CLUSTER_TYPE=kubernetes \
CLUSTER_HAS_EMULATED_PF=TRUE \
SRIOV_NODE_AND_DEVICE_NAME_FILTER='^.*:sriovtest0$' \
JUNIT_OUTPUT=/workspaces/k8snetworkplumbingwg/switchdev-mock-driver/artifacts/main-cluster-e2e-20261006/full-conformance \
SUITE=./test/conformance hack/run-e2e-conformance.sh
```

Runtime passed: exit 0, **47 passed / 0 failed / 17 skipped**, all 64 specs
selected, no focus filter. Seed 1791315682; 2026-10-06 19:41:21–20:22:29 UTC,
2465.505 seconds of suite execution. JUnit also contains the two suite hooks.
Skips are existing platform/hardware/Prometheus requirements, igb limitations,
and absence of a gateway PF in the native-only selection; none skips switchdev.

The shared switchdev spec passed in 263.365 seconds on virtual-worker-0:
five real PCI VFs, operator-managed bridge br-0000_2a_00.0, two Running/Ready
OVS-CNI pods, and 5/5 ping in both directions. Allocated PCI VFs
0000:2a:10.2 and 0000:2a:10.4 mapped to representors msnicp0_1 and msnicp0_2.
OVS IPv4 counters increased 0→4 and 4→9; matching TC in_hw redirects reported
31 and 44 hardware packets. Native IPv6 traffic, VF allocation/release,
MTU reconciliation, reboot recovery and RDMA-mode reboot transitions also passed.

Cleanup passed: both workers Ready/schedulable, current-generation Ready NodeState
conditions with syncStatus=Succeeded, empty desired interfaces/bridges, legacy
mode, zero VFs, empty mock flow tables and no OVS bridges. Test policies, pools,
networks, NADs and pods are gone. Injector/webhook remain enabled and the bridge
gate is restored. Worker0's boot binding preceded kubelet; primary/native bindings
on both workers remain igb. No hypervisor password or unrelated VM was changed.

Artifacts: `artifacts/main-cluster-e2e-20261006/RUN.md`, full log and JUnit,
switchdev log/TC dumps/two-Ready-pod snapshot, source and image digests, and
final cleanup snapshots. Provisioning retries and orchestration errors are
recorded separately in RUN.md; they are not reported as passing runs.

Final documentation checks: `scripts/ci.sh local`, exit 0 (22 tests, one optional
PyYAML skip); `git diff --check`, exit 0 in both repositories. No driver or
installer code changed after the published main revision tested above.

Not tested: mock module runtime on 6.12/7.2 or GitHub Actions. The shared test
passed on real OpenShift/Mellanox devices below. The full virtual suite above supersedes the earlier pending
publication/redeployment checkpoint.


## OpenShift Mellanox focused test: passed (2026-10-07)

Implemented in the operator tests: derive hardware-offload pool name from the
selected node's rendered MachineConfig owner; omit the named pool's nodeSelector
as required by admission; check effective host OVS settings on both platforms;
remove the syncStatus-only readiness workaround. Feature-gate restoration now
has independent cleanup. Local unit checks, compilation and lint exit 0.

Runtime attempted on cnfdc10, OpenShift 5.0.0-rc.1/Kubernetes v1.36.3, RHCOS 10.2,
worker kernel 6.12.0-211.51.1.el10_2.x86_64, real mlx5_core (15b3:101f/101d).
No mock module was installed on physical hardware. First attempt failed admission
because Name and nodeSelector cannot coexist. Second attempt created
00-worker-cnf-ovs-hw-offload for worker-cnf, then its VM worker rebooted and
remained NotReady. Interrupted safely before the baremetal hardware rollout;
no pod traffic or offload pass is claimed.

Confirmed with an isolated OVS database: a service pre-start database write
without --no-wait waits for the not-yet-started ovs-vswitchd and exits 142;
with --no-wait it exits 0. Fixed this command in the operator service template.
User recovered the VM and removed it from worker-cnf. The requested rrun build
and push completed for operator, config daemon and webhook; running imageIDs
match the published manifests. The updated pre-start unit passed the next
baremetal reboot and all pools returned healthy.

Attempt 3 finished 08:04:39 UTC, exit 1 (0 passed, 1 failed, 63 focus-excluded).
Five genuine VFs/representors and two Ready OVS-CNI pods were configured on
0000:01:00.0 (15b3:101f), but the first VF pair failed ARP/ping with 100% loss.
No target-pair hardware offload pass is claimed. Kernel and CNI setup succeeded;
Attempt 4 reproduced the failure (exit 1, 0 passed, 1 failed, 63 focus-excluded),
with live counters confirming VF TX but zero representor software RX/OpenFlow
hits. Firmware health was reported healthy. Cleanup completed and all MCPs
returned Updated/nondegraded. Through the user-supplied bastion, previous boot
logs also show temporary API DNS lookup failures delaying kubelet recovery.

User requested the unused NIC with link up. Shared discovery now requires carrier
for switchdev traffic while preserving legacy tests' selection. Unit checks,
conformance compilation and lint pass. Attempt 5 passed the same five-VF traffic
flow on linked eno16705np1 / 0001:3f:00.1 / 15b3:101d, with no driver-specific
branch or skip. The pool name was derived as worker-cnf.

Exact command and environment: `attempt5/run-focused-switchdev.sh` in the artifact
directory below. Started 08:40:53 UTC, finished 09:06:49 UTC, seed 1791362453,
exit 0. Ginkgo: 1 passed, 0 failed, 63 focus-excluded, 1554.316 seconds.
Five operator-created PCI VFs, two Ready OVS-CNI pods, and 5/5 ping in both
directions. Selected IPv4 OVS type=offloaded counters increased 0→4 and 4→9;
matching kernel TC redirects reported in_hw=true and 21/31 hardware packets.
Both configuration/firmware reboots completed within the original readiness
deadline. The published operator, daemon and webhook images remain deployed.

Final cleanup passed: no test CRs/pods/NADs or generated MachineConfig;
original worker-cnf rendered config and bridge gate restored. All nodes are
Ready/schedulable, all MachineConfigPools Updated/nondegraded, and NodeState
Ready conditions match the current generation with syncStatus=Succeeded.
All PFs have zero VFs; the selected PF is back in legacy mode. Only existing
br-ex/br-int remain; primary eno16695np0 still uses mlx5_core on br-ex and the
original default route is preserved. Existing hw-offload=true remains enabled.
Logs, commands, JUnit, source patch and cleanup snapshots:
`artifacts/openshift-switchdev-cnfdc10-20261007/RUN.md`.

## 2026-10-07 — K09 mock uplink readiness after boot

Implemented in scripts/guest.sh: persistent binding brings up the one uplink
under the exact selected PCI PF, including the already-bound probe path. Without
this, the PF stays administratively DOWN after reboot and carrier-based shared
switchdev discovery excludes it. No module or conformance test code changed.
README documents the setup state; the reboot integration checks operstate=up.

Local checks: scripts/ci.sh local, exit 0, 23 tests (one existing optional PyYAML
skip); bash syntax and git diff --check, exit 0. A runnable check rejects zero
or multiple uplinks and brings up only the selected PF uplink.
Runtime: installed the guarded boot script on both XML-attested virtual workers,
module main 0e2e1ab, running kernel 5.14.0-427.el9.x86_64. Both PFs report
UP/LOWER_UP, zero mock VFs; native management/test PF drivers remain igb and
default routes are unchanged. Exact commands, hashes and outputs:
artifacts/parallel-full-conformance-20261007/update-worker-boot.py and
kubernetes/worker-*-boot-update.log. This check did not validate a fresh install
or the new script across reboot; those remain pending. The user requested
publication to main, a fresh virtual cluster and full conformance afterward.
The real OpenShift full suite continues independently with identical test code.
