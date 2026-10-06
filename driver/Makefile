# SPDX-License-Identifier: GPL-2.0-only
obj-m += mock_smartnic.o
mock_smartnic-y := main.o pci_pf.o pci_vf.o netdev.o devlink.o eswitch.o tc.o

# Distro backports can change this field without changing the base kernel version.
ccflags-y += $(shell grep -qw netns_immutable $(srctree)/include/linux/netdevice.h && echo -DMSNIC_HAVE_NETNS_IMMUTABLE)
