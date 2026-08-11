#!/usr/bin/env bash
# =====================================================================================================
# CONSERVATION GATE — matter and energy do not appear or vanish, and this is the red run.
#
# It was `run_sim_offscreen.sh` exiting 126 on any violation. That conflated two questions — "did the run
# complete" and "did the physics hold" — so every caller had to special-case one exit code and most did not.
# When the ceilings became float noise it started firing on EVERY run, and a signal that always fires is
# ignored, which is exactly what a red run exists to prevent. The verdict lives here instead: stricter than
# before, and red without making every iteration read as a broken run.
#
# THE BAR IS ZERO, plus arithmetic. LAMaterialFieldConservation3D derives its floor from the float32 format
# and the cell count; there is no per-substance allowance and adding one needs the maintainer.
#
# EXIT CODES. 0 conserved · 1 a substance drifted · 2 could not run, never a silent pass.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMES="${LA_CONS_FRAMES:-150}"
SEED="${LA_CONS_SEED:-4242}"

# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v godot >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }

OUT="$(mktemp "${TMPDIR:-/tmp}/la_cons.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-600}" LA_NO_STREAMER=1 \
  "$REPO_ROOT/scripts/run_sim_offscreen.sh" --path "$REPO_ROOT" \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- --sandbox --planet-only --no-fauna --bare "--run-frames=${FRAMES}" --fast=8 "--seed=${SEED}" \
  > "$OUT" 2>&1
rc=$?

if ! grep -q '^SIM_REPORT=' "$OUT"; then
  echo "ERROR: the run produced no SIM_REPORT (exit $rc) — refusing to report a pass on no data." >&2
  tail -20 "$OUT" >&2
  exit 2
fi

n="$(grep -c '^CONSERVATION_VIOLATION=' "$OUT" || true)"
if [ "$n" -eq 0 ]; then
  echo "check_conservation: OK — every gated substance held to arithmetic noise."
  exit 0
fi
grep '^CONSERVATION_VIOLATION=' "$OUT"
echo
echo "$n substance(s) drifted beyond arithmetic noise. Matter and energy do not appear or vanish; the"
echo "allowance is zero and raising it needs the maintainer AND a measurement taken after the floor holds"
echo "(determinism, observer independence, a physics-clock horizon)."
exit 1
