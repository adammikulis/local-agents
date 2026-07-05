#!/usr/bin/env bash
# Unified agent entrypoint that wraps the project's canonical test/run harnesses,
# tees full output to a log, and prints one machine-parseable result line.
#
# IMPORTANT: never invoke addons/local_agents/tests/test_*.gd directly; that is
# banned by scripts/check_no_direct_refcounted_invocation.sh. Always route
# through the canonical run_*.gd runners or the run_*.sh wrapper scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
MAIN_SCENE="res://addons/local_agents/scenes/simulation/WorldSimulation.tscn"

DEFAULT_LOG_DIR="/private/tmp/claude-501/-Users-adammikulis-Documents-repos-godot-local-agents/875e28b8-01fe-4c33-9e93-4e0845b300cd/scratchpad"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

usage() {
  cat <<'USAGE'
Usage: scripts/agent_harness.sh <command> [args...]

Commands:
  fast          Run the fast test sweep (run_all_tests.gd --fast).
  all [args]    Run the full test suite (run_all_tests.gd --timeout=120).
  bounded [a]   Run bounded runtime suite (run_runtime_tests_bounded.gd).
                e.g. bounded --suite=fast --workers=2
  single <f> [a] Run one test via scripts/run_single_test.sh <f> [--timeout=120].
  smoke         Boot the main scene headless briefly; fail on script/parse errors.
  extension     Validate the GDExtension via scripts/check_extension.gd.
  lint          Run lint checks: no-direct-refcounted (gate) + file-length &amp;
                policy markers (advisory).
  -h | --help   Show this help and exit 0.

Environment:
  LOG_DIR   Directory for combined logs (default: session scratchpad).
  GODOT     Godot binary (default: godot on PATH).

Every command tees output to a log and prints a final line:
  AGENT_HARNESS_RESULT={"command":...,"status":...,"exit_code":...,...}
USAGE
}

# --- argument dispatch -------------------------------------------------------
cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

case "$cmd" in
  fast|all|bounded|single|smoke|extension|lint) ;;
  *)
    echo "agent_harness: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/agent_harness_${cmd}_$(date +%s).log"

# --- build the child command as an argv array --------------------------------
child=()
case "$cmd" in
  fast)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --fast)
    ;;
  all)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120 "$@")
    ;;
  bounded)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120 "$@")
    ;;
  single)
    if [[ $# -lt 1 ]]; then
      echo "agent_harness: 'single' requires a test file argument" >&2
      usage >&2
      exit 2
    fi
    target="$1"; shift
    child=("$SCRIPT_DIR/run_single_test.sh" "$target" "$@")
    ;;
  smoke)
    child=("$GODOT" --headless --no-window --quit-after 120 "$MAIN_SCENE")
    ;;
  extension)
    child=("$GODOT" -s scripts/check_extension.gd)
    ;;
  lint)
    : # handled specially below
    ;;
esac

# --- run the child, tee to the log, preserve its exit code -------------------
SECONDS=0
exit_code=0
if [[ "$cmd" == "lint" ]]; then
  set +e
  {
    set +e
    # Advisory: file-length soft limit (1000, matches docs + CI) never gates.
    MAX_FILE_LINES=1000 "$SCRIPT_DIR/check_max_file_length.sh"
    # Advisory: policy/plan marker drift never gates.
    "$SCRIPT_DIR/check_policy_plan_markers.sh"
    # Gate: banning direct test_*.gd invocation is a genuine correctness check.
    "$SCRIPT_DIR/check_no_direct_refcounted_invocation.sh"
    rc_gate=$?
    set -e
    if [[ $rc_gate -ne 0 ]]; then
      echo "LINT_FAIL: check_no_direct_refcounted_invocation.sh ($rc_gate)"
      exit 1
    fi
    # Gate: no inferred typing (:=) in the new voxel scene.
    set +e
    "$SCRIPT_DIR/check_no_inferred_typing.sh"
    rc_typing=$?
    set -e
    if [[ $rc_typing -ne 0 ]]; then
      echo "LINT_FAIL: check_no_inferred_typing.sh ($rc_typing)"
      exit 1
    fi
    echo "All lint gates passed (file-length + policy markers are advisory)."
    exit 0
  } 2>&1 | tee "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}
  set -e
else
  set +e
  "${child[@]}" 2>&1 | tee "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}
  set -e
fi
duration=$SECONDS

# Remaining work is best-effort log parsing + result emission; a non-matching
# grep must not abort the script before the result line is printed.
set +e

# --- classify status ---------------------------------------------------------
if [[ "$exit_code" -eq 0 ]]; then
  status="pass"
elif [[ "$exit_code" -eq 124 ]]; then
  status="timeout"
else
  status="fail"
fi

# --- parse the log for pass/fail signal --------------------------------------
passed="null"
failed="null"

# Preferred: structured AGENT_TEST_RESULT={json}. Take the last one.
result_json="$(grep -o 'AGENT_TEST_RESULT=.*' "$LOG_FILE" 2>/dev/null | tail -n 1 | sed 's/^AGENT_TEST_RESULT=//')"
if [[ -n "$result_json" ]]; then
  p="$(printf '%s' "$result_json" | grep -oE '"passed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  f="$(printf '%s' "$result_json" | grep -oE '"failed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  [[ -n "$p" ]] && passed="$p"
  [[ -n "$f" ]] && failed="$f"
fi

# Legacy markers: "<N> passed" / "<N> failed" summary lines.
if [[ "$passed" == "null" ]]; then
  p="$(grep -oE '[0-9]+ passed' "$LOG_FILE" 2>/dev/null | tail -n1 | grep -oE '^[0-9]+')"
  [[ -n "$p" ]] && passed="$p"
fi
if [[ "$failed" == "null" ]]; then
  f="$(grep -oE '[0-9]+ failed' "$LOG_FILE" 2>/dev/null | tail -n1 | grep -oE '^[0-9]+')"
  [[ -n "$f" ]] && failed="$f"
fi

# Smoke: treat script/parse/dependency errors as failure even if exit was 0.
if [[ "$cmd" == "smoke" && "$status" == "pass" ]]; then
  if grep -qiE 'SCRIPT ERROR|Parse Error|dependency error|Failed loading resource' "$LOG_FILE" 2>/dev/null; then
    status="fail"
    if [[ "$exit_code" -eq 0 ]]; then exit_code=1; fi
  fi
fi

# --- emit exactly one machine-parseable result line --------------------------
extra=""
printf 'AGENT_HARNESS_RESULT={"command":"%s","status":"%s","exit_code":%d,"duration_s":%d,"log":"%s","passed":%s,"failed":%s%s}\n' \
  "$cmd" "$status" "$exit_code" "$duration" "$LOG_FILE" "$passed" "$failed" "$extra"

# Mirror the child's exit code.
exit "$exit_code"
