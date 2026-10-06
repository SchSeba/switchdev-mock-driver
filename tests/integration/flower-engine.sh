#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
[[ $EMULATED_PF_ACK == "$PF_BDF" && $EXCLUSIVE_PF_ACK == YES ]] || die 'Require exact PF and exclusive-use acknowledgements.'
rsync -a --timeout=60 -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10' \
  "$ROOT/tests/integration/flower-engine.py" "$SSH_TARGET:$REMOTE_DIR/src/flower-engine.py"
remote sudo -n python3 "$REMOTE_DIR/src/flower-engine.py" "$PF_BDF"
