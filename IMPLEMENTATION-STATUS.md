# Implementation status

## Package delivery

- Architecture and work packages: specified.
- VM and Kubernetes harness: implemented and replayed against the configured lab.
- Local checks: 17 tests, one optional PyYAML skip; VALIDATION-REPORT.md is historical.
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
| K09 resilience and CI | yes | checks pass | yes | 50 pod cycles, allocation recovery, kernel stress/reload/reboot; local/VM/Kubernetes CI passed; optional OpenShift/debug/signing untested |

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
explicit failures. Basic Ethernet ARP forwarding is supported. OpenShift/MCO,
enforced signing, other kernels, KASAN/lockdep and online GitHub execution remain
NOT TESTED. Their absence does not count as a runtime pass.

README.md provides the demo entry point, CR-to-device-plugin flow and cleanup
links. docs/05 gives the 50-cycle/failure/stress/CI replay and ordered cleanup.
The final operator-managed pair is intentionally left available for inspection.
