#!/usr/bin/env bash
# Controller-side SSH harness; never disables host-key checking or transfers keys.
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"
need ssh; need rsync; need python3
ACTION=${1:-preflight}
case "$ACTION" in
  preflight|build|bind|vfs|pci-vfs|tc-smoke|reset|pci-reset|persist|unpersist|restore|collect|stats|flows|mapping|tc-json|ovs-evidence|operator-preflight) ;;
  *) die 'Usage: scripts/lab.sh preflight|build|bind|vfs|pci-vfs|tc-smoke|reset|pci-reset|persist|unpersist|restore|collect|stats|flows|mapping|tc-json|ovs-evidence|operator-preflight' ;;
esac
mkdir -p "$ROOT/artifacts"
RSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10"
remote mkdir -p "$REMOTE_DIR/harness/lib" "$REMOTE_DIR/src"
rsync -a --timeout=60 -e "$RSH" "$ROOT/scripts/guest.sh" "$ROOT/scripts/tc-smoke.sh" "$SSH_TARGET:$REMOTE_DIR/harness/"
rsync -a --timeout=60 -e "$RSH" "$ROOT/scripts/lib/pf-guard.sh" "$SSH_TARGET:$REMOTE_DIR/harness/lib/"
# Transfer only non-secret lab configuration; no kubeconfig or SSH credentials.
CFG=$(mktemp)
trap 'rm -f "$CFG"' EXIT
{
  for key in PF_BDF NUM_VFS EXPECTED_PF_VENDOR EXPECTED_PF_DEVICE EXPECTED_VF_DEVICE EMULATED_PF_ACK EXCLUSIVE_PF_ACK PERSISTENCE_ACK; do
    printf '%s=%q\n' "$key" "${!key:-}"
  done
  printf 'SOURCE_DIR=%q\n' "$REMOTE_DIR/src"
} > "$CFG"
rsync -a --timeout=60 -e "$RSH" "$CFG" "$SSH_TARGET:$REMOTE_DIR/harness/lab.env"
if [[ "$ACTION" == build ]]; then
  [[ -f "$SRC_ROOT/driver/Makefile" ]] || die 'driver/Makefile is missing: implement work package K01 first.'
  # No --delete. Exclude private local configuration and derived binaries.
  rsync -a --timeout=60 -e "$RSH" --exclude='.git/' --exclude='config/lab.env' --exclude='artifacts/' \
    --exclude='rendered/' --exclude='*.ko' --exclude='*.o' --exclude='*.cmd' \
    --exclude='*.mod*' --exclude='Module.symvers' --exclude='modules.order' \
    "$SRC_ROOT/driver/" "$SSH_TARGET:$REMOTE_DIR/src/driver/"
  remote bash "$REMOTE_DIR/harness/guest.sh" build | tee "$ROOT/artifacts/build.log"
else
  # The peer address lets the guest reject a PF carrying this SSH connection.
  CONN=$(remote bash -c 'printf "%s" "${SSH_CONNECTION:-}"')
  PEER=${CONN%% *}
  remote sudo -n bash "$REMOTE_DIR/harness/guest.sh" "$ACTION" "$PEER"
fi
