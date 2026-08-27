#!/usr/bin/env bash
# ONE ENGINE RUN PER LINT. Records the shared sim arm and the one headless batch every gate reads, and
# prints the capture directory; agent_harness.sh lint runs it once and exports LA_LINT_CAPTURE.
# The arm is the union of what the GPU gates ask of a global run, and it records the slice box's
# exterior face state so the boundary gates consume that capture rather than taking their own.
# EXIT 0 the capture stands · 2 it could not be made.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"

CAP="${LA_LINT_CAPTURE:-}"
if [ -z "$CAP" ]; then
	CAP="$(mktemp -d "${TMPDIR:-/tmp}/la_lint_capture.XXXXXX")" || {
		echo "lint_capture: no writable temp directory." >&2; exit 2; }
fi
mkdir -p "$CAP/headless" || { echo "lint_capture: cannot write $CAP." >&2; exit 2; }

FRAMES="${LA_CAPTURE_FRAMES:-20}"
SEED="${LA_CAPTURE_SEED:-4242}"

# THE CACHE IS NOT INVALIDATED BY AN INCLUDE: editing a .glsli leaves every .glsl that includes it holding
# its old SPIR-V, and --import does not notice. Drop the kernels' cache so the arm below and the shader
# probe in the batch both compile from source.
if [ -d "$ROOT/.godot/imported" ]; then
	find "$ROOT/.godot/imported" -maxdepth 1 -name '*.glsl-*' -delete
fi
"$SCRIPT_DIR/godot_import.sh" "$ROOT" >/dev/null 2>&1 || true

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
"$SCRIPT_DIR/sim_run.sh" --path "$ROOT" --frames "$FRAMES" --seed "$SEED" --keep --raw \
	--slice-capture "$CAP/slice_state.json" > "$CAP/report.raw" 2> "$CAP/sim_run.err"
SIM_RC=$?
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
fi
printf '%s\n' "$SIM_RC" > "$CAP/sim_run.rc"

BATCH_REL="addons/local_agents/tests/lint_headless_batch.gd"
if [ ! -f "$ROOT/$BATCH_REL" ]; then
	echo "lint_capture: MISSING $BATCH_REL — the headless gates have no batch to read." >&2
	exit 2
fi
rm -f "$CAP"/headless/*.log
BATCH_LOG="$CAP/headless/batch.log"
LA_GODOT_TIMEOUT="${LA_BATCH_TIMEOUT:-900}" la_godot --headless --path "$ROOT" \
	--log-file "$BATCH_LOG" -s "res://$BATCH_REL" > "$CAP/headless/batch.stdout" 2>&1
[ -s "$BATCH_LOG" ] || cp "$CAP/headless/batch.stdout" "$BATCH_LOG"

awk -v dir="$CAP/headless" '
	/^LA_BATCH_BEGIN=/ { name = substr($0, index($0, "=") + 1); out = dir "/" name ".log"; printf "" > out; next }
	/^LA_BATCH_END=/   { out = ""; next }
	out != "" { print >> out }
' "$BATCH_LOG"

printf '%s\n' "$CAP"
exit 0
