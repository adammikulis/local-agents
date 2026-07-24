#!/usr/bin/env bash
# Launch the voxel sim for non-interactive runs (--run-frames/--shoot) WITHOUT interrupting the user:
# the window is positioned off-screen to the BOTTOM-LEFT (off the left edge + below the visible area, so it's
# out of view) AND keyboard focus is handed back to whatever app was frontmost, so a verification run never
# steals attention. Override the position with LA_WIN_POS="x,y". Pass the normal godot args, e.g.:
#   scripts/run_sim_offscreen.sh --path . addons/.../VoxelWorld.tscn -- --run-frames=200
# Env passthrough (LA_NO_STREAMER etc.) works as usual. Requires macOS (osascript); elsewhere it just runs.
# Rendering driver defaults to metal (this project's verified default — cel-shading/water/sky shaders have
# all been built and checked against it). Override with LA_RENDER_DRIVER=vulkan for a one-off diagnostic run
# (e.g. real GPU-side timestamp queries via RenderingDevice.get_captured_timestamp_gpu_time — Metal's Godot
# 4.7 backend always returns 0 there, MoltenVK/Vulkan returns real values; see MaterialSphereGPU3D.gd). Not
# yet verified as a safe DEFAULT switch — that needs a real visual check of every shader path, not just this.
# Test runs are SILENT by default (no audio during the dev loop) — the shipped game keeps audio on.
# Force audio on for a specific test with `LA_NO_AUDIO=0 scripts/run_sim_offscreen.sh ...`.
export LA_NO_AUDIO="${LA_NO_AUDIO:-1}"
# Route EVERY window this process opens off-view, not just the main sim window. The CLI --position below
# only moves the first/main window; a secondary window the game pops up (the model-download / model-manager
# panel — the "DEBUG" banner + Qwen model list) is hidden by the in-code LA_OFFSCREEN guards instead. Setting
# it here makes those guards fire for agent/test runs so no stray window ever appears in front of the user.
# (Off-screen, not minimized: a minimized Metal window stops rendering, which would break --shoot capture.)
export LA_OFFSCREEN="${LA_OFFSCREEN:-1}"
# Hard watchdog: kill godot if it runs past LA_RUN_TIMEOUT seconds (default 240). A crashed/hung sim that
# never reaches --run-frames (GPU stall, infinite loop, assert spin) would otherwise orphan past the outer
# `timeout` because godot is backgrounded here — the watchdog guarantees the run always terminates.
RUN_TIMEOUT="${LA_RUN_TIMEOUT:-240}"
FRONT_BID="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
# Fully off-view to the upper-left. The negative X must exceed the WINDOW WIDTH so the right edge also clears
# the screen: at a 1080p test res (1920 px wide) -2400 left only -480 of slack, so a wide window still poked out
# on the left. -10000 clears any width, and matches the in-code reposition (VoxelWorld sends the window to
# -8000,-8000), so neither the initial paint nor the reposition shows.
WIN_POS="${LA_WIN_POS:--10000,-10000}"
RENDER_DRIVER="${LA_RENDER_DRIVER:-metal}"
godot --rendering-driver "$RENDER_DRIVER" --position "$WIN_POS" --resolution "${LA_RES:-640x400}" "$@" &
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
