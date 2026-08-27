#!/usr/bin/env bash
# ONE ARM PER RUNG. A rung gate reads the world the sim seeds WITH THAT RUNG'S PROCESSES AND NO OTHERS,
# so it may not read the shared lint capture: that arm is the demo world's rung, not this one.

LA_RUNG_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $1 rung, $2 frames, $3 comma-separated SIM_REPORT keys. Prints sim_run's report block.
la_rung_report() {
	"$LA_RUNG_SCRIPTS/sim_run.sh" --rung "$1" --frames "$2" --report "$3" 2>&1
}

la_rung_numeric() {
	printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
}

# $1 the report block, $2 a key. The scalar, or the gauge's `cur`. A key the run did not publish prints
# NOTHING: a reading that was never taken is absent, and never a zero standing in for one.
la_rung_value() {
	local raw
	raw="$(printf '%s\n' "$1" | sed -n "s/^$2  *= *//p" | head -1)"
	case "$raw" in "" | *ABSENT* | *None*) return 0 ;; esac
	raw="$(printf '%s' "$raw" | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e "s/[^0-9eE.+-]//g")"
	la_rung_numeric "$raw" && printf '%s' "$raw"
	return 0
}

# $1 the report block, then key names. Exits 2 naming the first key that carries no number.
la_rung_require() {
	local block="$1"
	shift
	local k v
	for k in "$@"; do
		v="$(la_rung_value "$block" "$k")"
		if ! la_rung_numeric "$v"; then
			echo "ERROR: the run published no numeric $k, so the claim went unmeasured." >&2
			printf '%s\n' "$block" | tail -20 >&2
			return 2
		fi
	done
	return 0
}
