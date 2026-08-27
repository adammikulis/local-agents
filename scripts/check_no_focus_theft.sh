#!/usr/bin/env bash
# A GPU run may never become the frontmost app. Samples the frontmost bundle id for the whole run.
# EXIT 0 clean · 1 the sim or SystemUIServer was frontmost · 2 the run did not complete.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(uname)" = "Darwin" ] || { echo "check_no_focus_theft: OK (not macOS)"; exit 0; }
command -v osascript >/dev/null 2>&1 || { echo "check_no_focus_theft: no osascript" >&2; exit 2; }
SAMPLES="$(mktemp -t la_front)"
front() { osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null; }
( while :; do front >> "$SAMPLES"; sleep 0.1; done ) &
POLL=$!
LOG="$(mktemp -t la_focus_run)"
"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" addons/local_agents/game/VoxelWorld.tscn -- \
	--sandbox --run-frames=2 --seed=1 --bare --planet-only --no-fauna > "$LOG" 2>&1
rc=$?
kill "$POLL" 2>/dev/null; wait "$POLL" 2>/dev/null
if ! grep -q '^LA_RUN_COMPLETE=' "$LOG"; then
	echo "check_no_focus_theft: the run did not complete (rc=$rc); cannot judge focus." >&2
	rm -f "$SAMPLES" "$LOG"; exit 2
fi
rm -f "$LOG"
if grep -qE 'com\.localagents\.godot-agent|com\.apple\.systemuiserver' "$SAMPLES"; then
	echo "FAIL  the sim took the foreground during a run:" >&2
	sort "$SAMPLES" | uniq -c >&2
	rm -f "$SAMPLES"; exit 1
fi
n="$(wc -l < "$SAMPLES" | tr -d ' ')"
rm -f "$SAMPLES"
[ "$n" -gt 0 ] || { echo "check_no_focus_theft: no samples taken" >&2; exit 2; }
echo "check_no_focus_theft: OK (the sim was never frontmost over $n samples)"
