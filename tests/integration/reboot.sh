#!/usr/bin/env bash
# Reboot only the explicitly configured Kubernetes DUT, after persistent binding.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
cluster_guard; mutation_guard
[[ $PERSISTENCE_ACK == YES && $OPERATOR_REBOOT_ACK == YES && ${VM_RECOVERY_ACK:-} == YES ]] || die 'Require persistence, reboot and tested VM recovery acknowledgements.'
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
machine=$(k get node "$NODE_NAME" -o json | jq -r '.status.nodeInfo.machineID' | tr -d '-')
[[ $machine == "$(remote cat /etc/machine-id | tr -d '\r\n-')" ]] || die 'SSH VM does not match the configured node.'
old_boot=$(remote cat /proc/sys/kernel/random/boot_id)
old_kernel=$(remote uname -r)
old_cordon=$(k get node "$NODE_NAME" -o json | jq -r '.spec.unschedulable // false')
remote sudo -n bash -s -- "$PF_BDF" "$old_kernel" <<'SH'
set -Eeuo pipefail
p=/sys/bus/pci/devices/$1
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") == 0 ]]
[[ $(cat /var/lib/mock-smartnic-lab/"$1"/installed-kernel) == "$2" ]]
systemctl is-active --quiet mock-smartnic-lab.service
systemctl is-enabled --quiet mock-smartnic-lab.service
systemctl show kubelet.service -p Requires --value | tr ' ' '\n' | grep -Fx mock-smartnic-lab.service
SH
k drain "$NODE_NAME" --ignore-daemonsets --timeout=180s
remote sudo -n systemctl reboot || { rc=$?; [[ $rc == 255 ]] || exit "$rc"; }
# Use a fresh SSH connection so a stale multiplexed session cannot mask reboot.
deadline=$((SECONDS+WAIT_SECONDS)); new_boot=
until [[ -n $new_boot && $new_boot != "$old_boot" ]]; do
  ((SECONDS < deadline)) || die 'Reboot/SSH readiness deadline expired; node remains cordoned for recovery.'
  new_boot=$(timeout --foreground --kill-after=2 20 ssh "${SSH_OPTS[@]}" \
    -o ControlPath=none "$SSH_TARGET" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
  sleep 3
done
remote sudo -n bash -s -- "$PF_BDF" "$old_kernel" <<'SH'
set -Eeuo pipefail
bdf=$1; kernel=$2; p=/sys/bus/pci/devices/$bdf
[[ $(uname -r) == "$kernel" ]]
[[ $(basename "$(readlink -f "$p/driver")") == mock_smartnic_pf ]]
[[ $(cat "$p/sriov_numvfs") == 0 && $(cat "$p/sriov_drivers_autoprobe") == 1 ]]
mapfile -t uplinks < <(find "$p/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
((${#uplinks[@]} == 1))
[[ $(cat "/sys/class/net/${uplinks[0]}/operstate") == up ]]
[[ -d /sys/bus/pci/drivers/mock_smartnic_vf && -d /sys/module/igbvf ]]
modprobe -c | grep -Fx "softdep igbvf pre: mock_smartnic"
systemctl is-active --quiet mock-smartnic-lab.service
systemctl is-active --quiet kubelet.service
module_time=$(systemctl show mock-smartnic-lab.service -p ActiveEnterTimestampMonotonic --value)
kubelet_time=$(systemctl show kubelet.service -p ActiveEnterTimestampMonotonic --value)
((module_time > 0 && kubelet_time >= module_time))
printf 'Binding active at %s; kubelet active at %s (monotonic microseconds)\n' "$module_time" "$kubelet_time"
modinfo -F vermagic mock_smartnic
sha256sum "/lib/modules/$kernel/extra/mock_smartnic.ko"
devlink -j dev eswitch show "pci/$bdf"
jq -e '.eswitch_mode=="legacy" and .active_flows==0' "/sys/kernel/debug/mock_smartnic/$bdf/stats"
systemctl show kubelet.service -p Requires -p After
SH
k wait --for=condition=Ready "node/$NODE_NAME" --timeout=180s
[[ $old_cordon == true ]] || k uncordon "$NODE_NAME"
printf 'PASS: boot changed %s -> %s; kernel-matched module, persistent PF, zero VFs, default VF driver and kubelet ordering.\n' "$old_boot" "$new_boot"
