#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
rsync -a --timeout=60 -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10' \
  "$ROOT/scripts/udp-probe.py" "$ROOT/tests/integration/udp-echo.py" "$SSH_TARGET:$REMOTE_DIR/src/"
remote sudo -n bash -s -- "$PF_BDF" "$REMOTE_DIR/src" <<'SH'
set -Eeuo pipefail
trap 'echo "FAIL: OVS offload line $LINENO" >&2' ERR
bdf=$1; src=$2; p=/sys/bus/pci/devices/$bdf
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf && $(cat "$p/sriov_numvfs") == 2 ]]
[[ -z $(ovs-vsctl --timeout=5 list-br) ]] # global HWOL restart only on this empty dedicated OVS
saved_config=$(ovs-vsctl --timeout=5 get Open_vSwitch . other_config)
echo "OVS before: $saved_config"
ports=$(devlink -j port show)
r0=$(jq -er --arg p "pci/$bdf/1" '.port[$p].netdev' <<< "$ports")
r1=$(jq -er --arg p "pci/$bdf/2" '.port[$p].netdev' <<< "$ports")
pf=$(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
v0=$(find "$(readlink -f "$p/virtfn0")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
v1=$(find "$(readlink -f "$p/virtfn1")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
for d in "$pf" "$v0" "$v1" "$r0" "$r1"; do
  [[ -n $d && -z $(ip -o addr show dev "$d" scope global) && ! -L /sys/class/net/$d/master ]]
done
for d in "$r0" "$r1" "$pf"; do
  [[ -z $(tc filter show dev "$d" ingress) ]]
  ! tc -j qdisc show dev "$d" | jq -e 'any(.[]; .kind=="clsact" or .kind=="ingress")' >/dev/null
done
n0=msnic-ovs0-$$; n1=msnic-ovs1-$$; bridge=msnic-hwol
[[ ! -e /run/netns/$n0 && ! -e /run/netns/$n1 ]]
made0=0; made1=0; moved0=0; moved1=0; made_bridge=0; changed_config=0; server=
tmp=$(mktemp -d /var/tmp/msnic-ovs.XXXXXX)
debug=/sys/kernel/debug/mock_smartnic/$bdf
dump() {
  ovs-appctl dpctl/dump-flows -m --names || true
  ovs-appctl dpctl/dump-flows -m --names type=offloaded || true
  tc -s -d -j filter show dev "$r0" ingress
  tc -s -d -j filter show dev "$r1" ingress
  cat "$debug/stats" "$debug/flows"
}
remove_qdiscs() {
  for d in "$r0" "$r1" "$pf"; do
    [[ -z $(tc filter show dev "$d" ingress) ]] || { echo "Filters remain on $d; preserving qdisc" >&2; return 1; }
    if tc -j qdisc show dev "$d" | jq -e 'any(.[]; .kind=="clsact")' >/dev/null; then
      tc qdisc del dev "$d" clsact
    fi
  done
}
cleanup() {
  result=$?; trap - EXIT
  if ((result)); then dump || true; fi
  if [[ -n $server ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  if ((made_bridge)); then ovs-vsctl --timeout=5 del-br "$bridge" || result=1; fi
  remove_qdiscs || result=1
  if ((changed_config)); then
    ovs-vsctl --timeout=5 set Open_vSwitch . other_config="$saved_config" || result=1
    systemctl restart ovs-vswitchd || result=1
  fi
  if ((moved0)); then
    ip -n "$n0" addr flush dev "$v0" || result=1
    ip -n "$n0" link set "$v0" down || result=1
    ip -n "$n0" link set "$v0" netns 1 || result=1
  fi
  if ((moved1)); then
    ip -n "$n1" addr flush dev "$v1" || result=1
    ip -n "$n1" link set "$v1" down || result=1
    ip -n "$n1" link set "$v1" netns 1 || result=1
  fi
  if ((made0)); then ip netns del "$n0" || result=1; fi
  if ((made1)); then ip netns del "$n1" || result=1; fi
  rm -rf -- "$tmp"
  echo "OVS restored: $(ovs-vsctl --timeout=5 get Open_vSwitch . other_config)"
  exit "$result"
}
trap cleanup EXIT
ip netns add "$n0"; made0=1
ip netns add "$n1"; made1=1
ip link set "$v0" netns "$n0"; moved0=1
ip link set "$v1" netns "$n1"; moved1=1
for d in "$pf" "$r0" "$r1"; do ip link set "$d" up; done
for n in "$n0" "$n1"; do ip -n "$n" link set lo up; done
ip -n "$n0" link set "$v0" up; ip -n "$n1" link set "$v1" up
ip -n "$n0" addr add 198.18.0.1/24 dev "$v0"
ip -n "$n1" addr add 198.18.0.2/24 dev "$v1"
m0=$(ip -n "$n0" -j link show "$v0" | jq -r '.[0].address')
m1=$(ip -n "$n1" -j link show "$v1" | jq -r '.[0].address')
ip -n "$n0" neigh replace 198.18.0.2 lladdr "$m1" nud permanent dev "$v0"
ip -n "$n1" neigh replace 198.18.0.1 lladdr "$m0" nud permanent dev "$v1"
ip netns exec "$n1" python3 -u "$src/udp-echo.py" 198.18.0.2 > "$tmp/server.log" 2>&1 & server=$!
for i in {1..50}; do grep -q READY "$tmp/server.log" && break; sleep .1; done
grep -q READY "$tmp/server.log"
bridge_create() {
  ovs-vsctl --timeout=5 add-br "$bridge" -- set Bridge "$bridge" datapath_type=system fail_mode=secure external_ids:mock-smartnic-lab=true
  made_bridge=1
  ovs-vsctl --timeout=5 add-port "$bridge" "$r0" -- set Interface "$r0" ofport_request=10 \
    -- add-port "$bridge" "$r1" -- set Interface "$r1" ofport_request=11 \
    -- add-port "$bridge" "$pf" -- set Interface "$pf" ofport_request=12
  ovs-ofctl add-flow "$bridge" 'priority=100,in_port=10,udp,nw_src=198.18.0.1,nw_dst=198.18.0.2,tp_dst=9000,actions=output:11'
  ovs-ofctl add-flow "$bridge" 'priority=100,in_port=11,udp,nw_src=198.18.0.2,nw_dst=198.18.0.1,tp_src=9000,actions=output:10'
  ovs-ofctl add-flow "$bridge" 'priority=90,in_port=10,icmp,nw_src=198.18.0.1,nw_dst=198.18.0.2,actions=output:11'
  ovs-ofctl add-flow "$bridge" 'priority=90,in_port=11,icmp,nw_src=198.18.0.2,nw_dst=198.18.0.1,actions=output:10'
}
# Independent software baseline. These are OpenFlow rules, never manual TC rules.
changed_config=1
ovs-vsctl --timeout=5 set Open_vSwitch . other_config:hw-offload=true other_config:tc-policy=skip_hw
systemctl restart ovs-vswitchd
bridge_create
before=$(jq -er .offload_hits "$debug/stats")
ip netns exec "$n0" python3 "$src/udp-probe.py" 198.18.0.1 198.18.0.2 --count 30
ip netns exec "$n0" ping -I "$v0" -c 2 -W 2 198.18.0.2
[[ $(jq -er .offload_hits "$debug/stats") == "$before" ]]
[[ $(jq -er .active_flows "$debug/stats") == 0 ]]
echo 'PASS: OVS skip_hw baseline; identical UDP payloads; no driver hits.'
ovs-vsctl --timeout=5 del-br "$bridge"; made_bridge=0
remove_qdiscs
ovs-vsctl --timeout=5 set Open_vSwitch . other_config:tc-policy=skip_sw
systemctl restart ovs-vswitchd
bridge_create
before=$(jq -er .offload_hits "$debug/stats")
ip netns exec "$n0" python3 "$src/udp-probe.py" 198.18.0.1 198.18.0.2 --count 600
ip netns exec "$n0" ping -I "$v0" -c 10 -i .1 -W 2 198.18.0.2
dump
for d in "$r0" "$r1"; do
  tc -s -d -j filter show dev "$d" ingress | jq -e 'any(.[]; .options.in_hw==true)' >/dev/null
done
(( $(jq -er .offload_hits "$debug/stats") - before > 500 ))
jq -e 'any(.flows[]; .ingress_vf==0 and .packets>100 and any(.actions[]; .kind=="redirect" and .vf==1)) and any(.flows[]; .ingress_vf==1 and .packets>100 and any(.actions[]; .kind=="redirect" and .vf==0))' "$debug/flows" >/dev/null
ovs-vsctl --timeout=5 del-br "$bridge"; made_bridge=0
remove_qdiscs
[[ $(jq -er .active_flows "$debug/stats") == 0 ]]
if ip netns exec "$n0" ping -I "$v0" -c 2 -W 1 198.18.0.2; then echo 'Hidden forwarding survived OVS removal' >&2; exit 1; fi
echo 'PASS: standalone OVS-generated in_hw flows, both engine directions, identical UDP and ping; removal restores isolation.'
SH
