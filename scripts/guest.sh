#!/usr/bin/env bash
# DUT-side build, binding and inspection harness. Run through scripts/lab.sh.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/lab.env"
ACTION=${1:-preflight}
SSH_PEER=${2:-}
P=/sys/bus/pci/devices/$PF_BDF
STATE=/var/lib/mock-smartnic-lab/$PF_BDF
PF_DRIVER=mock_smartnic_pf
VF_DRIVER=mock_smartnic_vf
MODULE=mock_smartnic
MODULE_FILE=$SOURCE_DIR/driver/mock_smartnic.ko
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null || fail "Missing command: $1"; }
current_driver() { [[ ! -L "$1/driver" ]] || basename "$(readlink -f "$1/driver")"; }
pf_netdev() {
  local names=()
  mapfile -t names < <(find "$P/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
  ((${#names[@]} == 1)) || fail 'The PF must have exactly one PCI-parented uplink netdev.'
  printf '%s\n' "${names[0]}"
}
identity() {
  [[ -d "$P" ]] || fail "PCI function absent: $PF_BDF"
  [[ $(cat "$P/vendor") == "$EXPECTED_PF_VENDOR" && $(cat "$P/device") == "$EXPECTED_PF_DEVICE" ]] || fail 'Unexpected PCI identity.'
  [[ -r "$P/sriov_totalvfs" ]] || fail 'Missing SR-IOV capability; pci-testdev is not sufficient.'
  (($(cat "$P/sriov_totalvfs") >= NUM_VFS)) || fail 'Not enough VFs exposed by the emulator.'
}
mutation() {
  [[ $EUID == 0 ]] || fail 'This action needs root.'
  [[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || fail 'Require exact EMULATED_PF_ACK and EXCLUSIVE_PF_ACK=YES.'
  identity
  require systemd-detect-virt
  case "$(systemd-detect-virt --vm || true)" in qemu|kvm) ;; *) fail 'This harness only mutates an attested QEMU/KVM guest.';; esac
}
not_used() {
  local dev=$1
  [[ ! -L /sys/class/net/$dev/master ]] || fail "$dev belongs to a bridge/bond/VRF."
  ! compgen -G "/sys/class/net/$dev/upper_*" >/dev/null || fail "$dev has an upper device."
  [[ -z $(ip -o addr show dev "$dev" scope global) ]] || fail "$dev has a global IP address."
  [[ -z $(ip route show default dev "$dev") && -z $(ip -6 route show default dev "$dev") ]] || fail "$dev carries a default route."
  if [[ -n $SSH_PEER ]]; then
    local route
    route=$(ip route get "$SSH_PEER" 2>/dev/null || ip -6 route get "$SSH_PEER" 2>/dev/null || true)
    [[ " $route " != *" dev $dev "* ]] || fail "$dev carries the SSH connection."
  fi
  if command -v ovs-vsctl >/dev/null; then
    local br
    ovs-vsctl --timeout=3 show >/dev/null 2>&1 || fail "Cannot verify OVS ownership of $dev: OVSDB is unavailable."
    br=$(ovs-vsctl --timeout=3 iface-to-br "$dev" 2>/dev/null || true)
    [[ -z $br ]] || fail "$dev belongs to OVS bridge $br. Clean up its owner first."
  fi
}
reps() {
  devlink -j port show | jq -r --arg p "pci/$PF_BDF/" '
    (.port // {}) | to_entries[] | select(.key|startswith($p)) |
    select(.value.flavour == "pcivf") | .value.netdev // empty'
}
assert_idle_vfs() {
  local vf drv names d
  shopt -s nullglob
  for vf in "$P"/virtfn*; do
    vf=$(readlink -f "$vf"); drv=$(current_driver "$vf")
    [[ -n $drv ]] || continue
    [[ $drv == "$VF_DRIVER" ]] || fail "VF bound to unexpected driver $drv; refusing reset."
    names=$(find "$vf/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true)
    [[ -n $names ]] || fail 'VF netdev absent from host namespace; remove its pod/netns first.'
    while read -r d; do not_used "$d"; done <<< "$names"
  done
  while read -r d; do [[ -z $d ]] || not_used "$d"; done < <(reps)
}
case "$ACTION" in
  build)
    require make; require gcc
    [[ -d /lib/modules/$(uname -r)/build ]] || fail 'Install headers/devel for the RUNNING kernel, not merely the newest kernel.'
    [[ -f $SOURCE_DIR/driver/Makefile ]] || fail 'Implement driver/Makefile before building.'
    jobs=$(getconf _NPROCESSORS_ONLN); ((jobs <= 8)) || jobs=8
    make -C "/lib/modules/$(uname -r)/build" M="$SOURCE_DIR/driver" clean
    make -C "/lib/modules/$(uname -r)/build" M="$SOURCE_DIR/driver" W=1 -j"$jobs" modules
    test -s "$MODULE_FILE"
    modinfo "$MODULE_FILE"
    sha256sum "$MODULE_FILE"
    exit ;;
esac
[[ $EUID == 0 ]] || fail 'Use sudo -n for DUT inspection and mutation.'
require ip; require lspci; require ethtool; require devlink; require jq
case "$ACTION" in
  preflight)
    identity
    uname -a; cat /etc/os-release
    systemd-detect-virt --vm || true
    printf '\nPCI\n'; lspci -Dnnk -s "$PF_BDF"; lspci -Dvv -s "$PF_BDF"
    printf '\nSR-IOV\n'; cat "$P/sriov_totalvfs" "$P/sriov_numvfs" "$P/sriov_drivers_autoprobe"
    printf '\nNETWORK\n'; ip -br link; ip -br addr; ip route; ip -6 route
    printf '\nKERNEL BUILD\n'; ls -ld "/lib/modules/$(uname -r)/build" || true
    [[ ! -f /sys/kernel/security/lockdown ]] || cat /sys/kernel/security/lockdown
    command -v mokutil >/dev/null && mokutil --sb-state || true
    printf '\nOVS\n'; ovs-vsctl --version 2>/dev/null || true
    systemctl cat ovs-vswitchd.service 2>/dev/null || true
    printf '\nNOTE: DMI + PCI IDs do not prove emulation. Inspect hypervisor XML before ACK.\n'
    ;;
  bind)
    mutation
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Start with zero VFs; do not destroy existing allocations.'
    [[ $(current_driver "$P") != "$PF_DRIVER" ]] || fail 'Already bound. Use reset/restore before replacing a loaded module.'
    old=$(current_driver "$P"); [[ $old == igb ]] || fail 'The initial carrier must be bound to native igb.'
    dev=$(pf_netdev); not_used "$dev"
    [[ -f $MODULE_FILE ]] || fail 'Build the driver first.'
    [[ $(modinfo -F vermagic "$MODULE_FILE") == "$(uname -r) "* ]] || fail 'Module vermagic differs from running kernel.'
    [[ ! -e /sys/module/$MODULE ]] || fail 'Module already loaded; restore/unload it before another bind.'
    [[ ! -e $STATE/original.env ]] || fail 'Existing recovery state found; restore it instead of overwriting.'
    # Do not displace any unrelated native VF driver users.
    if [[ -d /sys/bus/pci/drivers/igbvf ]]; then
      [[ -z $(find /sys/bus/pci/drivers/igbvf -maxdepth 1 -type l -name '????:??:??.?' -print) ]] || fail 'Other native igbvf devices are bound.'
    fi
    if [[ -d /sys/module/igbvf ]]; then modprobe -r igbvf || fail 'Cannot unload igbvf (possibly built-in).'; fi
    block=/etc/modprobe.d/mock-smartnic-lab-igbvf.conf
    [[ ! -e $block ]] || fail "Refusing to overwrite $block. Recover the earlier run."
    install -d -m 700 "$STATE"
    {
      printf 'ORIGINAL_DRIVER=%q\n' "$old"
      printf 'ORIGINAL_OVERRIDE=%q\n' "$(cat "$P/driver_override")"
      printf 'ORIGINAL_AUTOPROBE=%q\n' "$(cat "$P/sriov_drivers_autoprobe")"
      printf 'ORIGINAL_IFNAME=%q\n' "$dev"
      printf 'ORIGINAL_ADMIN_UP=%q\n' "$(ip -j link show "$dev" | jq -r '.[0].flags|index("UP") != null')"
    } > "$STATE/original.env"
    # Lab-only temporary native-VF suppression. Remove during restore.
    printf '# mock-smartnic-lab owned\nblacklist igbvf\ninstall igbvf /bin/false\n' > "$block"
    modprobe sch_ingress; modprobe cls_flower; modprobe act_mirred
    insmod "$MODULE_FILE" target_pf="$PF_BDF" allow_igb_emulation=1
    printf '%s\n' "$PF_DRIVER" > "$P/driver_override"
    printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
    if ! printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$PF_DRIVER/bind"; then
      printf '%s\n' "$old" > "$P/driver_override"
      printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$old/bind" || true
      fail "Mock probe failed; native rebind attempted. Inspect state in $STATE and run restore."
    fi
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'PF did not bind to mock driver.'
    mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
    dev=$(pf_netdev)
    ethtool -i "$dev"; devlink dev show; ip -d link show "$dev"
    ;;
  vfs|pci-vfs)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Bind the mock PF first.'
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Use reset before another manual VF test.'
    # Manual test intentionally suppresses autoprobe; Kubernetes test restores it.
    printf '0\n' > "$P/sriov_drivers_autoprobe"
    printf '%s\n' "$NUM_VFS" > "$P/sriov_numvfs"
    for ((i=0;i<NUM_VFS;i++)); do
      vf=$(readlink -f "$P/virtfn$i"); bdf=${vf##*/}
      [[ $(cat "$vf/device") == "$EXPECTED_VF_DEVICE" ]] || fail "Unexpected VF identity $bdf"
      printf '%s\n' "$VF_DRIVER" > "$vf/driver_override"
      printf '%s\n' "$bdf" > "/sys/bus/pci/drivers/$VF_DRIVER/bind"
      [[ $(current_driver "$vf") == "$VF_DRIVER" ]] || fail "VF $bdf did not bind."
      [[ $(find "$vf/net" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]] || fail "VF $bdf needs exactly one endpoint."
    done
    if [[ $ACTION == pci-vfs ]]; then
      lspci -Dnnk
      exit 0
    fi
    devlink dev eswitch set "pci/$PF_BDF" mode switchdev
    [[ $(reps | wc -l) == "$NUM_VFS" ]] || fail 'Representor count differs from VF count.'
    devlink -j port show | jq .; ip -d link show
    ;;
  tc-smoke)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF is not bound.'
    assert_idle_vfs
    exec bash "$HERE/tc-smoke.sh" ;;
  reset|pci-reset)
    mutation
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF is not bound.'
    assert_idle_vfs
    printf '0\n' > "$P/sriov_numvfs"
    if [[ $ACTION == reset ]]; then
      devlink dev eswitch set "pci/$PF_BDF" mode legacy
    fi
    printf '1\n' > "$P/sriov_drivers_autoprobe"
    if [[ $ACTION == reset ]]; then
      printf 'Reset complete: zero VFs, legacy, autoprobe enabled. Operator now owns creation.\n'
    else
      printf 'PCI-only reset complete: zero VFs, autoprobe enabled; eswitch mode was NOT changed. Use full reset before Kubernetes.\n'
    fi
    ;;
  persist)
    mutation
    [[ ${PERSISTENCE_ACK:-} == YES ]] || fail 'Set PERSISTENCE_ACK=YES.'
    [[ $(current_driver "$P") == "$PF_DRIVER" && -f $STATE/original.env ]] || fail 'Bind successfully first.'
    [[ ! -e /etc/systemd/system/mock-smartnic-lab.service ]] || fail 'Persistence already exists; unpersist before replacing it.'
    [[ ! -e /run/ostree-booted ]] || fail 'Use the documented kernel-matched module image/KMM path on immutable nodes.'
    install -d /usr/local/libexec/mock-smartnic-lab /etc/mock-smartnic-lab "/lib/modules/$(uname -r)/extra"
    install -m 0644 "$MODULE_FILE" "/lib/modules/$(uname -r)/extra/mock_smartnic.ko"
    printf '%s\n' "$(uname -r)" > "$STATE/installed-kernel"
    printf 'options mock_smartnic target_pf=%s allow_igb_emulation=1\n' "$PF_BDF" > /etc/modprobe.d/mock-smartnic-lab.conf
    printf 'PF_BDF=%q\n' "$PF_BDF" > /etc/mock-smartnic-lab/boot.env
    cat > /usr/local/libexec/mock-smartnic-lab/boot-bind <<'BOOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/mock-smartnic-lab/boot.env
P=/sys/bus/pci/devices/$PF_BDF
[[ $(cat "$P/vendor") == 0x8086 && $(cat "$P/device") == 0x10c9 ]]
case "$(systemd-detect-virt --vm)" in qemu|kvm) ;; *) exit 1;; esac
[[ $(cat "$P/sriov_numvfs") == 0 ]]
# A built-in/early-bound native VF driver is not an acceptable test configuration.
[[ ! -e /sys/module/igbvf ]]
modprobe sch_ingress; modprobe cls_flower; modprobe act_mirred
modprobe mock_smartnic
if [[ -L $P/driver && $(basename "$(readlink -f "$P/driver")") == mock_smartnic_pf ]]; then
  printf '1\n' > "$P/sriov_drivers_autoprobe"
  exit 0
fi
printf 'mock_smartnic_pf\n' > "$P/driver_override"
[[ ! -L $P/driver ]] || printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
printf '%s\n' "$PF_BDF" > /sys/bus/pci/drivers/mock_smartnic_pf/bind
printf '1\n' > "$P/sriov_drivers_autoprobe"
BOOT
    chmod 0755 /usr/local/libexec/mock-smartnic-lab/boot-bind
    cat > /etc/systemd/system/mock-smartnic-lab.service <<'UNIT'
[Unit]
Description=Bind the dedicated emulated SmartNIC before Kubernetes reconciliation
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service
Before=kubelet.service sriov-config.service sriov-config-post-network.service ovs-vswitchd.service
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mock-smartnic-lab/boot-bind
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
    install -d /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/30-mock-smartnic-lab.conf <<'UNIT'
[Unit]
Requires=mock-smartnic-lab.service
After=mock-smartnic-lab.service
UNIT
    depmod -a
    systemctl daemon-reload
    systemctl enable mock-smartnic-lab.service
    touch "$STATE/persisted"
    printf 'Persistence installed for this kernel only. No reboot was performed.\n'
    ;;
  unpersist)
    mutation
    [[ ${PERSISTENCE_ACK:-} == YES && -e $STATE/persisted ]] || fail 'No owned persistence state, or PERSISTENCE_ACK missing.'
    systemctl disable mock-smartnic-lab.service
    rm -f /etc/systemd/system/mock-smartnic-lab.service /etc/systemd/system/kubelet.service.d/30-mock-smartnic-lab.conf
    rm -f /etc/modprobe.d/mock-smartnic-lab.conf /usr/local/libexec/mock-smartnic-lab/boot-bind /etc/mock-smartnic-lab/boot.env
    ver=$(cat "$STATE/installed-kernel")
    [[ $ver =~ ^[a-zA-Z0-9_.+-]+$ ]] || fail 'Invalid recorded kernel version.'
    rm -f "/lib/modules/$ver/extra/mock_smartnic.ko"
    depmod -a "$ver"; systemctl daemon-reload
    rm -f "$STATE/persisted"
    ;;
  restore)
    mutation
    [[ -f $STATE/original.env ]] || fail 'No original state exists.'
    [[ ! -e $STATE/persisted ]] || fail 'Run unpersist first.'
    [[ $(cat "$P/sriov_numvfs") == 0 ]] || fail 'Remove pods/policies/bridges and run reset first.'
    # A failed probe can leave the PF unbound with no netdev. Still permit
    # recovery using the original state; check ownership whenever a netdev exists.
    if [[ -d $P/net ]]; then
      while read -r dev; do [[ -z $dev ]] || not_used "$dev"; done < <(find "$P/net" -mindepth 1 -maxdepth 1 -printf '%f\n')
    fi
    # shellcheck disable=SC1090
    source "$STATE/original.env"
    [[ ! -L $P/driver ]] || printf '%s\n' "$PF_BDF" > "$P/driver/unbind"
    [[ ! -e /sys/module/$MODULE ]] || rmmod "$MODULE"
    rm -f /etc/modprobe.d/mock-smartnic-lab-igbvf.conf
    modprobe "$ORIGINAL_DRIVER"
    printf '%s\n' "$ORIGINAL_DRIVER" > "$P/driver_override"
    printf '%s\n' "$PF_BDF" > "/sys/bus/pci/drivers/$ORIGINAL_DRIVER/bind"
    if [[ $ORIGINAL_OVERRIDE == '(null)' || -z $ORIGINAL_OVERRIDE ]]; then
      printf '\n' > "$P/driver_override"
    else printf '%s\n' "$ORIGINAL_OVERRIDE" > "$P/driver_override"; fi
    printf '%s\n' "$ORIGINAL_AUTOPROBE" > "$P/sriov_drivers_autoprobe"
    dev=$(pf_netdev)
    if [[ $ORIGINAL_ADMIN_UP == true ]]; then ip link set "$dev" up; else ip link set "$dev" down; fi
    mv "$STATE/original.env" "$STATE/restored-$(date +%s).env"
    printf 'Native driver restored. Global OVS/operator changes are handled separately.\n'
    ;;
  operator-preflight)
    identity
    [[ $(current_driver "$P") == "$PF_DRIVER" ]] || fail 'Mock PF must already be bound.'
    [[ $(cat "$P/sriov_numvfs") == 0 && $(cat "$P/sriov_drivers_autoprobe") == 1 ]] || fail 'Run reset before applying the node policy.'
    [[ -e $STATE/persisted && -f /etc/systemd/system/mock-smartnic-lab.service ]] || fail 'Install and test reboot-safe binding before enabling operator HWOL.'
    [[ -e /usr/lib/systemd/system/ovs-vswitchd.service ]] || fail 'Pinned Kubernetes operator requires /usr/lib/systemd/system/ovs-vswitchd.service; adapt distro integration explicitly.'
    systemctl is-enabled mock-smartnic-lab.service
    ovs-vsctl --timeout=5 show
    ;;
  mapping|tc-json)
    python3 - "$PF_BDF" "$ACTION" <<'PYGUEST'
import json, pathlib, subprocess, sys
bdf, action = sys.argv[1:]
ports = json.loads(subprocess.check_output(["devlink", "-j", "port", "show"]))["port"]
reps = {int(v["vfnum"]): v["netdev"] for k,v in ports.items()
        if k.startswith("pci/"+bdf+"/") and v.get("flavour")=="pcivf" and "netdev" in v}
if action == "mapping":
    result=[]
    for path in sorted(pathlib.Path("/sys/bus/pci/devices", bdf).glob("virtfn*")):
        idx=int(path.name[6:]); vf=path.resolve()
        result.append({"vf":idx, "pci":vf.name, "representor":reps.get(idx),
                       "host_netdevs":[p.name for p in (vf/"net").glob("*")]})
    print(json.dumps({"pf":bdf,"vfs":result}))
else:
    result={str(idx):{"representor":rep,"filters":json.loads(subprocess.check_output(
        ["tc","-s","-d","-j","filter","show","dev",rep,"ingress"]))} for idx,rep in reps.items()}
    print(json.dumps(result))
PYGUEST
    ;;
  stats|flows)
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/$ACTION"
    ;;
  ovs-evidence)
    dev=$(pf_netdev)
    printf 'HWOL='; ovs-vsctl --timeout=5 get Open_vSwitch . other_config:hw-offload
    ovs-vsctl --timeout=5 show
    ovs-appctl dpctl/dump-flows --names type=offloaded
    while read -r d; do [[ -z $d ]] || tc -s -d -j filter show dev "$d" ingress; done < <(reps)
    ;;
  collect)
    date -Is; uname -a; lspci -Dnnk -s "$PF_BDF"
    ip -d link; devlink -j port show; devlink dev eswitch show "pci/$PF_BDF" || true
    ovs-vsctl --timeout=5 show 2>/dev/null || true
    ovs-appctl dpctl/dump-flows --names type=offloaded 2>/dev/null || true
    while read -r d; do [[ -z $d ]] || tc -s -d -j filter show dev "$d" ingress; done < <(reps)
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/stats" 2>/dev/null || true
    cat "/sys/kernel/debug/mock_smartnic/$PF_BDF/flows" 2>/dev/null || true
    dmesg --level=emerg,alert,crit,err,warn | tail -n 150
    ;;
  *) fail "Unknown guest action: $ACTION" ;;
esac
