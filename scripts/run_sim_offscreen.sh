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

# --- WHERE THE WINDOW GOES ---------------------------------------------------
# Far right of the SECONDARY display, so a run is watchable without covering the primary. The geometry is
# read at launch rather than hardcoded: `bounds of window of desktop` returns the union of every display, so
# its right edge is the right edge of the rightmost monitor whatever the arrangement. Falls back to
# off-screen if AppleScript answers nothing (headless CI, no window server).
_res="${LA_RES:-640x400}"
_w="${_res%%x*}"
_h="${_res##*x}"
_bounds="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | tr -d ' ')"
if [ -n "$_bounds" ]; then
  _right="$(printf '%s' "$_bounds" | cut -d, -f3)"
  _bottom="$(printf '%s' "$_bounds" | cut -d, -f4)"
  # Primary spans 0..primary_w; anything beyond it is the secondary. Land the window against the far right
  # edge, inset by its own width, and below the menu bar so the title bar stays grabbable.
  _x=$(( _right - _w ))
  _y=40
  # If the desktop is a single display, keep the old off-view behaviour rather than covering the user's screen.
  if [ "$_right" -le 3441 ]; then
    _x=-10000; _y=-10000
  fi
  DEFAULT_WIN_POS="${_x},${_y}"
else
  DEFAULT_WIN_POS="-10000,-10000"
fi
# Fully off-view to the upper-left. The negative X must exceed the WINDOW WIDTH so the right edge also clears
# the screen: at a 1080p test res (1920 px wide) -2400 left only -480 of slack, so a wide window still poked out
# on the left. -10000 clears any width, and matches the in-code reposition (VoxelWorld sends the window to
# -8000,-8000), so neither the initial paint nor the reposition shows.
WIN_POS="${LA_WIN_POS:-$DEFAULT_WIN_POS}"
RENDER_DRIVER="${LA_RENDER_DRIVER:-metal}"

# --- STALE-SHADER GUARD ------------------------------------------------------
# A .glsl whose COMPILED resource under .godot/imported/ is older than the source means Godot loads the OLD
# kernel and says nothing. The run completes, prints a full normal-looking SIM_REPORT, and every number in it
# is fiction.
#
# WHY THIS EXISTS. Measured 2026-08-09: the PRIMARY checkout had 15 kernels whose compiled .res predated their
# source, reactions_sphere3d.glsl by six days and four commits. A 600-frame run there gave `biomass_total`
# 0.0, `snow_cells` 0, `o2_total` 40474, `carbon_total` 606 — against 5.25 / 1160 / 3695 / 12425 from the SAME
# COMMIT in a freshly imported worktree. The entire reaction engine had not run. That run was taken as an A/B
# baseline before the mismatch was spotted, and its whole "before" arm was an artefact of the stale cache.
#
# THE GAP IS IN DOCUMENTED PROCESS, NOT CODE. scripts/new_worktree.sh imports a FRESH worktree and every doc
# says to use it. NOTHING re-imports a LONG-LIVED checkout after a merge lands someone else's kernel edit, so
# the primary checkout rots silently from that moment on.
#
# FAIL, DO NOT AUTO-FIX: a measurement wrapper that quietly mutates the import cache is exactly the hidden
# side effect this project bans on authoritative paths. Name what is stale and how to fix it.
# LA_SKIP_SHADER_CHECK=1 bypasses, for a tree that is meant to be unimported.

# Godot writes the source hash it compiled from into a .md5 beside each resource. That is the FACT; an mtime
# is a proxy, and a checkout or an identical rewrite moves it without changing the content — `--import` then
# has nothing to do, so the warning cannot be cleared and the only way out is the blanket bypass. Returning
# false (no record, no md5 tool) leaves the mtime verdict standing: a missing tool never relaxes the gate.
_shader_hash_matches() {
  src_f="$1"
  rec_f="$2"
  [ -f "$rec_f" ] || return 1
  want_h="$(sed -n 's/^source_md5="\(.*\)"$/\1/p' "$rec_f" | head -1)"
  [ -n "$want_h" ] || return 1
  if command -v md5sum >/dev/null 2>&1; then
    have_h="$(md5sum "$src_f" | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    have_h="$(md5 -q "$src_f")"
  else
    return 1
  fi
  [ "$want_h" = "$have_h" ]
}

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
    while IFS= read -r src; do
      base="$(basename "$src")"
      newest="$(ls -t "$proj"/.godot/imported/"$base"-*.res 2>/dev/null | head -1)"
      # CONTENT, NOT MTIME. Godot reimports by comparing the source md5 against the `source_md5` recorded
      # beside the artifact, so that comparison is authoritative and _shader_hash_matches owns it. An mtime
      # test disagrees with it after any git operation that rewrites the working tree, and a gate that
      # cries wolf gets bypassed.
      if [ -z "$newest" ]; then
        stale=1                                   # no resource at all: load() returns null, pass is dead
      elif _shader_hash_matches "$src" "${newest%.res}.md5"; then
        stale=0
      elif [ "$src" -nt "$newest" ]; then
        stale=1                                   # no record or no md5 tool: the mtime verdict stands
      else
        stale=0
      fi
      if [ "$stale" -eq 1 ]; then
        stale_n=$((stale_n + 1))
        if [ "$stale_n" -le 8 ]; then stale_list="$stale_list
    $base"; fi
      fi
    # SCOPE MATTERS OR THE GUARD CRIES WOLF AND GETS BYPASSED. `.claude/worktrees/` holds whole sibling
    # CHECKOUTS (675 .glsl in this tree against 82 real ones), and `thirdparty/` vendors llama.cpp's and
    # whisper.cpp's Vulkan shaders, which no sim pass loads. What is left is the 34 kernels the field runs.
    done < <(find "$proj" -name '*.glsl' \
      -not -path '*/.godot/*' -not -path '*/.claude/*' -not -path '*/.git/*' \
      -not -path '*/thirdparty/*' 2>/dev/null)
    if [ "$stale_n" -gt 0 ]; then
      {
        echo "STALE_SHADERS={\"count\":$stale_n,\"path\":\"$proj\"}"
        echo ""
        echo "REFUSING TO RUN: $stale_n compute kernel(s) are newer than their compiled resource, so Godot"
        echo "  would load the OLD kernel and print a normal-looking SIM_REPORT built on it. Stale:$stale_list"
        if [ "$stale_n" -gt 8 ]; then echo "    ... and $((stale_n - 8)) more"; fi
        echo ""
        echo "  Fix:  godot --headless --path $proj --import"
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
cleanup() {
  if [ -n "$REASON_FILE" ]; then rm -f "$REASON_FILE"; fi
  if [ -n "${LOG_ARGS[*]}" ] && [ -n "$TAP" ]; then rm -f "$TAP" "$TAP".*; fi
}
trap cleanup EXIT

LA_WIN_POS="$WIN_POS" godot --rendering-driver "$RENDER_DRIVER" --position "$WIN_POS" --resolution "${LA_RES:-640x400}" \
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

# --- CONSERVATION: A RUN THAT BREAKS THE LAW IS A FAILED RUN ------------------------------------------------
# Once the world is sealed, matter and energy are closed apart from booked exchange.
# LAMaterialFieldConservation3D audits every gated quantity at a fixed horizon past the seal.
#
# TWO FINDINGS, TWO CODES, AND A BREACH OUTRANKS A STARVED AUDIT. A run whose books COULD NOT ANSWER is not
# a clean run; it used to exit 0, which is the same silent pass a missing gate gives.
#   126  CONSERVATION_VIOLATION — a quantity drifted past the float floor
#   123  CONSERVATION_UNMEASURED — the audit ran and a quantity had no number to give
if [ "$TAP" != "caller-owned" ] && [ -f "$TAP" ] && [ "$GODOT_RC" -eq 0 ]; then
  if grep -q '^CONSERVATION_VIOLATION=' "$TAP" 2>/dev/null; then
    echo "CONSERVATION_FAILED={\"count\":$(grep -c '^CONSERVATION_VIOLATION=' "$TAP")}" >&2
    grep '^CONSERVATION_VIOLATION=' "$TAP" >&2
    GODOT_RC=126
  elif grep -q '^CONSERVATION_UNMEASURED=' "$TAP" 2>/dev/null; then
    grep '^CONSERVATION_UNMEASURED=' "$TAP" >&2
    echo "CONSERVATION_UNMEASURED: the audit could not answer, so this run proves nothing about the law." >&2
    GODOT_RC=123
  fi
fi
exit "$GODOT_RC"
