#!/usr/bin/env bash
# ONE DEFINITION OF THE NEIGHBOUR-SLOT LAYOUT, ENFORCED.
#
# The 6-slot layout was written from memory in every kernel that touches `nbr[]`, and most of them wrote it
# down wrong. LAVoxelGrid is the one declaration: six axis tags -X,+X,-Y,+Y,-Z,+Z, ordered so the reverse of
# slot d is d ^ 1. A slot is a face of the box and never a direction — down is -normalize(g), read per cell.
#
# It asks three structural questions:
#   1. Does any kernel name a slot by a bare integer instead of looping or using the SSOT accessor?
#   2. Is the GLSL slot count still equal to LAVoxelGrid's?
#   3. Is the GLSL reverse-link function still the same function as LAVoxelGrid.opposite_slot?
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg

K="$ROOT/addons/local_agents/sim/material/kernels3d"
SSOT="$K/neighbours.glsli"
GRID="$ROOT/addons/local_agents/sim/voxel/VoxelGrid.gd"
fail=0

[ -f "$SSOT" ] || { echo "check_neighbour_slots: MISSING $SSOT — the SSOT include is gone." >&2; exit 2; }
[ -f "$GRID" ] || { echo "check_neighbour_slots: MISSING $GRID." >&2; exit 2; }

# 1. No bare integer slot index. `nbr[base + 5u]` is a kernel asserting slot 5 means something; on a box the
# slots are axis tags, so a kernel either loops over all six or asks for the reverse of the one it holds.
bare=$(grep -nE '\b(nbr|send|send_h|send_q)\[[^]]*[+-][[:space:]]*[0-9]+u?[[:space:]]*\]' "$K"/*.glsl "$K"/*.glsli 2>/dev/null || true)
if [ -n "$bare" ]; then
  echo "check_neighbour_slots: BARE SLOT INDEX — a slot is an axis tag, never a named direction." >&2
  echo "$bare" >&2
  fail=1
fi

# 2. The slot count must equal the number of steps LAVoxelGrid actually builds neighbours for.
gv=$(grep -oE '^const uint N_SLOTS[[:space:]]*=[[:space:]]*[0-9]+u' "$SSOT" | grep -oE '[0-9]+' | head -1)
dv=$(awk '/^const SLOT_STEP/ { on = 1; next } on && /^\]/ { exit } on { n += gsub(/Vector3i\(/, "") } END { print n + 0 }' "$GRID")
if [ -z "$gv" ] || [ "$dv" -eq 0 ]; then
  echo "check_neighbour_slots: could not read the slot count (glsl='$gv' gd='$dv')." >&2
  fail=1
elif [ "$gv" != "$dv" ]; then
  echo "check_neighbour_slots: SLOT COUNT DIVERGED — neighbours.glsli=$gv, VoxelGrid.gd SLOT_STEP=$dv." >&2
  fail=1
fi

# 3. The reverse link is the bit flip in both copies, or neither. When these disagree a gather debits a slot
# no cell reads and credits one twice, which is mass created and destroyed in the same step.
grep -qE 'uint opposite_slot\(uint d\)[[:space:]]*\{[[:space:]]*return d \^ 1u;[[:space:]]*\}' "$SSOT" || {
  echo "check_neighbour_slots: neighbours.glsli opposite_slot is not \`d ^ 1u\`." >&2; fail=1; }
grep -qE '^[[:space:]]*return d \^ 1[[:space:]]*$' "$GRID" || {
  echo "check_neighbour_slots: LAVoxelGrid.opposite_slot is not \`d ^ 1\`." >&2; fail=1; }

# 4. THE GPU MUST GET THE SSOT TABLE ITSELF, NOT A PERMUTED COPY. A reorder on the way to the SSBO put a
# lateral where the kernels read UP, and link_partner then indexed an order the table no longer had.
permuted=$(grep -rnE 'nbr_bytes[^=]*=|kernel_order' --include='*.gd' "$ROOT/addons" 2>/dev/null \
           | grep -v '\.neighbours\.to_byte_array()' || true)
if [ -n "$permuted" ]; then
  echo "check_neighbour_slots: THE NEIGHBOUR SSBO IS NOT LAVoxelGrid.neighbours. Upload the table itself." >&2
  echo "$permuted" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check_neighbour_slots: FAILED." >&2
  exit 1
fi
echo "Neighbour-slot SSOT gate passed (six axis tags, reverse = d ^ 1, GLSL == LAVoxelGrid)."
