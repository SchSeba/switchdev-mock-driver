#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
cluster_guard; mutation_guard
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require dedicated PF acknowledgements.'
k -n "$OPERATOR_NAMESPACE" get sriovnetworknodestate "$NODE_NAME" -o json | jq -e '
 .status.syncStatus=="Succeeded" and ((.spec.interfaces//[])|length==0) and ((.status.bridges.ovs//[])|length==0)' >/dev/null || die 'Clean up operator policy/bridge before manual kernel stress.'
[[ $(k -n "$WORKLOAD_NAMESPACE" get pods -l app.kubernetes.io/part-of=mock-smartnic-lab -o json | jq '.items|length') == 0 ]] || die 'Remove assigned pods first.'
rsync -a --timeout=60 -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10' "$ROOT/tests/integration/kernel-stress.py" "$SSH_TARGET:$REMOTE_DIR/src/kernel-stress.py"
remote sudo -n python3 "$REMOTE_DIR/src/kernel-stress.py" "$PF_BDF"
