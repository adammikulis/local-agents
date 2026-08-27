#!/usr/bin/env bash
# AN ATMOSPHERE AT REST, IN BALANCE, STAYS AT REST. A one-cell-wide column on the declared body's radius,
# every face shut, so its cell centres sit on the body axis and the solved gravity is exactly axial.
# The bar is the arithmetic's: frames * TransportPass.SUBSTEP_MAX machine epsilons, nothing fitted.
# The control arm opens the top face to SPACE, taking one cell's wall push away; it must read past the bar.
# EXIT 0 at rest * 1 the seeded world moves itself * 2 could not run.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool python3

CELL="${LA_REST_CELL_M:-2000}"
CELLS="${LA_REST_CELLS:-20}"
FRAMES="${LA_REST_FRAMES:-12}"

PASS_GD="$ROOT/addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
[ -f "$PASS_GD" ] || { echo "check_atmosphere_at_rest: MISSING TransportPass.gd." >&2; exit 2; }
SUBSTEP_MAX="$(rg -N -o -e 'const SUBSTEP_MAX: int = [0-9]+' "$PASS_GD" | rg -N -o -e '[0-9]+$')"
case "${SUBSTEP_MAX:-}" in "" | *[!0-9]*)
	echo "check_atmosphere_at_rest: TransportPass.gd declares no SUBSTEP_MAX, so the bar has no substep count." >&2
	exit 2 ;;
esac
# float32 epsilon.
BOUND="$(awk -v f="$FRAMES" -v s="$SUBSTEP_MAX" 'BEGIN{printf "%.12g", f * s * 1.1920929e-7}')"

# One column run at the given face spec. Prints the three readings, space separated, or nothing.
column() {
	LA_BOUNDARY_FACES="$1" "$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice \
		--slice-box "0,surface,0,1,${CELLS},1,${CELL}" --frames "$FRAMES" \
		--report wind_speed_max,celerity_max,pressure_rest_rel 2>&1
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

# One arm's verdict inputs: "finite mach pressure_rest_rel". `finite` 0 means the field went non-finite,
# which is the loudest form of NOT at rest and carries no comparable numbers.
measure() {
	local out wind cel prel
	out="$(column "$1")"
	wind="$(reading wind_speed_max "$out")"
	cel="$(reading celerity_max "$out")"
	prel="$(reading pressure_rest_rel "$out")"
	# The run's own guard says it first: a reduced row that went non-finite is refused as fiction, and
	# sim_run then withholds every number. That IS the reading — the column did not stay at rest.
	if printf '%s\n' "$out" | rg -N -q -e 'reduced to (inf|-inf|nan)'; then
		echo "0 0 0"
		return 0
	fi
	if printf '%s %s %s' "$wind" "$cel" "$prel" | rg -N -q -i -e 'nan|inf'; then
		echo "0 0 0"
		return 0
	fi
	if ! numeric "$wind" || ! numeric "$cel" || ! numeric "$prel"; then
		printf '%s\n' "$out" | tail -20 >&2
		return 1
	fi
	if ! awk -v c="$cel" 'BEGIN{exit !(c > 0)}'; then
		echo "check_atmosphere_at_rest: celerity_max is not positive; the column holds no matter." >&2
		return 1
	fi
	awk -v w="$wind" -v c="$cel" -v p="$prel" 'BEGIN{printf "1 %.12g %.12g", w / c, p}'
}

# True when this arm stayed at rest: finite, and both readings inside the arithmetic's own bar.
at_rest() {
	awk -v f="$1" -v m="$2" -v p="$3" -v b="$BOUND" 'BEGIN{exit !(f == 1 && m <= b && p <= b)}'
}

rest="$(measure "shut,shut,shut,shut,shut,shut")" || {
	echo "check_atmosphere_at_rest: the resting column published no wind_speed_max/celerity_max/pressure_rest_rel." >&2
	exit 2
}
read -r REST_FIN REST_MACH REST_PREL <<EOF
$rest
EOF
echo "ATMOSPHERE_AT_REST={\"finite\":$REST_FIN,\"mach\":$REST_MACH,\"pressure_rest_rel\":$REST_PREL,\"bound\":$BOUND}"

vent="$(measure "shut,shut,shut,space,shut,shut")" || {
	echo "check_atmosphere_at_rest: the vented control published no readings, so the gate has no control." >&2
	exit 2
}
read -r VENT_FIN VENT_MACH VENT_PREL <<EOF
$vent
EOF
echo "ATMOSPHERE_VENTED={\"finite\":$VENT_FIN,\"mach\":$VENT_MACH,\"pressure_rest_rel\":$VENT_PREL}"

# THE CONTROL FIRST: a gate whose disabled arm also passes is holding nothing.
if at_rest "$VENT_FIN" "$VENT_MACH" "$VENT_PREL"; then
	echo >&2
	echo "check_atmosphere_at_rest: the column with its top face OPEN TO SPACE also stayed at rest." >&2
	echo "One cell's wall push is gone there, so it must move. This gate cannot fail and asserts nothing." >&2
	exit 2
fi

if at_rest "$REST_FIN" "$REST_MACH" "$REST_PREL"; then
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
