#!/usr/bin/env bash
# ONE DEFINITION OF THE NEIGHBOUR-SLOT LAYOUT, ENFORCED.
#
# WHY IT EXISTS. The 6-slot layout was written from memory in every kernel that touches `nbr[]`, and most of
# them wrote it down WRONG — as `0 = down, 1..4 = lateral, 5 = up`. LASphereGrid builds it as
# `neighbours[c*6 + N_IN|N_OUT|N_A0+lateral_slot]`, so slot 1 is UP and 2..5 are the four laterals.
#
# Twelve kernels read slot 5 as "the cell above" and were walking SIDEWAYS around the sphere at constant
# radius: the solar column, the aquifer walk, reactions' GATE_SURFACE / GATE_OPEN_ABOVE / GATE_AIR_ABOVE,
# both buoyancy kernels, tracer transport and the wind. Four two-pass gathers (gravity_flow, soil,
# erosion_transport, plate_advect) hand-rolled the reverse map as `0<->5, 1<->2, 3<->4` instead of `d ^ 1`,
# so they debited send slots no cell ever read (mass destroyed) and read others twice (mass duplicated).
# In gravity_flow alone that was +149% mineral and +47% of the planet's whole thermal stock, from nothing.
#
# Same shape as check_heat_capacity_ssot.sh: a gate on the STRUCTURE, not the values. Every copy read the
# table correctly; they disagreed about what the slots MEANT, which no value gate can see.
#
# It asks two structural questions:
#   1. Does any kernel index nbr[] or send[] with a bare integer instead of the named slot constants?
#   2. Are the GLSL constants still equal to LASphereGrid's?
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg

K="$ROOT/addons/local_agents/sim/material/kernels3d"
SSOT="$K/neighbours.glsli"
GRID="$ROOT/addons/local_agents/sim/sphere/SphereGrid.gd"
fail=0

[ -f "$SSOT" ] || { echo "check_neighbour_slots: MISSING $SSOT — the SSOT include is gone." >&2; exit 2; }
[ -f "$GRID" ] || { echo "check_neighbour_slots: MISSING $GRID." >&2; exit 2; }

# 1. No bare integer slot index into the neighbour or send tables.
bare=$(grep -nE '\b(nbr|send)\[[^]]*[0-9]u?\]' "$K"/*.glsl 2>/dev/null \
       | grep -vE 'N_IN|N_OUT|N_A0|N_A1|N_B0|N_B1|N_SLOTS|N_LAT0|N_LATERAL_COUNT|opposite' || true)
if [ -n "$bare" ]; then
  echo "check_neighbour_slots: BARE SLOT INDEX — use the names from neighbours.glsli, never a number." >&2
  echo "$bare" >&2
  fail=1
fi

# 2. No kernel may re-derive the reverse link. `opposite()` is the only reverse map.
rolled=$(grep -nE '\?\s*5u\s*:|\?\s*0u\s*:.*\^|== 5u\) \? 0u' "$K"/*.glsl 2>/dev/null || true)
if [ -n "$rolled" ]; then
  echo "check_neighbour_slots: HAND-ROLLED REVERSE MAP — the only reverse link is opposite(d) = d ^ 1." >&2
  echo "$rolled" >&2
  fail=1
fi

# 3. The GLSL constants must equal LASphereGrid's.
for pair in "N_IN:N_IN" "N_OUT:N_OUT" "N_A0:N_A0" "N_A1:N_A1" "N_B0:N_B0" "N_B1:N_B1"; do
  g="${pair%%:*}"; d="${pair##*:}"
  gv=$(grep -oE "^const uint $g\s*=\s*([0-9]+)u" "$SSOT" | grep -oE '[0-9]+' | head -1)
  dv=$(grep -oE "^const $d: int = ([0-9]+)" "$GRID" | grep -oE '[0-9]+' | head -1)
  if [ -z "$gv" ] || [ -z "$dv" ]; then
    echo "check_neighbour_slots: could not read $g (glsl='$gv' gd='$dv')." >&2; fail=1; continue
  fi
  if [ "$gv" != "$dv" ]; then
    echo "check_neighbour_slots: $g DIVERGED — neighbours.glsli=$gv, SphereGrid.gd=$dv." >&2; fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check_neighbour_slots: FAILED." >&2
  exit 1
fi
echo "Neighbour-slot SSOT gate passed (one layout, opposite(d) = d ^ 1, GLSL == LASphereGrid)."
