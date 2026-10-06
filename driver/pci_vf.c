// SPDX-License-Identifier: GPL-2.0-only
#include "mock_smartnic.h"

static int msnic_vf_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct msnic_pf *pf;
	struct net_device *dev;
	int vf, err;

	if (!pdev->is_virtfn || strcmp(pci_name(pci_physfn(pdev)), target_pf) ||
	    pdev->vendor != PCI_VENDOR_ID_INTEL || pdev->device != 0x10ca)
		return -ENODEV;
	/* PCI-core association is valid until this VF's remove callback finishes. */
	pf = pci_iov_get_pf_drvdata(pdev, &msnic_pf_driver);
	if (IS_ERR(pf))
		return PTR_ERR(pf);
	vf = pci_iov_vf_id(pdev);
	if (vf < 0 || vf >= MSNIC_MAX_VFS)
		return -EINVAL;
	err = pci_enable_device(pdev);
	if (err)
		return err;
	rtnl_lock();
	dev = msnic_alloc_netdev(pf, pdev, vf, false);
	if (!dev) {
		err = -ENOMEM;
		goto disable;
	}
	err = register_netdevice(dev);
	if (err)
		goto free_dev;
	pci_set_drvdata(pdev, dev);
	rcu_assign_pointer(pf->ports[vf].endpoint, dev);
	rtnl_unlock();
	return 0;

free_dev:
	free_netdev(dev);
disable:
	rtnl_unlock();
	pci_disable_device(pdev);
	return err;
}

static void msnic_vf_remove(struct pci_dev *pdev)
{
	struct net_device *dev = pci_get_drvdata(pdev);
	struct msnic_net *priv = netdev_priv(dev);
	struct msnic_pf *pf = priv->pf;

	rtnl_lock();
	RCU_INIT_POINTER(pf->ports[priv->vf].endpoint, NULL);
	rtnl_unlock();
	synchronize_net();
	unregister_netdev(dev);
	free_netdev(dev);
	pci_set_drvdata(pdev, NULL);
	pci_disable_device(pdev);
}

static const struct pci_device_id msnic_vf_ids[] = {
	{ PCI_DEVICE(PCI_VENDOR_ID_INTEL, 0x10ca) },
	{ }
};

struct pci_driver msnic_vf_driver = {
	.name = "mock_smartnic_vf",
	.id_table = msnic_vf_ids,
	.probe = msnic_vf_probe,
	.remove = msnic_vf_remove,
};
