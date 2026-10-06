#!/usr/bin/env bash
# Explicit CI layers; privileged lanes require the authorized external lab.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
lane=${1:-local}
mkdir -p "$ROOT/artifacts/ci"
skip() {
 printf 'SKIP: %s\n' "$1" >&2
 printf '{"lane":"%s","passed":null,"skipped":true}\n' "$lane" > "$ROOT/artifacts/ci/$lane.json"
 exit 77
}
case $lane in
 local) "$ROOT/scripts/run-local-checks.sh" ;;
 vm)
  [[ -f ${LAB_CONFIG:-$ROOT/config/lab.env} ]] || skip 'No explicit VM configuration; no PCI/TC runtime result.'
  source "$ROOT/scripts/lib/common.sh"
  cluster_guard; mutation_guard
  k -n "$OPERATOR_NAMESPACE" get sriovnetworknodestate "$NODE_NAME" -o json | jq -e '((.spec.interfaces//[])|length==0)' >/dev/null || die 'Clean up operator ownership before the VM lane.'
  "$ROOT/scripts/lab.sh" operator-preflight
  "$ROOT/tests/integration/pci-lifecycle.sh"
  "$ROOT/tests/integration/devlink-lifecycle.sh"
  "$ROOT/scripts/lab.sh" vfs
  "$ROOT/tests/integration/flower-engine.sh"
  "$ROOT/scripts/lab.sh" tc-smoke
  "$ROOT/tests/integration/ovs-offload.sh"
  "$ROOT/scripts/lab.sh" reset
  ;;
 kubernetes)
  [[ -f ${LAB_CONFIG:-$ROOT/config/lab.env} ]] || skip 'No explicit cluster configuration; no operator/CNI runtime result.'
  "$ROOT/scripts/kube.sh" apply
  "$ROOT/scripts/kube.sh" verify
  "$ROOT/scripts/kube.sh" collect
  ;;
 openshift) skip 'Optional immutable-host/signing/MCO lane requires its own explicitly configured lab; not tested here.' ;;
 *) printf 'Usage: ci.sh local|vm|kubernetes|openshift\n' >&2;exit 2 ;;
esac
printf '{"lane":"%s","passed":true,"skipped":false}\n' "$lane" > "$ROOT/artifacts/ci/$lane.json"
