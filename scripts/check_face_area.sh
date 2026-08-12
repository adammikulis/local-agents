#!/usr/bin/env bash
# ONE DEFINITION OF THE FACE-AREA TABLE, ENFORCED — AND THE TABLE ITSELF MEASURED.
#
# WHY IT EXISTS. How much heat or matter crosses the wall between two cells is proportional to that wall's
# AREA. Until this table there was none anywhere in the tree: cell VOLUME had one (binding 40) and the radial
# runs had one (binding 39), but every conductive and diffusive flux stood in `1/dx^2`, a bare per-face
# constant, or a count of faces. On a cubed sphere that is wrong per cell — a cell's outward radial face
# exceeds its inward one by (r_out/r_in)^2, and a lateral face near a cube-face corner is several times
# smaller than one near the centre.
#
# Two halves, because the failure modes are different:
#   STRUCTURE, like check_shell_table.sh — the writer and the reader agreeing on the buffer and disagreeing
#   about what is in it. Accessor-only access, binding 42 unshared, includes present and in order.
#   VALUES, which no text gate can see — scripts/check_face_area.gd builds the grid and asserts the table
#   closes: shared faces equal from both ends (partner slot LOOKED UP, never computed), each shell's radial
#   faces summing to 4*pi*r^2, the radial pair reproducing the cell volume, and the corner set the lateral
#   arcs are measured between reproducing the solid angle.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
GODOT="${GODOT:-godot}"
command -v require_tool >/dev/null 2>&1 && require_tool "$GODOT"

K="$ROOT/addons/local_agents/sim/material/kernels3d"
SSOT="$K/facearea.glsli"
NBR="$K/neighbours.glsli"
GRID="$ROOT/addons/local_agents/sim/sphere/SphereGrid.gd"
GPU="$ROOT/addons/local_agents/sim/material/MaterialSphereGPU3D.gd"
PROBE="$ROOT/scripts/check_face_area.gd"
fail=0

[ -f "$SSOT" ] || { echo "check_face_area: MISSING $SSOT — the SSOT include is gone." >&2; exit 2; }
[ -f "$NBR" ] || { echo "check_face_area: MISSING $NBR." >&2; exit 2; }
[ -f "$GRID" ] || { echo "check_face_area: MISSING $GRID." >&2; exit 2; }
[ -f "$GPU" ] || { echo "check_face_area: MISSING $GPU." >&2; exit 2; }
[ -f "$PROBE" ] || { echo "check_face_area: MISSING $PROBE — the numeric half cannot run." >&2; exit 2; }

# 1. Only the accessor touches the raw array. A kernel doing its own stride arithmetic is the whole defect.
raw=$(grep -n 'face_area\[' "$K"/*.glsl 2>/dev/null || true)
if [ -n "$raw" ]; then
  echo "check_face_area: RAW FACE-AREA INDEXING — use face_area_of() from facearea.glsli." >&2
  echo "$raw" >&2
  fail=1
fi

# 2. The GLSL stride is N_SLOTS and the GDScript writes cell_count*6. Both must be 6.
nslots=$(grep -oE '^const uint N_SLOTS[[:space:]]*=[[:space:]]*[0-9]+u' "$NBR" | grep -oE '[0-9]+' | head -1)
gd_stride=$(grep -oE '_face_area\.resize\(cell_count \* [0-9]+\)' "$GRID" | grep -oE '[0-9]+' | tail -1)
if [ "$nslots" != "6" ] || [ "$gd_stride" != "6" ]; then
  echo "check_face_area: STRIDE DIVERGED — neighbours.glsli N_SLOTS='$nslots', _face_area resize stride='$gd_stride'." >&2
  fail=1
fi
if ! grep -q 'face_area\[c \* N_SLOTS + d\]' "$SSOT"; then
  echo "check_face_area: facearea.glsli does not index by N_SLOTS." >&2
  fail=1
fi

# 3. Binding 42 belongs to the face-area table. A second claimant silently aliases the buffer.
other=$(grep -n 'binding = 42' "$K"/*.glsl "$K"/*.glsli 2>/dev/null | grep -v 'FaceArea' || true)
if [ -n "$other" ]; then
  echo "check_face_area: BINDING 42 IS THE FACE-AREA TABLE. Something else claims it:" >&2
  echo "$other" >&2
  fail=1
fi

# 4. A kernel calling the accessor without the include compiles against nothing and reads garbage.
for f in "$K"/*.glsl; do
  if grep -qE '\bface_area_of\(' "$f" && ! grep -q '#include "facearea.glsli"' "$f"; then
    echo "check_face_area: ${f##*/} reads a face area without including facearea.glsli." >&2
    fail=1
  fi
done

# 5. Godot resolves no nested #include, so the order is the caller's job: face_area_of uses N_SLOTS.
for f in "$K"/*.glsl; do
  grep -q '#include "facearea.glsli"' "$f" || continue
  n=$(grep -n '#include "neighbours.glsli"' "$f" | head -1 | cut -d: -f1)
  h=$(grep -n '#include "facearea.glsli"' "$f" | head -1 | cut -d: -f1)
  if [ -z "$n" ] || [ "$n" -gt "$h" ]; then
    echo "check_face_area: ${f##*/} includes facearea.glsli without neighbours.glsli before it." >&2
    fail=1
  fi
done
if grep -qE '^[[:space:]]*#include' "$SSOT"; then
  echo "check_face_area: $SSOT has a nested #include. Godot does not resolve one." >&2
  fail=1
fi

# 6. The GPU must get the SSOT table itself, not a rebuilt or rescaled copy.
if ! grep -q '_grid\.face_areas()\.to_byte_array()' "$GPU"; then
  echo "check_face_area: MaterialSphereGPU3D does not upload LASphereGrid.face_areas() itself." >&2
  fail=1
fi

# 7. THE VALUES. A structural gate cannot see a wrong area, only a wrongly-shaped one.
OUT=$("$GODOT" --headless --path "$ROOT" -s "res://scripts/check_face_area.gd" 2>&1)
rc=$?
LINE=$(echo "$OUT" | grep -oE 'FACE_AREA=.*' | tail -1)
if [ -z "$LINE" ]; then
  echo "check_face_area: NO RESULT — the probe did not report." >&2
  echo "$OUT" >&2
  exit 2
fi
echo "$LINE"
if [ "$rc" -eq 2 ]; then
  echo "check_face_area: the probe could not run." >&2
  exit 2
fi
echo "$LINE" | grep -q '"ok":true' || {
  echo "check_face_area: THE TABLE DOES NOT CLOSE." >&2
  fail=1
}

if [ "$fail" -ne 0 ]; then
  echo "check_face_area: FAILED." >&2
  exit 1
fi
echo "Face-area gate passed (accessor only, binding 42 unshared, table reciprocal and closing 4*pi*r^2)."
