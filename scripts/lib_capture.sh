#!/usr/bin/env bash
# THE SHARED LINT CAPTURE. One sim arm per lint, recorded by lint_capture.sh into the directory
# LA_LINT_CAPTURE names; every GPU gate reads it instead of launching its own engine.
# With no capture set, each helper falls through to the launch a hand-run gate needs.
# A capture that is set and does not hold the reading is exit 2 — could not run, never a pass.

LA_CAP_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

la_cap_dir() {
	[ -n "${LA_LINT_CAPTURE:-}" ] || return 1
	[ -d "$LA_LINT_CAPTURE" ] || return 1
	printf '%s' "$LA_LINT_CAPTURE"
}

# $1 comma-separated SIM_REPORT keys; the rest go to sim_run.sh when there is no capture.
la_report() {
	local keys="$1"
	shift
	local cap
	if cap="$(la_cap_dir)"; then
		if [ ! -s "$cap/report.json" ]; then
			echo "la_report: the shared arm published no SIM_REPORT, so nothing was measured." >&2
			return 2
		fi
		REPORT_KEYS="$keys" RAW=0 python3 "$LA_CAP_SCRIPTS/lib_report.py" "$cap/report.json"
		return $?
	fi
	"$LA_CAP_SCRIPTS/sim_run.sh" --report "$keys" "$@" 2>&1
}

la_report_raw() {
	local cap
	if cap="$(la_cap_dir)"; then
		if [ ! -s "$cap/report.json" ]; then
			echo "la_report_raw: the shared arm published no SIM_REPORT." >&2
			return 2
		fi
		RAW=1 python3 "$LA_CAP_SCRIPTS/lib_report.py" "$cap/report.json"
		return $?
	fi
	"$LA_CAP_SCRIPTS/sim_run.sh" --raw "$@" 2>/dev/null
}

# First line of the shared arm's log matching $1.
la_marker() {
	local cap
	cap="$(la_cap_dir)" || return 1
	if [ ! -s "$cap/global.log" ]; then
		echo "la_marker: the capture holds no run log." >&2
		return 2
	fi
	local line
	line="$(grep -m1 -e "$1" "$cap/global.log")"
	if [ -z "$line" ]; then
		echo "la_marker: the shared arm published no line matching '$1'." >&2
		return 2
	fi
	printf '%s\n' "$line"
}

# The face-state capture the shared arm recorded.
la_cap_state() {
	local cap
	cap="$(la_cap_dir)" || return 1
	if [ ! -s "$cap/slice_state.json" ]; then
		echo "la_cap_state: the shared arm recorded no face-state capture." >&2
		return 2
	fi
	printf '%s' "$cap/slice_state.json"
}

# The frontmost-application samples taken for the length of the shared arm.
la_cap_front() {
	local cap
	cap="$(la_cap_dir)" || return 1
	if [ ! -s "$cap/front_samples" ]; then
		echo "la_cap_front: the capture holds no frontmost samples." >&2
		return 2
	fi
	printf '%s' "$cap/front_samples"
}

# One headless runner's slice of the batch launch's log.
la_headless() {
	local cap
	cap="$(la_cap_dir)" || return 1
	if [ ! -s "$cap/headless/$1.log" ]; then
		echo "la_headless: the batch published no output for '$1'." >&2
		return 2
	fi
	cat "$cap/headless/$1.log"
}
