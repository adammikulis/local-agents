#!/usr/bin/env bash
# A PLANET AT REST DOES NOT BLOW ITSELF SUPERSONIC. Nothing drives this world but pressure and gravity,
# which cancel at hydrostatic balance, so a wind past the substrate's OWN sound speed is the discrete
# imbalance accelerating matter. Both numbers are the substrate's: no threshold is invented here.
#
# EXIT 0 subsonic · 1 not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

LOG="$(mktemp "${TMPDIR:-/tmp}/la_wind.XXXXXX")"
LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-120}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
	-- --sandbox --rung=3 "--run-frames=${LA_WIND_FRAMES:-12}" --seed=4242 --planet-only --no-fauna \
	> "$LOG" 2>&1 || true

read -r WIND CEL NF <<EOF
$(rg -N -o 'SIM_REPORT=.*' "$LOG" | tail -1 | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read()[len('SIM_REPORT='):])['gauges']
    print(d['wind_speed_max']['max'], d['celerity_max']['max'], d['nonfinite_cells']['max'])
except Exception:
    print('', '', '')
")
EOF
case "${WIND:-}${CEL:-}${NF:-}" in "" ) echo "check_wind_subsonic: the run published no wind_speed_max/celerity_max/nonfinite_cells." >&2; exit 2 ;; esac
[ -n "$WIND" ] && [ -n "$CEL" ] && [ -n "$NF" ] || { echo "check_wind_subsonic: the run published no wind_speed_max/celerity_max/nonfinite_cells." >&2; exit 2; }
# A MACH NUMBER OFF A POISONED FIELD IS TWO FICTIONS DIVIDED. Both readings are the substrate's, so a
# run that put a NaN or an infinity in any cell says nothing about either, whatever their ratio is.
if ! awk -v n="$NF" 'BEGIN{exit !(n == 0)}'; then
	echo "check_wind_subsonic: the run left non-finite state in the field, so neither the wind nor the" >&2
	echo "                     sound speed is a reading. Their ratio is not a verdict." >&2
	exit 1
fi

awk -v w="$WIND" -v c="$CEL" 'BEGIN {
	if (c <= 0) { print "check_wind_subsonic: celerity_max is not positive; no sound speed to compare against." > "/dev/stderr"; exit 2 }
	if (w > c) {
		printf "check_wind_subsonic: peak wind %.6g m/s against a sound speed of %.6g (Mach %.4g).\n", w, c, w/c > "/dev/stderr"
		printf "                     Nothing drives this world but pressure and gravity, and at balance they cancel.\n" > "/dev/stderr"
		exit 1
	}
	printf "check_wind_subsonic: OK (peak wind %.6g m/s, sound speed %.6g)\n", w, c
}'
