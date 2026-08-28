#!/usr/bin/env bash
# =====================================================================================================
# VOXEL GRID — the structural claims of the uniform Cartesian grid, checked rather than asserted.
#
# The cubed-sphere grid this replaces had to EARN reciprocity: a face seam table, family orientation
# repair, a kernel-order slot permutation, and a reciprocal-slot lookup that was wrong for all four
# lateral slots (matter destroyed on two faces of six, duplicated on two others). On an axis-aligned
# grid the opposite of d IS d ^ 1 and there is nothing to get wrong — but "nothing to get wrong" is a
# claim, so it is tested.
#
# It also checks the property the whole migration is FOR:
#   volume_ratio == 1      every cell is the same size, so no transfer needs a donor/receiver ratio.
#
# EXIT CODES. 0 pass · 1 a structural claim is false · 2 could not run.
# =====================================================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/addons/local_agents/sim/voxel/VoxelGrid.gd" ] || { echo "ERROR: VoxelGrid.gd missing." >&2; exit 2; }

PROBE_REL="addons/local_agents/tests/gate_voxel_grid.gd"
[ -f "$REPO_ROOT/$PROBE_REL" ] || { echo "ERROR: MISSING $PROBE_REL." >&2; exit 2; }

if la_cap_dir >/dev/null; then
  out="$(la_headless voxel_grid)" || exit 2
else
  out="$(la_godot --headless --path "$REPO_ROOT" -s "res://$PROBE_REL" 2>&1)"
fi

line="$(printf '%s\n' "$out" | grep -m1 '^VOXEL_GRID=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no VOXEL_GRID line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
# The marker carries the verdict; a batched runner has no exit code of its own.
fails="$(printf '%s' "$line" | grep -oE '"failures":[0-9]+' | grep -oE '[0-9]+$')"
[ -n "$fails" ] || { echo "ERROR: the probe published no failure count." >&2; exit 2; }
if [ "$fails" -ne 0 ]; then
  echo
  echo "A structural claim of the uniform grid is false. These are the properties the cubed-sphere grid"
  echo "had to earn with a seam table and got wrong; on this grid they should hold by construction."
  exit 1
fi
echo "check_voxel_grid: OK"
