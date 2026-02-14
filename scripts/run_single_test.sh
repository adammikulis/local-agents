#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR_REL="addons/local_agents/tests"
DEFAULT_TIMEOUT=120

usage() {
  cat <<USAGE
Usage: scripts/run_single_test.sh <test_file> [--timeout=<seconds>] [extra harness args...]

Run exactly one addons/local_agents/tests/test_*.gd module through the canonical SceneTree harness.

Examples:
  scripts/run_single_test.sh test_native_voxel_op_contracts.gd
  scripts/run_single_test.sh addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=180 -- --verbose
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

test_input="$1"
shift

timeout="$DEFAULT_TIMEOUT"
extra_args=()
for arg in "$@"; do
  if [[ "$arg" == --timeout=* ]]; then
    timeout="${arg#--timeout=}"
    continue
  fi
  extra_args+=("$arg")
done

if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -le 0 ]]; then
  echo "Invalid --timeout value '$timeout'; expected positive integer seconds." >&2
  exit 2
fi

normalized_test="$test_input"
normalized_test="${normalized_test#res://}"
normalized_test="${normalized_test#./}"
if [[ "$normalized_test" == "$TEST_DIR_REL/"* ]]; then
  normalized_test="${normalized_test#${TEST_DIR_REL}/}"
fi

if [[ "$normalized_test" == */* ]]; then
  echo "Expected a test file under $TEST_DIR_REL, got '$test_input'." >&2
  echo "Pass a file like test_native_voxel_op_contracts.gd or ${TEST_DIR_REL}/test_native_voxel_op_contracts.gd." >&2
  exit 2
fi

if [[ "$normalized_test" != test_*.gd ]]; then
  echo "Only test modules matching test_*.gd are supported, got '$test_input'." >&2
  exit 2
fi

repo_test_path="$REPO_ROOT/$TEST_DIR_REL/$normalized_test"
if [[ ! -f "$repo_test_path" ]]; then
  echo "Test file not found: $repo_test_path" >&2
  exit 2
fi

test_res_path="res://$TEST_DIR_REL/$normalized_test"

cd "$REPO_ROOT"
cmd=(
  godot
  --headless
  --no-window
  -s addons/local_agents/tests/run_single_test.gd
  --
  "--test=$test_res_path"
  "--timeout=$timeout"
)
if [[ ${#extra_args[@]} -gt 0 ]]; then
  cmd+=("${extra_args[@]}")
fi
"${cmd[@]}"
