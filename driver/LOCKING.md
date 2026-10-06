# PCI-carrier locking and ownership (K01/K02)

The PCI core holds the PF device lock around sriov_configure and PF removal.
The order is PF device lock -> devlink instance lock -> config_lock -> RTNL.
Devlink mode callbacks already hold the instance lock and use devl port APIs.
Release the instance lock and config_lock before calling
pci_enable_sriov/pci_disable_sriov: these calls take child device locks and invoke
VF probe/remove, which take RTNL around endpoint publication/unpublication.
Never acquire a PF device lock in a child callback.

pci_iov_get_pf_drvdata supplies the PF association for the lifetime of a bound
VF. PF removal calls pci_disable_sriov, which waits for child removal before
freeing PF state. Unpublishing an endpoint precedes synchronize_net and netdev
unregistration. Endpoint namespace moves do not change the endpoint pointer.
VF netlink setters hold RTNL and never acquire config_lock. The port policy
spinlock protects admin MAC copies; no sleeping operation takes that spinlock.

No mutex is taken in ndo_start_xmit. Uplink TX is an explicit sink. VF TX enters
the representor ingress engine in switchdev; a TC miss reaches representor RX.
Representor TX reaches the corresponding VF endpoint. Legacy VF TX is dropped.

K05 TC callbacks use the native flow-block helper with locked callbacks: TC core
holds RTNL. They never take devlink/config_lock. Binding holds the ingress device
until unbind. Flow identity is that private ingress block, VF index, chain zero
and TC cookie. Output references belong to immutable RCU rules. Flow publication
and deletion take flow_lock; packet lookup takes only RCU and per-counter spinlock.
Stats polls take flow_lock then counter lock; packet execution never reverses that
order. Same-cookie replacement shares refcounted counters; this kernel's ordinary
flower replacement instead creates a new cookie, which gets a new counter lifetime.

Topology writers set QUIESCING/REMOVING before flushing *all* switch flows, and
rule publication checks state again under flow_lock. This prevents late publication
of an output reference while unregister waits on that representor. Flushing before
removing any representor avoids cross-port reference cycles. Deferred rule callbacks
release output and counter references; module exit waits via rcu_barrier.

Debugfs safe proxy protects open against removal. Each open holds the PF kref and
module owner reference. PF unbind removes debugfs before teardown; an already-open
file cannot access freed PF state. Final close frees the unregistered devlink private
allocation and its PCI reference. Stats output never dereferences removed netdevs.

PF HW_TC is the shared switch-programming gate used by the pinned operator.
Representor rule publication requires both PF and representor HW_TC enabled.
Turning the PF gate off with any active switch rule fails with EBUSY. The PF has
no external RX engine, so its own ingress flow block is explicitly rejected;
only representor ingress can acknowledge and execute TC offloads.
