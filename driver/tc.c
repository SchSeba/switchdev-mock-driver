// SPDX-License-Identifier: GPL-2.0-only
#include <linux/debugfs.h>
#include <linux/icmp.h>
#include <linux/ip.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <net/ip.h>
#include <net/pkt_cls.h>
#include <net/net_ratelimit.h>
#include "mock_smartnic.h"

#define MSNIC_MAX_FLOWS 256

struct msnic_keys {
	struct flow_dissector_key_control control;
	struct flow_dissector_key_basic basic;
	struct flow_dissector_key_eth_addrs eth;
	struct flow_dissector_key_ipv4_addrs ipv4;
	struct flow_dissector_key_ip ip;
	struct flow_dissector_key_ports ports;
	struct flow_dissector_key_tcp tcp;
	struct flow_dissector_key_icmp icmp;
	struct flow_dissector_key_meta meta;
	struct flow_dissector_key_num_of_vlans vlans;
};

struct msnic_counters {
	refcount_t refs;
	spinlock_t lock;
	u64 packets, bytes, drops, lastused;
	u64 reported_packets, reported_bytes, reported_drops;
};

struct msnic_flow {
	struct list_head list;
	struct rcu_head rcu;
	struct msnic_keys key, mask;
	unsigned long cookie;
	u32 priority;
	int ingress_vf;
	enum flow_action_id action;
	struct net_device *output;
	int output_vf;
	struct msnic_counters *counters;
	bool needs_ip, needs_ports, needs_tcp, needs_icmp;
};

struct msnic_key_desc {
	const char *name;
	size_t size;
	int offset; /* -1: nonzero masks unsupported. */
};

#define KEY(ID, type, field) [FLOW_DISSECTOR_KEY_##ID] = { #ID, \
	sizeof(struct flow_dissector_key_##type), offsetof(struct msnic_keys, field) }
#define NO_KEY(ID, type) [FLOW_DISSECTOR_KEY_##ID] = { #ID, \
	sizeof(struct flow_dissector_key_##type), -1 }
static const struct msnic_key_desc msnic_key_descs[FLOW_DISSECTOR_KEY_MAX] = {
	KEY(CONTROL, control, control), KEY(BASIC, basic, basic),
	KEY(IPV4_ADDRS, ipv4_addrs, ipv4), NO_KEY(IPV6_ADDRS, ipv6_addrs),
	KEY(PORTS, ports, ports), NO_KEY(PORTS_RANGE, ports_range),
	KEY(ICMP, icmp, icmp), KEY(ETH_ADDRS, eth_addrs, eth),
	NO_KEY(TIPC, tipc), NO_KEY(ARP, arp), NO_KEY(VLAN, vlan),
	NO_KEY(FLOW_LABEL, tags), NO_KEY(GRE_KEYID, keyid),
	NO_KEY(MPLS_ENTROPY, keyid), NO_KEY(ENC_KEYID, keyid),
	NO_KEY(ENC_IPV4_ADDRS, ipv4_addrs), NO_KEY(ENC_IPV6_ADDRS, ipv6_addrs),
	NO_KEY(ENC_CONTROL, control), NO_KEY(ENC_PORTS, ports), NO_KEY(MPLS, mpls),
	KEY(TCP, tcp, tcp), KEY(IP, ip, ip), NO_KEY(CVLAN, vlan),
	NO_KEY(ENC_IP, ip), NO_KEY(ENC_OPTS, enc_opts), KEY(META, meta, meta),
	NO_KEY(CT, ct), NO_KEY(HASH, hash), KEY(NUM_OF_VLANS, num_of_vlans, vlans),
	NO_KEY(PPPOE, pppoe), NO_KEY(L2TPV3, l2tpv3), NO_KEY(CFM, cfm),
};
#undef KEY
#undef NO_KEY

#define DISSECT(ID, field) { FLOW_DISSECTOR_KEY_##ID, offsetof(struct msnic_keys, field) }
static const struct flow_dissector_key msnic_dissector_keys[] = {
	DISSECT(CONTROL, control), DISSECT(BASIC, basic), DISSECT(ETH_ADDRS, eth),
	DISSECT(IPV4_ADDRS, ipv4), DISSECT(IP, ip), DISSECT(PORTS, ports),
	DISSECT(TCP, tcp), DISSECT(ICMP, icmp), DISSECT(META, meta),
	DISSECT(NUM_OF_VLANS, vlans),
};
#undef DISSECT
static struct flow_dissector msnic_dissector;

static bool msnic_nonzero(const void *data, size_t size)
{
	return memchr_inv(data, 0, size) != NULL;
}

static bool msnic_predicates_overlap(const struct msnic_flow *a, const struct msnic_flow *b)
{
	unsigned int i;

	for (i = 0; i < sizeof(a->key); i++)
		if ((((u8 *)&a->key)[i] ^ ((u8 *)&b->key)[i]) &
		    ((u8 *)&a->mask)[i] & ((u8 *)&b->mask)[i])
			return false;
	return true;
}

static int msnic_parse_match(struct flow_cls_offload *cls, struct msnic_flow *flow)
{
	struct flow_rule *rule = flow_cls_offload_flow_rule(cls);
	struct netlink_ext_ack *ack = cls->common.extack;
	struct msnic_keys allowed = {};
	struct flow_match_control control;
	const u8 *mask = (const u8 *)&flow->mask;
	u8 *key = (u8 *)&flow->key;
	int i;

	flow_rule_match_control(rule, &control);
	for (i = 0; i < FLOW_DISSECTOR_KEY_MAX; i++) {
		const struct msnic_key_desc *desc = &msnic_key_descs[i];
		const void *src_mask, *src_key;

		if (!flow_rule_match_key(rule, i))
			continue;
		if (!desc->size) {
			NL_SET_ERR_MSG_MOD(ack, "Unknown dissector key");
			return -EOPNOTSUPP;
		}
		src_mask = skb_flow_dissector_target(rule->match.dissector, i, rule->match.mask);
		if (!msnic_nonzero(src_mask, desc->size))
			continue;
		/* This kernel's flower registers both union address aliases. The
		 * control discriminator selects IPv4; remaining union bytes must be zero.
		 */
		if (i == FLOW_DISSECTOR_KEY_IPV6_ADDRS &&
		    control.mask->addr_type == U16_MAX &&
		    control.key->addr_type == FLOW_DISSECTOR_KEY_IPV4_ADDRS &&
		    flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV4_ADDRS) &&
		    rule->match.dissector->offset[i] ==
		    rule->match.dissector->offset[FLOW_DISSECTOR_KEY_IPV4_ADDRS] &&
		    !msnic_nonzero((u8 *)src_mask + sizeof(struct flow_dissector_key_ipv4_addrs),
			      desc->size - sizeof(struct flow_dissector_key_ipv4_addrs)))
			continue;
		if (desc->offset < 0) {
			NL_SET_ERR_MSG_FMT_MOD(ack, "Unsupported nonzero %s mask", desc->name);
			return -EOPNOTSUPP;
		}
		src_key = skb_flow_dissector_target(rule->match.dissector, i, rule->match.key);
		memcpy((u8 *)&flow->mask + desc->offset, src_mask, desc->size);
		memcpy((u8 *)&flow->key + desc->offset, src_key, desc->size);
	}
	allowed.control.addr_type = U16_MAX;
	allowed.control.flags = FLOW_DIS_IS_FRAGMENT | FLOW_DIS_FIRST_FRAG;
	allowed.basic.n_proto = htons(U16_MAX);
	allowed.basic.ip_proto = U8_MAX;
	memset(&allowed.eth, 0xff, sizeof(allowed.eth));
	memset(&allowed.ipv4, 0xff, sizeof(allowed.ipv4));
	memset(&allowed.ip, 0xff, sizeof(allowed.ip));
	memset(&allowed.ports, 0xff, sizeof(allowed.ports));
	allowed.tcp.flags = htons(0x0fff);
	memset(&allowed.icmp, 0xff, sizeof(allowed.icmp));
	allowed.meta.ingress_ifindex = -1;
	allowed.meta.ingress_iftype = U16_MAX;
	allowed.vlans.num_of_vlans = U8_MAX;
	for (i = 0; i < sizeof(flow->mask); i++) {
		if (mask[i] & ~((u8 *)&allowed)[i]) {
			NL_SET_ERR_MSG_MOD(ack, "Unsupported control flag, metadata or padding mask bit");
			return -EOPNOTSUPP;
		}
		key[i] &= mask[i];
	}
	/* The TC classifier protocol is itself a predicate, including L2-only rules. */
	if (cls->common.protocol != htons(ETH_P_ALL)) {
		if ((flow->key.basic.n_proto ^ cls->common.protocol) & flow->mask.basic.n_proto) {
			NL_SET_ERR_MSG_MOD(ack, "Classifier and flower protocols disagree");
			return -EINVAL;
		}
		flow->key.basic.n_proto = cls->common.protocol;
		flow->mask.basic.n_proto = htons(U16_MAX);
	}
	flow->needs_ports = msnic_nonzero(&flow->mask.ports, sizeof(flow->mask.ports));
	flow->needs_tcp = flow->mask.tcp.flags != 0;
	flow->needs_icmp = msnic_nonzero(&flow->mask.icmp, sizeof(flow->mask.icmp));
	flow->needs_ip = flow->mask.control.addr_type || flow->mask.control.flags ||
		flow->mask.basic.ip_proto || msnic_nonzero(&flow->mask.ipv4, sizeof(flow->mask.ipv4)) ||
		msnic_nonzero(&flow->mask.ip, sizeof(flow->mask.ip)) ||
		flow->needs_ports || flow->needs_tcp || flow->needs_icmp;
	if (flow->needs_ip && (flow->mask.basic.n_proto != htons(U16_MAX) ||
			      flow->key.basic.n_proto != htons(ETH_P_IP))) {
		NL_SET_ERR_MSG_MOD(ack, "IP predicates require exact IPv4 ethertype");
		return -EOPNOTSUPP;
	}
	if ((flow->needs_ports && (flow->mask.basic.ip_proto != U8_MAX ||
		(flow->key.basic.ip_proto != IPPROTO_TCP && flow->key.basic.ip_proto != IPPROTO_UDP))) ||
	    (flow->needs_tcp && (flow->mask.basic.ip_proto != U8_MAX ||
		flow->key.basic.ip_proto != IPPROTO_TCP)) ||
	    (flow->needs_icmp && (flow->mask.basic.ip_proto != U8_MAX ||
		flow->key.basic.ip_proto != IPPROTO_ICMP))) {
		NL_SET_ERR_MSG_MOD(ack, "L4 predicates require exact matching TCP, UDP or ICMP protocol");
		return -EOPNOTSUPP;
	}
	if (flow->mask.vlans.num_of_vlans && flow->key.vlans.num_of_vlans) {
		NL_SET_ERR_MSG_MOD(ack, "Only untagged VLAN predicates are implemented");
		return -EOPNOTSUPP;
	}
	return 0;
}

static int msnic_parse_action(struct msnic_net *priv, struct flow_cls_offload *cls,
			      struct msnic_flow *flow)
{
	struct flow_action *actions = &cls->rule->action;
	struct flow_action_entry *action;
	struct netlink_ext_ack *ack = cls->common.extack;
	struct msnic_pf *pf = priv->pf;
	int i;

	if (actions->num_entries != 1) {
		NL_SET_ERR_MSG_MOD(ack, "Exactly one terminal redirect or drop action is supported");
		return -EOPNOTSUPP;
	}
	action = &actions->entries[0];
	if (!action->hw_stats || (action->hw_stats & ~FLOW_ACTION_HW_STATS_DONT_CARE)) {
		NL_SET_ERR_MSG_MOD(ack, "Unsupported HW stats mask");
		return -EOPNOTSUPP;
	}
	if (!flow_action_hw_stats_check(actions, ack, FLOW_ACTION_HW_STATS_DELAYED_BIT))
		return -EOPNOTSUPP;
	/* TC fills miss_cookie even for a plain terminal action. No accepted
	 * program resumes after an action, so this core identity is never emitted.
	 */
	flow->action = action->id;
	if (action->id == FLOW_ACTION_DROP)
		return 0;
	if (action->id != FLOW_ACTION_REDIRECT) {
		NL_SET_ERR_MSG_FMT_MOD(ack, "Unsupported action ID %u; only redirect and drop", action->id);
		return -EOPNOTSUPP;
	}
	flow->output_vf = -1;
	if (action->dev != pf->uplink) {
		for (i = 0; i < READ_ONCE(pf->num_vfs); i++)
			if (action->dev == rcu_access_pointer(pf->ports[i].representor))
				break;
		if (i == READ_ONCE(pf->num_vfs)) {
			NL_SET_ERR_MSG_MOD(ack, "Redirect must target a representor or uplink of this mock switch");
			return -EOPNOTSUPP;
		}
		flow->output_vf = i;
	}
	if (!action->dev || action->dev->reg_state != NETREG_REGISTERED) {
		NL_SET_ERR_MSG_MOD(ack, "Redirect destination is not registered");
		return -ENODEV;
	}
	flow->output = action->dev;
	dev_hold(flow->output);
	return 0;
}

static void msnic_flow_free(struct msnic_flow *flow)
{
	if (flow->output)
		dev_put(flow->output);
	if (flow->counters && refcount_dec_and_test(&flow->counters->refs))
		kfree(flow->counters);
	kfree(flow);
}

static void msnic_flow_retire(struct rcu_head *rcu)
{
	msnic_flow_free(container_of(rcu, struct msnic_flow, rcu));
}

void msnic_flows_flush(struct msnic_pf *pf, int ingress_vf)
{
	struct msnic_flow *flow, *next;

	spin_lock_bh(&pf->flow_lock);
	list_for_each_entry_safe(flow, next, &pf->flows, list) {
		if (ingress_vf >= 0 && flow->ingress_vf != ingress_vf)
			continue;
		list_del_rcu(&flow->list);
		pf->active_flows--;
		call_rcu(&flow->rcu, msnic_flow_retire);
	}
	spin_unlock_bh(&pf->flow_lock);
}

static int msnic_replace(struct msnic_net *priv, struct flow_cls_offload *cls)
{
	struct msnic_pf *pf = priv->pf;
	struct netlink_ext_ack *ack = cls->common.extack;
	struct msnic_flow *flow, *cursor, *old = NULL;
	struct list_head *position;
	int err;

	flow = kzalloc(sizeof(*flow), GFP_KERNEL);
	if (!flow)
		return -ENOMEM;
	flow->cookie = cls->cookie;
	flow->priority = cls->common.prio;
	flow->ingress_vf = priv->vf;
	err = msnic_parse_match(cls, flow);
	if (err)
		goto fail;
	err = msnic_parse_action(priv, cls, flow);
	if (err)
		goto fail;
	flow->counters = kzalloc(sizeof(*flow->counters), GFP_KERNEL);
	if (!flow->counters) {
		err = -ENOMEM;
		goto fail;
	}
	refcount_set(&flow->counters->refs, 1);
	spin_lock_init(&flow->counters->lock);
	spin_lock_bh(&pf->flow_lock);
	/* Topology writers quiesce before flushing under this same lock. Check
	 * again here so a parser that started earlier cannot republish afterward.
	 */
	if (READ_ONCE(pf->state) != MSNIC_READY ||
	    READ_ONCE(pf->mode) != DEVLINK_ESWITCH_MODE_SWITCHDEV) {
		NL_SET_ERR_MSG_MOD(ack, "Switch topology changed during rule preparation");
		err = -EBUSY;
		goto unlock_fail;
	}
	position = &pf->flows;
	list_for_each_entry(cursor, &pf->flows, list) {
		if (cursor->ingress_vf == priv->vf && cursor->cookie == cls->cookie)
			old = cursor;
		if (cursor->ingress_vf == priv->vf && cursor->priority == flow->priority &&
		    cursor->cookie != flow->cookie &&
		    msnic_predicates_overlap(cursor, flow) &&
		    (memcmp(&cursor->key, &flow->key, sizeof(flow->key)) ||
		     memcmp(&cursor->mask, &flow->mask, sizeof(flow->mask)))) {
			NL_SET_ERR_MSG_MOD(ack, "Overlapping different predicates at one priority are ambiguous");
			err = -EOPNOTSUPP;
			goto unlock_fail;
		}
		if (cursor->priority < flow->priority)
			position = &cursor->list;
	}
	if (!old && pf->active_flows >= MSNIC_MAX_FLOWS) {
		NL_SET_ERR_MSG_MOD(ack, "Mock switch rule capacity (256) exhausted");
		err = -ENOSPC;
		goto unlock_fail;
	}
	if (old) {
		kfree(flow->counters);
		flow->counters = old->counters;
		refcount_inc(&flow->counters->refs);
		list_replace_rcu(&old->list, &flow->list);
		call_rcu(&old->rcu, msnic_flow_retire);
	} else {
		/* Flower's successful replace adds a new cookie before destroying the old
		 * cookie. Identical predicates at one priority therefore put newest first.
		 */
		list_add_rcu(&flow->list, position);
		pf->active_flows++;
	}
	spin_unlock_bh(&pf->flow_lock);
	return 0;
unlock_fail:
	spin_unlock_bh(&pf->flow_lock);
fail:
	msnic_flow_free(flow);
	return err;
}

static int msnic_flower(enum tc_setup_type type, void *data, void *cb_priv)
{
	struct net_device *dev = cb_priv;
	struct msnic_net *priv = netdev_priv(dev);
	struct msnic_pf *pf = priv->pf;
	struct flow_cls_offload *cls = data;
	struct msnic_flow *flow;
	int err = -ENOENT;

	if (type != TC_SETUP_CLSFLOWER)
		return -EOPNOTSUPP;
	if (cls->common.chain_index || cls->classid || cls->use_act_stats) {
		NL_SET_ERR_MSG_MOD(cls->common.extack, "Only chain zero, no class and per-flow stats are supported");
		return -EOPNOTSUPP;
	}
	if (cls->command == FLOW_CLS_REPLACE) {
		if (!(dev->features & NETIF_F_HW_TC) || !(pf->uplink->features & NETIF_F_HW_TC) ||
		    READ_ONCE(pf->state) != MSNIC_READY ||
		    READ_ONCE(pf->mode) != DEVLINK_ESWITCH_MODE_SWITCHDEV) {
			NL_SET_ERR_MSG_MOD(cls->common.extack, "HW TC disabled or switch topology changing");
			return -EBUSY;
		}
		err = msnic_replace(priv, cls);
		if (err && net_ratelimit())
			netdev_warn(dev, "Rejected flower cookie %#lx: %d (%s)\n", cls->cookie, err,
				    cls->common.extack && cls->common.extack->_msg ?
				    cls->common.extack->_msg : "no extack");
		return err;
	}
	if (cls->command != FLOW_CLS_DESTROY && cls->command != FLOW_CLS_STATS) {
		NL_SET_ERR_MSG_MOD(cls->common.extack, "Unsupported flower command");
		return -EOPNOTSUPP;
	}
	spin_lock_bh(&pf->flow_lock);
	list_for_each_entry(flow, &pf->flows, list) {
		struct msnic_counters *stats;

		if (flow->ingress_vf != priv->vf || flow->cookie != cls->cookie)
			continue;
		err = 0;
		if (cls->command == FLOW_CLS_DESTROY) {
			list_del_rcu(&flow->list);
			pf->active_flows--;
			call_rcu(&flow->rcu, msnic_flow_retire);
			break;
		}
		stats = flow->counters;
		spin_lock(&stats->lock);
		flow_stats_update(&cls->stats, stats->bytes - stats->reported_bytes,
				  stats->packets - stats->reported_packets,
				  stats->drops - stats->reported_drops, stats->lastused,
				  FLOW_ACTION_HW_STATS_DELAYED);
		stats->reported_bytes = stats->bytes;
		stats->reported_packets = stats->packets;
		stats->reported_drops = stats->drops;
		spin_unlock(&stats->lock);
		break;
	}
	spin_unlock_bh(&pf->flow_lock);
	return err;
}

int msnic_setup_tc(struct net_device *dev, enum tc_setup_type type, void *data)
{
	struct msnic_net *priv = netdev_priv(dev);
	struct flow_block_offload *block = data;
	int err;

	if (type != TC_SETUP_BLOCK)
		return -EOPNOTSUPP;
	if (!priv->representor) {
		NL_SET_ERR_MSG_MOD(block->extack, "PF HW_TC controls switch programming; only VF representor ingress has an RX engine");
		return -EOPNOTSUPP;
	}
	if (block->binder_type != FLOW_BLOCK_BINDER_TYPE_CLSACT_INGRESS || block->block_shared) {
		NL_SET_ERR_MSG_MOD(block->extack, "Only a private representor ingress block is supported");
		return -EOPNOTSUPP;
	}
	err = flow_block_cb_setup_simple(block, &priv->block_cb_list,
					msnic_flower, dev, dev, true);
	if (err)
		return err;
	if (block->command == FLOW_BLOCK_BIND) {
		priv->block = block->block;
		dev_hold(dev);
	} else if (block->command == FLOW_BLOCK_UNBIND) {
		msnic_flows_flush(priv->pf, priv->vf);
		priv->block = NULL;
		dev_put(dev);
	}
	return 0;
}

int msnic_set_features(struct net_device *dev, netdev_features_t features)
{
	struct msnic_net *priv = netdev_priv(dev);
	struct msnic_flow *flow;
	int err = 0;

	if ((features & NETIF_F_HW_TC) || !(dev->features & NETIF_F_HW_TC))
		return 0;
	spin_lock_bh(&priv->pf->flow_lock);
	list_for_each_entry(flow, &priv->pf->flows, list)
		if (priv->vf < 0 || flow->ingress_vf == priv->vf) {
			err = -EBUSY;
			break;
		}
	spin_unlock_bh(&priv->pf->flow_lock);
	return err;
}

/* Native dissector handles options and nonlinear skbs. Validate L3/L4 length
 * separately: absent/truncated headers must not masquerade as masked zeroes.
 */
static void msnic_packet_keys(struct sk_buff *skb, struct net_device *rep,
			      struct msnic_keys *keys, bool *ip_ok, bool *l4_ok)
{
	struct iphdr storage, *ip;
	unsigned int offset, ihl, length;

	skb->protocol = eth_hdr(skb)->h_proto;
	skb_set_network_header(skb, ETH_HLEN);
	skb_flow_dissect(skb, &msnic_dissector, keys,
			 FLOW_DISSECTOR_F_PARSE_1ST_FRAG | FLOW_DISSECTOR_F_STOP_BEFORE_ENCAP);
	keys->meta.ingress_ifindex = rep->ifindex;
	keys->meta.ingress_iftype = rep->type;
	/* VLAN rules are rejected; only untagged IP predicates are executable. */
	if (keys->vlans.num_of_vlans || keys->basic.n_proto != htons(ETH_P_IP))
		return;
	offset = ETH_HLEN;
	ip = skb_header_pointer(skb, offset, sizeof(storage), &storage);
	if (!ip || ip->version != 4 || ip->ihl < 5)
		return;
	ihl = ip->ihl * 4;
	length = ntohs(ip->tot_len);
	if (length < ihl || length > skb->len - offset)
		return;
	*ip_ok = true;
	if (ip->frag_off & htons(IP_OFFSET))
		return;
	offset += ihl;
	length -= ihl;
	if (ip->protocol == IPPROTO_UDP) {
		struct udphdr storage_udp, *udp;

		udp = skb_header_pointer(skb, offset, sizeof(storage_udp), &storage_udp);
		if (!udp || length < sizeof(*udp) || ntohs(udp->len) < sizeof(*udp) ||
		    (!(ip->frag_off & htons(IP_MF)) && ntohs(udp->len) > length))
			return;
	} else if (ip->protocol == IPPROTO_TCP) {
		struct tcphdr storage_tcp, *tcp;

		tcp = skb_header_pointer(skb, offset, sizeof(storage_tcp), &storage_tcp);
		if (!tcp || length < sizeof(*tcp) || tcp->doff < 5 || tcp->doff * 4 > length)
			return;
	} else if (ip->protocol == IPPROTO_ICMP) {
		if (length < sizeof(struct icmphdr))
			return;
	} else {
		return;
	}
	*l4_ok = true;
	/* The pinned native dissector skips ports on *all* fragments. A validated
	 * first fragment still contains ports; non-first fragments never do.
	 */
	if (ip->protocol == IPPROTO_UDP || ip->protocol == IPPROTO_TCP) {
		struct flow_dissector_key_ports storage_ports, *ports;

		ports = skb_header_pointer(skb, offset, sizeof(storage_ports), &storage_ports);
		if (ports)
			keys->ports = *ports;
	}
}

bool msnic_tc_execute(struct sk_buff *skb, struct msnic_net *source, struct net_device *rep)
{
	struct msnic_pf *pf = source->pf;
	struct msnic_keys keys = {};
	struct msnic_flow *flow;
	bool ip_ok = false, l4_ok = false;

	if (list_empty(&pf->flows))
		return false;
	msnic_packet_keys(skb, rep, &keys, &ip_ok, &l4_ok);
	/* ponytail: O(n) for at most 256 rules; use a classifier index if scale grows. */
	list_for_each_entry_rcu(flow, &pf->flows, list) {
		struct msnic_counters *stats;
		bool match = true, dropped;
		unsigned int i;

		if (flow->ingress_vf != source->vf || (flow->needs_ip && !ip_ok) ||
		    ((flow->needs_ports || flow->needs_tcp || flow->needs_icmp) && !l4_ok))
			continue;
		for (i = 0; i < sizeof(keys); i++)
			if ((((u8 *)&keys)[i] & ((u8 *)&flow->mask)[i]) != ((u8 *)&flow->key)[i]) {
				match = false;
				break;
			}
		if (!match)
			continue;
		stats = flow->counters;
		dropped = flow->action == FLOW_ACTION_DROP;
		spin_lock_bh(&stats->lock);
		stats->packets++;
		stats->bytes += skb->len; /* Includes Ethernet header; not FCS. */
		stats->drops += dropped;
		stats->lastused = jiffies;
		spin_unlock_bh(&stats->lock);
		atomic64_inc(&pf->offload_hits);
		if (dropped) {
			atomic64_inc(&pf->drop_packets);
			atomic64_inc(&source->tx_dropped);
			dev_kfree_skb_any(skb);
		} else {
			atomic64_inc(&pf->redirect_packets);
			if (flow->output_vf < 0) {
				atomic64_inc(&pf->uplink_sink_packets);
				dev_consume_skb_any(skb);
			} else if (READ_ONCE(pf->ports[flow->output_vf].link_state) == IFLA_VF_LINK_STATE_DISABLE) {
				dropped = true;
				atomic64_inc(&source->tx_dropped);
				dev_kfree_skb_any(skb);
			} else {
				dropped = !msnic_deliver_endpoint(skb, rcu_dereference(pf->ports[flow->output_vf].endpoint), source);
			}
			if (dropped) {
				atomic64_inc(&pf->drop_packets);
				spin_lock_bh(&stats->lock);
				stats->drops++;
				spin_unlock_bh(&stats->lock);
			}
		}
		return true;
	}
	return false;
}

static int msnic_stats_show(struct seq_file *seq, void *unused)
{
	struct msnic_pf *pf = seq->private;

	seq_printf(seq, "{\"schema_version\":1,\"pf_bdf\":\"%s\",\"eswitch_mode\":\"%s\",",
		   pci_name(pf->pdev), READ_ONCE(pf->mode) == DEVLINK_ESWITCH_MODE_SWITCHDEV ? "switchdev" : "legacy");
	seq_printf(seq, "\"offload_hits\":%lld,\"offload_misses\":%lld,\"slowpath_packets\":%lld,",
		   atomic64_read(&pf->offload_hits), atomic64_read(&pf->offload_misses), atomic64_read(&pf->slowpath_packets));
	seq_printf(seq, "\"redirect_packets\":%lld,\"drop_packets\":%lld,\"uplink_sink_packets\":%lld,",
		   atomic64_read(&pf->redirect_packets), atomic64_read(&pf->drop_packets), atomic64_read(&pf->uplink_sink_packets));
	seq_printf(seq, "\"active_flows\":%u,\"spoof_drops\":%lld}\n", READ_ONCE(pf->active_flows), atomic64_read(&pf->spoof_drops));
	return 0;
}

static int msnic_nonlinear_check(struct msnic_pf *pf)
{
	/* Identical IPv4-options/UDP packet, once linear and once split inside IP. */
	const u8 packet[46] = {
		[0] = 2, [6] = 2, [12] = 8, [14] = 0x46, [17] = 32,
		[22] = 64, [23] = IPPROTO_UDP, [26] = 192, [28] = 2, [29] = 1,
		[30] = 192, [32] = 2, [33] = 2, [34] = 1, [35] = 1, [36] = 1,
		[37] = 1, [38] = 4, [39] = 0x57, [40] = 0x10, [41] = 0x92, [43] = 8,
	};
	struct msnic_keys keys[2] = {};
	int i;

	for (i = 0; i < 2; i++) {
		unsigned int split = i ? 25 : sizeof(packet);
		struct sk_buff *skb = alloc_skb(split, GFP_KERNEL);
		bool ip_ok = false, l4_ok = false;

		if (!skb)
			return -ENOMEM;
		skb_put_data(skb, packet, split);
		if (i) {
			struct page *page = alloc_page(GFP_KERNEL);

			if (!page) {
				kfree_skb(skb);
				return -ENOMEM;
			}
			memcpy(page_address(page), packet + split, sizeof(packet) - split);
			skb_add_rx_frag(skb, 0, page, 0, sizeof(packet) - split, PAGE_SIZE);
		}
		skb->dev = pf->uplink;
		skb_reset_mac_header(skb);
		msnic_packet_keys(skb, pf->uplink, &keys[i], &ip_ok, &l4_ok);
		kfree_skb(skb);
		if (!ip_ok || !l4_ok || keys[i].ports.dst != htons(4242))
			return -EINVAL;
	}
	if (memcmp(&keys[0], &keys[1], sizeof(keys[0])))
		return -EINVAL;
	dev_info(&pf->pdev->dev, "linear/nonlinear IPv4-options and UDP parser check passed\n");
	return 0;
}

static int msnic_flows_show(struct seq_file *seq, void *unused)
{
	struct msnic_pf *pf = seq->private;
	struct msnic_flow *flow;
	bool comma = false;

	seq_puts(seq, "{\"schema_version\":1,\"flows\":[");
	rcu_read_lock();
	list_for_each_entry_rcu(flow, &pf->flows, list) {
		u64 packets, bytes;

		spin_lock_bh(&flow->counters->lock);
		packets = flow->counters->packets;
		bytes = flow->counters->bytes;
		spin_unlock_bh(&flow->counters->lock);
		seq_printf(seq, "%s{\"cookie\":\"0x%lx\",\"ingress_vf\":%d,\"chain\":0,\"priority\":%u,\"packets\":%llu,\"bytes\":%llu,",
			   comma ? "," : "", flow->cookie, flow->ingress_vf, flow->priority, packets, bytes);
		seq_printf(seq, "\"match\":{\"ethertype\":%u,\"ip_proto\":%u,\"src_ipv4\":\"%pI4\",\"dst_ipv4\":\"%pI4\",\"src_port\":%u,\"dst_port\":%u,\"fragment_mask\":%u},",
			   ntohs(flow->key.basic.n_proto), flow->key.basic.ip_proto, &flow->key.ipv4.src, &flow->key.ipv4.dst,
			   ntohs(flow->key.ports.src), ntohs(flow->key.ports.dst), flow->mask.control.flags);
		if (flow->action == FLOW_ACTION_DROP)
			seq_puts(seq, "\"actions\":[{\"kind\":\"drop\"}]}");
		else if (flow->output_vf < 0)
			seq_puts(seq, "\"actions\":[{\"kind\":\"uplink\"}]}");
		else
			seq_printf(seq, "\"actions\":[{\"kind\":\"redirect\",\"vf\":%d}]}", flow->output_vf);
		comma = true;
	}
	rcu_read_unlock();
	seq_puts(seq, "]}\n");
	return 0;
}

static int msnic_debug_open(struct inode *inode, struct file *file)
{
	struct msnic_pf *pf = inode->i_private;
	int err;

	/* debugfs safe proxy excludes removal while .open acquires this reference. */
	kref_get(&pf->ref);
	err = single_open(file, !strcmp(file->f_path.dentry->d_name.name, "stats") ?
			  msnic_stats_show : msnic_flows_show, pf);
	if (err)
		msnic_pf_put(pf);
	return err;
}

static int msnic_debug_release(struct inode *inode, struct file *file)
{
	struct seq_file *seq = file->private_data;
	struct msnic_pf *pf = seq->private;
	int err = single_release(inode, file);

	msnic_pf_put(pf);
	return err;
}

static const struct file_operations msnic_debug_fops = {
	.owner = THIS_MODULE,
	.open = msnic_debug_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.release = msnic_debug_release,
};

int msnic_debug_init(struct msnic_pf *pf)
{
	struct dentry *file;
	int err;

	/* Init is serialized by this module's single, exact-PF probe. */
	skb_flow_dissector_init(&msnic_dissector, msnic_dissector_keys, ARRAY_SIZE(msnic_dissector_keys));
	err = msnic_nonlinear_check(pf);
	if (err)
		return err;
	pf->debug_dir = debugfs_create_dir(pci_name(pf->pdev), msnic_debug_root);
	if (IS_ERR(pf->debug_dir))
		return PTR_ERR(pf->debug_dir);
	file = debugfs_create_file("stats", 0400, pf->debug_dir, pf, &msnic_debug_fops);
	if (!IS_ERR(file))
		file = debugfs_create_file("flows", 0400, pf->debug_dir, pf, &msnic_debug_fops);
	if (IS_ERR(file)) {
		msnic_debug_fini(pf);
		return PTR_ERR(file);
	}
	return 0;
}

void msnic_debug_fini(struct msnic_pf *pf)
{
	debugfs_remove_recursive(pf->debug_dir);
	pf->debug_dir = NULL;
}
