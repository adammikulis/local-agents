#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_TIMEOUT=45

usage() {
  cat <<USAGE
Usage: scripts/run_fps_fire_destroy.sh [--timeout=<seconds>] [--test_mode_minimized=<true|false>]

Launches Godot in windowed mode and runs the deterministic FPS fire destroy harness.
Exit code:
  0 = harness pass
  1 = harness failure or timeout
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

timeout="$DEFAULT_TIMEOUT"
test_mode_minimized="true"
for arg in "$@"; do
  if [[ "$arg" == --timeout=* ]]; then
    timeout="${arg#--timeout=}"
    continue
  fi
  if [[ "$arg" == --test_mode_minimized=* ]]; then
    test_mode_minimized="${arg#--test_mode_minimized=}"
    continue
  fi
  echo "Unknown argument: $arg" >&2
  usage
  exit 2
done

if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -le 0 ]]; then
  echo "Invalid --timeout value '$timeout'; expected positive integer seconds." >&2
  exit 2
fi

if [[ "$test_mode_minimized" != "true" && "$test_mode_minimized" != "false" ]]; then
  echo "Invalid --test_mode_minimized value '$test_mode_minimized'; expected true or false." >&2
  exit 2
fi

cd "$REPO_ROOT"
cmd=(godot --disable-crash-handler -- --test_mode=fps_fire_destroy "--test_mode_minimized=$test_mode_minimized")
pass_marker="fps_fire_destroy harness passed."
fail_marker="fps_fire_destroy harness failed."
result_marker=""
log_file="$(mktemp)"
timeout_flag="$(mktemp)"
rm -f "$timeout_flag"

cleanup() {
  rm -f "$log_file"
  rm -f "$timeout_flag"
}
trap cleanup EXIT

"${cmd[@]}" > >(tee "$log_file") 2>&1 &
godot_pid=$!

(
  sleep "$timeout"
  if kill -0 "$godot_pid" 2>/dev/null; then
    echo "timeout" > "$timeout_flag"
    echo "run_fps_fire_destroy.sh timed out after ${timeout}s; requesting graceful exit." >&2
    kill -TERM "$godot_pid" 2>/dev/null || true
    sleep 5
    if kill -0 "$godot_pid" 2>/dev/null; then
      echo "run_fps_fire_destroy.sh timeout safety escalation: forcing process kill." >&2
      kill -KILL "$godot_pid" 2>/dev/null || true
    fi
  fi
) &
watchdog_pid=$!

while kill -0 "$godot_pid" 2>/dev/null; do
  if grep -Fq "$pass_marker" "$log_file"; then
    result_marker="pass"
    break
  fi
  if grep -Fq "$fail_marker" "$log_file"; then
    result_marker="fail"
    break
  fi
  sleep 0.1
done

set +e
wait "$godot_pid"
exit_code=$?
set -e

kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

if [[ -z "$result_marker" ]]; then
  if grep -Fq "$pass_marker" "$log_file"; then
    result_marker="pass"
  elif grep -Fq "$fail_marker" "$log_file"; then
    result_marker="fail"
  fi
fi

if [[ -f "$timeout_flag" ]]; then
  exit 1
fi

if [[ "$result_marker" == "pass" ]]; then
  exit 0
fi

if [[ "$result_marker" == "fail" ]]; then
  exit 1
fi

if [[ "$exit_code" -eq 0 ]]; then
  exit 0
fi

exit 1
