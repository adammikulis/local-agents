#!/usr/bin/env bash
# THE DEMO'S BOX STANDS ON A COAST, read off the shared capture's slice arm (a hand run launches its own).
# THE SITE RULE holds the reading: the shoreline runs ACROSS the footprint, a row of its sampling grid
# each side, and the land rises over the line by more than the finest cell.
# Mutation: LA_SITE_BOX="0,surface,0,3,24,3,5120,10" stands the box on the pole and this goes red.
# EXIT 0 the box stands on a coast * 1 it does not * 2 the gate could not run * 3 the capture is the body.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_capture.sh"
require_tool rg
require_tool python3

DECLARED="$("$ROOT/scripts/sim_run.sh" --print-slice-box)"
BOX="${LA_SITE_BOX:-$DECLARED}"
LOG=""
if [ -z "${LA_SITE_BOX:-}" ] && la_cap_dir > /dev/null; then
	arm="$(la_cap_arm)" || { echo "check_slice_site: the capture names no arm." >&2; exit 2; }
	case "$arm" in
		*'"slice":null'*)
			echo "LINT_NOT_EXAMINED: check_slice_site reads a slice arm's site; the capture is the whole body"
			exit 3 ;;
	esac
	captured="$(printf '%s' "$arm" | sed -n 's/.*"slice":"\([^"]*\)".*/\1/p')"
	if [ "$captured" != "$DECLARED" ]; then
		echo "check_slice_site: the capture resolved the site of box \"$captured\" and this tree declares" >&2
		echo "                  \"$DECLARED\", so the site it read is not the demo's." >&2
		exit 1
	fi
	SITE="$(la_marker '^SLICE_SITE=')" || exit 2
else
	LOG="$(mktemp "${TMPDIR:-/tmp}/la_slice_site.XXXXXX")"
	trap 'rm -f "$LOG"' EXIT
	LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_SITE_TIMEOUT:-100}" \
		"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
		addons/local_agents/game/VoxelWorld.tscn \
		-- --sandbox --planet-only --no-fauna --rung=0 --run-frames=1 > "$LOG" 2>&1
	SITE="$(rg -N -o '^SLICE_SITE=.*' "$LOG" | head -1)"
fi
if [ -z "$SITE" ]; then
	echo "check_slice_site: the run published no SLICE_SITE for \"$BOX\", so the box resolved to no site" >&2
	echo "                  and nothing was examined." >&2
	[ -z "$LOG" ] || tail -25 "$LOG" >&2
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
