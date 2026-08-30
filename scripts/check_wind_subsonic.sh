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

read -r MACH MASS NF <<EOF
$(rg -N -o 'SIM_REPORT=.*' "$LOG" | tail -1 | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read()[len('SIM_REPORT='):])['gauges']
    print(d['mach_max']['max'], d['momentum_mass_kg']['max'], d['nonfinite_cells']['max'])
except Exception:
    print('', '', '')
")
EOF
[ -n "${MACH:-}" ] && [ -n "${MASS:-}" ] && [ -n "${NF:-}" ] || { echo "check_wind_subsonic: the run published no mach_max/momentum_mass_kg/nonfinite_cells." >&2; exit 2; }
# A MACH NUMBER OFF A POISONED FIELD IS TWO FICTIONS DIVIDED. Both readings are the substrate's, so a
# run that put a NaN or an infinity in any cell says nothing about either, whatever their ratio is.
if ! awk -v n="$NF" 'BEGIN{exit !(n == 0)}'; then
	echo "check_wind_subsonic: the run left non-finite state in the field, so neither the wind nor the" >&2
	echo "                     sound speed is a reading. Their ratio is not a verdict." >&2
	exit 1
fi

awk -v m="$MACH" -v k="$MASS" 'BEGIN {
	if (k <= 0) { print "check_wind_subsonic: no open cell holds matter; no sound speed to compare against." > "/dev/stderr"; exit 2 }
	if (!(m <= 1)) {
		printf "check_wind_subsonic: a cell outran its own sound speed (mach_max %.4g).\n", m > "/dev/stderr"
		printf "                     Nothing drives this world but pressure and gravity, and at balance they cancel.\n" > "/dev/stderr"
		exit 1
	}
	printf "check_wind_subsonic: OK (mach_max %.4g)\n", m
}'
