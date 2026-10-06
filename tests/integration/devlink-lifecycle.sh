#!/usr/bin/env bash
# Run with zero VFs and the mock PF bound; resolves actual netdevices via devlink.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
remote sudo -n bash -s -- "$PF_BDF" "$NUM_VFS" "$REMOTE_DIR/src/sriovnet-discovery" <<'SH'
set -Eeuo pipefail
trap 'echo "FAIL: devlink lifecycle line $LINENO" >&2' ERR
bdf=$1; count=$2; discovery=$3
p=/sys/bus/pci/devices/$bdf
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") == 0 && -x $discovery ]]
pf=$(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
rep_for() { devlink -j port show | jq -er --arg port "pci/$bdf/$((1+$1))" '.port[$port].netdev'; }
rep_count() { devlink -j port show | jq --arg prefix "pci/$bdf/" '[.port|to_entries[]|select(.key|startswith($prefix))|select(.value.flavour=="pcivf")]|length'; }
for sequence in mode-first vfs-first; do
  devlink dev eswitch set "pci/$bdf" mode legacy
  printf '1\n' > "$p/sriov_drivers_autoprobe"
  if [[ $sequence == mode-first ]]; then
    devlink dev eswitch set "pci/$bdf" mode switchdev
    [[ $(rep_count) == 0 ]]
    printf '%s\n' "$count" > "$p/sriov_numvfs"
  else
    printf '%s\n' "$count" > "$p/sriov_numvfs"
    [[ $(rep_count) == 0 ]]
    devlink dev eswitch set "pci/$bdf" mode switchdev
  fi
  [[ $(rep_count) == "$count" ]]
  [[ $(find "$p/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]
  for ((i=0;i<count;i++)); do
    vf=$(readlink -f "$p/virtfn$i"); vbdf=${vf##*/}; rep=$(rep_for "$i")
    [[ $(cat /sys/class/net/"$rep"/phys_switch_id) == "$(cat /sys/class/net/"$pf"/phys_switch_id)" ]]
    [[ $(cat /sys/class/net/"$rep"/phys_port_name) == "pf0vf$i" ]]
    [[ $(basename "$(readlink -f "$vf/driver")") == mock_smartnic_vf ]]
    "$discovery" "$vbdf"
  done
  vf=$(readlink -f "$p/virtfn0"); vbdf=${vf##*/}; rep=$(rep_for 0)
  saved_ifindex=$(cat /sys/class/net/"$rep"/ifindex)
  for attempt in {1..10}; do
    printf '%s\n' "$vbdf" > "$vf/driver/unbind"
    [[ $(cat /sys/class/net/"$rep"/ifindex) == "$saved_ifindex" ]]
    printf '\n' > "$vf/driver_override"
    printf '%s\n' "$vbdf" > /sys/bus/pci/drivers_probe
    [[ $(basename "$(readlink -f "$vf/driver")") == mock_smartnic_vf ]]
    [[ $(cat /sys/class/net/"$rep"/ifindex) == "$saved_ifindex" ]]
    [[ $(find "$vf/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]
    echo "PASS: default-driver rebind $sequence $attempt; representor identity retained."
  done
  endpoint=$(find "$vf/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
  ns=msnic-discovery-$$
  [[ ! -e /run/netns/$ns ]]
  ip netns add "$ns"
  trap 'ip netns del "$ns" 2>/dev/null || true' EXIT
  ip link set "$endpoint" netns "$ns"
  moved=$("$discovery" "$vbdf")
  printf '%s\n' "$moved"
  jq -e '.host_endpoints|length==0' <<< "$moved"
  ip netns del "$ns"
  trap - EXIT
  deadline=$((SECONDS+30))
  until [[ $(find "$vf/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]; do
    ((SECONDS < deadline)) || { echo 'VF did not return after namespace deletion' >&2; exit 1; }
    sleep 1
  done
  [[ $(cat /sys/class/net/"$rep"/ifindex) == "$saved_ifindex" ]]
  printf '0\n' > "$p/sriov_numvfs"
  [[ $(rep_count) == 0 && -d /sys/class/net/$pf ]]
  echo "PASS: $sequence, metadata, sriovnet, default-driver rebind, namespace return."
done
devlink dev eswitch set "pci/$bdf" mode legacy
SH
