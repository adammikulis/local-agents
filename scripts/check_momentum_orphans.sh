#!/usr/bin/env bash
# MOMENTUM MOVES WITH ITS MASS. A cell holding momentum and no matter is a scheme defect: the mass
# and the momentum crossed different faces. state_derive.glsl flags it per cell and the
# momentum_orphan_cells row counts the flags; the count must read exactly 0.
# EXIT 0 no orphan · 1 an orphan · 2 the row is absent, so nothing was measured.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_capture.sh"
command -v python3 >/dev/null 2>&1 || { echo "check_momentum_orphans: python3 absent." >&2; exit 2; }
[ -x "$ROOT/scripts/sim_run.sh" ] || { echo "check_momentum_orphans: no scripts/sim_run.sh." >&2; exit 2; }
out="$(la_report_raw --path "$ROOT" --frames "${LA_ORPHAN_FRAMES:-20}" 2>/dev/null)"
[ -n "$out" ] || { echo "check_momentum_orphans: the run published no SIM_REPORT." >&2; exit 2; }
printf '%s' "$out" | python3 -c '
import json, sys
try:
    rep = json.loads(sys.stdin.read())
except Exception as e:
    print("check_momentum_orphans: the report did not parse (%s)." % e, file=sys.stderr); raise SystemExit(2)
def look(key):
    if key in rep:
        return rep[key]
    for sub in ("gauges", "events"):
        b = rep.get(sub)
        if isinstance(b, dict) and key in b:
            return b[key]
    return None
def scalar(v):
    if isinstance(v, dict):
        v = v.get("cur", v.get("value"))
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
cells = scalar(look("field_cells"))
if cells is None or cells <= 0:
    print("check_momentum_orphans: the run reports no field cells.", file=sys.stderr); raise SystemExit(2)
n = scalar(look("momentum_orphan_cells"))
if n is None:
    print("check_momentum_orphans: no momentum_orphan_cells row in the report; the detector did not run.", file=sys.stderr)
    raise SystemExit(2)
if n != 0:
    print("check_momentum_orphans: FAILED — momentum_orphan_cells=%r: momentum sits in cells holding no matter." % n, file=sys.stderr)
    raise SystemExit(1)
print("check_momentum_orphans: OK (no open cell carries momentum without mass)")
'
