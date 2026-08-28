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
TRANSPORT="$K/flux.glsl"
for f in "$DERIVE" "$LITHO" "$TRANSPORT"; do
	[ -f "$f" ] || { echo "check_pressure_split: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

fail=0

# 1. The EOS writer takes open cells only.
rg -qU 'if \(solid\[g\] == 0\.0\) \{\s*\n\s*pressure\[g\] = p_pa;' "$DERIVE" || {
	echo "FAIL  state_derive.glsl writes pressure without guarding on an OPEN cell, so it and" >&2
	echo "      pressure.glsl both write the rock and the later dispatch silently wins." >&2
	fail=1
}

# 1b. And the pressure it writes is the equation of state's, solved against the ladder.
rg -qU 'p_next = la_eos_p\(' "$DERIVE" || {
	echo "FAIL  state_derive.glsl no longer states an open cell's pressure from its own matter." >&2
	fail=1
}

# 2. The lithostatic writer takes solid cells only.
rg -qU 'if \(solid\[g\] == 0\.0\) \{\s*\n\s*return;' "$LITHO" || {
	echo "FAIL  pressure.glsl does not return on an open cell, so it overwrites the state-function" >&2
	echo "      pressure state_derive.glsl computed for the fluid." >&2
	fail=1
}

# 3. THE SEAM. A wall face takes the FLUID cell's own pressure, and a face onto vacuum takes none.
#    Reading a solid neighbour's here is what puts a lithostatic gigapascal into the momentum of the air.
rg -qU 'fp_star\[f\] = pc;' "$TRANSPORT" || {
	echo "FAIL  flux.glsl's wall face no longer takes the fluid cell's own pressure. Rock is" >&2
	echo "      quasi-static and its pressure is not on the same scale; feeding it to -grad(p) is" >&2
	echo "      what the split exists to prevent." >&2
	fail=1
}

# 4. And the Riemann correction that could read it is guarded by that same wall test.
rg -qU 'if \(inb < 0 \|\| solid\[uint\(inb\)\] != 0\.0\) \{\s*\n\s*fp_star\[f\] = pc;' "$TRANSPORT" || {
	echo "FAIL  flux.glsl's Riemann face pressure is no longer guarded by the wall test, so a" >&2
	echo "      solid neighbour's lithostatic pressure can reach the momentum equation." >&2
	fail=1
}

# 5. AND ONE WRITER, NOT THREE. Transport moves matter; the equation of state says what pressure that
#    matter is at. A linearised increment beside it is a second account of a compression the mass flux
#    across the face already performed, and counted twice it does work on the gas every step.
if rg -N -q -e 'pressure\[[A-Za-z_][A-Za-z_0-9]*\][[:space:]]*[-+*/]?=' "$TRANSPORT"; then
	echo "FAIL  flux.glsl writes pressure[]. An open cell's pressure is state_derive.glsl's" >&2
	echo "      equation of state and nothing else's; transport moves the matter it is derived from." >&2
	rg -N -n -e 'pressure\[[A-Za-z_][A-Za-z_0-9]*\][[:space:]]*[-+*/]?=' "$TRANSPORT" >&2
	fail=1
fi
rg -q 'readonly buffer PressureBuf' "$TRANSPORT" || {
	echo "FAIL  flux.glsl no longer binds the pressure buffer readonly, so a write to it is one" >&2
	echo "      edit away and nothing but this gate stands between." >&2
	fail=1
}

# 6. The decision is declared, or it is not a decision.
rg -q 'quasi_static_solid_pressure' "$ROOT/docs/APPROXIMATIONS.md" || {
	echo "FAIL  docs/APPROXIMATIONS.md no longer declares quasi_static_solid_pressure." >&2
	fail=1
}

[ "$fail" -eq 0 ] || exit 1
echo "check_pressure_split: OK (one writer per cell class, transport is not one, and the wall takes the fluid's own pressure)"
