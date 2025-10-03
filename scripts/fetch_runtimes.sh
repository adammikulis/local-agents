#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
"${REPO_ROOT}/addons/local_agents/gdextensions/localagents/scripts/fetch_runtimes.sh" "$@"
