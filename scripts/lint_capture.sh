#!/usr/bin/env bash
# THE SHARED ARM AND THE ONE HEADLESS BATCH EVERY GATE READS, printed as a capture directory;
# agent_harness.sh lint runs it once and exports LA_LINT_CAPTURE.
# THE ACCEPTANCE ARM IS THE SLICE. A body run records the slice box's exterior face state, so the
# boundary gates consume that capture rather than taking their own, and the slice stands in it.
# --body makes the whole planet the arm instead, which is the smoke test.
# EXIT 0 the capture stands · 2 it could not be made.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_import.sh"

ARM=slice
while [ $# -gt 0 ]; do
	case "$1" in
		--slice) ARM=slice; shift ;;
		--body) ARM=body; shift ;;
		*) echo "lint_capture: unknown argument '$1'" >&2; exit 2 ;;
	esac
done

CAP="${LA_LINT_CAPTURE:-}"
if [ -z "$CAP" ]; then
	CAP="$(mktemp -d "${TMPDIR:-/tmp}/la_lint_capture.XXXXXX")" || {
		echo "lint_capture: no writable temp directory." >&2; exit 2; }
fi
mkdir -p "$CAP/headless" || { echo "lint_capture: cannot write $CAP." >&2; exit 2; }

FRAMES="${LA_CAPTURE_FRAMES:-20}"
SEED="${LA_CAPTURE_SEED:-4242}"
LIFE_FRAMES="${LA_LIFE_FRAMES:-300}"
LIFE_FPS="${LA_LIFE_FPS:-60}"
PLAYABLE="$(rg -N -o '^[0-9]+$' "$ROOT/docs/PLAYABLE_RUNG" 2>/dev/null | head -1)"
CAP_RUNG="${LA_CAPTURE_RUNG:-${PLAYABLE:-0}}"
# A CLASS EVICTS ONLY ITS OWN. Every lane lints LA_NO_GPU=1 and the integrator lints with a device; one
# shared shelf meant four lane captures pushed the device capture out, so the full lint re-ran the sim
# every landing. The shelf is per class, and a class holds the newest few trees.
CACHE_ROOT="${LA_CAPTURE_CACHE:-$HOME/.cache/local-agents/capture}"
CACHE_CLASS="$ARM.gpu${LA_NO_GPU:-0}.r$CAP_RUNG"
CACHE_SHELF="$CACHE_ROOT/$CACHE_CLASS"
KEEP_ENTRIES=4

"$SCRIPT_DIR/godot_import.sh" "$ROOT" >/dev/null 2>&1 || true

# THE CAPTURE IS A FUNCTION OF WHAT PRODUCED IT: every source that reaches a run, the compiled extension,
# the engine, and this arm's configuration. A docs-only or scripts-only change lints without launching a
# sim, because nothing the run reads has moved.
KEY="$("$SCRIPT_DIR/cache_key.sh" capture --path "$ROOT" \
	"seed=$SEED" "rung=$CAP_RUNG" "frames=$FRAMES" "arm=$ARM" "gpu=${LA_NO_GPU:-0}" \
	"life=$LIFE_FRAMES@$LIFE_FPS" 2>/dev/null || echo "")"
if [ -n "$KEY" ] && [ -f "$CACHE_SHELF/$KEY/COMPLETE" ]; then
	if cp -Rp "$CACHE_SHELF/$KEY/." "$CAP/" 2>/dev/null; then
		rm -f "$CAP/COMPLETE"
		[ -s "$CAP/arm" ] && cat "$CAP/arm" >&2
		printf '%s\n' "$CAP"
		exit 0
	fi
fi


# LA_NO_GPU=1 has no device to run the arm on, so the capture holds the headless batch and nothing else;
# agent_harness.sh skips exactly the gates that would read the missing half.
if [ "${LA_NO_GPU:-0}" = "1" ]; then
	SIM_RC=0
else

# The frontmost bundle id for the whole arm — check_no_focus_theft's measurement, off this same run.
SAMPLES="$CAP/front_samples"
: > "$SAMPLES"
POLL=""
if [ "$(uname)" = "Darwin" ] && command -v lsappinfo >/dev/null 2>&1; then
	( while :; do
		lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | sed 's/.*=//' >> "$SAMPLES"
		sleep 0.02
	done ) &
	POLL=$!
fi

# --raw so the report reaches the capture through sim_run's OWN error census: a run that logged engine
# errors prints no JSON, and the capture then holds no numbers for any gate to read.
# THE WHOLE WORLD, not the demo's rung: a gate that asks after a process reads a world that has it.
# The rung is written beside the capture, because a face state replayed into another rung's interior is
# an exterior from a different world.
printf '%s\n' "$CAP_RUNG" > "$CAP/rung"
# THE EXTERIOR THE SLICE STANDS IN. Only the whole body can record its own faces, so this run is --body
# whichever arm the acceptance report comes from, and the boundary gates read it instead of taking one.
"$SCRIPT_DIR/sim_run.sh" --path "$ROOT" --body --frames "$FRAMES" --seed "$SEED" --rung "$CAP_RUNG" \
	--slice-capture "$CAP/slice_state.json" --keep --raw > "$CAP/body.raw" 2> "$CAP/body.err"
SIM_RC=$?
# THE BODY'S OWN NUMBERS, KEPT. This run happens on every lint whichever arm the acceptance report comes
# from, so a gate that can only weigh the whole planet reads it instead of taking a second body run.
if [ "$SIM_RC" -eq 0 ] && [ -s "$CAP/body.raw" ] && head -c 1 "$CAP/body.raw" | grep -q '{'; then
	cp "$CAP/body.raw" "$CAP/body_report.json"
fi
if [ "$ARM" = "body" ]; then
	mv -f "$CAP/body.raw" "$CAP/report.raw"
	mv -f "$CAP/body.err" "$CAP/sim_run.err"
else
	rm -f "$CAP/body.raw"
	while IFS= read -r kept; do rm -f "$kept"; done \
		< <(sed -n 's/^sim_run: log kept at //p' "$CAP/body.err")
	"$SCRIPT_DIR/sim_run.sh" --path "$ROOT" --frames "$FRAMES" --seed "$SEED" --rung "$CAP_RUNG" \
		--slice-state "$CAP/slice_state.json" --keep --raw \
		> "$CAP/report.raw" 2> "$CAP/sim_run.err"
	SIM_RC=$?
fi
if [ -n "$POLL" ]; then kill "$POLL" 2>/dev/null; wait "$POLL" 2>/dev/null; fi

LOG="$(sed -n 's/^sim_run: log kept at //p' "$CAP/sim_run.err" | head -1)"
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
	cp "$LOG" "$CAP/global.log"
	rm -f "$LOG"
fi
if [ -s "$CAP/report.raw" ] && head -c 1 "$CAP/report.raw" | grep -q '{'; then
	mv "$CAP/report.raw" "$CAP/report.json"
else
	rm -f "$CAP/report.raw"
fi

# THE LIFE ARM, ONCE. Three gates read this same run: what its books did, what it looks like, and what
# its bodies burned. LA_EVO_FAST is set empty so simulated seconds are frames over fps whatever the
# caller's environment holds.
LIFE_SCENE="addons/local_agents/examples/LifeDemo.tscn"
if [ -f "$ROOT/$LIFE_SCENE" ]; then
	LA_RUN_TIMEOUT="${LA_LIFE_TIMEOUT:-110}" LA_EVO_FAST= "$SCRIPT_DIR/run_sim_offscreen.sh" \
		--path "$ROOT" "$LIFE_SCENE" --fixed-fps "$LIFE_FPS" -- --sandbox "--run-frames=$LIFE_FRAMES" \
		> "$CAP/life_demo.log" 2>&1
	printf '{"frames":%s,"fps":%s,"rc":%s}\n' "$LIFE_FRAMES" "$LIFE_FPS" "$?" > "$CAP/life_demo.arm"
fi

# THE RIGS THAT ONLY NEED A DEVICE, IN ONE LAUNCH. Every launch is a trip through the machine GPU lock,
# so a rig that boots an engine to dispatch one pass shares this one.
DEVICE_REL="addons/local_agents/tests/lint_device_batch.gd"
if [ -f "$ROOT/$DEVICE_REL" ]; then
	LA_CAPTURE_RUNG="$CAP_RUNG" LA_DONE_RE='^LA_DEVICE_BATCH_DONE=' \
		LA_RUN_TIMEOUT="${LA_DEVICE_BATCH_TIMEOUT:-120}" "$SCRIPT_DIR/run_sim_offscreen.sh" \
		--path "$ROOT" -s "res://$DEVICE_REL" > "$CAP/device_batch.log" 2>&1
fi
fi
printf '%s\n' "$SIM_RC" > "$CAP/sim_run.rc"
# THE ARM, PUBLISHED. A gate that compares a run to the whole body's declared record reads this and says
# it was not examined rather than comparing a box to a planet.
if [ "$ARM" = "body" ]; then
	printf 'LADDER_ARM={"slice":null}\n' > "$CAP/arm"
else
	printf 'LADDER_ARM={"slice":"%s"}\n' "$("$SCRIPT_DIR/sim_run.sh" --print-slice-box)" > "$CAP/arm"
fi
cat "$CAP/arm" >&2

BATCH_REL="addons/local_agents/tests/lint_headless_batch.gd"
if [ ! -f "$ROOT/$BATCH_REL" ]; then
	echo "lint_capture: MISSING $BATCH_REL — the headless gates have no batch to read." >&2
	exit 2
fi
rm -f "$CAP"/headless/*.log
BATCH_LOG="$CAP/headless/batch.log"
LA_GODOT_TIMEOUT="${LA_BATCH_TIMEOUT:-120}" la_godot --headless --path "$ROOT" \
	--log-file "$BATCH_LOG" -s "res://$BATCH_REL" > "$CAP/headless/batch.stdout" 2>&1
[ -s "$BATCH_LOG" ] || cp "$CAP/headless/batch.stdout" "$BATCH_LOG"

split_fenced() {
	[ -s "$1" ] || return 0
	awk -v dir="$CAP/headless" '
		/^LA_BATCH_BEGIN=/ { name = substr($0, index($0, "=") + 1); out = dir "/" name ".log"; printf "" > out; next }
		/^LA_BATCH_END=/   { out = ""; next }
		out != "" { print >> out }
	' "$1"
}
split_fenced "$BATCH_LOG"
split_fenced "$CAP/device_batch.log"

# A FAILED CAPTURE IS NOT RECORDED. The arm that logged engine errors publishes no report, and a gate
# reading a cached absence would read it as a measurement.
publishable=0
if [ -s "$BATCH_LOG" ]; then
	if [ "${LA_NO_GPU:-0}" = "1" ]; then publishable=1
	elif [ "$SIM_RC" -eq 0 ] && [ -f "$CAP/report.json" ] && [ -s "$CAP/life_demo.log" ]; then publishable=1
	fi
fi
if [ -n "$KEY" ] && [ "$publishable" -eq 1 ] && [ ! -d "$CACHE_SHELF/$KEY" ]; then
	mkdir -p "$CACHE_SHELF/$KEY.tmp"
	if cp -Rp "$CAP/." "$CACHE_SHELF/$KEY.tmp/" 2>/dev/null; then
		: > "$CACHE_SHELF/$KEY.tmp/COMPLETE"
		mv "$CACHE_SHELF/$KEY.tmp" "$CACHE_SHELF/$KEY" 2>/dev/null || rm -rf "$CACHE_SHELF/$KEY.tmp"
	else
		rm -rf "$CACHE_SHELF/$KEY.tmp"
	fi
	ls -dt "$CACHE_SHELF"/*/ 2>/dev/null | tail -n +$((KEEP_ENTRIES + 1)) | while IFS= read -r old; do
		rm -rf "$old"
	done
fi

printf '%s\n' "$CAP"
exit 0
