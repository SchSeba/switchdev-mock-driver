#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh; do bash -n "$f"; done
python3 -m py_compile "$ROOT"/scripts/*.py "$ROOT"/tests/test_harness.py
python3 -m unittest discover -s "$ROOT/tests" -v
echo 'Local harness checks passed; this does not validate a kernel module or VM.'
