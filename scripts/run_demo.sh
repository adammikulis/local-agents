#!/usr/bin/env bash
# Run the addon's example scenes BARE HEADLESS — the fast path for verification.
#
#   scripts/run_demo.sh --list              # which scenes honour --run-frames, and which do not
#   scripts/run_demo.sh BoxFieldDemo        # one demo, 40 frames
#   scripts/run_demo.sh BoxFieldDemo 200    # one demo, 200 frames
#   scripts/run_demo.sh --all [frames]      # every demo that honours the contract
#
# Why this exists: scripts/run_sim_offscreen.sh opens a real window, which only game/VoxelWorld.tscn
# actually needs (its field is a compute shader; headless has no compute device, and the headless run
# silently reports an EMPTY field rather than failing). Every example scene runs headless in ~1s.
# Measured on this tree 2026-07-28 (see the run_sim_offscreen.sh header for the windowed comparison).
#
# `--run-frames` is not an engine flag — it is a contract implemented by LocalAgentDemoHarness
# (addons/local_agents/runtime/DemoHarness.gd). A scene with no harness IGNORES it and runs forever,
# which is the real reason a wrapper run used to burn its whole timeout. This script detects harness
# support per scene and refuses the others up front instead of hanging on them.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
EXAMPLES_REL="addons/local_agents/examples"
EXAMPLES_DIR="$REPO_ROOT/$EXAMPLES_REL"
DEFAULT_FRAMES="${LA_DEMO_FRAMES:-40}"
# Ceiling per demo. These finish in ~1s; anything near the ceiling is a scene that stopped self-terminating.
DEMO_TIMEOUT="${LA_DEMO_TIMEOUT:-60}"

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

# A scene honours the run contract when it (or its sibling script) builds a LocalAgentDemoHarness.
# Detected, never hardcoded, so this stays true as other scenes gain or lose the harness.
supports_contract() {
  local name="$1"
  grep -qs 'DemoHarness' "$EXAMPLES_DIR/$name.gd" "$EXAMPLES_DIR/$name.tscn"
}

list_demos() {
  local f name
  for f in "$EXAMPLES_DIR"/*.tscn; do
    name="$(basename "$f" .tscn)"
    if supports_contract "$name"; then
      printf '  %-24s honours --run-frames\n' "$name"
    else
      printf '  %-24s no harness — ignores --run-frames, would run forever\n' "$name"
    fi
  done
  echo ""
  echo "  Scenes with no harness: run them with the engine flag instead, e.g."
  echo "    $GODOT --headless --path . $EXAMPLES_REL/<name>.tscn --quit-after 120"
  echo "  game/VoxelWorld.tscn needs a real window: use scripts/run_sim_offscreen.sh."
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
  if ! supports_contract "$name"; then
    echo "run_demo: '$name' has no LocalAgentDemoHarness — it ignores --run-frames and never exits." >&2
    echo "run_demo: run it with the engine flag instead:" >&2
    echo "  $GODOT --headless --path . $scene --quit-after 120" >&2
    return 2
  fi

  local log start rc elapsed marker
  log="$(mktemp -t la_run_demo)"
  start="$(now_ms)"
  set +e
  ( cd "$REPO_ROOT" && "$GODOT" --headless --path . "$scene" -- --run-frames="$frames" ) >"$log" 2>&1 &
  local child=$!
  # Poll in one-second slices rather than one long `sleep $DEMO_TIMEOUT`. A single long sleep survives the
  # kill below (SIGTERM reaps the subshell, not the sleep it is blocked in) and the orphan keeps this
  # script's stdout open — which stalls any caller reading us through a pipe for the WHOLE timeout.
  # Measured: `agent_harness.sh demo --all` took 64s that way and 4s this way. The slice loop exits within
  # a second of the child, so nothing outlives the run.
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

  # `|| true` is load-bearing: under `set -eo pipefail` a no-match grep exits 1 and killed the script
  # RIGHT HERE — taking the whole failure-reporting path below with it. A failing demo printed only a
  # kill line, dumped no output, emitted no RUN_DEMO line, leaked its temp log, and aborted --all
  # before the remaining demos ran. The one case this code exists to handle was the one it could not
  # reach. Match the completion sentinel first, then fall back to any report-shaped line.
  marker="$(grep -aE '^LA_RUN_COMPLETE=' "$log" | tail -n 1 || true)"
  if [ -z "$marker" ]; then
    marker="$(grep -aE '^([A-Z][A-Z0-9_]*=\{|SHOT_SAVED=)' "$log" | tail -n 1 || true)"
  fi
  if [ -n "$marker" ]; then
    echo "$marker"
  else
    echo "run_demo: $name produced NO completion marker (rc=$rc). Full output:" >&2
    cat "$log" >&2
    if [ "$rc" -eq 0 ]; then rc=1; fi
  fi
  # Parse/script errors do not always change the exit code; treat them as failure like agent_harness does.
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
    for f in "$EXAMPLES_DIR"/*.tscn; do
      name="$(basename "$f" .tscn)"
      supports_contract "$name" || continue
      ran=$((ran + 1))
      # `|| rc=$?` rather than `set +e` around the call: run_one re-enables `set -e` internally and
      # leaks it back to this loop, so a failing demo aborted --all and hid every demo after it. The
      # `||` form is exempt from set -e no matter what the callee does to shell options.
      rc=0
      run_one "$name" "$frames" || rc=$?
      if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); fi
    done
    printf 'RUN_DEMO_ALL={"ran":%d,"failed":%d,"frames":%d}\n' "$ran" "$failed" "$frames"
    [ "$failed" -eq 0 ] || exit 1
    exit 0
    ;;
  *)
    run_one "$1" "${2:-$DEFAULT_FRAMES}"
    exit $?
    ;;
esac
