#!/usr/bin/env bash
# Direct TC-only test. Refuses to mix manual TC ownership with OVS ownership.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/lab.env"
P=/sys/bus/pci/devices/$PF_BDF
NS0=msnic-vf0; NS1=msnic-vf1
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 && $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || fail 'Missing lab authorization.'
[[ $(cat "$P/sriov_numvfs") -ge 2 ]] || fail 'Create VFs first.'
PORTS=$(devlink -j port show)
rep() { jq -er --arg p "pci/$PF_BDF/" --argjson n "$1" '.port|to_entries[]|select(.key|startswith($p))|select(.value.flavour=="pcivf" and .value.vfnum==$n)|.value.netdev' <<< "$PORTS"; }
R0=$(rep 0); R1=$(rep 1)
V0=$(find "$(readlink -f "$P/virtfn0")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
V1=$(find "$(readlink -f "$P/virtfn1")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
[[ -n $V0 && -n $V1 && $V0 != *$'\n'* && $V1 != *$'\n'* ]] || fail 'Expected one host-side netdev per VF.'
for d in "$R0" "$R1"; do
  [[ -z $(ovs-vsctl --timeout=3 iface-to-br "$d" 2>/dev/null || true) ]] || fail "$d is managed by OVS."
  [[ ! -L /sys/class/net/$d/master ]] || fail "$d has a master."
  [[ -z $(tc filter show dev "$d" ingress 2>/dev/null) ]] || fail "$d already has ingress filters."
  if tc -j qdisc show dev "$d" | jq -e 'any(.[]; .kind=="clsact" or .kind=="ingress")' >/dev/null; then
    fail "$d already has an ingress/clsact qdisc; do not take over another owner."
  fi
done
for n in "$NS0" "$NS1"; do
  [[ ! -e /run/netns/$n ]] || fail "Namespace $n already exists."
done
# Preserve PF/VF identities and original VF names; avoid touching arbitrary netns.
created0=0; created1=0; moved0=0; moved1=0; q0=0; q1=0
cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  if ((q0)); then tc qdisc del dev "$R0" clsact || cleanup_rc=1; fi
  if ((q1)); then tc qdisc del dev "$R1" clsact || cleanup_rc=1; fi
  if ((moved0)); then
    ip -n "$NS0" addr flush dev "$V0" || cleanup_rc=1
    ip -n "$NS0" link set "$V0" down || cleanup_rc=1
    ip -n "$NS0" link set "$V0" netns 1 || cleanup_rc=1
  fi
  if ((moved1)); then
    ip -n "$NS1" addr flush dev "$V1" || cleanup_rc=1
    ip -n "$NS1" link set "$V1" down || cleanup_rc=1
    ip -n "$NS1" link set "$V1" netns 1 || cleanup_rc=1
  fi
  if ((created0)); then ip netns del "$NS0" || cleanup_rc=1; fi
  if ((created1)); then ip netns del "$NS1" || cleanup_rc=1; fi
  if ((cleanup_rc)); then echo 'ERROR: cleanup incomplete; inspect namespaces/VF location.' >&2; ((rc!=0)) || rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
ip netns add "$NS0"; created0=1
ip netns add "$NS1"; created1=1
ip link set "$R0" up; ip link set "$R1" up
ip link set "$V0" netns "$NS0"; moved0=1
ip link set "$V1" netns "$NS1"; moved1=1
ip -n "$NS0" link set lo up; ip -n "$NS1" link set lo up
ip -n "$NS0" link set "$V0" up; ip -n "$NS1" link set "$V1" up
ip -n "$NS0" addr add 198.18.0.1/24 dev "$V0"
ip -n "$NS1" addr add 198.18.0.2/24 dev "$V1"
M0=$(ip -n "$NS0" -j link show "$V0" | jq -r '.[0].address')
M1=$(ip -n "$NS1" -j link show "$V1" | jq -r '.[0].address')
ip -n "$NS0" neigh replace 198.18.0.2 lladdr "$M1" nud permanent dev "$V0"
ip -n "$NS1" neigh replace 198.18.0.1 lladdr "$M0" nud permanent dev "$V1"
ethtool -K "$R0" hw-tc-offload on; ethtool -K "$R1" hw-tc-offload on
tc qdisc add dev "$R0" clsact; q0=1
tc qdisc add dev "$R1" clsact; q1=1
tc filter add dev "$R0" ingress protocol ip pref 10 flower skip_sw dst_ip 198.18.0.2 action mirred egress redirect dev "$R1"
tc filter add dev "$R1" ingress protocol ip pref 10 flower skip_sw dst_ip 198.18.0.1 action mirred egress redirect dev "$R0"
STATS=/sys/kernel/debug/mock_smartnic/$PF_BDF/stats
before=$(jq -er '.offload_hits' "$STATS")
ip netns exec "$NS0" ping -I "$V0" -c 10 -W 2 198.18.0.2
for d in "$R0" "$R1"; do
  dump=$(tc -s -d -j filter show dev "$d" ingress)
  jq . <<< "$dump"
  jq -e 'any(.[]; .options.in_hw == true)' <<< "$dump" >/dev/null || fail "$d has no in_hw filter."
  jq -e '[..|objects|.packets? // empty|numbers]|add > 0' <<< "$dump" >/dev/null || fail "$d has no packet stats."
done
after=$(jq -er '.offload_hits' "$STATS")
((after > before)) || fail 'Connectivity succeeded without increasing simulator offload hits.'
# Negative control: no OVS/bridge/software rule remains to deliver this traffic.
tc filter del dev "$R0" ingress pref 10
tc filter del dev "$R1" ingress pref 10
if ip netns exec "$NS0" ping -I "$V0" -c 2 -W 1 198.18.0.2; then
  fail 'Traffic still succeeds with rules removed: hidden VF-to-VF bypass exists.'
fi
echo 'PASS: TC in_hw, packet counters, driver hits, and negative-control isolation.'
