#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NON_HEADLESS_TIMEOUT=45
HEADLESS_TIMEOUT=120
WORKERS=1

usage() {
  cat <<USAGE
Usage: scripts/run_destruction_tests.sh [--non-headless-timeout=<seconds>] [--timeout-sec=<seconds>] [--workers=<N>] [extra runtime args...]

Runs the destruction validation sequence in canonical order:
1) Non-headless FPS fire destruction harness.
2) Headless destruction-only bounded runtime suite.

Examples:
  scripts/run_destruction_tests.sh
  scripts/run_destruction_tests.sh --timeout-sec=180 --workers=2
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

extra_runtime_args=()
for arg in "$@"; do
  case "$arg" in
    --non-headless-timeout=*)
      NON_HEADLESS_TIMEOUT="${arg#--non-headless-timeout=}"
      ;;
    --timeout-sec=*|--timeout=*)
      HEADLESS_TIMEOUT="${arg#*=}"
      ;;
    --workers=*)
      WORKERS="${arg#--workers=}"
      ;;
    *)
      extra_runtime_args+=("$arg")
      ;;
  esac
done

if ! [[ "$NON_HEADLESS_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$NON_HEADLESS_TIMEOUT" -le 0 ]]; then
  echo "Invalid --non-headless-timeout value '$NON_HEADLESS_TIMEOUT'; expected positive integer seconds." >&2
  exit 2
fi

if ! [[ "$HEADLESS_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$HEADLESS_TIMEOUT" -le 0 ]]; then
  echo "Invalid --timeout-sec/--timeout value '$HEADLESS_TIMEOUT'; expected positive integer seconds." >&2
  exit 2
fi

if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -le 0 ]]; then
  echo "Invalid --workers value '$WORKERS'; expected positive integer." >&2
  exit 2
fi

cd "$REPO_ROOT"

echo "==> [destruction] running non-headless FPS fire harness"
"$SCRIPT_DIR/run_fps_fire_destroy.sh" --timeout="$NON_HEADLESS_TIMEOUT"

echo "==> [destruction] running headless destruction suite"
runtime_cmd=(
  godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd --
  --suite=destruction
  --timeout-sec="$HEADLESS_TIMEOUT"
  --workers="$WORKERS"
)
if [[ ${#extra_runtime_args[@]} -gt 0 ]]; then
  runtime_cmd+=("${extra_runtime_args[@]}")
fi
"${runtime_cmd[@]}"
