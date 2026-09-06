#!/usr/bin/env bash
# THE LIQUID SURFACE THE DEVICE EXTRACTS, against the field it reads. Two arms: a box the fill left water
# in publishes a surface whose shared corners the two cells meeting there agree about, and a box the fill
# left dry publishes none. MUTATION: return a constant from la_surface_r in mesh_extract.glsl -> the dry
# arm draws a surface and goes red; drop the sort in la_corner_r -> the seam count rises past its ceiling.
# EXIT 0 the detector reads the field * 1 it does not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_ceiling.sh"
require_tool rg

CEIL_FILE="$ROOT/docs/MESH_SEAM_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_mesh_detector: no docs/MESH_SEAM_CEILING, so the seam count is held to nothing." >&2; exit 2; }
CEIL="$(rg -N -o -e '^[0-9]+$' "$CEIL_FILE" | head -1)"
[ -n "$CEIL" ] || { echo "check_mesh_detector: docs/MESH_SEAM_CEILING states no count." >&2; exit 2; }

# The box the demo stands in, and one on the pole the fill leaves dry.
WET_BOX="${LA_MESH_WET_BOX:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}"
DRY_BOX="${LA_MESH_DRY_BOX:-0,surface,0,3,24,3,5120,640}"

reading() { printf '%s\n' "$2" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[[:space:]]*$//' -e 's/\.0*$//'; }

run_box() {
  LA_MESH_CHECK=1 "$ROOT/scripts/sim_run.sh" --path "$ROOT" --slice --slice-box "$1" --rung 1 --frames 4 \
    --report water_surface_quads,mesh_seam_breaks,mesh_seams 2>&1
}

WET_OUT="$(run_box "$WET_BOX")"
QUADS="$(reading water_surface_quads "$WET_OUT")"
BREAKS="$(reading mesh_seam_breaks "$WET_OUT")"
SEAMS="$(reading mesh_seams "$WET_OUT")"
if ! printf '%s' "${QUADS:-}${BREAKS:-}${SEAMS:-}" | grep -Eq '^[0-9]+$'; then
  printf '%s\n' "$WET_OUT" | tail -20 >&2
  echo "check_mesh_detector: the wet arm published no mesh reading, so nothing was examined." >&2
  exit 2
fi
if [ "$QUADS" -le 0 ] || [ "$SEAMS" -le 0 ]; then
  echo "MESH_DETECTOR={\"quads\":$QUADS,\"seams\":$SEAMS}"
  echo "check_mesh_detector: the box the fill left water in published no surface, so the detector was" >&2
  echo "                     never exercised and this gate asserts nothing." >&2
  exit 2
fi

DRY_OUT="$(run_box "$DRY_BOX")"
DRY_QUADS="$(reading water_surface_quads "$DRY_OUT")"
if ! printf '%s' "${DRY_QUADS:-}" | grep -Eq '^[0-9]+$'; then
  printf '%s\n' "$DRY_OUT" | tail -20 >&2
  echo "check_mesh_detector: the dry arm published no mesh reading, so the detector was held to nothing." >&2
  exit 2
fi

echo "MESH_DETECTOR={\"quads\":$QUADS,\"seams\":$SEAMS,\"breaks\":$BREAKS,\"ceiling\":$CEIL,\"dry_quads\":$DRY_QUADS}"
fail=0
if [ "$BREAKS" -gt "$CEIL" ]; then
  echo "check_mesh_detector: $BREAKS shared corners are in two places, against a ceiling of $CEIL." >&2
  echo "                     Two cells meeting at a corner have to put it in one place, or the sheet" >&2
  echo "                     has a hole along that edge." >&2
  fail=1
fi
if [ "$DRY_QUADS" -ne 0 ]; then
  echo "check_mesh_detector: a box the fill left dry published $DRY_QUADS quads of water surface, so the" >&2
  echo "                     detector is not reading the field it stands on." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
ceiling_slack "MESH_SEAM_CEILING" "$BREAKS" "$CEIL" 0 "$ROOT" || exit 1
echo "check_mesh_detector: OK ($QUADS quads over $SEAMS seams, $BREAKS in two places; a dry box draws none)"
exit 0
