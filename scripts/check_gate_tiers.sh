#!/usr/bin/env bash
# A DIFF CAN SKIP A SLOW GATE ONLY IF THE GATE SAYS WHAT IT READS. A slow row (one that launches an engine, reads
# the capture one made, or needs a device) declares `inputs` in scripts/gates.toml; the few that do not are named
# in docs/SLOW_GATES_WITHOUT_INPUTS, which docs/SLOW_GATES_WITHOUT_INPUTS_CEILING holds from growing.
# EXIT 0 clean · 1 a row is unlisted, a line is stale, or the list rose · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
exec python3 "$ROOT/scripts/gate_runner.py" --check-tiers
