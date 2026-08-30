#!/usr/bin/env bash
# FREE GAS DOES NOT SIT INSIDE STONE, AND THAT HOLDS FOR EVERY GAS. For a gas channel the whole-box total
# and the open-cells total are the SAME NUMBER; any gap between all_X and open_X is gas inside solid rock.
# The gas list comes from Channels.gd, so a gas added tomorrow is covered the same day.
#
# EXIT 0 no gas in rock · 1 some gas is in rock · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

# ARM ONE, ON THE KERNEL. The face scratch is one buffer for every record, so a pass that reads a
# NEIGHBOUR's face slot reads whatever record wrote that slot last: that is how joules of radiated heat
# arrived in a rock cell as moles of gas. A record clears its own faces, writes its own faces, and reads
# nothing but its own faces back.
T="$ROOT/addons/local_agents/sim/material/kernels3d/flux.glsl"
[ -f "$T" ] || { echo "check_gas_in_rock: MISSING ${T#"$ROOT"/}" >&2; exit 2; }
rg -q -e 'x_amt\[f\] = 0\.0;' "$T" || {
	echo "check_gas_in_rock: flux.glsl's flux half no longer clears the faces it is about to write." >&2
	exit 1
}
if rg -q -e 'la_back_face\(' "$T"; then
	echo "check_gas_in_rock: flux.glsl reads a partner face again, so a record can take delivery of" >&2
	echo "                   whatever record wrote that slot last." >&2
	exit 1
fi
# The wall belongs to the FACE, so the same test stands on both halves of the record: the flux refuses
# to write and the apply refuses to receive.
sides="$(rg -N -c -e 'if \(\(?solid\[c\] != 0\.0( \|\| collisionless\(c\))?\)? && !pores && !heat\)' "$T" || true)"
[ "${sides:-0}" -ge 2 ] || {
	echo "check_gas_in_rock: flux.glsl states the solid wall on one half of the record only, so stone" >&2
	echo "                   may take delivery of what it would never be sent." >&2
	exit 1
}

# ARM TWO, ON THE WORLD.
CH="$ROOT/addons/local_agents/sim/material/Channels.gd"
[ -f "$CH" ] || { echo "check_gas_in_rock: MISSING Channels.gd" >&2; exit 2; }
GASES="$(rg -N -o -e '^\s*"([a-z0-9_]+)":.*"phase": "gas"' -r '$1' "$CH")"
[ -n "$GASES" ] || { echo "check_gas_in_rock: Channels.gd declares no gas channel. A gate that examines nothing is not a gate." >&2; exit 2; }

keys=""
for g in $GASES; do keys="${keys}all_${g},open_${g},"; done
# The gap opens over the run, so an arm short enough to miss it is a gate that cannot fail: this is the
# shared capture's own length, rung and seed.
out="$(la_report "${keys%,}" --path "$ROOT" --frames "${LA_GAS_FRAMES:-20}" \
	--rung "${LA_GAS_RUNG:-8}" --seed 4242 --from-seal 2>&1)" || true
# A gauge publishes {'cur': x, 'min': y, 'max': z}; the stock now is 'cur'.
reading() {
	printf '%s\n' "$out" | sed -n "s/^$1  *= *//p" | head -1 \
		| sed -n "s/.*'cur': *\([-+0-9.eE]*\).*/\1/p"
}
numeric() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }

fail=0
seen=0
for g in $GASES; do
	a="$(reading "all_${g}")"
	o="$(reading "open_${g}")"
	if ! numeric "$a" || ! numeric "$o"; then
		echo "check_gas_in_rock: the run published no all_${g}/open_${g}; an absent reading is not a clean one." >&2
		exit 2
	fi
	seen=$((seen + 1))
	# A gas that was never seeded says nothing either way, and its absence is not evidence.
	awk -v a="$a" -v o="$o" -v g="$g" 'BEGIN {
		if (a <= 0.0) { exit 0 }
		gap = a - o
		if (gap > 1.0e-6 * a) {
			printf "check_gas_in_rock: %s holds %.3g of %.3g inside solid rock.\n", g, gap, a > "/dev/stderr"
			exit 1
		}
	}' || fail=1
done
[ "$seen" -gt 0 ] || { echo "check_gas_in_rock: examined no gas." >&2; exit 2; }
[ "$fail" -eq 0 ] && echo "check_gas_in_rock: OK (${seen} gas channels, none inside rock)"
exit "$fail"
