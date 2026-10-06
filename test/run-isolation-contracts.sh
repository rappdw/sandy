#!/usr/bin/env bash
# Neutral host projection and Linux-container execution tests; no model/API calls.
set -euo pipefail
ISOLATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISOLATION_VENV="$(mktemp -d)"
trap 'rm -rf "$ISOLATION_VENV"' EXIT
python3 -m venv "$ISOLATION_VENV"
"$ISOLATION_VENV/bin/python" -m pip install --quiet pytest
"$ISOLATION_VENV/bin/python" -m pytest -q \
  "$ISOLATION_ROOT/test/test_submounts.py" "$ISOLATION_ROOT/test/test_managed_exec.py"
