#!/usr/bin/env bash
# A CELL IS EMPTY WHEN IT HOLDS NO MATTER, AND NOTHING ELSE. A density below which a cell "counts as
# empty" dropped the momentum it held and refused its donation, so a floor is a place momentum is
# destroyed. No kernel, pass or query may declare one.
# EXIT 0 no floor named · 1 a floor is back · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
SIM="$ROOT/addons/local_agents/sim"
EXT="$ROOT/addons/local_agents/gdextensions/localagents/src"
for d in "$KERNELS" "$SIM" "$EXT"; do
	[ -d "$d" ] || { echo "check_no_empty_floor: MISSING $d" >&2; exit 2; }
done
n="$(find "$KERNELS" -name '*.glsl' | wc -l | tr -d ' ')"
[ "$n" -ge 5 ] || { echo "check_no_empty_floor: $n kernels found; the scope collapsed." >&2; exit 2; }
NAMES='\b(rho_floor|donor_floor|EMPTY_RHO_KG_M3|min_fill|min_amount|MIN_FILL_FRAC|MIN_AMOUNT)\b'
hits="$(rg -n --glob '*.glsl' --glob '*.glsli' --glob '*.gd' --glob '*.cpp' --glob '*.hpp' "$NAMES" "$KERNELS" "$SIM" "$EXT" || true)"
if [ -n "$hits" ]; then
	echo "check_no_empty_floor: FAILED — an emptiness floor is named:" >&2
	echo "$hits" >&2
	echo "A cell is empty iff rho_bulk == 0; a density floor destroys the momentum under it." >&2
	exit 1
fi
echo "check_no_empty_floor: OK ($n kernels, sim and extension sources name no emptiness floor)"
