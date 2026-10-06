/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef MOCK_SMARTNIC_H
#define MOCK_SMARTNIC_H

#include <linux/etherdevice.h>
#include <linux/mutex.h>
#include <linux/kref.h>
#include <linux/pci.h>
#include <linux/rtnetlink.h>
#include <net/devlink.h>
#include <net/flow_offload.h>

#define MSNIC_MAX_VFS 7

enum msnic_state { MSNIC_READY, MSNIC_ENABLING, MSNIC_QUIESCING, MSNIC_REMOVING };

struct msnic_port {
	struct net_device __rcu *endpoint;
	struct net_device __rcu *representor;
	struct devlink_port dl_port;
	u8 mac[ETH_ALEN];
	spinlock_t policy_lock;
	bool spoofchk;
	int link_state;
};

struct msnic_pf {
	struct kref ref;
	struct dentry *debug_dir;
	struct pci_dev *pdev;
	struct net_device *uplink;
	struct devlink *devlink;
	struct devlink_port uplink_port;
	u16 mode;
	struct mutex config_lock;
	enum msnic_state state;
	unsigned int num_vfs;
	struct msnic_port ports[MSNIC_MAX_VFS];
	atomic64_t slowpath_packets, uplink_sink_packets, spoof_drops;
	atomic64_t offload_hits, offload_misses, redirect_packets, drop_packets;
	spinlock_t flow_lock;
	struct list_head flows;
	unsigned int active_flows;
};

struct msnic_net {
	struct msnic_pf *pf;
	struct pci_dev *pdev;
	int vf; /* -1 is the isolated uplink. */
	bool representor;
	struct list_head block_cb_list;
	struct flow_block *block;
	atomic64_t tx_packets, tx_bytes, tx_dropped;
	atomic64_t rx_packets, rx_bytes, rx_dropped;
};

extern char *target_pf;
extern struct pci_driver msnic_pf_driver;
extern struct pci_driver msnic_vf_driver;
extern const struct devlink_ops msnic_devlink_ops;

struct net_device *msnic_alloc_netdev(struct msnic_pf *pf, struct pci_dev *pdev,
				    int vf, bool representor);
int msnic_devlink_init(struct msnic_pf *pf);
void msnic_devlink_fini(struct msnic_pf *pf);
int msnic_reps_create(struct msnic_pf *pf);
void msnic_reps_destroy(struct msnic_pf *pf);
netdev_tx_t msnic_xmit(struct sk_buff *skb, struct net_device *dev);
bool msnic_deliver_endpoint(struct sk_buff *skb, struct net_device *dest,
			    struct msnic_net *source);
int msnic_setup_tc(struct net_device *dev, enum tc_setup_type type, void *data);
int msnic_set_features(struct net_device *dev, netdev_features_t features);
bool msnic_tc_execute(struct sk_buff *skb, struct msnic_net *source,
		      struct net_device *rep);
void msnic_flows_flush(struct msnic_pf *pf, int ingress_vf);
int msnic_debug_init(struct msnic_pf *pf);
void msnic_debug_fini(struct msnic_pf *pf);
void msnic_pf_put(struct msnic_pf *pf);
extern struct dentry *msnic_debug_root;

#endif
