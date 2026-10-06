#!/usr/bin/env bash
# Test the patched operator renderer through the guest's actual systemd parser.
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
mutation_guard
[[ -d ${OPERATOR_SOURCE:-}/.git ]] || die 'Set the pinned OPERATOR_SOURCE.'
[[ $(git -C "$OPERATOR_SOURCE" rev-parse HEAD) == "$OPERATOR_REF" ]] || die 'Wrong operator source.'
OUT="$ROOT/artifacts/ovs-unit-render-k08.conf"
(cd "$OPERATOR_SOURCE"; MOCK_OVS_UNIT_OUT="$OUT" go test ./pkg/host/internal/service -run '^TestOVSUnitArguments$' -count=1)
remote sudo -n tee "$REMOTE_DIR/ovs-unit-test.conf" < "$OUT" >/dev/null
remote sudo -n bash -s -- "$REMOTE_DIR" <<'GUEST'
set -Eeuo pipefail
base=$1
unit=mock-smartnic-ovs-unit-test.service
file=/run/systemd/system/$unit
[[ ! -e $file && ! -e $base/ovs-unit-stub.py ]]
cleanup() {
 systemctl stop "$unit" || true
 rm -f "$file" "$base/ovs-unit-stub.py" "$base/ovs-unit-argv.jsonl" "$base/ovs-unit-test.conf"
 systemctl daemon-reload
 systemctl reset-failed "$unit" 2>/dev/null || true
}
trap cleanup EXIT
cat > "$base/ovs-unit-stub.py" <<'PY'
#!/usr/bin/python3
import json,sys
from pathlib import Path
p=Path(__file__).with_name('ovs-unit-argv.jsonl')
with p.open('a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
if 'get' in sys.argv: print('"old-owned-key"')
PY
chmod 755 "$base/ovs-unit-stub.py"
python3 - "$base" "$file" <<'PY'
import sys
from pathlib import Path
base=Path(sys.argv[1]); text=(base/'ovs-unit-test.conf').read_text()
text=text.replace('/bin/ovs-vsctl',str(base/'ovs-unit-stub.py')).replace('ExecStartPre=', 'ExecStart=')
Path(sys.argv[2]).write_text('[Unit]\nDescription=Owned OVS argument regression\n'+text+'\nType=oneshot\nRemainAfterExit=yes\nTimeoutStartSec=20\n')
PY
systemd-analyze verify "$file"
systemctl daemon-reload
timeout 30 systemctl start "$unit"
python3 - "$base/ovs-unit-argv.jsonl" <<'PY'
import json,sys
from pathlib import Path
rows=[json.loads(x) for x in Path(sys.argv[1]).read_text().splitlines()]
assert rows[1]==['--no-wait','remove','Open_vSwitch','.','other_config','old-owned-key'],rows
assert rows[2][-1]=='external_ids:sriov-operator-owned-keys=hw-offload tc-policy test-value',rows
expected=['--no-wait','set','Open_vSwitch','.','other_config:hw-offload=true','other_config:tc-policy=none',
 'other_config:test-value=$NOT_AN_ENV; $(exit 73); `exit 74`; %n " \\']
assert rows[3]==expected,rows
assert len(rows)==4,rows
print('PASS: native systemd parsing, owned-key cleanup, literal quotes/dollar/backtick/percent/backslash arguments')
PY
GUEST
