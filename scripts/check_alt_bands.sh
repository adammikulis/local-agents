#!/usr/bin/env bash
# THE ALTITUDE BANDS MUST BE ABLE TO DISAGREE. clim_alt<b>_min is the coldest open cell in one band of
# height above the SEA SHELL, and those edges only mean anything while state_derive.glsl measures `alt`
# from that shell. Write one value into `alt`, or push no sea radius, and every band admits the same
# cells or none, while each row still prints a number.

#   1. every band declared in HeatRows.ALT_BAND_FLOORS_M publishes its cell count
#   2. at least two bands hold cells, so the gate on `alt` separates the field
#   3. the populated bands do not all read the same minimum

# A band with no open cell publishes no minimum: an absent reading is not a cold one.
# EXIT 0 the bands separate · 1 they do not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"

ROWS="$ROOT/addons/local_agents/sim/material/reduce/HeatRows.gd"
[ -f "$ROWS" ] || { echo "check_alt_bands: MISSING $ROWS" >&2; exit 2; }
floors="$(rg -N -o -e 'ALT_BAND_FLOORS_M: Array = \[[^]]*\]' "$ROWS" | head -1)"
[ -n "$floors" ] || { echo "check_alt_bands: HeatRows.gd declares no ALT_BAND_FLOORS_M." >&2; exit 2; }
BANDS="$(( $(printf '%s' "$floors" | tr -cd ',' | wc -c | tr -d ' ') + 1 ))"
[ "$BANDS" -ge 2 ] || { echo "check_alt_bands: fewer than two bands declared; nothing can separate." >&2; exit 2; }

keys=""
b=0
while [ "$b" -lt "$BANDS" ]; do
	keys="${keys}clim_alt${b}_min,clim_alt${b}_n,"
	b=$((b + 1))
done
out="$(la_report "${keys%,}" --path "$ROOT" --frames "${LA_ALT_BAND_FRAMES:-20}" 2>&1)"
reading() { printf '%s\n' "$out" | sed -n "s/^$1  *= *//p" | head -1 | tr -d ' '; }
numeric() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }

populated=0
mins=""
empty=""
b=0
while [ "$b" -lt "$BANDS" ]; do
	n="$(reading "clim_alt${b}_n")"
	if ! numeric "$n"; then
		echo "ERROR: the run published no clim_alt${b}_n, so the band was never dispatched. Refusing to" >&2
		echo "       report a pass." >&2
		printf '%s\n' "$out" | tail -20 >&2
		exit 2
	fi
	m="$(reading "clim_alt${b}_min")"
	if [ "$n" -gt 0 ]; then
		if ! numeric "$m"; then
			echo "FAIL  band $b holds $n open cell(s) and published no minimum." >&2
			exit 1
		fi
		populated=$((populated + 1))
		mins="$mins $m"
	else
		empty="$empty $b"
		if numeric "$m"; then
			echo "FAIL  band $b holds no open cell and still published a minimum ($m)." >&2
			exit 1
		fi
	fi
	b=$((b + 1))
done

echo "ALT_BANDS={\"bands\":$BANDS,\"populated\":$populated,\"empty\":\"${empty# }\"}"
if [ "$populated" -lt 2 ]; then
	echo
	echo "Fewer than two altitude bands hold an open cell, so the gate on \`alt\` is not separating the"
	echo "field: every cell is landing in one band, or in none at all. Either state_derive.glsl is writing"
	echo "one value into \`alt\`, or no sea radius reached the push constant and every alt is NaN."
	exit 1
fi
distinct="$(printf '%s\n' $mins | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" -lt 2 ]; then
	echo
	echo "$populated altitude bands hold cells and every one of them reads the SAME minimum temperature."
	echo "Distinct heights above the sea shell cannot all be equally cold: the bands are reading one"
	echo "population, so the gate on \`alt\` is admitting the same cells to every band."
	exit 1
fi
echo "check_alt_bands: OK ($populated of $BANDS bands populated, $distinct distinct minima)"
