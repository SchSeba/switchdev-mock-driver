#!/usr/bin/env bash
# Shared by first bind, restore, and boot. Callers provide fail() and SSH_PEER.
not_used() {
  local dev=$1 route br addresses v4 v6
  [[ ! -L /sys/class/net/$dev/master ]] || fail "$dev belongs to a bridge/bond/VRF."
  ! compgen -G "/sys/class/net/$dev/upper_*" >/dev/null || fail "$dev has an upper device."
  addresses=$(ip -o addr show dev "$dev" scope global) || fail "Cannot inspect addresses on $dev."
  [[ -z $addresses ]] || fail "$dev has a global IP address."
  v4=$(ip route show default dev "$dev") || fail "Cannot inspect IPv4 routes on $dev."
  v6=$(ip -6 route show default dev "$dev") || fail "Cannot inspect IPv6 routes on $dev."
  [[ -z $v4 && -z $v6 ]] || fail "$dev carries a default route."
  if [[ -n ${SSH_PEER:-} ]]; then
    route=$(ip route get "$SSH_PEER" 2>/dev/null || ip -6 route get "$SSH_PEER" 2>/dev/null) || fail 'Cannot resolve the SSH peer route.'
    [[ " $route " != *" dev $dev "* ]] || fail "$dev carries the SSH connection."
  fi
  # Boot runs before OVS; no live OVS ports exist then. All other binds check OVSDB.
  if [[ ${2:-} != boot ]] && command -v ovs-vsctl >/dev/null; then
    ovs-vsctl --timeout=3 show >/dev/null 2>&1 || fail "Cannot verify OVS ownership of $dev: OVSDB is unavailable."
    br=$(ovs-vsctl --timeout=3 iface-to-br "$dev" 2>/dev/null || true)
    [[ -z $br ]] || fail "$dev belongs to OVS bridge $br. Clean up its owner first."
  fi
}
