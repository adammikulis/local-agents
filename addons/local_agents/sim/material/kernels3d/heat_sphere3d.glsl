#[compute]
#version 450

// CUBED-SPHERE heat conduction (Phase B template). The box port of heat3d.glsl gathered 6 neighbours by
// idx arithmetic (±1, ±dim_x, ±layer) with `if(ix>0)` boundary drops; here every cell gathers its 6
// neighbours from a precomputed INDEX TABLE `nbr[idx*6 + d]` (slot 0=inward/down, 1-4 lateral, 5=outward/up;
// -1 = boundary → skipped). This is the mechanical transformation EVERY field kernel follows for the sphere:
// replace the idx±offset + bounds-if with `int nb = nbr[idx*6+d]; if (nb >= 0) …`.
//
// CRUST INSULATION (why this is a per-neighbour FLUX, not a relax-to-mean): a planet has a genuinely HOT deep
// interior (a ~1300°C pinned magma core) yet a TEMPERATE habitable surface. That coexists only because ROCK
// INSULATES — solid crust conducts heat far more slowly than open air/water mixes. The old kernel relaxed every
// cell toward its neighbour MEAN by ONE global CONDUCT_FRACTION, so rock conducted as fast as air and the core
// heat baked straight through the crust to the surface (surface ~110°C mean — everything died of heatstroke).
// Here conduction is a proper finite-difference flux with a PER-BOND conductivity that depends on PHASE: a bond
// touching SOLID rock uses the low ROCK_CONDUCT; an open↔open (air/water) bond uses the brisk VOID_CONDUCT. So
// the hot core diffuses UP through the crust slowly (a steep geothermal gradient near the core, gentle near the
// surface) while the outermost open cells stay well mixed and shed their heat to space via the solar/radiative
// pass — hot deep interior + temperate surface, exactly as a real planet. Double-buffered (read temp_in, write
// temp_out). Stable: Σ conductivity over ≤6 bonds ≤ 6·VOID_CONDUCT = 0.14 < 0.5.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TempIn { float temp_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer TempOut { float temp_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Neigh { int nbr[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Per-bond conductivity (fraction of the temperature difference exchanged across a bond per step).
// VOID_CONDUCT ≈ the old 0.14 relax-to-mean spread over 6 open bonds (air/water mix briskly). ROCK_CONDUCT is
// ~6× lower so the crust insulates: the deep interior stays near the core pin while the surface equilibrates to
// the solar/radiative ambient band. Tuned so a 1300°C core coexists with a temperate (~15-30°C) surface.
// VOID_CONDUCT cut 0.016 -> 0.0015 (about 10x). AIR IS A POOR CONDUCTOR; it moves heat by ADVECTION.
//
// At 0.016 per bond, ~0.096 per step over six bonds, the atmosphere equilibrated globally in roughly ten
// steps — it conducted like a metal, so the whole planet sat near one temperature and a pole could not
// stay cold no matter what the radiation budget did. This is precisely the behaviour the deleted
// ATMOS_RELAX anchor was invented to fight: its comment records that "brisk lateral air mixing slowly
// HOMOGENIZED the equator-to-pole gradient". The response then was to re-assert the gradient by fiat at a
// rate tuned to outvote conduction. The cause was the conductivity itself.
//
// Real air has a thermal conductivity around 0.026 W/m/K against ~2 for rock and ~200 for aluminium — it
// is an insulator, and Earth's equator-to-pole heat transport is done by WIND and ocean currents, not by
// conduction. This sim already has the advection: GasWindPass moves temp with the wind field. Lowering
// conduction lets that be the transport instead of a competitor to it.
const float VOID_CONDUCT = 0.0015;
// ROCK_CONDUCT cut 0.004 -> 0.0002 (20x) so the crust actually INSULATES.
//
// Measured 2026-07-30, with every prescribed temperature target removed: the planet's floor sat at
// 11.06 C and its mean at 40.6 C, set by geothermal conduction from the 1300 C core rather than by the
// sun — cutting the solar constant 20% moved the mean by ONE degree. The old hardcoded night floor,
// AMBIENT_NIGHT = 13.0, was approximately that geothermal equilibrium: the prescribed target had been
// tracking a real effect at the wrong scale the whole time.
//
// On Earth the surface geothermal flux is ~0.087 W/m^2 against ~340 W/m^2 of insolation, a ratio of about
// 1:4000 — the interior is thermally almost irrelevant at the surface, which is exactly why the sun sets
// the climate there. Here it was the senior partner. A thinner conductive path is the physical lever: the
// core stays hot (it is still 1300 C, and a deep cave or a magma chamber is still hot), but that heat no
// longer floods the surface faster than the surface can radiate it away.
const float ROCK_CONDUCT = 0.0002;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	float here = temp_in[idx];
	bool here_solid = solid[idx] != 0.0;
	float delta = 0.0;
	for (int d = 0; d < 6; d++) {
		int nb = nbr[idx * 6u + uint(d)];
		if (nb >= 0) {
			// A bond touching rock (either endpoint solid) conducts slowly; open↔open air/water mixes briskly.
			float k = (here_solid || solid[nb] != 0.0) ? ROCK_CONDUCT : VOID_CONDUCT;
			delta += k * (temp_in[nb] - here);
		}
	}
	temp_out[idx] = here + delta;
}
