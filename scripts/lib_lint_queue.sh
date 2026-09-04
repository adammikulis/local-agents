#!/usr/bin/env bash
# ONE TIMING LINE, for a caller that ran a list of things and kept each one's wall seconds.
# scripts/gate_runner.py emits LINT_TIMING itself; check_process_ladder.sh emits LADDER_TIMING from here.

# $1 a file of "<seconds>\t<label>" lines, $2 the marker. One line, longest first.
la_timing_line() {
	[ -s "$1" ] || return 0
	sort -rn -k1,1 "$1" | awk -F'\t' -v marker="$2" '
		BEGIN { printf "%s={", marker }
		{ gsub(/"/, "", $2); printf "%s\"%s\":%s", (NR > 1 ? "," : ""), $2, ($1 == "" ? "0" : $1) }
		END { print "}" }'
}
