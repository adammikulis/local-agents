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
const float VOID_CONDUCT = 0.016;
const float ROCK_CONDUCT = 0.004;

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
