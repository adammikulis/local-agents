#!/usr/bin/env bash
# ONE DEFINITION OF THE CELL GEOMETRY TABLES, ENFORCED.
#
# WHY IT EXISTS. `cell_size` was one scalar standing for three different quantities — a radial thickness, a
# lateral spacing, and a cell volume — in 33 kernel sites. Splitting them means the radial half now arrives
# as a packed SSBO, and a packed table has exactly the failure mode the neighbour table had: the writer and
# the reader agree on the buffer and disagree about what is in it. LASphereGrid.shell_table() writes the
# fields in one order; kernels3d/shell.glsli names their offsets. Nothing checks they match but this.
#
# Same shape as check_neighbour_slots.sh: a gate on the STRUCTURE, not the values.
#   1. Does any kernel index shell_geom[]/cell_vol[] directly instead of going through the accessors?
#   2. Do the GLSL stride + field offsets still match the order shell_table() packs them in?
#   3. Are bindings 39 and 40 the geometry tables everywhere, and nothing else?
#   4. Does every kernel that reads an accessor actually include the file that declares it?
#   5. Are the includes in order? Godot resolves no nested #include.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

K="$ROOT/addons/local_agents/sim/material/kernels3d"
SSOT="$K/shell.glsli"
VOL="$K/cellvol.glsli"
GRID="$ROOT/addons/local_agents/sim/sphere/SphereGrid.gd"
fail=0

[ -f "$SSOT" ] || { echo "check_shell_table: MISSING $SSOT — the SSOT include is gone." >&2; exit 2; }
[ -f "$VOL" ] || { echo "check_shell_table: MISSING $VOL — the cell-volume include is gone." >&2; exit 2; }
[ -f "$GRID" ] || { echo "check_shell_table: MISSING $GRID." >&2; exit 2; }

# 1. Only the accessors touch the raw arrays. A kernel doing its own stride arithmetic is the whole defect.
raw=$(grep -n 'shell_geom\[\|cell_vol\[' "$K"/*.glsl 2>/dev/null || true)
if [ -n "$raw" ]; then
  echo "check_shell_table: RAW GEOMETRY INDEXING — use the shell.glsli / cellvol.glsli accessors." >&2
  echo "$raw" >&2
  fail=1
fi

# 2. The GLSL stride and offsets must equal what LASphereGrid.shell_table() writes.
#    shell_table() packs `out[r * S + N] = <field>`; shell.glsli declares `#define SHELL_<FIELD> Nu`.
stride=$(grep -oE "^#define SHELL_STRIDE[[:space:]]+[0-9]+u" "$SSOT" | grep -oE '[0-9]+' | head -1)
gd_stride=$(grep -oE "out\.resize\(depth \* [0-9]+\)" "$GRID" | grep -oE '[0-9]+' | tail -1)
if [ -z "$stride" ] || [ -z "$gd_stride" ] || [ "$stride" != "$gd_stride" ]; then
  echo "check_shell_table: STRIDE DIVERGED — shell.glsli='$stride', shell_table() resizes depth*'$gd_stride'." >&2
  fail=1
  stride="${stride:-0}"
fi
for pair in "DR:shell_dr" "MID:shell_mid" "D_OUT:shell_d_out" "D_IN:shell_d_in"; do
  fld="${pair%%:*}"; src="${pair##*:}"
  gv=$(grep -oE "^#define SHELL_$fld[[:space:]]+[0-9]+u" "$SSOT" | grep -oE '[0-9]+' | head -1)
  dv=$(grep -oE "out\[r \* $stride \+ [0-9]+\] = $src\[r\]" "$GRID" | grep -oE '\+ [0-9]+\]' | grep -oE '[0-9]+' | head -1)
  if [ -z "$gv" ] || [ -z "$dv" ]; then
    echo "check_shell_table: could not read SHELL_$fld (glsl='$gv' gd='$dv')." >&2; fail=1; continue
  fi
  if [ "$gv" != "$dv" ]; then
    echo "check_shell_table: SHELL_$fld DIVERGED — shell.glsli=$gv, shell_table() writes $src at $dv." >&2
    fail=1
  fi
done

# 3. Bindings 39 and 40 belong to the geometry tables. A second claimant silently aliases the buffer.
other=$(grep -n 'binding = 39' "$K"/*.glsl "$K"/*.glsli 2>/dev/null | grep -v 'ShellGeom' || true)
if [ -n "$other" ]; then
  echo "check_shell_table: BINDING 39 IS THE SHELL TABLE. Something else claims it:" >&2
  echo "$other" >&2
  fail=1
fi
other40=$(grep -n 'binding = 40' "$K"/*.glsl "$K"/*.glsli 2>/dev/null | grep -v 'CellVol' || true)
if [ -n "$other40" ]; then
  echo "check_shell_table: BINDING 40 IS THE CELL-VOLUME TABLE. Something else claims it:" >&2
  echo "$other40" >&2
  fail=1
fi

# 4. A kernel calling an accessor without the include compiles against nothing and reads garbage.
for f in "$K"/*.glsl; do
  if grep -qE '\bshell_(dr|mid|d_in|d_out|vol|run)\(' "$f" && ! grep -q '#include "shell.glsli"' "$f"; then
    echo "check_shell_table: ${f##*/} reads the shell table without including shell.glsli." >&2
    fail=1
  fi
  if grep -qE '\bvol_ratio\(' "$f" && ! grep -q '#include "cellvol.glsli"' "$f"; then
    echo "check_shell_table: ${f##*/} reads a cell volume without including cellvol.glsli." >&2
    fail=1
  fi
done

# 5. Godot does NOT resolve a nested #include, so the order is the caller's job: neighbours.glsli must come
# before shell.glsli, whose shell_run needs N_IN. Getting it wrong is silent at import and shows up as an
# all-zero output buffer at run time.
for f in "$K"/*.glsl; do
  grep -q '#include "shell.glsli"' "$f" || continue
  n=$(grep -n '#include "neighbours.glsli"' "$f" | head -1 | cut -d: -f1)
  h=$(grep -n '#include "shell.glsli"' "$f" | head -1 | cut -d: -f1)
  if [ -z "$n" ] || [ "$n" -gt "$h" ]; then
    echo "check_shell_table: ${f##*/} includes shell.glsli without neighbours.glsli before it." >&2
    fail=1
  fi
done
for inc in "$SSOT" "$VOL"; do
  if grep -qE '^[[:space:]]*#include' "$inc"; then
    echo "check_shell_table: $inc has a nested #include. Godot does not resolve one." >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check_shell_table: FAILED." >&2
  exit 1
fi
echo "Shell-table SSOT gate passed (accessors only, GLSL offsets == shell_table(), bindings 39/40 unshared)."
