#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
remote sudo -n bash -s -- "$PF_BDF" "$REMOTE_DIR/src/packet-pipe.py" <<'SH'
set -Eeuo pipefail
trap 'echo "FAIL: slow path line $LINENO" >&2' ERR
p=/sys/bus/pci/devices/$1; pipe=$2
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") == 2 ]]
pf=$(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
ports=$(devlink -j port show)
r0=$(jq -er --arg p "pci/$1/1" '.port[$p].netdev' <<< "$ports")
r1=$(jq -er --arg p "pci/$1/2" '.port[$p].netdev' <<< "$ports")
v0=$(find "$(readlink -f "$p/virtfn0")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
v1=$(find "$(readlink -f "$p/virtfn1")/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
n0=msnic-slow0-$$; n1=msnic-slow1-$$; bridge=msnic-slow
[[ -n $v0 && -n $v1 && ! -e /run/netns/$n0 && ! -e /run/netns/$n1 ]]
if ovs-vsctl --timeout=5 br-exists "$bridge"; then echo 'Bridge already exists' >&2; exit 1; fi
for dev in "$v0" "$v1" "$r0" "$r1"; do
  [[ -z $(ip -o addr show dev "$dev" scope global) && ! -L /sys/class/net/$dev/master ]]
  [[ -z $(ovs-vsctl --timeout=5 iface-to-br "$dev" 2>/dev/null || true) ]]
done
created0=0; created1=0; moved0=0; moved1=0; made_bridge=0
cleanup() {
  result=$?; trap - EXIT
  if ((made_bridge)); then ovs-vsctl --timeout=5 del-br "$bridge" || result=1; fi
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
  if ((created0)); then ip netns del "$n0" || result=1; fi
  if ((created1)); then ip netns del "$n1" || result=1; fi
  ip link set "$pf" vf 0 spoofchk off || result=1
  ip link set "$pf" vf 0 state auto || result=1
  exit "$result"
}
trap cleanup EXIT
ip netns add "$n0"; created0=1
ip netns add "$n1"; created1=1
ip link set "$v0" netns "$n0"; moved0=1
ip link set "$v1" netns "$n1"; moved1=1
ip link set "$r0" up; ip link set "$r1" up
ip -n "$n0" link set lo up; ip -n "$n1" link set lo up
ip -n "$n0" link set "$v0" up; ip -n "$n1" link set "$v1" up
m0=$(ip -n "$n0" -j link show "$v0" | jq -r '.[0].address')
m1=$(ip -n "$n1" -j link show "$v1" | jq -r '.[0].address')
mr0=$(cat /sys/class/net/"$r0"/address)
python3 "$pipe" probe "$n0" "$v0" - "$r0" "$m0" "$mr0" 1
python3 "$pipe" probe - "$r0" "$n0" "$v0" "$mr0" "$m0" 1
python3 "$pipe" probe "$n0" "$v0" "$n1" "$v1" "$m0" "$m1" 0
ip link set "$pf" vf 0 spoofchk on
python3 "$pipe" probe "$n0" "$v0" - "$r0" "$m0" "$mr0" 1
python3 "$pipe" probe "$n0" "$v0" - "$r0" 02:76:de:ad:be:ef "$mr0" 0
ip link set "$pf" vf 0 spoofchk off
ip link set "$pf" vf 0 state disable
python3 "$pipe" probe - "$r0" "$n0" "$v0" "$mr0" "$m0" 0
ip link set "$pf" vf 0 state auto
ip -n "$n0" addr add 198.18.0.1/24 dev "$v0"
ip -n "$n1" addr add 198.18.0.2/24 dev "$v1"
ip -n "$n0" neigh replace 198.18.0.2 lladdr "$m1" nud permanent dev "$v0"
ip -n "$n1" neigh replace 198.18.0.1 lladdr "$m0" nud permanent dev "$v1"
if ip netns exec "$n0" ping -I "$v0" -c 2 -W 1 198.18.0.2; then echo 'Hidden forwarding exists' >&2; exit 1; fi
ovs-vsctl --timeout=5 add-br "$bridge" -- set Bridge "$bridge" datapath_type=system external_ids:mock-smartnic-lab=true
made_bridge=1
ovs-vsctl --timeout=5 add-port "$bridge" "$r0" -- add-port "$bridge" "$r1"
ip netns exec "$n0" ping -I "$v0" -c 5 -W 2 198.18.0.2
ip netns exec "$n1" ping -I "$v1" -c 5 -W 2 198.18.0.1
ovs-appctl dpctl/dump-flows --names
ovs-vsctl --timeout=5 del-br "$bridge"; made_bridge=0
if ip netns exec "$n0" ping -I "$v0" -c 2 -W 1 198.18.0.2; then echo 'Traffic survived software bridge removal' >&2; exit 1; fi
echo 'PASS: Ethernet payloads, correct directions, no duplicates/bypass, spoof/link policy, software OVS ping.'
SH
