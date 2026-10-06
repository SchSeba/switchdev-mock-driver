#!/usr/bin/env bash
# Run inside an attested QEMU guest, after cloning this repository.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo 'Usage: sudo scripts/setup-worker.sh --pf 0000:29:00.0 --emulated-pf [--restore]'
  echo 'Builds for the running kernel. Optional --kernel RELEASE asserts an expected release.'
  echo '--emulated-pf acknowledges hypervisor XML inspection of this dedicated emulated igb PF.'
}
PF_BDF= EXPECTED_KERNEL= EMULATED_PF_ACK= ACTION=install
while (($#)); do
  case $1 in
    --pf|--kernel) (($# >= 2)) || fail "Missing value for $1"; if [[ $1 == --pf ]]; then PF_BDF=$2; else EXPECTED_KERNEL=$2; fi; shift 2 ;;
    --emulated-pf) EMULATED_PF_ACK=YES; shift ;;
    --restore) ACTION=restore; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
[[ $PF_BDF =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]$ ]] || fail 'Provide one canonical PF BDF.'
KERNEL_RELEASE=$(uname -r)
[[ $KERNEL_RELEASE =~ ^[a-zA-Z0-9_.+-]+$ ]] || fail 'Invalid running kernel release.'
[[ -z $EXPECTED_KERNEL || $KERNEL_RELEASE == "$EXPECTED_KERNEL" ]] || fail 'Running kernel differs from the requested release.'
[[ $EMULATED_PF_ACK == YES && $EUID == 0 ]] || fail 'Root and explicit --emulated-pf acknowledgement required.'
[[ ! -e /run/ostree-booted ]] || fail 'Immutable hosts require a separate signed module delivery path.'
case "$(systemd-detect-virt --vm)" in qemu|kvm) ;; *) fail 'Only attested QEMU/KVM guests are supported.';; esac
P=/sys/bus/pci/devices/$PF_BDF
STATE=/var/lib/mock-smartnic-lab/$PF_BDF
NM=/etc/NetworkManager/conf.d/90-mock-smartnic-lab.conf
SSH_PEER=${SSH_CONNECTION:-}
SSH_PEER=${SSH_PEER%% *}
source "$ROOT/scripts/lib/pf-guard.sh"
[[ -d $P && ! -e $P/physfn && $(cat "$P/vendor") == 0x8086 && $(cat "$P/device") == 0x10c9 ]] || fail 'Expected an Intel 82576 PF, never a VF.'
[[ -r $P/sriov_totalvfs && $(cat "$P/sriov_totalvfs") =~ ^[0-9]+$ ]] && (($(cat "$P/sriov_totalvfs") >= 2)) || fail 'Carrier lacks usable PCI SR-IOV capability.'
[[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Remove the policies, pods and VFs owned by the operator before setup/restore.'
mapfile -t names < <(find "$P/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
if [[ $ACTION == install ]]; then
  ((${#names[@]} == 1)) || fail 'Expected exactly one PF uplink in the host namespace.'
fi
for name in "${names[@]}"; do not_used "$name"; done
if [[ $ACTION == restore ]]; then
  [[ -f $STATE/harness/lab.env ]] || fail 'No owned worker setup exists.'
  [[ ! -e $STATE/persisted ]] || bash "$STATE/harness/guest.sh" unpersist "$SSH_PEER"
  if [[ -f $STATE/original.env ]]; then
    bash "$STATE/harness/guest.sh" restore "$SSH_PEER"
  else
    [[ $(basename "$(readlink -f "$P/driver")") == igb ]] || fail 'Missing native recovery state.'
  fi
  if [[ -f $STATE/owned-nm.conf ]]; then
    cmp -s "$NM" "$STATE/owned-nm.conf" || fail 'NetworkManager file changed; preserve it for manual review.'
    rm "$NM" "$STATE/owned-nm.conf"
    systemctl is-active --quiet NetworkManager && nmcli general reload conf || true
  fi
  exit 0
fi
[[ $(basename "$(readlink -f "$P/driver")") == igb ]] || fail 'Require the native igb PF driver; restore an earlier installation first.'
[[ ! -e $STATE/original.env && ! -e /etc/systemd/system/mock-smartnic-lab.service && ! -e $NM ]] || fail 'Existing installation/configuration: recover its owner before reinstalling.'
if [[ -r /sys/kernel/security/lockdown ]]; then
  lockdown=$(cat /sys/kernel/security/lockdown)
  [[ $lockdown != *'[integrity]'* && $lockdown != *'[confidentiality]'* ]] || fail 'Enforced module signing requires a separate authorized signed-module delivery path.'
fi
[[ $(cat /proc/sys/kernel/modules_disabled) == 0 ]] || fail 'Kernel module loading is disabled.'
"$ROOT/scripts/bootstrap-guest.sh" --install
install -d -m 700 "$STATE/harness/lib"
install -m 755 "$ROOT/scripts/guest.sh" "$ROOT/scripts/tc-smoke.sh" "$STATE/harness/"
install -m 644 "$ROOT/scripts/lib/pf-guard.sh" "$STATE/harness/lib/"
{
  printf 'SOURCE_DIR=%q\nPF_BDF=%q\n' "$ROOT" "$PF_BDF"
  printf 'NUM_VFS=2\nEXPECTED_PF_VENDOR=0x8086\nEXPECTED_PF_DEVICE=0x10c9\nEXPECTED_VF_DEVICE=0x10ca\n'
  printf 'EMULATED_PF_ACK=%q\nEXCLUSIVE_PF_ACK=YES\nPERSISTENCE_ACK=YES\n' "$PF_BDF"
} > "$STATE/harness/lab.env"
bash "$STATE/harness/guest.sh" build
# Protect only this PF and the netdevs owned by the mock driver from DHCP/IPv6.
install -d /etc/NetworkManager/conf.d
cat > "$STATE/owned-nm.conf" <<NMCONF
# mock-smartnic-lab owned: $PF_BDF
[device-mock-smartnic-lab]
match-device=path:pci-$PF_BDF
managed=0
[device-mock-smartnic-ports]
match-device=interface-name:msnicp*,interface-name:msnicr*,interface-name:msnicv*
managed=0
NMCONF
install -m 644 "$STATE/owned-nm.conf" "$NM"
if systemctl is-active --quiet NetworkManager; then nmcli general reload conf; fi
bash "$STATE/harness/guest.sh" bind "$SSH_PEER"
bash "$STATE/harness/guest.sh" persist "$SSH_PEER"
systemctl start mock-smartnic-lab.service
[[ $(cat "$P/sriov_numvfs") == 0 && $(cat "$P/sriov_drivers_autoprobe") == 1 ]]
devlink dev eswitch show "pci/$PF_BDF"
echo "Ready: $PF_BDF bound to mock_smartnic_pf on $KERNEL_RELEASE; zero VFs, operator owns switchdev/OVS configuration."
