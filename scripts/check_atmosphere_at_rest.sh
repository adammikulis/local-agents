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
# The control drains a column this short in about a minute, so it runs four frames, past the seal: long enough for
# gas to leave through the open top, short enough that matter remains to be read.
VENT_FRAMES="${LA_REST_VENT_FRAMES:-4}"

# One column run at the given face spec. Prints the three readings, space separated, or nothing.
column() {
	LA_BOUNDARY_FACES="$1" "$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --rung 3 \
		--slice-box "0,surface,0,1,${CELLS},1,${CELL}" --frames "${2:-$FRAMES}" \
		--report mach_max,momentum_mass_kg,pressure_rest_rel,transport_levels,bnd_n2,energy_residual_rel,energy_held,energy_turnover_j,energy_stock,energy_stock_open 2>&1
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
	out="$(column "$1" "${2:-$FRAMES}")"
	wind="$(reading mach_max "$out")"
	cel="$(reading momentum_mass_kg "$out")"
	prel="$(reading pressure_rest_rel "$out")"
	lv="$(reading transport_levels "$out")"
	local left eres held turn ebar
	left="$(reading bnd_n2 "$out")"
	eres="$(reading energy_residual_rel "$out")"
	held="$(reading energy_held "$out")"
	turn="$(reading energy_turnover_j "$out")"
	local stock sopen
	stock="$(reading energy_stock "$out")"
	sopen="$(reading energy_stock_open "$out")"
	numeric "$left" || left=0
	# The residual is SIGNED; an absent reading is the empty string, never a number standing in for it.
	numeric "$eres" || eres=""
	numeric "$held" || held=0
	numeric "$turn" || turn=0
	numeric "$stock" || stock=0
	numeric "$sopen" || sopen=0
	# float32's own rounding of the book: two readings of the held total, the rock's stock rounded once
	# a frame, the air's once a substep, as a share of the joules that crossed.
	ebar="$(awk -v h="$held" -v t="$turn" -v l="$lv" -v n="${2:-$FRAMES}" -v s="$stock" -v o="$sopen" \
		'function a(x){return x < 0 ? -x : x} BEGIN{ e = 1.1920929e-7; if (t > 0) printf "%.12g", e * (2 * a(h) + n * a(s - o) + n * (2 ^ l) * a(o)) / t; else print -1 }')"
	# The run's own guard says it first: a reduced row that went non-finite is refused as fiction, and
	# sim_run then withholds every number. That IS the reading — the column did not stay at rest.
	# A row the clock refuses because its own cells signal at light is the same reading by another name.
	if printf '%s\n' "$out" | rg -N -q -e 'reduced to (inf|-inf|nan)|signal speed at or past light'; then
		echo "0 0 0 0 0 none -1"
		return 0
	fi
	if printf '%s %s %s' "$wind" "$cel" "$prel" | rg -N -q -i -e 'nan|inf'; then
		echo "0 0 0 0 0 none -1"
		return 0
	fi
	if ! numeric "$wind" || ! numeric "$cel" || ! numeric "$prel" || ! numeric "$lv"; then
		printf '%s\n' "$out" | tail -20 >&2
		return 1
	fi
	if ! awk -v c="$cel" 'BEGIN{exit !(c > 0)}'; then
		echo "check_atmosphere_at_rest: momentum_mass_kg is not positive; the column holds no matter." >&2
		return 1
	fi
	awk -v w="$wind" -v c="$cel" -v p="$prel" -v l="$lv" -v x="$left" -v e="${eres:-none}" -v b="$ebar" \
		'BEGIN{printf "1 %.12g %.12g %d %.12g %s %.12g", w, p, l, x, e, b}'
}

# True when this arm stayed at rest: finite, and both readings inside the arithmetic's own bar — the
# substeps the run's own finest temporal level takes, over the frames it took, in machine epsilons.
at_rest() {
	awk -v f="$1" -v m="$2" -v p="$3" -v l="$4" -v n="$FRAMES" \
		'BEGIN{b = n * (2 ^ l) * 1.1920929e-7; exit !(f == 1 && m <= b && p <= b)}'
}

rest="$(measure "shut,shut,shut,shut,shut,shut")" || {
	echo "check_atmosphere_at_rest: the resting column published no mach_max/momentum_mass_kg/pressure_rest_rel." >&2
	exit 2
}
read -r REST_FIN REST_MACH REST_PREL REST_LV REST_LEFT REST_ERES REST_EBAR <<EOF
$rest
EOF
echo "ATMOSPHERE_AT_REST={\"finite\":$REST_FIN,\"mach\":$REST_MACH,\"pressure_rest_rel\":$REST_PREL,\"levels\":$REST_LV}"

# THE CONTROL ANSWERS THE QUESTION THE SEALED ARM LEFT OPEN, and only that one. A sealed column that
# MOVED has already shown this instrument reads motion, so there is nothing for a vented arm to prove
# and no engine to start for it. A sealed column at rest is the reading that needs a control.
if at_rest "$REST_FIN" "$REST_MACH" "$REST_PREL" "$REST_LV"; then
	vent="$(measure "shut,shut,shut,space,shut,shut" "$VENT_FRAMES")" || {
		echo "check_atmosphere_at_rest: the vented control published no readings, so the gate has no control." >&2
		exit 2
	}
	read -r VENT_FIN VENT_MACH VENT_PREL VENT_LV VENT_LEFT VENT_ERES VENT_EBAR <<EOF
$vent
EOF
	echo "ATMOSPHERE_VENTED={\"finite\":$VENT_FIN,\"gas_left\":$VENT_LEFT,\"energy_residual_rel\":$VENT_ERES,\"energy_bar\":$VENT_EBAR,\"levels\":$VENT_LV}"
	# THE CONTROL: gas leaves through the open face, and the energy book closes on what left — the
	# residual over the turnover inside the book's own float32 rounding.
	if ! awk -v l="$VENT_LEFT" 'BEGIN{exit !(l < 0)}'; then
		echo >&2
		echo "check_atmosphere_at_rest: the column with its TOP OPEN TO SPACE lost no gas through it, so" >&2
		echo "the instrument reads no venting. This gate cannot fail." >&2
		exit 2
	fi
	if ! numeric "$VENT_ERES"; then
		echo >&2
		echo "check_atmosphere_at_rest: the vented column published no energy_residual_rel, so its book" >&2
		echo "was never read." >&2
		exit 2
	fi
	if ! awk -v r="$VENT_ERES" -v b="$VENT_EBAR" 'BEGIN{a = r < 0 ? -r : r; exit !(a <= b)}'; then
		echo >&2
		echo "check_atmosphere_at_rest: the vented column's energy book does not close: residual $VENT_ERES of" >&2
		echo "the turnover against a bar of $VENT_EBAR. Enthalpy, motion and what left through the face disagree." >&2
		exit 1
	fi
	echo "check_atmosphere_at_rest: OK"
	exit 0
fi
echo
echo "The sealed column moved. Its own weight and its own pressure are all that act on it, and a"
echo "hydrostatic state cancels them face by face, so the seed is not in the discrete balance the"
echo "stepper holds — flux.glsl's face_p() reconstruction against the bodyf_* impulse. At balance"
echo "the acoustic pass also sees zero divergence, so no cell's pressure leaves the value it was seeded"
echo "with either."
exit 1
