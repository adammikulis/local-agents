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

# The arm the capture was taken on: LADDER_ARM={"slice":"<box>"} or {"slice":null}.
la_cap_arm() {
	local cap
	cap="$(la_cap_dir)" || return 1
	[ -s "$cap/arm" ] || return 1
	cat "$cap/arm"
}

# A GATE THAT COMPARES A RUN TO THE WHOLE BODY'S DECLARED RECORD CANNOT READ A BOX. On a slice capture
# it is NOT EXAMINED — never a pass, never a violation. With no capture it takes its own --body arm.
# $1 the gate script's basename.
la_body_scoped() {
	local arm
	arm="$(la_cap_arm 2>/dev/null || true)"
	case "$arm" in
		*'"slice":null'* | "") return 0 ;;
	esac
	echo "LINT_NOT_EXAMINED: $1 is body-scoped; the capture is a slice arm"
	return 3
}

# The rung the shared arm ran at, so a replay of its face state runs in the same world.
la_cap_rung() {
	local cap
	cap="$(la_cap_dir)" || return 1
	[ -s "$cap/rung" ] || return 1
	tr -d '[:space:]' < "$cap/rung"
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
# THE LADDER DECIDES WHAT LINT MAY READ. A gate assigned to a rung above the capture's is not examined:
# it exits 3 with LINT_NOT_EXAMINED, which the harness counts apart from a gate that could not run.
# $1 the gate script's basename. No capture, or a gate no rung names, examines as before.
la_examined() {
	local cap rung mine
	cap="$(la_cap_dir)" || return 0
	[ -s "$cap/rung" ] && [ -s "$cap/headless/gate_rungs.log" ] || return 0
	rung="$(head -1 "$cap/rung" | tr -d '[:space:]')"
	mine="$(sed -n "s/^GATE_RUNG=$1 //p" "$cap/headless/gate_rungs.log" | head -1)"
	[ -n "$mine" ] || return 0
	if [ "$mine" -gt "$rung" ]; then
		echo "LINT_NOT_EXAMINED: $1 needs rung $mine; the capture is the ladder's rung $rung."
		return 3
	fi
	return 0
}

la_headless() {
	local cap
	cap="$(la_cap_dir)" || return 1
	if [ ! -s "$cap/headless/$1.log" ]; then
		echo "la_headless: the batch published no output for '$1'." >&2
		return 2
	fi
	cat "$cap/headless/$1.log"
}
