#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
remote sudo -n bash -s -- "$PF_BDF" <<'SH'
set -Eeuo pipefail
trap 'echo "FAIL: VF netlink line $LINENO" >&2' ERR
p=/sys/bus/pci/devices/$1
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") -ge 2 ]]
pf=$(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
vf=$(readlink -f "$p/virtfn0")
endpoint=$(find "$vf/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
[[ -n $endpoint && -z $(ip -o addr show dev "$endpoint" scope global) ]]
ip link set dev "$endpoint" up
ip link set dev "$pf" vf 0 mac 02:76:aa:bb:cc:00
[[ $(cat /sys/class/net/"$endpoint"/address) == 02:76:aa:bb:cc:00 ]]
ip -d link show dev "$pf" | grep -F '02:76:aa:bb:cc:00'
ip link set dev "$endpoint" mtu 1400
[[ $(cat /sys/class/net/"$endpoint"/mtu) == 1400 ]]
ip link set dev "$endpoint" mtu 1500
ip link set dev "$pf" vf 0 state disable
[[ $(cat /sys/class/net/"$endpoint"/carrier) == 0 ]]
ip link set dev "$pf" vf 0 state enable
[[ $(cat /sys/class/net/"$endpoint"/carrier) == 1 ]]
ip link set dev "$pf" vf 0 state auto
ip link set dev "$pf" vf 0 spoofchk on
ip -d link show dev "$pf" | grep -F 'spoof checking on'
ip link set dev "$pf" vf 0 spoofchk off
ip link set dev "$pf" vf 0 trust off
ip link set dev "$pf" vf 0 vlan 0
ip link set dev "$pf" vf 0 min_tx_rate 0 max_tx_rate 0
reject() { if "$@"; then echo 'Unsupported VF setting accepted' >&2; exit 1; fi; }
reject ip link set dev "$pf" vf 0 vlan 200
reject ip link set dev "$pf" vf 0 trust on
reject ip link set dev "$pf" vf 0 max_tx_rate 100
ip link set dev "$endpoint" down
echo 'PASS: VF MAC, MTU, carrier policy, netlink state, explicit unsupported-setting rejection.'
echo 'Spoof enforcement traffic is tested by the K04 datapath gate.'
SH
