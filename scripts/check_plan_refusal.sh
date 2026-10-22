#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log="$(mktemp "${TMPDIR:-/tmp}/la_plan_refusal.XXXXXX")"
trap 'rm -f "$log"' EXIT
LA_DONE_RE='^PLAN_REFUSAL:' "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" -s res://addons/local_agents/tests/gate_plan_refusal.gd > "$log" 2>&1
rc=$?
cat "$log"
[ "$rc" -eq 0 ] || exit "$rc"
grep -q '^PLAN_REFUSAL: OK$' "$log" || exit 2
python3 - "$log" <<'PY'
import re,sys
text=open(sys.argv[1],errors='replace').read()
expected=['LASubstances gives "fixed_n" no specific heat','LAFieldDriver: channel fert has no valid heat capacity']
errors=[line for line in text.splitlines() if re.match(r'^(SCRIPT )?ERROR:',line)]
if any(not any(message in line for message in expected) for line in errors):sys.exit(1)
if any(not any(message in line for line in errors) for message in expected):sys.exit(1)
print('check_plan_refusal: OK')
PY
