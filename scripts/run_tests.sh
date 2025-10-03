#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
GODOT_BIN=${GODOT_BIN:-}

# Discover a Godot executable if GODOT_BIN is not set.
if [[ -z "${GODOT_BIN}" ]]; then
    if command -v godot >/dev/null 2>&1; then
        GODOT_BIN=$(command -v godot)
    elif command -v godot4 >/dev/null 2>&1; then
        GODOT_BIN=$(command -v godot4)
    else
        echo "error: could not find a Godot executable. Set GODOT_BIN to your Godot 4 binary." >&2
        exit 1
    fi
fi

# Basic sanity check for the native extension binaries.
ext_bin_dir="${REPO_ROOT}/addons/local_agents/gdextensions/localagents/bin"
FOUND_EXT=""
shopt -s nullglob
for candidate in "${ext_bin_dir}"/localagents.*.{dylib,so,dll}; do
    FOUND_EXT="${candidate}"
    break
done
shopt -u nullglob

if [[ -z "${FOUND_EXT}" ]]; then
    echo "warning: no compiled localagents extension found under ${ext_bin_dir}." >&2
    echo "         Build it first with ./addons/local_agents/gdextensions/localagents/scripts/build_extension.sh" >&2
fi

TEST_SCRIPTS=(
    "addons/local_agents/tests/test_network_graph.gd"
    "addons/local_agents/tests/test_conversation_store.gd"
    "addons/local_agents/tests/test_project_graph_service.gd"
)

echo "==> Running editor script check"
GODOT_BIN="${GODOT_BIN}" "${REPO_ROOT}/scripts/run_godot_check.sh"
echo "==> Editor script check completed"
echo

for test_script in "${TEST_SCRIPTS[@]}"; do
    echo "==> Running ${test_script}"
    "${GODOT_BIN}" --headless --no-window -s "${REPO_ROOT}/${test_script}"
    echo "==> ${test_script} completed"
    echo
done

echo "All Local Agents tests passed."
