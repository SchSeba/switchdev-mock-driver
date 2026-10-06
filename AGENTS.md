# Working on the switchdev mock driver

Read README.md, docs/01-architecture.md and driver/LOCKING.md before changing the
driver. IMPLEMENTATION-STATUS.md records the completed K00–K09 implementation and
actual runtime results; dated commands describe the historical run.

Keep one GPL-compatible module, mock_smartnic.ko, with PCI drivers
mock_smartnic_pf and mock_smartnic_vf. Use only a dedicated XML-attested QEMU igb
PF and its real PCI VFs. Never fabricate sysfs, manually set TC in_hw bookkeeping,
impersonate another vendor, or substitute VFIO/DPDK for kernel netdev tests.

Only use the explicitly configured VM/cluster in config/lab.env. Begin with
read-only preflight. Exact PF BDF and nonempty mutation acknowledgements are
mandatory. Never choose the first NIC or use vendor-wide binding. Preserve the
primary interface and SSH host-key verification. Never print or commit credentials.
Do not change security settings or bypass signing/immutable-host prerequisites.

Preserve VF/representor lifetime independence, namespace-safe references and
teardown, representor ingress = VF TX, and redirect-to-representor = peer VF RX.
TC misses use the representor slow path. Reject unsupported matches/actions/flags
with extack; keep no callback-owned flow_rule pointers. Use the running kernel's
actual APIs and matching headers; no fixed kernel release is required.

Reuse the existing scripts. setup-worker.sh installs OVS/builds/binds/persists the
selected test PF and leaves zero VFs. The operator/CNI own final VFs, bridge, NAD,
representor ports and NodeState status. Do not create or edit those for them.
Clean up only owned resources; every readiness check needs a deadline.

Run scripts/ci.sh local after script/docs changes and the relevant actual VM tests
for driver/binding changes. Record commands, exit status, kernel/source versions
and artifacts in IMPLEMENTATION-STATUS.md. Distinguish implemented, built, runtime
passed, not tested and blocked. Never claim runtime success from syntax checks.
