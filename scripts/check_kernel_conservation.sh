#!/usr/bin/env bash
# Dispatches each transport kernel on a small real grid and asserts total mass is unchanged. Needs a GPU, so
# it runs windowed and is NOT part of the headless `lint`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=$(LA_RUN_TIMEOUT=180 "$ROOT/scripts/run_sim_offscreen.sh" --path "${1:-$ROOT}" \
  addons/local_agents/tests/KernelConservation.tscn 2>&1 | grep -oE 'KERNEL_CONSERVATION=.*' | tail -1)
if [ -z "$OUT" ]; then
  echo "check_kernel_conservation: NO RESULT — the harness did not report." >&2
  exit 2
fi
echo "$OUT"
echo "$OUT" | grep -q '"ok":true' || { echo "check_kernel_conservation: FAILED." >&2; exit 1; }
