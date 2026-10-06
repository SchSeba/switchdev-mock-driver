# Worker development

[README.md](../README.md) covers the minimal clone-and-install workflow. The
controller-side development harness lets you build and iterate without recloning.

Copy `config/lab.env.example` to the ignored `config/lab.env`. Set `SSH_TARGET`
using a verified host alias (ProxyJump is supported), `PF_BDF` from hypervisor XML
and the matching MAC, and the explicitly authorized cluster context/node. Use
`StrictHostKeyChecking yes` and a separate management interface. Inspect console
and snapshot recovery before permitting persistent changes/reboots.

```bash
./scripts/lab.sh preflight
./scripts/lab.sh build
```

Build transfers handwritten sources, cleans old outputs and runs `W=1` against
`/lib/modules/$(uname -r)/build`. The target is the running guest kernel, not the
controller kernel. A failed build must never lead to loading an older binary.

To install from scratch, prefer `setup-worker.sh` in README: it also owns the
scoped NetworkManager rules and starts OVS. For manual development, prepare those
prerequisites first, then set `EMULATED_PF_ACK` to the exact BDF and
`EXCLUSIVE_PF_ACK=YES` only after confirming exclusive ownership:

```bash
./scripts/lab.sh bind
./tests/integration/pci-lifecycle.sh
./tests/integration/devlink-lifecycle.sh
./scripts/lab.sh vfs
./tests/integration/flower-engine.sh
./scripts/lab.sh tc-smoke
./tests/integration/ovs-offload.sh
./scripts/lab.sh reset
```

Manual tests deliberately create their own VFs; reset leaves zero VFs, legacy
mode, autoprobe enabled. Never run them while the operator owns allocations.
Representor rules act on VF TX; no-rule traffic must pass through the slow path.

Before operator use, set `PERSISTENCE_ACK=YES`, run `lab.sh persist`, and exercise
an authorized reboot with bounded SSH/node readiness checks and console recovery.
The binding unit runs before kubelet/OVS and checks the module's vermagic against
the running kernel before touching the PF. No fixed release is required, but
kernel upgrades need a new build and installation for that release.

For cleanup after all owners release the PF:

```bash
./scripts/lab.sh reset
./scripts/lab.sh unpersist
./scripts/lab.sh restore
```

The old manual harness does not own/remove separately created NetworkManager
files. `setup-worker.sh --restore` additionally removes its own unchanged scoped
file. A partial bind leaves original state for recovery. Diagnose through console
and saved state rather than rebinding a used interface or deleting live resources.
