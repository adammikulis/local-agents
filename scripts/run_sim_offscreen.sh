#!/usr/bin/env bash
# Launch the voxel sim for non-interactive runs (--run-frames/--shoot) WITHOUT interrupting the user:
# the window is positioned off-screen to the BOTTOM-LEFT (off the left edge + below the visible area, so it's
# out of view) AND keyboard focus is handed back to whatever app was frontmost, so a verification run never
# steals attention. Override the position with LA_WIN_POS="x,y". Pass the normal godot args, e.g.:
#   scripts/run_sim_offscreen.sh --path . addons/.../VoxelWorld.tscn -- --run-frames=200
# Env passthrough (LA_NO_STREAMER etc.) works as usual. Requires macOS (osascript); elsewhere it just runs.
# Test runs are SILENT by default (no audio during the dev loop) — the shipped game keeps audio on.
# Force audio on for a specific test with `LA_NO_AUDIO=0 scripts/run_sim_offscreen.sh ...`.
export LA_NO_AUDIO="${LA_NO_AUDIO:-1}"
# Hard watchdog: kill godot if it runs past LA_RUN_TIMEOUT seconds (default 240). A crashed/hung sim that
# never reaches --run-frames (GPU stall, infinite loop, assert spin) would otherwise orphan past the outer
# `timeout` because godot is backgrounded here — the watchdog guarantees the run always terminates.
RUN_TIMEOUT="${LA_RUN_TIMEOUT:-240}"
FRONT_BID="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
# Bottom-left + off-view: negative X pushes the whole window off the left edge; the large Y drops it below the
# visible desktop — so it consistently lands out of view toward the bottom-left, never over the user's work.
WIN_POS="${LA_WIN_POS:--2400,1600}"
godot --rendering-driver metal --position "$WIN_POS" --resolution "${LA_RES:-640x400}" "$@" &
GODOT_PID=$!
( sleep "$RUN_TIMEOUT"; kill -KILL "$GODOT_PID" 2>/dev/null && echo "RUN_TIMEOUT: killed godot after ${RUN_TIMEOUT}s (did not finish)" >&2 ) &
WATCHDOG_PID=$!
if [ -n "$FRONT_BID" ]; then
  # Godot grabs focus during startup; reclaim it for the user's app a few times as it comes up.
  for d in 0.4 1.0 2.0 3.5; do
    ( sleep "$d"; osascript -e "tell application id \"$FRONT_BID\" to activate" >/dev/null 2>&1 ) &
  done
fi
wait "$GODOT_PID"
GODOT_RC=$?
# Godot exited on its own (finished, crashed, or was watchdog-killed) — cancel the watchdog and reap it.
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null
exit "$GODOT_RC"
