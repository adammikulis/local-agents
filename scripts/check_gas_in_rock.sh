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

CH="$ROOT/addons/local_agents/sim/material/Channels.gd"
[ -f "$CH" ] || { echo "check_gas_in_rock: MISSING Channels.gd" >&2; exit 2; }
GASES="$(rg -N -o -e '^\s*"([a-z0-9_]+)":.*"phase": "gas"' -r '$1' "$CH")"
[ -n "$GASES" ] || { echo "check_gas_in_rock: Channels.gd declares no gas channel. A gate that examines nothing is not a gate." >&2; exit 2; }

keys=""
for g in $GASES; do keys="${keys}all_${g},open_${g},"; done
out="$(la_report "${keys%,}" --path "$ROOT" --frames "${LA_GAS_FRAMES:-2}" 2>&1)" || true
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
