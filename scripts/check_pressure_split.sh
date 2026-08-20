#!/usr/bin/env bash
# TWO PRESSURES, ONE PER CELL CLASS, AND THEY MAY NOT MEET. An open cell's pressure is a state function
# of its own matter; a solid cell's is the column standing over it. That split is only honest while every
# cell has exactly ONE writer and rock's pressure never reaches the momentum equation. Maintainer's
# DECISION, recorded as `quasi_static_solid_pressure` in docs/APPROXIMATIONS.md.
#
# EXIT 0 the split holds · 1 it does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool rg
K="$ROOT/addons/local_agents/sim/material/kernels3d"
DERIVE="$K/state_derive.glsl"
LITHO="$K/pressure.glsl"
TRANSPORT="$K/transport.glsl"
for f in "$DERIVE" "$LITHO" "$TRANSPORT"; do
	[ -f "$f" ] || { echo "check_pressure_split: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

fail=0

# 1. The EOS writer takes open cells only.
rg -qU 'if \(solid\[g\] == 0\.0\) \{\s*\n\s*pressure\[g\] = la_eos_p' "$DERIVE" || {
	echo "FAIL  state_derive.glsl writes pressure without guarding on an OPEN cell, so it and" >&2
	echo "      pressure.glsl both write the rock and the later dispatch silently wins." >&2
	fail=1
}

# 2. The lithostatic writer takes solid cells only.
rg -qU 'if \(solid\[g\] == 0\.0\) \{\s*\n\s*return;' "$LITHO" || {
	echo "FAIL  pressure.glsl does not return on an open cell, so it overwrites the state-function" >&2
	echo "      pressure state_derive.glsl computed for the fluid." >&2
	fail=1
}

# 3. THE SEAM. A wall face takes the FLUID cell's own pressure. Reading a solid neighbour's here is what
#    puts a lithostatic gigapascal into the momentum of the air touching it.
rg -qU 'float p_face = face_p\(gidx, d\);\s*\n\s*if \(!wall\) \{' "$TRANSPORT" || {
	echo "FAIL  transport.glsl's wall face no longer takes the fluid cell's own pressure. Rock is" >&2
	echo "      quasi-static and its pressure is not on the same scale; feeding it to -grad(p) is" >&2
	echo "      what the split exists to prevent." >&2
	fail=1
}

# 4. The decision is declared, or it is not a decision.
rg -q 'quasi_static_solid_pressure' "$ROOT/docs/APPROXIMATIONS.md" || {
	echo "FAIL  docs/APPROXIMATIONS.md no longer declares quasi_static_solid_pressure." >&2
	fail=1
}

[ "$fail" -eq 0 ] || exit 1
echo "check_pressure_split: OK (one writer per cell class, and the wall takes the fluid's own pressure)"
