#!/usr/bin/env bash
# Dependencies for a mutable guest, matching the RUNNING kernel exactly.
set -Eeuo pipefail
[[ ${1:-} == --install && $EUID == 0 ]] || { echo 'Usage: sudo bootstrap-guest.sh --install' >&2; exit 1; }
[[ ! -e /run/ostree-booted ]] || { echo 'Immutable OS: provide a signed kernel-matched module image.' >&2; exit 1; }
source /etc/os-release
missing=false
for tool in gcc make ip ethtool lspci modinfo jq python3 rsync ping devlink; do
  command -v "$tool" >/dev/null || missing=true
done
[[ -d /lib/modules/$(uname -r)/build ]] || missing=true
case "$ID" in
  ubuntu|debian)
    if $missing; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential "linux-headers-$(uname -r)" \
        iproute2 ethtool pciutils kmod jq python3 rsync iputils-ping
    fi
    if ! command -v ovs-vsctl >/dev/null; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch
    fi
    ovs_service=openvswitch-switch
    ;;
  fedora|rhel|centos|rocky|almalinux)
    if $missing; then
      # Archived signed headers for the tested CentOS kernel; no kernel upgrade.
      devel="kernel-devel-$(uname -r)"
      if [[ $ID == centos && $(uname -r) == 5.14.0-427.el9.x86_64 ]]; then
        devel=https://kojihub.stream.centos.org/kojifiles/packages/kernel/5.14.0/427.el9/data/signed/8483c65d/x86_64/kernel-devel-5.14.0-427.el9.x86_64.rpm
      fi
      dnf --setopt=localpkg_gpgcheck=1 install -y gcc make elfutils-libelf-devel "$devel" \
        iproute ethtool pciutils kmod jq python3 rsync iputils
    fi
    if ! command -v ovs-vsctl >/dev/null; then
      ovs_package=openvswitch
      if [[ $ID == centos && $VERSION_ID == 9 ]]; then
        dnf install -y centos-release-nfv-openvswitch
        ovs_package=openvswitch3.5
      fi
      dnf install -y "$ovs_package"
    fi
    ovs_service=openvswitch
    ;;
  *) echo "Unsupported dependency mapping for $ID; install tools and OVS manually." >&2; exit 1 ;;
esac
[[ -d /lib/modules/$(uname -r)/build ]]
systemctl enable "$ovs_service"
systemctl is-active --quiet "$ovs_service" || systemctl start "$ovs_service"
ovs-vsctl --timeout=10 show
