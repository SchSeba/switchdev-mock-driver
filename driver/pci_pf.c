// SPDX-License-Identifier: GPL-2.0-only
#include "mock_smartnic.h"

static void msnic_pf_release(struct kref *ref)
{
	struct msnic_pf *pf = container_of(ref, struct msnic_pf, ref);
	struct pci_dev *pdev = pf->pdev;

	devlink_free(pf->devlink);
	pci_dev_put(pdev);
}

void msnic_pf_put(struct msnic_pf *pf)
{
	kref_put(&pf->ref, msnic_pf_release);
}

static int msnic_pf_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct msnic_pf *pf;
	struct devlink *devlink;
	int err, i;

	if (strcmp(pci_name(pdev), target_pf) || pdev->is_virtfn ||
	    pdev->vendor != PCI_VENDOR_ID_INTEL || pdev->device != 0x10c9 ||
	    (pdev->class >> 8) != PCI_CLASS_NETWORK_ETHERNET ||
	    !pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_SRIOV))
		return -ENODEV;
	err = pci_enable_device(pdev);
	if (err)
		return err;
	/* No BAR access, bus mastering, DMA, native registers or firmware. */
	devlink = devlink_alloc(&msnic_devlink_ops, sizeof(*pf), &pdev->dev);
	if (!devlink) {
		err = -ENOMEM;
		goto disable;
	}
	pf = devlink_priv(devlink);
	pf->devlink = devlink;
	pf->pdev = pci_dev_get(pdev);
	kref_init(&pf->ref);
	spin_lock_init(&pf->flow_lock);
	INIT_LIST_HEAD(&pf->flows);
	pf->state = MSNIC_READY;
	pf->mode = DEVLINK_ESWITCH_MODE_LEGACY;
	mutex_init(&pf->config_lock);
	pf->uplink = msnic_alloc_netdev(pf, pdev, -1, false);
	if (!pf->uplink) {
		err = -ENOMEM;
		goto free_pf;
	}
	for (i = 0; i < MSNIC_MAX_VFS; i++) {
		spin_lock_init(&pf->ports[i].policy_lock);
		ether_addr_copy(pf->ports[i].mac, pf->uplink->dev_addr);
		pf->ports[i].mac[1] = 0x76;
		pf->ports[i].mac[5] ^= i + 1;
	}
	pci_set_drvdata(pdev, pf);
	err = msnic_devlink_init(pf);
	if (err)
		goto free_netdev;
	err = register_netdev(pf->uplink);
	if (err)
		goto fini_devlink;
	err = msnic_debug_init(pf);
	if (err) {
		unregister_netdev(pf->uplink);
		goto fini_devlink;
	}
	dev_info(&pdev->dev, "mock PCI carrier ready; uplink has no external wire\n");
	return 0;

fini_devlink:
	msnic_devlink_fini(pf);
free_netdev:
	pci_set_drvdata(pdev, NULL);
	free_netdev(pf->uplink);
free_pf:
	msnic_pf_put(pf);
disable:
	pci_disable_device(pdev);
	return err;
}

static int msnic_sriov_configure(struct pci_dev *pdev, int count)
{
	struct msnic_pf *pf = pci_get_drvdata(pdev);
	int err = 0;

	devl_lock(pf->devlink);
	mutex_lock(&pf->config_lock);
	if (pf->state != MSNIC_READY) {
		err = -EBUSY;
		goto unlock;
	}
	if (count < 0 || count > MSNIC_MAX_VFS || count > pci_sriov_get_totalvfs(pdev)) {
		err = -EINVAL;
		goto unlock;
	}
	if (count && pf->num_vfs) {
		err = count == pf->num_vfs ? count : -EBUSY;
		goto unlock;
	}
	if (!count && pci_vfs_assigned(pdev)) {
		err = -EBUSY;
		goto unlock;
	}
	WRITE_ONCE(pf->state, count ? MSNIC_ENABLING : MSNIC_QUIESCING);
	if (!count)
		msnic_reps_destroy(pf);
	mutex_unlock(&pf->config_lock);
	devl_unlock(pf->devlink);
	/* PCI core may synchronously call VF probe/remove. No config_lock or RTNL. */
	if (count)
		err = pci_enable_sriov(pdev, count);
	else
		pci_disable_sriov(pdev);
	devl_lock(pf->devlink);
	mutex_lock(&pf->config_lock);
	if (!err) {
		pf->num_vfs = count;
		if (count && pf->mode == DEVLINK_ESWITCH_MODE_SWITCHDEV)
			err = msnic_reps_create(pf);
	}
	if (err && count && pci_num_vf(pdev)) {
		/* Roll back real VFs as well as ports after a representor failure. */
		mutex_unlock(&pf->config_lock);
		devl_unlock(pf->devlink);
		pci_disable_sriov(pdev);
		devl_lock(pf->devlink);
		mutex_lock(&pf->config_lock);
		pf->num_vfs = 0;
	}
	WRITE_ONCE(pf->state, MSNIC_READY);
	if (!err)
		err = count;
unlock:
	mutex_unlock(&pf->config_lock);
	devl_unlock(pf->devlink);
	return err;
}

static void msnic_pf_remove(struct pci_dev *pdev)
{
	struct msnic_pf *pf = pci_get_drvdata(pdev);

	mutex_lock(&pf->config_lock);
	WRITE_ONCE(pf->state, MSNIC_REMOVING);
	mutex_unlock(&pf->config_lock);
	msnic_debug_fini(pf);
	msnic_flows_flush(pf, -1);
	/* All child remove callbacks finish before PF private state is freed. */
	pci_disable_sriov(pdev);
	unregister_netdev(pf->uplink);
	msnic_devlink_fini(pf);
	free_netdev(pf->uplink);
	pci_set_drvdata(pdev, NULL);
	pci_disable_device(pdev);
	msnic_pf_put(pf);
}

static const struct pci_device_id msnic_pf_ids[] = {
	{ PCI_DEVICE(PCI_VENDOR_ID_INTEL, 0x10c9) },
	{ }
};

/* No MODULE_DEVICE_TABLE: loading is deliberate and requires exact parameters. */
struct pci_driver msnic_pf_driver = {
	.name = "mock_smartnic_pf",
	.id_table = msnic_pf_ids,
	.probe = msnic_pf_probe,
	.remove = msnic_pf_remove,
	.sriov_configure = msnic_sriov_configure,
};
