#!/usr/bin/env bash

# Runs the Godot headless check to validate GDScript syntax and plugin readiness.
# Usage: scripts/run_godot_check.sh
# Set GODOT_CHECK_ARGS to pass extra arguments to Godot.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$ROOT_DIR"

if [[ -n "${GODOT_BIN:-}" ]]; then
  GODOT_CMD="${GODOT_BIN}"
elif command -v godot >/dev/null 2>&1; then
  GODOT_CMD="$(command -v godot)"
elif command -v godot4 >/dev/null 2>&1; then
  GODOT_CMD="$(command -v godot4)"
else
  echo "godot executable not found on PATH" >&2
  exit 127
fi

ARGS=("--headless" "--check-only" "project.godot")
if [[ "${GODOT_CHECK_ARGS:-}" != "" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=($GODOT_CHECK_ARGS)
  ARGS=("${EXTRA_ARGS[@]}" "${ARGS[@]}")
fi

echo "Running: ${GODOT_CMD} ${ARGS[*]}" >&2
"${GODOT_CMD}" "${ARGS[@]}"
