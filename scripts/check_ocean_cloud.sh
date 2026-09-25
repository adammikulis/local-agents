#!/usr/bin/env bash
# BULK WATER IS NOT CLOUD: condensate is liquid or ice hanging in a cell mostly gas that no floor holds.
# Arm 1: one column on the device classes rock, water and a band 0, cloud over the band 1, higher 2.
# Arm 2: a slice wholly under the settled water, at the gravity rung, reads no cloud or fog over its ocean.
# Mutation: state_derive.glsl's classifier writes 0 (arm 1), or AirRows.gd drops its air_class gate (arm 2).
# EXIT 0 condensate is classed where it hangs · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_rung.sh"
require_tool python3

PROBE="addons/local_agents/tests/gate_air_class.gd"
[ -f "$ROOT/$PROBE" ] || { echo "check_ocean_cloud: $PROBE is missing." >&2; exit 2; }
LOG="$(mktemp "${TMPDIR:-/tmp}/la_air_class.XXXXXX")"
trap 'rm -f "$LOG"' EXIT INT TERM
LA_DONE_RE='^AIR_CLASS=' "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" -s "res://$PROBE" > "$LOG" 2>&1
line="$(grep -m1 '^AIR_CLASS=' "$LOG")"
if [ -z "$line" ]; then
	echo "check_ocean_cloud: the column probe published no AIR_CLASS line." >&2
	tail -20 "$LOG" >&2
	exit 2
fi
echo "$line"
fails="$(printf '%s' "$line" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read().split("=", 1)[1])["failures"])')"
if [ "$fails" != "0" ]; then
	grep '^gate_air_class:' "$LOG" >&2
	[ "$fails" -lt 0 ] 2>/dev/null && exit 2
	echo "check_ocean_cloud: the column's condensate is classed wrong in $fails cell(s)." >&2
	exit 1
fi

BOX="0,site=sea,0,3,24,3,5120,10"
out="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice-box "$BOX" --rung 1 --frames 3 --keep \
	--report cloud_cells,fog_cells,wet_cells 2>&1)"
rc=$?
log="$(printf '%s\n' "$out" | sed -n 's/^sim_run: log kept at //p' | tail -1)"
site="$( [ -n "$log" ] && [ -f "$log" ] && grep -m1 -o '^SLICE_SITE=.*' "$log" | sed 's/^SLICE_SITE=//')"
[ -n "$log" ] && rm -f "$log"
la_rung_require "$out" cloud_cells fog_cells wet_cells || {
	echo "check_ocean_cloud: the ocean slice was not weighed (sim_run exit $rc)." >&2
	exit 2
}
if [ -z "$site" ]; then
	echo "check_ocean_cloud: the run published no SLICE_SITE for \"$BOX\", so no ocean was examined." >&2
	exit 2
fi
share="$(printf '%s' "$site" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["wet_share"])')"
cloud="$(la_rung_value "$out" cloud_cells)"
fog="$(la_rung_value "$out" fog_cells)"
wet="$(la_rung_value "$out" wet_cells)"
echo "OCEAN_CLOUD={\"site_wet_share\":$share,\"wet_cells\":$wet,\"cloud_cells\":$cloud,\"fog_cells\":$fog}"
if ! awk -v s="$share" -v w="$wet" 'BEGIN{exit !(s >= 1.0 && w > 0)}'; then
	echo "check_ocean_cloud: the box is not wholly under water or holds no wet cell, so there was no ocean" >&2
	echo "                  to misread and the zero below proves nothing." >&2
	exit 2
fi
if ! awk -v c="$cloud" -v f="$fog" 'BEGIN{exit !(c == 0 && f == 0)}'; then
	echo "check_ocean_cloud: an ocean slice with no condensate in its air reads $cloud cloud and $fog fog" >&2
	echo "                  cells: the rows count bulk water as cloud." >&2
	exit 1
fi
echo "check_ocean_cloud: OK ($wet wet cells, no cloud or fog over the ocean)"
