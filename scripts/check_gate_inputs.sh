#!/usr/bin/env bash
# A REUSED PASS IS ONLY AS TRUE AS THE INPUTS IT WAS KEYED ON. For every gates.toml row that declares `inputs`:
# each glob matches a file; editing the first file each glob matches, or the gate's own script, moves the
# key; touching a mtime does not; a file the row does not read does not; the key is the same in a second
# checkout of the same bytes; the script names no file, script or repository state the inputs leave out.
# EXIT 0 clean · 1 an input is false · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
require_tool git
exec python3 "$ROOT/scripts/gate_runner.py" --check-inputs
