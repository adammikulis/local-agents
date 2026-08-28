#!/usr/bin/env bash
# AN ATMOSPHERE AT REST, IN BALANCE, STAYS AT REST. A one-cell-wide column on the declared body's radius,
# every face shut, so its cell centres sit on the body axis and the solved gravity is exactly axial. The
# bar is the run's own: frames times the substeps its finest temporal level takes, in machine epsilons.
# The control arm opens the top face to SPACE, taking one cell's wall push away; it must read past it.
# EXIT 0 at rest * 1 the seeded world moves itself * 2 could not run.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool python3

CELL="${LA_REST_CELL_M:-2000}"
CELLS="${LA_REST_CELLS:-20}"
FRAMES="${LA_REST_FRAMES:-12}"

# One column run at the given face spec. Prints the three readings, space separated, or nothing.
column() {
	LA_BOUNDARY_FACES="$1" "$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --rung 3 \
		--slice-box "0,surface,0,1,${CELLS},1,${CELL}" --frames "$FRAMES" \
		--report wind_speed_max,celerity_max,pressure_rest_rel,transport_levels 2>&1
}

# `max` off one gauge line of sim_run's report; empty when the gauge is absent.
reading() {
	printf '%s\n' "$2" | python3 -c "
import re, sys
key = sys.argv[1]
for ln in sys.stdin:
    if ln.startswith(key) and '=' in ln:
        m = re.search(r\"'max': *([-+0-9.eE]+)\", ln)
        if m:
            print(m.group(1))
            break
        m = re.search(r'= *([-+0-9.eE]+)\s*\$', ln)
        if m:
            print(m.group(1))
            break
" "$1"
}

numeric() { printf '%s' "$1" | rg -N -q -e '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }

# One arm's verdict inputs: "finite mach pressure_rest_rel levels". `finite` 0 means the field went
# non-finite, the loudest form of NOT at rest, and carries no comparable numbers.
measure() {
	local out wind cel prel lv
	out="$(column "$1")"
	wind="$(reading wind_speed_max "$out")"
	cel="$(reading celerity_max "$out")"
	prel="$(reading pressure_rest_rel "$out")"
	lv="$(reading transport_levels "$out")"
	# The run's own guard says it first: a reduced row that went non-finite is refused as fiction, and
	# sim_run then withholds every number. That IS the reading — the column did not stay at rest.
	# A row the clock refuses because its own cells signal at light is the same reading by another name.
	if printf '%s\n' "$out" | rg -N -q -e 'reduced to (inf|-inf|nan)|signal speed at or past light'; then
		echo "0 0 0 0"
		return 0
	fi
	if printf '%s %s %s' "$wind" "$cel" "$prel" | rg -N -q -i -e 'nan|inf'; then
		echo "0 0 0 0"
		return 0
	fi
	if ! numeric "$wind" || ! numeric "$cel" || ! numeric "$prel" || ! numeric "$lv"; then
		printf '%s\n' "$out" | tail -20 >&2
		return 1
	fi
	if ! awk -v c="$cel" 'BEGIN{exit !(c > 0)}'; then
		echo "check_atmosphere_at_rest: celerity_max is not positive; the column holds no matter." >&2
		return 1
	fi
	awk -v w="$wind" -v c="$cel" -v p="$prel" -v l="$lv" \
		'BEGIN{printf "1 %.12g %.12g %d", w / c, p, l}'
}

# True when this arm stayed at rest: finite, and both readings inside the arithmetic's own bar — the
# substeps the run's own finest temporal level takes, over the frames it took, in machine epsilons.
at_rest() {
	awk -v f="$1" -v m="$2" -v p="$3" -v l="$4" -v n="$FRAMES" \
		'BEGIN{b = n * (2 ^ l) * 1.1920929e-7; exit !(f == 1 && m <= b && p <= b)}'
}

rest="$(measure "shut,shut,shut,shut,shut,shut")" || {
	echo "check_atmosphere_at_rest: the resting column published no wind_speed_max/celerity_max/pressure_rest_rel." >&2
	exit 2
}
read -r REST_FIN REST_MACH REST_PREL REST_LV <<EOF
$rest
EOF
echo "ATMOSPHERE_AT_REST={\"finite\":$REST_FIN,\"mach\":$REST_MACH,\"pressure_rest_rel\":$REST_PREL,\"levels\":$REST_LV}"

vent="$(measure "shut,shut,shut,space,shut,shut")" || {
	echo "check_atmosphere_at_rest: the vented control published no readings, so the gate has no control." >&2
	exit 2
}
read -r VENT_FIN VENT_MACH VENT_PREL VENT_LV <<EOF
$vent
EOF
echo "ATMOSPHERE_VENTED={\"finite\":$VENT_FIN,\"mach\":$VENT_MACH,\"pressure_rest_rel\":$VENT_PREL,\"levels\":$VENT_LV}"

# THE CONTROL FIRST: a gate whose disabled arm also passes is holding nothing.
if at_rest "$VENT_FIN" "$VENT_MACH" "$VENT_PREL" "$VENT_LV"; then
	echo >&2
	echo "check_atmosphere_at_rest: the column with its top face OPEN TO SPACE also stayed at rest." >&2
	echo "One cell's wall push is gone there, so it must move. This gate cannot fail and asserts nothing." >&2
	exit 2
fi

if at_rest "$REST_FIN" "$REST_MACH" "$REST_PREL" "$REST_LV"; then
	echo "check_atmosphere_at_rest: OK"
	exit 0
fi
echo
echo "The sealed column moved. Its own weight and its own pressure are all that act on it, and a"
echo "hydrostatic state cancels them face by face, so the seed is not in the discrete balance the"
echo "stepper holds — transport.glsl's face_p() reconstruction against the bodyf_* impulse. At balance"
echo "the acoustic pass also sees zero divergence, so no cell's pressure leaves the value it was seeded"
echo "with either."
exit 1
