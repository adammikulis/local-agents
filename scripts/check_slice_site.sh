#!/usr/bin/env bash
# THE DEMO'S BOX STANDS ON A COAST. The run resolves the site against the terrain and reads the surface
# back over the footprint; THE SITE RULE holds that reading: the shoreline runs ACROSS the footprint,
# a row of its sampling grid each side, and the land rises over the line by more than the finest cell.
# Mutation: LA_SITE_BOX="0,surface,0,3,24,3,5120,10" stands the box on the pole and this goes red.
# EXIT 0 the box stands on a coast * 1 it does not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool python3

BOX="${LA_SITE_BOX:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_slice_site.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_SITE_TIMEOUT:-100}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn \
	-- --sandbox --planet-only --no-fauna --rung=0 --run-frames=1 > "$LOG" 2>&1

SITE="$(rg -N -o '^SLICE_SITE=.*' "$LOG" | head -1)"
if [ -z "$SITE" ]; then
	echo "check_slice_site: the run published no SLICE_SITE for \"$BOX\", so the box resolved to no site" >&2
	echo "                  and nothing was examined." >&2
	tail -25 "$LOG" >&2
	exit 2
fi
echo "$SITE"

printf '%s' "${SITE#SLICE_SITE=}" | python3 -c '
import json, sys
f = json.loads(sys.stdin.read())
if "land_m" not in f:
    print("check_slice_site: the run read no ground back under the site it chose, so the surface there",
          file=sys.stderr)
    print("                  was never examined.", file=sys.stderr)
    raise SystemExit(2)
land = float(f["land_m"])
depth = float(f["depth_m"])
fine = float(f["fine_m"])
share = float(f["sea_share"])
# A LINE CROSSING A SQUARE LEAVES A ROW OF THE GRID ON EACH SIDE; one that clips a corner does not. The
# bar is the sampling the reading was taken at, published beside it, so nothing here names a share.
edge = 1.0 / float(f["samples"])
fail = 0
if not land > fine:
    print("check_slice_site: the highest ground in the box footprint stands %g m over the waterline, and"
          % land, file=sys.stderr)
    print("                  the box resolves %g m: it carries no coast it can draw." % fine,
          file=sys.stderr)
    fail = 1
if not (depth > 0.0 and min(share, 1.0 - share) >= edge):
    print("check_slice_site: %.2f of the box footprint stands below the waterline against the %.2f a"
          % (share, edge), file=sys.stderr)
    print("                  shoreline crossing it leaves: the line clips a corner, and the demo",
          file=sys.stderr)
    print("                  promises a coast.", file=sys.stderr)
    fail = 1
raise SystemExit(1 if fail else 0)
' || exit $?

echo "check_slice_site: OK"
