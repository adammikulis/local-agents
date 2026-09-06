#!/usr/bin/env bash
# THE LIQUID SURFACE THE DEVICE EXTRACTS, against the field it reads. A box the fill left water in
# publishes a sheet; a box it left dry publishes none. The sheet's own shape is asserted natively, in
# lasim --property-tests, where a 2:1 seam can be built to order.
# MUTATION: `return true` from la_has_water -> the dry box draws a sheet; `m < 999u` in the join -> the
# wet box draws none. EXIT 0 the detector reads the field * 1 it does not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

# The box the demo stands in, and one on the pole the fill leaves dry.
WET_BOX="${LA_MESH_WET_BOX:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}"
DRY_BOX="${LA_MESH_DRY_BOX:-0,surface,0,3,24,3,5120,640}"

reading() { printf '%s\n' "$2" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[[:space:]]*$//' -e 's/\.0*$//'; }

run_box() {
  "$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --slice-box "$1" --rung 1 --frames 4 \
    --report water_surface_verts,water_surface_tris 2>&1
}

WET_OUT="$(run_box "$WET_BOX")"
VERTS="$(reading water_surface_verts "$WET_OUT")"
TRIS="$(reading water_surface_tris "$WET_OUT")"
if ! printf '%s' "${VERTS:-}${TRIS:-}" | grep -Eq '^[0-9]+$'; then
  printf '%s\n' "$WET_OUT" | tail -20 >&2
  echo "check_mesh_detector: the wet arm published no mesh reading, so nothing was examined." >&2
  exit 2
fi

DRY_OUT="$(run_box "$DRY_BOX")"
DRY_VERTS="$(reading water_surface_verts "$DRY_OUT")"
DRY_TRIS="$(reading water_surface_tris "$DRY_OUT")"
if ! printf '%s' "${DRY_VERTS:-}${DRY_TRIS:-}" | grep -Eq '^[0-9]+$'; then
  printf '%s\n' "$DRY_OUT" | tail -20 >&2
  echo "check_mesh_detector: the dry arm published no mesh reading, so it was held to nothing." >&2
  exit 2
fi

echo "MESH_DETECTOR={\"verts\":$VERTS,\"tris\":$TRIS,\"dry_verts\":$DRY_VERTS,\"dry_tris\":$DRY_TRIS}"
fail=0
if [ "$VERTS" -le 0 ] || [ "$TRIS" -le 0 ]; then
  echo "check_mesh_detector: the box the fill left water in published no sheet, so the detector reads" >&2
  echo "                     nothing of the water standing in it." >&2
  fail=1
fi
if [ "$DRY_VERTS" -ne 0 ] || [ "$DRY_TRIS" -ne 0 ]; then
  echo "check_mesh_detector: a box the fill left dry published a water surface, so the detector is not" >&2
  echo "                     reading the field it stands on." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "check_mesh_detector: OK ($VERTS vertices over $TRIS triangles; a dry box draws none)"
exit 0
