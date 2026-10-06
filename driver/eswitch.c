// SPDX-License-Identifier: GPL-2.0-only
#include "mock_smartnic.h"

static void msnic_drop(struct sk_buff *skb, struct msnic_net *source)
{
	atomic64_inc(&source->tx_dropped);
	dev_kfree_skb_any(skb);
}

/* Input includes Ethernet header. Native handoff scrubs namespace metadata,
 * pulls L2 exactly once via eth_type_trans, and consumes skb on every return.
 * Caller holds RCU so dest and its private state survive the complete handoff.
 */
bool msnic_deliver_endpoint(struct sk_buff *skb, struct net_device *dest,
			    struct msnic_net *source)
{
	struct msnic_net *target;
	unsigned int bytes = skb->len;

	if (!dest || !netif_running(dest) || !netif_carrier_ok(dest)) {
		msnic_drop(skb, source);
		return false;
	}
	target = netdev_priv(dest);
	if (dev_forward_skb(dest, skb) == NET_RX_SUCCESS) {
		atomic64_inc(&target->rx_packets);
		atomic64_add(bytes, &target->rx_bytes);
		return true;
	} else {
		/* RX drops belong to native core_stats; do not count them twice. */
		atomic64_inc(&source->tx_dropped);
		return false;
	}
}

static void msnic_vf_xmit(struct sk_buff *skb, struct msnic_net *source)
{
	struct msnic_pf *pf = source->pf;
	struct msnic_port *port = &pf->ports[source->vf];
	struct net_device *rep;
	bool spoof;

	if (READ_ONCE(pf->mode) != DEVLINK_ESWITCH_MODE_SWITCHDEV ||
	    READ_ONCE(port->link_state) == IFLA_VF_LINK_STATE_DISABLE) {
		msnic_drop(skb, source);
		return;
	}
	spin_lock_bh(&port->policy_lock);
	spoof = READ_ONCE(port->spoofchk) &&
		!ether_addr_equal(eth_hdr(skb)->h_source, port->mac);
	spin_unlock_bh(&port->policy_lock);
	if (spoof) {
		atomic64_inc(&pf->spoof_drops);
		msnic_drop(skb, source);
		return;
	}
	rep = rcu_dereference(port->representor);
	if (rep && msnic_tc_execute(skb, source, rep))
		return;
	atomic64_inc(&pf->offload_misses);
	atomic64_inc(&pf->slowpath_packets);
	/* No implicit VF-to-VF switching. This is rep RX, not rep TX. */
	msnic_deliver_endpoint(skb, rep, source);
}

static void msnic_rep_xmit(struct sk_buff *skb, struct msnic_net *source)
{
	struct msnic_port *port = &source->pf->ports[source->vf];

	if (READ_ONCE(port->link_state) == IFLA_VF_LINK_STATE_DISABLE) {
		msnic_drop(skb, source);
		return;
	}
	msnic_deliver_endpoint(skb, rcu_dereference(port->endpoint), source);
}

netdev_tx_t msnic_xmit(struct sk_buff *skb, struct net_device *dev)
{
	struct msnic_net *source = netdev_priv(dev);
	struct msnic_pf *pf = source->pf;

	atomic64_inc(&source->tx_packets);
	atomic64_add(skb->len, &source->tx_bytes);
	if (!pskb_may_pull(skb, ETH_HLEN)) {
		msnic_drop(skb, source);
		return NETDEV_TX_OK;
	}
	skb_reset_mac_header(skb);
	rcu_read_lock();
	if (READ_ONCE(pf->state) != MSNIC_READY) {
		msnic_drop(skb, source);
	} else if (source->representor) {
		msnic_rep_xmit(skb, source);
	} else if (source->vf >= 0) {
		msnic_vf_xmit(skb, source);
	} else {
		atomic64_inc(&pf->uplink_sink_packets);
		dev_consume_skb_any(skb);
	}
	rcu_read_unlock();
	return NETDEV_TX_OK;
}
