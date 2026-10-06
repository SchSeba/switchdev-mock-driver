#!/usr/bin/env bash
# Local helpers. Configuration is an explicitly user-maintained, trusted shell file.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Required command missing: $1"; }
CONFIG=${LAB_CONFIG:-"$ROOT/config/lab.env"}
[[ -f "$CONFIG" ]] || die "Copy config/lab.env.example to config/lab.env first."
set -a
# shellcheck disable=SC1090
source "$CONFIG"
set +a
SRC_ROOT=${SRC_ROOT:-$ROOT}
WAIT_SECONDS=${WAIT_SECONDS:-900}
REMOTE_TIMEOUT=${REMOTE_TIMEOUT:-600}
[[ ${PF_BDF:-} =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || die 'Invalid PF_BDF'
[[ ${NUM_VFS:-} =~ ^[0-9]+$ ]] && ((NUM_VFS >= 2 && NUM_VFS <= 7)) || die 'Use 2..7 VFs for the igb prototype.'
[[ ${REMOTE_DIR:-} =~ ^/[a-zA-Z0-9_./-]+$ && $REMOTE_DIR != / && $REMOTE_DIR != /var && $REMOTE_DIR != /var/tmp && $REMOTE_DIR != *..* ]] || die 'Use a dedicated absolute REMOTE_DIR without spaces or ..'
[[ ${SSH_TARGET:-} =~ ^[a-zA-Z0-9_@.:-]+$ && $SSH_TARGET != -* ]] || die 'Use an SSH config alias or user@host.'
[[ $WAIT_SECONDS =~ ^[0-9]+$ ]] || die 'WAIT_SECONDS must be an integer.'
[[ $REMOTE_TIMEOUT =~ ^[0-9]+$ ]] || die 'REMOTE_TIMEOUT must be an integer.'
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
remote() {
    local cmd
    printf -v cmd '%q ' "$@"
    need timeout
    timeout --foreground --kill-after=10 "$REMOTE_TIMEOUT" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
}
cluster_guard() {
    need "$KUBECTL"; need jq
    [[ -n ${KUBE_CONTEXT:-} && -n ${NODE_NAME:-} ]] || die 'Set KUBE_CONTEXT and NODE_NAME.'
    local active
    active=$("$KUBECTL" config current-context)
    [[ "$active" == "$KUBE_CONTEXT" ]] || die "Wrong Kubernetes context: $active"
    "$KUBECTL" --context "$KUBE_CONTEXT" get node "$NODE_NAME" >/dev/null
}
k() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; }
mutation_guard() {
    [[ ${CLUSTER_MUTATION_ACK:-} == YES ]] || die 'Set CLUSTER_MUTATION_ACK=YES for the dedicated test cluster.'
}
