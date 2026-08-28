#!/usr/bin/env bash
# THE GRID FITS ITS DECLARED BUDGET AND SAYS WHAT IT REACHED. The capture's world publishes grid_cells,
# grid_max_level and grid_target_edge_m; the count may not pass docs/CELL_BUDGET.
# EXIT 0 fits · 1 over budget · 2 nothing published, so nothing was examined.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
command -v python3 >/dev/null 2>&1 || { echo "check_cell_budget: python3 absent." >&2; exit 2; }
CAP="$(rg -N -o '^[0-9]+$' "$ROOT/docs/CELL_BUDGET" 2>/dev/null | head -1)"
[ -n "$CAP" ] || { echo "check_cell_budget: docs/CELL_BUDGET carries no number." >&2; exit 2; }
out="$(la_report_raw --path "$ROOT" --frames "${LA_BUDGET_FRAMES:-2}" 2>/dev/null)"
[ -n "$out" ] || { echo "check_cell_budget: the run published no SIM_REPORT." >&2; exit 2; }
CAP="$CAP" printf '%s' "$out" | python3 -c '
import json, os, sys
rep = json.loads(sys.stdin.read())
def look(k):
    if k in rep: return rep[k]
    for s in ("gauges", "events"):
        b = rep.get(s)
        if isinstance(b, dict) and k in b: return b[k]
    return None
def scalar(v):
    if isinstance(v, dict): v = v.get("cur", v.get("value"))
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
cells = scalar(look("grid_cells")); lvl = scalar(look("grid_max_level")); edge = scalar(look("grid_target_edge_m"))
if cells is None or lvl is None or edge is None:
    print("check_cell_budget: the world published no grid_cells/grid_max_level/grid_target_edge_m.", file=sys.stderr); raise SystemExit(2)
cap = int(os.environ["CAP"])
print("CELL_BUDGET={\"cells\":%d,\"budget\":%d,\"max_level\":%d,\"target_edge_m\":%g}" % (cells, cap, lvl, edge))
if cells > cap:
    print("check_cell_budget: FAILED, %d cells against a budget of %d." % (cells, cap), file=sys.stderr); raise SystemExit(1)
print("check_cell_budget: OK")
'
