#!/usr/bin/env bash
# THE SLICE REACHES THE FINEST EDGE IT DECLARES, GRADED, INSIDE THE BUDGET. A box on the surface refines
# toward its spec's eighth field: the finest level must be populated, the coarsest must still be there
# (the box faces stay level 0), and the leaf count may not pass docs/CELL_BUDGET. A grid that is uniform
# resolves nothing at the surface; one that is fine everywhere does not fit the machine.
# EXIT 0 graded * 1 not graded, or over budget * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool python3

# THE BOX THE LADDER AND THE DEMO ACTUALLY RUN, from its one declaration in sim_run.sh.
BOX="$("$ROOT/scripts/sim_run.sh" --print-slice-box)"
case "$BOX" in
	*,*,*,*,*,*,*,*) ;;
	*) echo "check_slice_grading: the default slice box \"$BOX\" has no eighth field, so it declares no" >&2
	   echo "                     finest edge and nothing refines toward one." >&2
	   exit 1 ;;
esac
FINE="${BOX##*,}"

CAP="$(rg -N -o '^[0-9]+$' "$ROOT/docs/CELL_BUDGET" 2>/dev/null | head -1)"
[ -n "$CAP" ] || { echo "check_slice_grading: docs/CELL_BUDGET carries no number." >&2; exit 2; }

ERR="$(mktemp "${TMPDIR:-/tmp}/la_slice_grading.XXXXXX")"
out="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --slice-box "$BOX" --rung 0 --frames 1 --raw 2>"$ERR")"
rc=$?
if [ -z "$out" ]; then
	echo "check_slice_grading: the slice published no SIM_REPORT (sim_run exit $rc), so nothing was" >&2
	echo "                     examined." >&2
	tail -20 "$ERR" >&2
	rm -f "$ERR"
	exit 2
fi
rm -f "$ERR"

printf '%s' "$out" | FINE="$FINE" CAP="$CAP" BOX="$BOX" python3 -c '
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
cells = scalar(look("grid_cells"))
fine_edge = scalar(look("grid_fine_edge_m"))
counts = look("grid_level_counts")
if cells is None or fine_edge is None or not isinstance(counts, list) or not counts:
    print("check_slice_grading: the slice published no grid_cells / grid_fine_edge_m / grid_level_counts,",
          file=sys.stderr)
    print("                     so the grading was never read.", file=sys.stderr)
    raise SystemExit(2)
want = float(os.environ["FINE"])
cap = int(os.environ["CAP"])
coarsest, finest = int(counts[0]), int(counts[-1])
print("SLICE_GRADING={\"box\":\"%s\",\"cells\":%d,\"budget\":%d,\"fine_edge_m\":%g,\"declared_fine_m\":%g,"
      "\"level_counts\":%s}" % (os.environ["BOX"], cells, cap, fine_edge, want, json.dumps(counts)))
fail = 0
if abs(fine_edge - want) > 1e-6 * want:
    print("check_slice_grading: the grid reached %g m, and the box declares %g m. The refinement stopped"
          % (fine_edge, want), file=sys.stderr)
    print("                     short of the edge the spec asks for.", file=sys.stderr)
    fail = 1
if cells > cap:
    print("check_slice_grading: %d cells against a budget of %d." % (cells, cap), file=sys.stderr)
    fail = 1
if finest <= 0:
    print("check_slice_grading: the finest level holds no cells, so the box is not refined at the ground.",
          file=sys.stderr)
    fail = 1
if coarsest <= 0:
    print("check_slice_grading: level 0 holds no cells, so the box faces are not the coarsest and the",
          file=sys.stderr)
    print("                     exterior no longer meets them one to one.", file=sys.stderr)
    fail = 1
if len(counts) < 2:
    print("check_slice_grading: the grid carries one level, so nothing is graded.", file=sys.stderr)
    fail = 1
raise SystemExit(1 if fail else 0)
'
rc=$?
[ "$rc" -eq 0 ] && echo "check_slice_grading: OK"
exit $rc
