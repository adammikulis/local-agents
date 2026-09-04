#!/usr/bin/env bash
# THE REGOLITH IS WET ACCORDING TO WHERE IT IS, NOT TO THE PLANET'S TOTAL. Two boxes over different
# ground are seeded, and the share of their regolith cells holding pore water must differ: a water table
# is a level, so one box is wetter than the other and neither is uniformly saturated. A seed spreading
# the body's whole groundwater over whatever pore space its box holds reads the same everywhere.
# EXIT 0 local * 1 alike, or every cell wet * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

# Two boxes of the same size, a quarter turn apart on the body: same spec, different ground.
CELLS="3,24,3"
EDGES="5120,640"
OFFSETS="0,surface,0 surface,0,0"

# $1 the box spec. Prints "regolith_cells regolith_wet_cells", or nothing.
share() {
	local err out
	err="$(mktemp "${TMPDIR:-/tmp}/la_gw.XXXXXX")"
	out="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --slice-box "$1" --rung 1 --frames 1 --raw 2>"$err")"
	if [ -z "$out" ]; then
		echo "check_groundwater_local: the box \"$1\" published no SIM_REPORT." >&2
		tail -20 "$err" >&2
		rm -f "$err"
		return 2
	fi
	rm -f "$err"
	printf '%s' "$out" | python3 -c '
import json, sys
rep = json.loads(sys.stdin.read())
def look(k):
    if k in rep: return rep[k]
    for s in ("gauges", "events"):
        b = rep.get(s)
        if isinstance(b, dict) and k in b: return b[k]
    return None
n, w = look("regolith_cells"), look("regolith_wet_cells")
if not isinstance(n, int) or not isinstance(w, int) or n <= 0:
    print("check_groundwater_local: the box published no regolith_cells / regolith_wet_cells, so the",
          file=sys.stderr)
    print("                         water table was never read.", file=sys.stderr)
    raise SystemExit(2)
print("%d %d" % (n, w))
'
}

READINGS=""
for off in $OFFSETS; do
	spec="${off},${CELLS},${EDGES}"
	r="$(share "$spec")" || exit 2
	read -r n w <<EOF
$r
EOF
	echo "GROUNDWATER_LOCAL={\"box\":\"$spec\",\"regolith_cells\":$n,\"regolith_wet_cells\":$w}"
	READINGS="$READINGS $n:$w"
done

printf '%s\n' "$READINGS" | python3 -c '
import sys
pairs = [p for p in sys.stdin.read().split() if ":" in p]
if len(pairs) < 2:
    print("check_groundwater_local: fewer than two boxes were read.", file=sys.stderr)
    raise SystemExit(2)
shares = []
for p in pairs:
    n, w = (int(x) for x in p.split(":"))
    shares.append(w / n)
fail = 0
if max(shares) - min(shares) <= 0.0:
    print("check_groundwater_local: every box holds the same saturated share, so the seed did not read", file=sys.stderr)
    print("                         the ground under it. A water table is a level, not a fraction.", file=sys.stderr)
    fail = 1
if min(shares) >= 1.0:
    print("check_groundwater_local: every regolith cell in every box is saturated, so no box has a water", file=sys.stderr)
    print("                         table inside it and the rock above it is not dry.", file=sys.stderr)
    fail = 1
raise SystemExit(1 if fail else 0)
'
rc=$?
[ "$rc" -eq 0 ] && echo "check_groundwater_local: OK"
exit $rc
