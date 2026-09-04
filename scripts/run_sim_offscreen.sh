#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_import.sh"
# Launch a WINDOWED (GPU) run without interrupting the user: the window is positioned off-screen and
# keyboard focus is handed back to whatever app was frontmost, so a verification run never steals
# attention. Override the position with LA_WIN_POS="x,y". Pass the normal godot args, e.g.:
#   scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=200
# Env passthrough (LA_NO_STREAMER etc.) works as usual. Requires macOS (osascript); elsewhere it just runs.
#
# USE THIS ONLY FOR SCENES THAT NEED A REAL GPU: game/VoxelWorld.tscn, whose field is a compute shader and
# whose report measures nothing headless, because headless has no compute device. Every example scene under
# addons/local_agents/examples/ runs bare headless — use scripts/run_demo.sh for those.
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
# (Off-screen, not minimized: a minimized Metal window stops rendering, which would break --shoot capture,
# which draws into a SubViewport while the window itself stays one pixel.)
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
# Match the scene's OWN completion marker, never a shape a report body happens to share: VoxelWorld
# prints POP_TRACE={"frame":...} periodically, and a pattern loose enough to catch that arms the grace
# clock mid-run and SIGKILLs a healthy run before its SIM_REPORT.
#
# Every harness now prints one dedicated sentinel immediately before quitting
# (LocalAgentDemoHarness.print_complete -> `LA_RUN_COMPLETE={"code":N}`), so detection is explicit
# and no progress line can spoof it. Override LA_DONE_RE only for a scene with no harness at all.
DONE_RE="${LA_DONE_RE:-^LA_RUN_COMPLETE=}"

# Off-view far enough that no window width puts an edge back on screen. lib_godot.sh applies it.
DEFAULT_WIN_POS="99999,99999"
WIN_POS="${LA_WIN_POS:-$DEFAULT_WIN_POS}"
RENDER_DRIVER="${LA_RENDER_DRIVER:-metal}"

# --- STALE-SHADER GUARD ------------------------------------------------------
# A kernel whose compiled resource was built from other source, kernel or #include, loads OLD and says
# nothing: the run completes and every SIM_REPORT number is fiction. lib_import.sh answers, by content.
# FAIL, DO NOT AUTO-FIX: a measurement wrapper that quietly mutates the import cache is the hidden side
# effect this project bans on authoritative paths. LA_SKIP_SHADER_CHECK=1 bypasses, for a tree meant to
# be unimported.

if [ "${LA_SKIP_SHADER_CHECK:-0}" != "1" ]; then
  proj="."
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--path" ]; then proj="$arg"; break; fi
    prev="$arg"
  done
  if [ -d "$proj/.godot/imported" ]; then
    stale_list=""
    stale_n=0
    while IFS= read -r base; do
      stale_n=$((stale_n + 1))
      if [ "$stale_n" -le 8 ]; then stale_list="$stale_list
    $base"; fi
    done < <(la_stale_kernels "$proj")
    if [ "$stale_n" -gt 0 ]; then
      {
        echo "STALE_SHADERS={\"count\":$stale_n,\"path\":\"$proj\"}"
        echo ""
        echo "REFUSING TO RUN: $stale_n compute kernel(s) do not match the source they were compiled from,"
        echo "  kernel or #include, so Godot would load the OLD kernel and print a normal-looking SIM_REPORT"
        echo "  built on it. Stale:$stale_list"
        if [ "$stale_n" -gt 8 ]; then echo "    ... and $((stale_n - 8)) more"; fi
        echo ""
        echo "  Fix:  scripts/godot_import.sh $proj"
        echo "  Then re-run. Bypass with LA_SKIP_SHADER_CHECK=1 only if you MEAN to run an unimported tree."
      } >&2
      exit 3
    fi
  fi
fi

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
  TAP="$(mktemp "${TMPDIR:-/tmp}/la_offscreen_tap.XXXXXX")"
  LOG_ARGS=(--log-file "$TAP")
fi
REASON_FILE="$(mktemp "${TMPDIR:-/tmp}/la_offscreen_reason.XXXXXX")"
# The tap duplicates output that already streamed to this script's stdout, so nothing is lost by
# discarding it. `--log-file` rotates, so clear the siblings godot may have made next to it too.
# ONE SIM AT A TIME ON THIS MACHINE, AND IT IS HELD FOR THE WHOLE RUN — the watchdog and the census after
# it, not just the launch. la_godot takes the same lock for every engine start-up and sees this holder's
# marker, so the run acquires it once.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot_lock.sh"
GPU_HELD=0
la_gpu_lock
case $? in
  0) GPU_HELD=1 ;;
  2) ;;
  *) echo "run_sim_offscreen: timed out waiting for the GPU lock." >&2; exit 2 ;;
esac

cleanup() {
  [ "$GPU_HELD" -eq 1 ] && la_gpu_unlock
  if [ -n "$REASON_FILE" ]; then rm -f "$REASON_FILE"; fi
  if [ -n "${LOG_ARGS[*]}" ] && [ -n "$TAP" ]; then rm -f "$TAP" "$TAP".*; fi
}
trap cleanup EXIT

LA_WIN_POS="$WIN_POS" la_godot --rendering-driver "$RENDER_DRIVER" \
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

# --- CONSERVATION: A RUN THAT BREAKS THE LAW IS A FAILED RUN ------------------------------------------------
# Once the world is sealed, matter and energy are closed apart from booked exchange.
# LAMaterialFieldConservation3D audits every gated quantity at a fixed horizon past the seal.
#
# TWO FINDINGS, TWO CODES, AND A BREACH OUTRANKS A STARVED AUDIT. A run whose books COULD NOT ANSWER is
# not a clean run, and exiting 0 on one is the same silent pass a missing gate gives.
#   126  CONSERVATION_VIOLATION — a quantity drifted past the float floor
#   123  CONSERVATION_UNMEASURED — the audit ran and a quantity had no number to give
#   122  PRESSURE_BROKEN — pressure fell going DOWN
if [ "$TAP" != "caller-owned" ] && [ -f "$TAP" ] && [ "$GODOT_RC" -eq 0 ]; then
  if grep -q '^CONSERVATION_VIOLATION=' "$TAP" 2>/dev/null; then
    echo "CONSERVATION_FAILED={\"count\":$(grep -c '^CONSERVATION_VIOLATION=' "$TAP")}" >&2
    grep '^CONSERVATION_VIOLATION=' "$TAP" >&2
    GODOT_RC=126
  elif grep -q '^CONSERVATION_UNMEASURED=' "$TAP" 2>/dev/null; then
    grep '^CONSERVATION_UNMEASURED=' "$TAP" >&2
    echo "CONSERVATION_UNMEASURED: the audit could not answer, so this run proves nothing about the law." >&2
    GODOT_RC=123
  elif grep -q '^PRESSURE_BROKEN=' "$TAP" 2>/dev/null; then
    grep '^PRESSURE_BROKEN=' "$TAP" | tail -1 >&2
    echo "PRESSURE_BROKEN: pressure fell going down." >&2
    GODOT_RC=122
  fi
fi
exit "$GODOT_RC"
