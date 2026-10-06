#!/usr/bin/env bash
# Run after native restore, before binding a newly compiled module.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
remote sudo -n bash -s -- "$PF_BDF" "$REMOTE_DIR/src/driver/mock_smartnic.ko" <<'SH'
set -Eeuo pipefail
bdf=$1; module=$2
[[ ! -e /sys/module/mock_smartnic ]]
[[ $(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")") == igb ]]
reject() {
  if insmod "$module" "$@"; then
    rmmod mock_smartnic
    echo 'ERROR: invalid module parameters were accepted' >&2; exit 1
  fi
  [[ ! -e /sys/module/mock_smartnic ]]
}
reject
reject "target_pf=$bdf"
reject allow_igb_emulation=1
reject allow_igb_emulation=1 target_pf=0000:29:20.0
reject allow_igb_emulation=1 target_pf=0000:29:00.0suffix
insmod "$module" allow_igb_emulation=1 "target_pf=$bdf"
[[ -d /sys/bus/pci/drivers/mock_smartnic_pf && -d /sys/bus/pci/drivers/mock_smartnic_vf ]]
[[ $(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")") == igb ]]
rmmod mock_smartnic
echo 'PASS: parameter rejection, PCI driver registration, no native PF displacement.'
SH
