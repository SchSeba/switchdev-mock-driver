// SPDX-License-Identifier: GPL-2.0-only
#include <linux/ethtool.h>
#include <linux/if_arp.h>
#include "mock_smartnic.h"

static int msnic_open(struct net_device *dev)
{
	struct msnic_net *priv = netdev_priv(dev);

	if (priv->vf < 0 || priv->representor ||
	    READ_ONCE(priv->pf->ports[priv->vf].link_state) != IFLA_VF_LINK_STATE_DISABLE)
		netif_carrier_on(dev);
	netif_start_queue(dev);
	return 0;
}

static int msnic_stop(struct net_device *dev)
{
	netif_stop_queue(dev);
	netif_carrier_off(dev);
	return 0;
}

static void msnic_stats(struct net_device *dev, struct rtnl_link_stats64 *stats)
{
	struct msnic_net *priv = netdev_priv(dev);

	stats->tx_packets = atomic64_read(&priv->tx_packets);
	stats->tx_bytes = atomic64_read(&priv->tx_bytes);
	stats->tx_dropped = atomic64_read(&priv->tx_dropped);
	stats->rx_packets = atomic64_read(&priv->rx_packets);
	stats->rx_bytes = atomic64_read(&priv->rx_bytes);
	stats->rx_dropped = atomic64_read(&priv->rx_dropped);
}

static void msnic_drvinfo(struct net_device *dev, struct ethtool_drvinfo *info)
{
	struct msnic_net *priv = netdev_priv(dev);

	strscpy(info->driver, priv->vf < 0 || priv->representor ? "mock_smartnic_pf" : "mock_smartnic_vf",
		 sizeof(info->driver));
	strscpy(info->version, "0.1", sizeof(info->version));
	strscpy(info->bus_info, pci_name(priv->pdev), sizeof(info->bus_info));
}

static int msnic_link_settings(struct net_device *dev, struct ethtool_link_ksettings *cmd)
{
	cmd->base.speed = SPEED_UNKNOWN;
	cmd->base.duplex = DUPLEX_UNKNOWN;
	cmd->base.autoneg = AUTONEG_DISABLE;
	cmd->base.port = PORT_OTHER;
	return 0;
}

static const struct ethtool_ops msnic_ethtool_ops = {
	.get_drvinfo = msnic_drvinfo,
	.get_link = ethtool_op_get_link,
	.get_link_ksettings = msnic_link_settings,
};

/* VF netlink callbacks already hold RTNL; they never acquire config_lock. */
static struct msnic_port *msnic_vf_port(struct net_device *dev, int vf)
{
	struct msnic_net *priv = netdev_priv(dev);

	if (priv->vf >= 0 || vf < 0 || vf >= READ_ONCE(priv->pf->num_vfs))
		return NULL;
	return &priv->pf->ports[vf];
}

static int msnic_get_vf(struct net_device *dev, int vf, struct ifla_vf_info *info)
{
	struct msnic_port *port = msnic_vf_port(dev, vf);

	if (!port)
		return -EINVAL;
	memset(info, 0, sizeof(*info));
	info->vf = vf;
	spin_lock_bh(&port->policy_lock);
	ether_addr_copy(info->mac, port->mac);
	spin_unlock_bh(&port->policy_lock);
	info->spoofchk = READ_ONCE(port->spoofchk);
	info->linkstate = READ_ONCE(port->link_state);
	return 0;
}

static int msnic_set_vf_mac(struct net_device *dev, int vf, u8 *mac)
{
	struct msnic_port *port = msnic_vf_port(dev, vf);
	struct net_device *endpoint;
	/* New kernels take sockaddr_storage; old kernels take sockaddr. */
	union {
		struct sockaddr addr;
		struct sockaddr_storage storage;
	} mac_addr = { .addr.sa_family = ARPHRD_ETHER };
	int err;

	if (!port || !is_valid_ether_addr(mac))
		return -EINVAL;
	endpoint = rtnl_dereference(port->endpoint);
	if (endpoint) {
		ether_addr_copy(mac_addr.addr.sa_data, mac);
		err = dev_set_mac_address(endpoint, (void *)&mac_addr, NULL);
		if (err)
			return err;
	}
	spin_lock_bh(&port->policy_lock);
	ether_addr_copy(port->mac, mac);
	spin_unlock_bh(&port->policy_lock);
	return 0;
}

static int msnic_set_vf_vlan(struct net_device *dev, int vf, u16 vlan, u8 qos, __be16 proto)
{
	if (!msnic_vf_port(dev, vf))
		return -EINVAL;
	if (vlan || qos || proto != htons(ETH_P_8021Q)) {
		netdev_err(dev, "Nonzero VF VLAN/QoS and alternate VLAN protocols are unsupported\n");
		return -EOPNOTSUPP;
	}
	return 0;
}

static int msnic_set_vf_rate(struct net_device *dev, int vf, int min, int max)
{
	if (!msnic_vf_port(dev, vf))
		return -EINVAL;
	if (min || max) {
		netdev_err(dev, "VF rate limiting is unsupported\n");
		return -EOPNOTSUPP;
	}
	return 0;
}

static int msnic_set_vf_spoofchk(struct net_device *dev, int vf, bool enabled)
{
	struct msnic_port *port = msnic_vf_port(dev, vf);

	if (!port)
		return -EINVAL;
	WRITE_ONCE(port->spoofchk, enabled);
	return 0;
}

static int msnic_set_vf_trust(struct net_device *dev, int vf, bool enabled)
{
	if (!msnic_vf_port(dev, vf))
		return -EINVAL;
	if (enabled) {
		netdev_err(dev, "Trusted VF receive/promiscuity policy is unsupported\n");
		return -EOPNOTSUPP;
	}
	return 0;
}

static int msnic_set_vf_link(struct net_device *dev, int vf, int state)
{
	struct msnic_port *port = msnic_vf_port(dev, vf);
	struct net_device *endpoint;

	if (!port || state < IFLA_VF_LINK_STATE_AUTO || state > IFLA_VF_LINK_STATE_DISABLE)
		return -EINVAL;
	WRITE_ONCE(port->link_state, state);
	endpoint = rtnl_dereference(port->endpoint);
	if (endpoint) {
		if (state == IFLA_VF_LINK_STATE_DISABLE || !netif_running(endpoint))
			netif_carrier_off(endpoint);
		else
			netif_carrier_on(endpoint);
	}
	return 0;
}

static const struct net_device_ops msnic_netdev_ops = {
	.ndo_open = msnic_open,
	.ndo_stop = msnic_stop,
	.ndo_start_xmit = msnic_xmit,
	.ndo_set_mac_address = eth_mac_addr,
	.ndo_validate_addr = eth_validate_addr,
	.ndo_get_stats64 = msnic_stats,
	.ndo_setup_tc = msnic_setup_tc,
	.ndo_set_features = msnic_set_features,
	.ndo_get_vf_config = msnic_get_vf,
	.ndo_set_vf_mac = msnic_set_vf_mac,
	.ndo_set_vf_vlan = msnic_set_vf_vlan,
	.ndo_set_vf_rate = msnic_set_vf_rate,
	.ndo_set_vf_spoofchk = msnic_set_vf_spoofchk,
	.ndo_set_vf_trust = msnic_set_vf_trust,
	.ndo_set_vf_link_state = msnic_set_vf_link,
};

struct net_device *msnic_alloc_netdev(struct msnic_pf *pf, struct pci_dev *pdev,
				    int vf, bool representor)
{
	struct net_device *dev;
	struct msnic_net *priv;
	u8 mac[ETH_ALEN] = { 0x02, 0x6d, 0, 0, 0, 0 };

	if (vf < -1 || vf >= MSNIC_MAX_VFS || (representor && vf < 0))
		return NULL;
	dev = alloc_etherdev(sizeof(struct msnic_net));
	if (!dev)
		return NULL;
	priv = netdev_priv(dev);
	priv->pf = pf;
	priv->pdev = pdev;
	priv->vf = vf;
	priv->representor = representor;
	INIT_LIST_HEAD(&priv->block_cb_list);
	dev->netdev_ops = &msnic_netdev_ops;
	dev->ethtool_ops = &msnic_ethtool_ops;
	dev->min_mtu = ETH_MIN_MTU;
	dev->max_mtu = 9000;
	dev->priv_flags |= IFF_LIVE_ADDR_CHANGE;
	/* PF HW_TC is the shared switch programming gate; external uplink ingress
	 * is absent in this lab. Representors have their own per-port gate.
	 */
	if (representor || vf < 0) {
		dev->features |= NETIF_F_HW_TC;
		dev->hw_features |= NETIF_F_HW_TC;
	}
	if (!representor)
		SET_NETDEV_DEV(dev, &pdev->dev);
	else {
#ifdef NETIF_F_NETNS_LOCAL
		dev->features |= NETIF_F_NETNS_LOCAL;
#elif defined(MSNIC_HAVE_NETNS_IMMUTABLE)
		dev->netns_immutable = true;
#else
		dev->netns_local = true;
#endif
	}
	if (representor) {
		snprintf(dev->name, IFNAMSIZ, "msnicr%d", vf);
		spin_lock_bh(&pf->ports[vf].policy_lock);
		ether_addr_copy(mac, pf->ports[vf].mac);
		spin_unlock_bh(&pf->ports[vf].policy_lock);
		mac[1] = 0x72;
	} else if (vf < 0) {
		strscpy(dev->name, "msnicp%d", IFNAMSIZ);
		mac[2] = pci_domain_nr(pdev->bus) >> 8;
		mac[3] = pci_domain_nr(pdev->bus);
		mac[4] = pdev->bus->number;
		mac[5] = pdev->devfn;
	} else {
		snprintf(dev->name, IFNAMSIZ, "msnicv%d", vf);
		spin_lock_bh(&pf->ports[vf].policy_lock);
		ether_addr_copy(mac, pf->ports[vf].mac);
		spin_unlock_bh(&pf->ports[vf].policy_lock);
	}
	eth_hw_addr_set(dev, mac);
	ether_addr_copy(dev->perm_addr, mac);
	netif_carrier_off(dev);
	return dev;
}
