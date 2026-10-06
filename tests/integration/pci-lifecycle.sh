#!/usr/bin/env bash
# Exercise the compiled driver on the one explicitly configured PCI carrier.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
remote sudo -n bash -s -- "$PF_BDF" "$NUM_VFS" "$EMULATED_PF_ACK" "$EXCLUSIVE_PF_ACK" <<'SH'
set -Eeuo pipefail
bdf=$1; count=$2
[[ $3 == "$bdf" && $4 == YES && $EUID == 0 ]]
p=$(readlink -f "/sys/bus/pci/devices/$bdf")
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") == 0 ]]
initial_pf=$(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
[[ -n $initial_pf ]]
for autoprobe in 0 1; do
  printf '%s\n' "$autoprobe" > "$p/sriov_drivers_autoprobe"
  for cycle in 1 2; do
    printf '%s\n' "$count" > "$p/sriov_numvfs"
    [[ $(cat "$p/sriov_numvfs") == "$count" ]]
    for ((i=0;i<count;i++)); do
      vf=$(readlink -f "$p/virtfn$i"); vbdf=${vf##*/}
      [[ $(readlink -f "$vf/physfn") == "$p" ]]
      [[ $(cat "$vf/vendor") == 0x8086 && $(cat "$vf/device") == 0x10ca ]]
      if [[ $autoprobe == 0 ]]; then
        [[ ! -L $vf/driver ]]
        printf 'mock_smartnic_vf\n' > "$vf/driver_override"
        printf '%s\n' "$vbdf" > /sys/bus/pci/drivers/mock_smartnic_vf/bind
      fi
      [[ $(basename "$(readlink -f "$vf/driver")") == mock_smartnic_vf ]]
      [[ $(find "$vf/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]
      dev=$(find "$vf/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
      [[ -z $(ip -o addr show dev "$dev" scope global) && ! -L /sys/class/net/$dev/master ]]
      printf 'autoprobe=%s cycle=%s vf=%s pci=%s endpoint=%s physfn=%s\n' "$autoprobe" "$cycle" "$i" "$vbdf" "$dev" "$(readlink -f "$vf/physfn")"
    done
    if printf '%s\n' "$((count == 2 ? 3 : 2))" > "$p/sriov_numvfs" 2>/dev/null; then
      echo 'ERROR: nonzero count change unexpectedly succeeded' >&2; exit 1
    fi
    [[ $(cat "$p/sriov_numvfs") == "$count" ]]
    printf '0\n' > "$p/sriov_numvfs"
    printf '0\n' > "$p/sriov_numvfs"
    [[ $(cat "$p/sriov_numvfs") == 0 ]]
    [[ -z $(find "$p" -maxdepth 1 -name 'virtfn*') ]]
    [[ $(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n') == "$initial_pf" ]]
  done
done
if printf '8\n' > "$p/sriov_numvfs" 2>/dev/null; then
  echo 'ERROR: invalid count unexpectedly succeeded' >&2; exit 1
fi
[[ $(cat "$p/sriov_numvfs") == 0 ]]
printf '1\n' > "$p/sriov_drivers_autoprobe"
echo 'PASS: real PCI lifecycle, disabled/automatic probing, stable PF, count rejection.'
SH
