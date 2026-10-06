// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/debugfs.h>
#include "mock_smartnic.h"

char *target_pf;
struct dentry *msnic_debug_root;
static bool allow_igb_emulation;
module_param(target_pf, charp, 0444);
MODULE_PARM_DESC(target_pf, "Mandatory full lower-case PCI BDF of the dedicated emulated igb PF");
module_param(allow_igb_emulation, bool, 0444);
MODULE_PARM_DESC(allow_igb_emulation, "Explicit lab opt-in; hypervisor attestation is also required");

static int __init msnic_init(void)
{
	unsigned int domain, bus, slot, function;
	char canonical[13];
	int err;

	if (!allow_igb_emulation || !target_pf || strlen(target_pf) != 12 ||
	    sscanf(target_pf, "%4x:%2x:%2x.%1x", &domain, &bus, &slot, &function) != 4 ||
	    domain > 0xffff || bus > 0xff || slot > 0x1f || function > 7)
		return -EINVAL;
	snprintf(canonical, sizeof(canonical), "%04x:%02x:%02x.%x",
		 domain, bus, slot, function);
	if (strcmp(target_pf, canonical))
		return -EINVAL;
	msnic_debug_root = debugfs_create_dir("mock_smartnic", NULL);
	if (IS_ERR(msnic_debug_root))
		return PTR_ERR(msnic_debug_root);
	err = pci_register_driver(&msnic_vf_driver);
	if (err)
		goto remove_debug;
	err = pci_register_driver(&msnic_pf_driver);
	if (err) {
		pci_unregister_driver(&msnic_vf_driver);
		goto remove_debug;
	}
	return err;
remove_debug:
	debugfs_remove_recursive(msnic_debug_root);
	return err;
}

static void __exit msnic_exit(void)
{
	pci_unregister_driver(&msnic_pf_driver);
	pci_unregister_driver(&msnic_vf_driver);
	rcu_barrier();
	debugfs_remove_recursive(msnic_debug_root);
}

module_init(msnic_init);
module_exit(msnic_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Dedicated QEMU igb PCI carrier with a guest software switch engine");
MODULE_VERSION("0.1");
