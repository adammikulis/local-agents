#!/usr/bin/env bash
# ONE DEFINITION OF THE RADIAL SHELL TABLE, ENFORCED.
#
# WHY IT EXISTS. `cell_size` was one scalar standing for three different quantities — a radial thickness, a
# lateral spacing, and a cell volume — in 33 kernel sites. Splitting them means the radial half now arrives
# as a packed SSBO, and a packed table has exactly the failure mode the neighbour table had: the writer and
# the reader agree on the buffer and disagree about what is in it. LASphereGrid.shell_table() writes the
# fields in one order; kernels3d/shell.glsli names their offsets. Nothing checks they match but this.
#
# Same shape as check_neighbour_slots.sh: a gate on the STRUCTURE, not the values.
#   1. Does any kernel index shell_geom[] directly instead of going through the accessors?
#   2. Do the GLSL field offsets still match the order shell_table() packs them in?
#   3. Is binding 18 the shell table everywhere, and nothing else?
#   4. Does every kernel that reads a shell accessor actually include shell.glsli?
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

K="$ROOT/addons/local_agents/sim/material/kernels3d"
SSOT="$K/shell.glsli"
GRID="$ROOT/addons/local_agents/sim/sphere/SphereGrid.gd"
fail=0

[ -f "$SSOT" ] || { echo "check_shell_table: MISSING $SSOT — the SSOT include is gone." >&2; exit 2; }
[ -f "$GRID" ] || { echo "check_shell_table: MISSING $GRID." >&2; exit 2; }

# 1. Only the accessors touch the raw array. A kernel doing its own stride arithmetic is the whole defect.
raw=$(grep -n 'shell_geom\[' "$K"/*.glsl 2>/dev/null || true)
if [ -n "$raw" ]; then
  echo "check_shell_table: RAW SHELL INDEXING — use shell_dr/shell_mid/shell_d_in/shell_d_out/shell_run." >&2
  echo "$raw" >&2
  fail=1
fi

# 2. The GLSL offsets must equal the order LASphereGrid.shell_table() writes.
#    shell_table() packs `out[r * 4 + N] = <field>`; shell.glsli declares `#define SHELL_<FIELD> Nu`.
for pair in "DR:shell_dr" "MID:shell_mid" "D_OUT:shell_d_out" "D_IN:shell_d_in"; do
  fld="${pair%%:*}"; src="${pair##*:}"
  gv=$(grep -oE "^#define SHELL_$fld[[:space:]]+[0-9]+u" "$SSOT" | grep -oE '[0-9]+' | head -1)
  dv=$(grep -oE "out\[r \* 4 \+ [0-9]+\] = $src\[r\]" "$GRID" | grep -oE '\+ [0-9]+\]' | grep -oE '[0-9]+' | head -1)
  if [ -z "$gv" ] || [ -z "$dv" ]; then
    echo "check_shell_table: could not read SHELL_$fld (glsl='$gv' gd='$dv')." >&2; fail=1; continue
  fi
  if [ "$gv" != "$dv" ]; then
    echo "check_shell_table: SHELL_$fld DIVERGED — shell.glsli=$gv, shell_table() writes $src at $dv." >&2
    fail=1
  fi
done

# 3. Binding 39 belongs to the shell table. A second claimant silently aliases the buffer.
other=$(grep -n 'binding = 39' "$K"/*.glsl "$K"/*.glsli 2>/dev/null | grep -v 'ShellGeom' || true)
if [ -n "$other" ]; then
  echo "check_shell_table: BINDING 39 IS THE SHELL TABLE. Something else claims it:" >&2
  echo "$other" >&2
  fail=1
fi

# 4. A kernel calling an accessor without the include compiles against nothing and reads garbage.
for f in "$K"/*.glsl; do
  if grep -qE '\bshell_(dr|mid|d_in|d_out|run)\(' "$f" && ! grep -q '#include "shell.glsli"' "$f"; then
    echo "check_shell_table: ${f##*/} reads the shell table without including shell.glsli." >&2
    fail=1
  fi
done

# 5. Godot does NOT resolve a nested #include, so shell.glsli cannot pull in neighbours.glsli itself: every
# includer must include neighbours.glsli FIRST or `shell_run`'s N_IN is undefined and the stage fails to
# compile. That failure is silent at import and shows up as an all-zero output buffer at run time.
for f in "$K"/*.glsl; do
  grep -q '#include "shell.glsli"' "$f" || continue
  n=$(grep -n '#include "neighbours.glsli"' "$f" | head -1 | cut -d: -f1)
  h=$(grep -n '#include "shell.glsli"' "$f" | head -1 | cut -d: -f1)
  if [ -z "$n" ] || [ "$n" -gt "$h" ]; then
    echo "check_shell_table: ${f##*/} includes shell.glsli without neighbours.glsli before it." >&2
    fail=1
  fi
done
if grep -qE '^[[:space:]]*#include' "$SSOT"; then
  echo "check_shell_table: $SSOT has a nested #include. Godot does not resolve one." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check_shell_table: FAILED." >&2
  exit 1
fi
echo "Shell-table SSOT gate passed (accessors only, GLSL offsets == shell_table(), binding 39 unshared)."
