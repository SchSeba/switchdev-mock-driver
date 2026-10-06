// SPDX-License-Identifier: GPL-2.0-only
#include "mock_smartnic.h"

/* Topology changes hold devlink -> config_lock, then RTNL inside netdev APIs. */
static void msnic_port_attrs(struct msnic_pf *pf, struct devlink_port *port, int vf)
{
	struct devlink_port_attrs attrs = {};

	attrs.switch_id.id_len = ETH_ALEN;
	ether_addr_copy(attrs.switch_id.id, pf->uplink->perm_addr);
	if (vf < 0) {
		attrs.flavour = DEVLINK_PORT_FLAVOUR_PHYSICAL;
		attrs.phys.port_number = 0;
	} else {
		attrs.flavour = DEVLINK_PORT_FLAVOUR_PCI_VF;
		attrs.pci_vf.pf = 0;
		attrs.pci_vf.vf = vf;
	}
	devlink_port_attrs_set(port, &attrs);
}

void msnic_reps_destroy(struct msnic_pf *pf)
{
	int i;

	devl_assert_locked(pf->devlink);
	/* Output references must retire before unregister waits on any rep. */
	msnic_flows_flush(pf, -1);
	for (i = MSNIC_MAX_VFS - 1; i >= 0; i--) {
		struct msnic_port *port = &pf->ports[i];
		struct net_device *rep = rcu_dereference_protected(port->representor,
						lockdep_is_held(&pf->config_lock));

		if (!rep)
			continue;
		RCU_INIT_POINTER(port->representor, NULL);
		synchronize_net();
		unregister_netdev(rep);
		free_netdev(rep);
		devl_port_unregister(&port->dl_port);
	}
}

int msnic_reps_create(struct msnic_pf *pf)
{
	int i, err;

	devl_assert_locked(pf->devlink);
	for (i = 0; i < pf->num_vfs; i++) {
		struct msnic_port *port = &pf->ports[i];
		struct net_device *rep;

		memset(&port->dl_port, 0, sizeof(port->dl_port));
		msnic_port_attrs(pf, &port->dl_port, i);
		err = devl_port_register(pf->devlink, &port->dl_port, i + 1);
		if (err)
			goto rollback;
		rep = msnic_alloc_netdev(pf, pf->pdev, i, true);
		if (!rep) {
			err = -ENOMEM;
			goto unregister_port;
		}
		SET_NETDEV_DEVLINK_PORT(rep, &port->dl_port);
		err = register_netdev(rep);
		if (err) {
			free_netdev(rep);
			goto unregister_port;
		}
		rcu_assign_pointer(port->representor, rep);
	}
	return 0;

unregister_port:
	devl_port_unregister(&pf->ports[i].dl_port);
rollback:
	msnic_reps_destroy(pf);
	return err;
}

static int msnic_mode_get(struct devlink *devlink, u16 *mode)
{
	struct msnic_pf *pf = devlink_priv(devlink);

	*mode = pf->mode;
	return 0;
}

static int msnic_mode_set(struct devlink *devlink, u16 mode,
			  struct netlink_ext_ack *extack)
{
	struct msnic_pf *pf = devlink_priv(devlink);
	int err = 0;

	if (mode != DEVLINK_ESWITCH_MODE_LEGACY && mode != DEVLINK_ESWITCH_MODE_SWITCHDEV) {
		NL_SET_ERR_MSG_MOD(extack, "Only legacy and switchdev modes are implemented");
		return -EOPNOTSUPP;
	}
	mutex_lock(&pf->config_lock);
	if (pf->state != MSNIC_READY) {
		NL_SET_ERR_MSG_MOD(extack, "PCI VF topology is changing");
		err = -EBUSY;
		goto unlock;
	}
	if (mode == pf->mode)
		goto unlock;
	WRITE_ONCE(pf->state, MSNIC_QUIESCING);
	if (mode == DEVLINK_ESWITCH_MODE_SWITCHDEV) {
		err = msnic_reps_create(pf);
		if (err) {
			NL_SET_ERR_MSG_MOD(extack, "Representor allocation failed; previous mode retained");
			WRITE_ONCE(pf->state, MSNIC_READY);
			goto unlock;
		}
	} else {
		msnic_reps_destroy(pf);
	}
	WRITE_ONCE(pf->mode, mode);
	WRITE_ONCE(pf->state, MSNIC_READY);
unlock:
	mutex_unlock(&pf->config_lock);
	return err;
}

const struct devlink_ops msnic_devlink_ops = {
	.eswitch_mode_get = msnic_mode_get,
	.eswitch_mode_set = msnic_mode_set,
};

int msnic_devlink_init(struct msnic_pf *pf)
{
	int err;

	devl_lock(pf->devlink);
	err = devl_register(pf->devlink);
	if (err)
		goto unlock;
	msnic_port_attrs(pf, &pf->uplink_port, -1);
	err = devl_port_register(pf->devlink, &pf->uplink_port, 0);
	if (err)
		devl_unregister(pf->devlink);
	else
		SET_NETDEV_DEVLINK_PORT(pf->uplink, &pf->uplink_port);
unlock:
	devl_unlock(pf->devlink);
	return err;
}

void msnic_devlink_fini(struct msnic_pf *pf)
{
	devl_lock(pf->devlink);
	mutex_lock(&pf->config_lock);
	msnic_reps_destroy(pf);
	mutex_unlock(&pf->config_lock);
	devl_port_unregister(&pf->uplink_port);
	devl_unregister(pf->devlink);
	devl_unlock(pf->devlink);
}
