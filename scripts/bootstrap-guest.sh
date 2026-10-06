#!/usr/bin/env bash
# Optional mutable-guest dependency install. Explicit --install required.
set -Eeuo pipefail
[[ ${1:-} == --install && $EUID == 0 ]] || { echo 'Usage: sudo bootstrap-guest.sh --install' >&2; exit 1; }
[[ ! -e /run/ostree-booted ]] || { echo 'Immutable OS: use kernel-matched build/module delivery; do not install host build packages.' >&2; exit 1; }
source /etc/os-release
case "$ID" in
  ubuntu|debian)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential "linux-headers-$(uname -r)" \
      iproute2 ethtool pciutils kmod jq python3 rsync openvswitch-switch iputils-ping
    ;;
  fedora|rhel|centos|rocky|almalinux)
    dnf install -y gcc make elfutils-libelf-devel "kernel-devel-$(uname -r)" \
      iproute ethtool pciutils kmod jq python3 rsync openvswitch iputils
    ;;
  *) echo "Unsupported automatic package mapping for $ID; install the listed dependencies manually." >&2; exit 1 ;;
esac
[[ -d /lib/modules/$(uname -r)/build ]]
echo 'Installed build/network tools. Inspect and explicitly start the appropriate OVS service in the dedicated lab.'
echo 'No kernel upgrade, security bypass, PF rebind, or intentional reboot was performed.'
