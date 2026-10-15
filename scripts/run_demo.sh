#!/usr/bin/env bash
# Run the addon's example scenes headless. A fragment (scripts/lib_demo_fragment.sh) is not run.
#   scripts/run_demo.sh --list              # which scenes honour --run-frames, and which do not
#   scripts/run_demo.sh BoxFieldDemo        # one demo, 40 frames
#   scripts/run_demo.sh BoxFieldDemo 200    # one demo, 200 frames
#   scripts/run_demo.sh --all [frames]      # every demo that honours the contract and needs no window

# `--run-frames` is LocalAgentDemoHarness's contract (addons/local_agents/runtime/DemoHarness.gd), not an
# engine flag: a scene with no harness ignores it and never exits, so it is refused.
set -eo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_demo_fragment.sh" || exit 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
EXAMPLES_REL="addons/local_agents/examples"
EXAMPLES_DIR="$REPO_ROOT/$EXAMPLES_REL"
DEFAULT_FRAMES="${LA_DEMO_FRAMES:-40}"
# Ceiling per demo, seconds, counted once this run holds the machine's GPU lock.
DEMO_TIMEOUT="${LA_DEMO_TIMEOUT:-60}"
GPU_HELD=0
# The lock library is written for errexit off; `|| true` runs it so.
trap 'if [ "$GPU_HELD" -eq 1 ]; then la_gpu_unlock || true; fi' EXIT

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

supports_contract() {
  demo_has_harness "$REPO_ROOT" "$EXAMPLES_REL/$1.tscn"
}

list_demos() {
  local f name why
  for f in "$EXAMPLES_DIR"/*.tscn; do
    name="$(basename "$f" .tscn)"
    if demo_fragment_parent "$REPO_ROOT" "$EXAMPLES_REL/$name.tscn" >/dev/null; then continue; fi
    if why="$(demo_window_reason "$REPO_ROOT" "$EXAMPLES_REL/$name.tscn")"; then
      printf '  %-24s needs a window, it %s — scripts/run_sim_offscreen.sh\n' "$name" "$why"
    elif supports_contract "$name"; then
      printf '  %-24s honours --run-frames\n' "$name"
    else
      printf '  %-24s no harness — ignores --run-frames, would run forever\n' "$name"
    fi
  done
  echo ""
  echo "  Scenes with no harness: run them with the engine flag instead, e.g."
  echo "    $GODOT --headless --path . $EXAMPLES_REL/<name>.tscn --quit-after 120"
  echo "  game/VoxelWorld.tscn, the scenes inheriting it and the scenes holding a SPHERE LocalAgentSimWorld"
  echo "  need a real window: use scripts/run_sim_offscreen.sh."
}

# Returns the child's exit code; prints the marker line it emitted.
run_one() {
  local name="$1"
  local frames="$2"
  local scene="$EXAMPLES_REL/$name.tscn"
  if [ ! -f "$REPO_ROOT/$scene" ]; then
    echo "run_demo: no such demo '$name' (try --list)" >&2
    return 2
  fi
  local parent frag=0
  parent="$(demo_fragment_parent "$REPO_ROOT" "$scene")" || frag=$?
  if [ "$frag" -eq 0 ]; then
    echo "run_demo: '$name' is a fragment of $parent, not a scene to run." >&2
    return 2
  fi
  [ "$frag" -eq 1 ] || return 2
  local why
  if why="$(demo_window_reason "$REPO_ROOT" "$scene")"; then
    echo "run_demo: '$name' $why; a planet's field needs a compute device, which headless lacks." >&2
    echo "  scripts/run_sim_offscreen.sh --path . $scene -- --run-frames=$frames" >&2
    return 2
  fi
  if ! supports_contract "$name"; then
    echo "run_demo: '$name' has no LocalAgentDemoHarness — it ignores --run-frames and never exits." >&2
    echo "run_demo: run it with the engine flag instead:" >&2
    echo "  $GODOT --headless --path . $scene --quit-after 120" >&2
    return 2
  fi

  local log start rc elapsed marker lock_rc=0
  # la_godot waits for the lock otherwise, inside the demo's clock.
  la_gpu_lock || lock_rc=$?
  case "$lock_rc" in
    0) GPU_HELD=1 ;;
    2) ;;
    *) echo "run_demo: timed out waiting for the GPU lock; '$name' did not run." >&2; return 2 ;;
  esac
  log="$(mktemp "${TMPDIR:-/tmp}/la_run_demo.XXXXXX")"
  start="$(now_ms)"
  set +e
  ( cd "$REPO_ROOT" && la_godot --headless --path . "$scene" -- --run-frames="$frames" ) >"$log" 2>&1 &
  local child=$!
  # One-second slices: one long sleep would outlive the kill and hold this script's stdout open.
  (
    waited=0
    while [ "$waited" -lt "$DEMO_TIMEOUT" ] && kill -0 "$child" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$child" 2>/dev/null; then
      echo "run_demo: '$name' exceeded LA_DEMO_TIMEOUT=${DEMO_TIMEOUT}s without exiting — killing it." >&2
      kill -KILL "$child" 2>/dev/null
    fi
  ) &
  local guard=$!
  wait "$child"
  rc=$?
  kill "$guard" 2>/dev/null
  wait "$guard" 2>/dev/null
  set -e
  elapsed=$(( $(now_ms) - start ))
  if [ "$GPU_HELD" -eq 1 ]; then
    la_gpu_unlock || true
    GPU_HELD=0
  fi

  # The harness prints LA_RUN_COMPLETE on every exit it makes; `|| true` keeps a no-match grep from ending
  # the script under set -e.
  marker="$(grep -aE '^LA_RUN_COMPLETE=' "$log" | tail -n 1 || true)"
  if [ -n "$marker" ]; then
    echo "$marker"
  else
    echo "run_demo: $name produced NO completion marker (rc=$rc). Full output:" >&2
    cat "$log" >&2
    if [ "$rc" -eq 0 ]; then rc=1; fi
  fi
  # A logged SCRIPT ERROR or Parse Error fails the run whatever the exit code.
  if grep -qaE 'SCRIPT ERROR|Parse Error' "$log"; then
    echo "run_demo: $name logged SCRIPT ERROR/Parse Error:" >&2
    grep -aE 'SCRIPT ERROR|Parse Error' "$log" | head -n 5 >&2
    if [ "$rc" -eq 0 ]; then rc=1; fi
  fi
  rm -f "$log"
  printf 'RUN_DEMO={"demo":"%s","frames":%d,"exit_code":%d,"seconds":%d.%03d}\n' \
    "$name" "$frames" "$rc" "$((elapsed / 1000))" "$((elapsed % 1000))"
  return "$rc"
}

case "${1:-}" in
  ""|-h|--help)
    echo "Usage: scripts/run_demo.sh [--list | --all [frames] | <demo> [frames]]"
    echo ""
    list_demos
    exit 0
    ;;
  --list)
    list_demos
    exit 0
    ;;
  --all)
    frames="${2:-$DEFAULT_FRAMES}"
    ran=0
    failed=0
    skipped=0
    for f in "$EXAMPLES_DIR"/*.tscn; do
      name="$(basename "$f" .tscn)"
      if demo_fragment_parent "$REPO_ROOT" "$EXAMPLES_REL/$name.tscn" >/dev/null; then continue; fi
      supports_contract "$name" || continue
      if why="$(demo_window_reason "$REPO_ROOT" "$EXAMPLES_REL/$name.tscn")"; then
        skipped=$((skipped + 1))
        printf 'RUN_DEMO_SKIPPED={"demo":"%s","why":"needs_window","reason":"%s"}\n' "$name" "$why"
        continue
      fi
      ran=$((ran + 1))
      # `|| rc=$?`: run_one turns set -e back on, and the `||` form is exempt from it.
      rc=0
      run_one "$name" "$frames" || rc=$?
      if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); fi
    done
    printf 'RUN_DEMO_ALL={"ran":%d,"failed":%d,"skipped":%d,"frames":%d}\n' "$ran" "$failed" "$skipped" "$frames"
    [ "$failed" -eq 0 ] || exit 1
    exit 0
    ;;
  *)
    run_one "$1" "${2:-$DEFAULT_FRAMES}"
    exit $?
    ;;
esac
