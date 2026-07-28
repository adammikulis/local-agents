#!/usr/bin/env bash
# Launch a WINDOWED (GPU) run without interrupting the user: the window is positioned off-screen and
# keyboard focus is handed back to whatever app was frontmost, so a verification run never steals
# attention. Override the position with LA_WIN_POS="x,y". Pass the normal godot args, e.g.:
#   scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=200
# Env passthrough (LA_NO_STREAMER etc.) works as usual. Requires macOS (osascript); elsewhere it just runs.
#
# USE THIS ONLY FOR SCENES THAT NEED A REAL GPU: game/VoxelWorld.tscn (its field is a compute shader, and
# headless has no compute device). Every example scene under addons/local_agents/examples/ runs BARE
# HEADLESS in ~1-2s — use scripts/run_demo.sh for those. Measured 2026-07-28 on this tree:
#   BoxFieldDemo         headless 0.8s / windowed 1.7s   (both rc 0)
#   ThinkingCreatureDemo headless 0.9s / windowed 1.1s   (both rc 0)
#   SimWorldPlanetDemo   headless 1.7s / windowed 1.9s   (both rc 0)
#   CoreCreatureSmoke    headless 0.8s / windowed 1.0s   (both rc 0)
#   VoxelWorld           windowed 8.7s rc 0 (it DOES boot headless in ~6s, but with no
#                        compute device the field is empty, so the report measures nothing)
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

# --- watchdog budgets --------------------------------------------------------
# Hard ceiling on the whole run. 60s, not the old 240s: every scene this wrapper is meant for finishes in
# under 10s, so a run that reaches the ceiling is a FAILURE to report, not a long computation to wait out.
# The old 240s default meant a scene that ignores --run-frames burned four minutes and then said nothing
# useful about why. Raise it explicitly (LA_RUN_TIMEOUT=600) for a deliberately long soak run.
RUN_TIMEOUT="${LA_RUN_TIMEOUT:-60}"
# Once the scene has printed its completion marker its remaining work is one idle frame plus the hard exit.
# If it is still alive this many seconds later, the EXIT path is broken (not the scene) and we say so.
EXIT_GRACE="${LA_EXIT_GRACE:-10}"
# A run is "done" when the scene SAYS so, not when a line happens to look like a report.
#
# This used to match "an all-caps token followed by ={quote}", reasoning that only a JSON report body
# has quoted keys. VoxelWorld's own POP_TRACE={"frame":180,...} — printed every 180 frames by
# game/world/VoxelHarness.gd — matches that exactly, so the grace clock armed at frame 180 and this
# watchdog SIGKILLed healthy 800- and 1200-frame runs long before their SIM_REPORT. Measured: 300
# frames passed, 800 and 1200 died at ~26s with rc 125 and a confidently wrong "the EXIT path is
# broken" diagnosis.
#
# Every harness now prints one dedicated sentinel immediately before quitting
# (LocalAgentDemoHarness.print_complete -> `LA_RUN_COMPLETE={"code":N}`), so detection is explicit
# and no progress line can spoof it. Override LA_DONE_RE only for a scene with no harness at all.
DONE_RE="${LA_DONE_RE:-^LA_RUN_COMPLETE=}"

FRONT_BID="$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
# Fully off-view to the upper-left. The negative X must exceed the WINDOW WIDTH so the right edge also clears
# the screen: at a 1080p test res (1920 px wide) -2400 left only -480 of slack, so a wide window still poked out
# on the left. -10000 clears any width, and matches the in-code reposition (VoxelWorld sends the window to
# -8000,-8000), so neither the initial paint nor the reposition shows.
WIN_POS="${LA_WIN_POS:--10000,-10000}"
RENDER_DRIVER="${LA_RENDER_DRIVER:-metal}"

# --- output tap --------------------------------------------------------------
# The watchdog needs to see the child's output to tell "never got there" from "got there and hung". Godot's
# own `--log-file` gives that for free and flushes live (verified), so the child's stdout/stderr stay wired
# DIRECTLY to this script's — no tee, no process substitution, nothing that could truncate or reorder the
# report line the caller is reading. If the caller supplies their own --log-file we leave it alone and the
# watchdog falls back to a plain ceiling.
TAP=""
REASON_FILE=""
for arg in "$@"; do
  if [ "$arg" = "--log-file" ]; then
    TAP="caller-owned"
    break
  fi
done
LOG_ARGS=()
if [ -z "$TAP" ]; then
  TAP="$(mktemp -t la_offscreen_tap)"
  LOG_ARGS=(--log-file "$TAP")
fi
REASON_FILE="$(mktemp -t la_offscreen_reason)"
# The tap duplicates output that already streamed to this script's stdout, so nothing is lost by
# discarding it. `--log-file` rotates, so clear the siblings godot may have made next to it too.
cleanup() {
  if [ -n "$REASON_FILE" ]; then rm -f "$REASON_FILE"; fi
  if [ -n "${LOG_ARGS[*]}" ] && [ -n "$TAP" ]; then rm -f "$TAP" "$TAP".*; fi
}
trap cleanup EXIT

godot --rendering-driver "$RENDER_DRIVER" --position "$WIN_POS" --resolution "${LA_RES:-640x400}" \
  "${LOG_ARGS[@]}" "$@" &
GODOT_PID=$!

# Poll once a second: cheap, and it lets the wrapper distinguish the two failure modes instead of silently
# burning the whole budget on both.
(
  elapsed=0
  marker_at=-1
  while kill -0 "$GODOT_PID" 2>/dev/null; do
    if [ "$marker_at" -lt 0 ] && [ "$TAP" != "caller-owned" ] && grep -qE "$DONE_RE" "$TAP" 2>/dev/null; then
      marker_at="$elapsed"
    fi
    if [ "$marker_at" -ge 0 ] && [ "$((elapsed - marker_at))" -ge "$EXIT_GRACE" ]; then
      echo "hung_after_report" > "$REASON_FILE"
      {
        echo ""
        echo "RUN_HUNG_AFTER_REPORT: the scene printed its completion marker ${EXIT_GRACE}s ago and the"
        echo "  process is STILL RUNNING. The scene did its job; the EXIT path is what is broken. Check that"
        echo "  the quit call reaches LAAppExit.quit() and that LAProcess.exit_now fires (ClassDB must know"
        echo "  LAProcess — an unbuilt/unloaded GDExtension drops you to tree.quit(), which on Metal can"
        echo "  stall or abort). Killing after ${elapsed}s."
      } >&2
      kill -KILL "$GODOT_PID" 2>/dev/null
      exit 0
    fi
    if [ "$elapsed" -ge "$RUN_TIMEOUT" ]; then
      echo "timeout_no_report" > "$REASON_FILE"
      {
        echo ""
        echo "RUN_TIMEOUT: killed godot after ${RUN_TIMEOUT}s — it never printed a completion marker."
        echo "  The usual cause is NOT a hang: the scene simply does not implement the --run-frames contract,"
        echo "  so the flag was ignored and the scene ran forever. Only scenes carrying a"
        echo "  LocalAgentDemoHarness (runtime/DemoHarness.gd) honour --run-frames / --shoot; of the twelve"
        echo "  example scenes only five do. Use 'scripts/run_demo.sh --list' to see which."
        echo "  Engine-level fallback for any other scene: godot --quit-after <iterations>."
        echo "  Raise the ceiling for a deliberate soak run with LA_RUN_TIMEOUT=<seconds>."
      } >&2
      kill -KILL "$GODOT_PID" 2>/dev/null
      exit 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
) &
WATCHDOG_PID=$!

if [ -n "$FRONT_BID" ]; then
  # Godot grabs focus during startup; reclaim it for the user's app a few times as it comes up.
  # The `>/dev/null 2>&1` is on the SUBSHELL, not just osascript: these outlive a fast run, and while
  # they hold this script's inherited stdout they hold open the write end of any pipe the caller reads
  # us through — measured 3.8s vs 1.7s for the same BoxFieldDemo run just from that. (This was never
  # the cause of the old 240s runs; that was scenes with no harness. It is only a couple of seconds.)
  for d in 0.4 1.0 2.0 3.5; do
    ( sleep "$d"; osascript -e "tell application id \"$FRONT_BID\" to activate" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  done
fi
wait "$GODOT_PID"
GODOT_RC=$?
# Godot exited on its own (finished, crashed, or was watchdog-killed) — cancel the watchdog and reap it.
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

# A watchdog kill lands as rc 137 (SIGKILL), which reads like a crash. Re-map it to a code that says which
# failure it was, so a caller can tell "the scene never self-terminates" from "the sim actually died".
REASON="$(cat "$REASON_FILE" 2>/dev/null)"
if [ "$REASON" = "timeout_no_report" ]; then
  GODOT_RC=124
elif [ "$REASON" = "hung_after_report" ]; then
  GODOT_RC=125
fi
exit "$GODOT_RC"
