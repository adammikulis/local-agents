#[compute]
#version 450

// ONE TRANSPORT KERNEL FOR EVERY GAS. Diffusion + wind advection + a density-driven settle, on the
// cubed-sphere lattice, with a CFL cap that keeps the exchange conservative to the face.
//
// ===== WHY THERE IS ONE OF THESE AND NOT ONE PER GAS =======================================================
//
// There used to be o2_transport_sphere3d.glsl and co2_transport_sphere3d.glsl, and they were the same kernel
// twice. After the shared solver landed they differed by EXACTLY ONE FLOAT — the gas's density contrast
// against air — plus their buffer names and their comments. Two pipelines, two dispatches and two files to
// keep in step, for one number.
//
// AND WHILE THEY WERE SEPARATE THEY DRIFTED, WHICH IS THE WHOLE ARGUMENT. co2_transport advected with the
// wind; o2_transport did not, and said why in its own header:
//
//     "NON-MECHANICAL: the wind ADVECTION term is DROPPED here. ... The sphere neighbour table carries only
//      indices, not per-slot world directions, so the directional bias cannot be mechanically preserved."
//
// That was FALSE, and the refutation was the file sitting next to it: `ltan`, the per-column link-tangent
// table, is exactly those per-slot directions, and co2_transport was already using it on this same lattice.
// So in one parcel of air the CO2 blew downwind and the O2 did not, for a limitation that did not exist —
// and nothing could catch it, because the two kernels were allowed to disagree by construction.
//
// A NEW GAS IS NOW A TABLE ROW, NOT A KERNEL: bind its channel and pass its contrast.
//
// ===== WHAT IS A PROPERTY OF THE GAS, AND WHAT IS A PROPERTY OF THE FLOW ===================================
//
// TURBULENT MIXING IS A PROPERTY OF THE FLOW, NOT THE MOLECULE, so DIFFUSE and ADVECT are kernel constants
// shared by every gas rather than per-gas numbers. Molecular diffusion of O2 in air is 2.0e-5 m^2/s, which
// moves oxygen a measurable distance across one of these cells in MONTHS — negligible on every timescale
// this simulation runs. What actually mixes a planet's atmosphere is eddy transport, orders of magnitude
// faster and set by the wind. Giving two gases two different mixing rates would be asserting that the air
// stirs one and not the other.
//
// THE SETTLE IS THE ONLY PER-GAS TERM, and it is DERIVED. co2_transport carried `CO2_SETTLE = 0.05` with its
// own comment admitting it was "a downward share chosen to produce the behaviour" — a fitted constant. What
// drives a dense gas down is its density contrast against air, and at fixed p and T that goes as molar mass,
// which LASubstances already carries. The caller passes (M_gas - M_air)/M_air:
//
//     CO2 (44.010 vs 28.968) -> +0.51927        O2 (31.998 vs 28.968) -> +0.10460
//
// A gas LIGHTER than air gets a negative contrast and rises, out of the same expression with no branch.
//
// STATED, NOT HIDDEN: gravitational separation of a well-mixed turbulent atmosphere is weak, and on Earth it
// does not happen below the turbopause at all. This term is modelling "a heavy gas released into STILL air
// pools in hollows" — a volcanic vent filling a crater, Lake Nyos — which this simulation does produce. It is
// at least PROPORTIONAL to the real property that drives it now, instead of being one number per kernel.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer GasIn   { float gas_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer GasOut { float gas_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid   { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX    { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelY    { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelZ    { float vel_z[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh   { int nbr[]; };      // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };   // per-column dirs

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint depth;              // radial shells per column — turns a cell index into its column for `ltan`
	float settle_contrast;   // (M_gas - M_air) / M_air. THE ONLY per-gas number.
	float pad0;
} params;

// Wind speed at which the advective addition saturates. A NUMERICAL scale of this grid and step.
const float WIND_REF = 6.0;
const float INV_WIND_REF = 1.0 / WIND_REF;

// Per-open-neighbour mixing share, and the wind-driven addition at or above WIND_REF. Both are stand-ins for
// eddy mixing at this grid's scale — properties of this model, with no measured value to check against.
const float DIFFUSE = 0.12;
const float ADVECT = 0.08;

// Downward share per unit of fractional molar-mass excess over dry air.
const float SETTLE_PER_CONTRAST = 0.0963;

// CFL cap on a cell's TOTAL outgoing share. A cell cannot send more than it holds, so the physical ceiling is
// 1.0; 0.9 keeps a 10% stability margin on this first-order upwind scheme.
//
// THIS CAP IS LOAD-BEARING AND ITS ABSENCE MINTED CARBON. Unscaled shares reached 1.25 on a windy cell: the
// donor wrote `keep = max(0, 1 - 1.25)` = 0 while every neighbour still gathered its FULL share, so the six
// neighbours between them received more than the donor ever held. Measured before that fix,
// carbon_first 720.0 -> carbon_total 5818.96 over 786 steps. Every share a cell sends is scaled, and every
// neighbour gathers that same scaled share, so the exchange is conservative to the face and neither end
// needs a clamp.
const float OUT_MAX = 0.9;

float settle() {
	return SETTLE_PER_CONTRAST * params.settle_contrast;
}

// Outflow/inflow share toward a neighbour the wind blows toward at speed `toward` (>= 0). A neighbour the
// wind blows AWAY from still gets the diffusive share, which is what makes this reduce to pure symmetric
// mixing in still air.
float share(float toward) {
	return DIFFUSE + ADVECT * clamp(max(0.0, toward) * INV_WIND_REF, 0.0, 1.0);
}

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
// THIS is the per-slot world direction the O2 kernel said the lattice did not have.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// TOTAL outgoing share of cell `c`, before scaling. Reads ONLY c's own velocity and the solid flags of c's
// neighbours, so c and every neighbour of c compute the SAME number — which is what makes the scaled
// exchange conservative to the face without a precomputed buffer.
float raw_out(uint c) {
	uint b = c * 6u;
	float t = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[b + uint(l + 1)];
		if (m >= 0 && solid[m] == 0.0) { t += share(toward_link(c, l)); }
	}
	int cu = nbr[b + 5u];
	if (cu >= 0 && solid[cu] == 0.0) { t += share(vel_y[c]); }
	int cd = nbr[b + 0u];
	if (cd >= 0 && solid[cd] == 0.0) { t += share(-vel_y[c]) + settle(); }
	return t;
}

float out_scale(uint c) {
	float t = raw_out(c);
	return (t > OUT_MAX) ? (OUT_MAX / t) : 1.0;
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}

	if (solid[g] != 0.0) {
		// ROCK GREW OVER A POCKET OF AIR: TRAP THE GAS, DO NOT DELETE IT. Both predecessors used to write a
		// bare 0.0 here, which DESTROYED the gas every time a cell crossed the rock threshold — `solid` is
		// re-derived from rock_fill every step (solid_derive_sphere3d.glsl), so a solidifying lava front or a
		// filling crater annihilated the air in its way, unaccounted. Held in place instead: no transport path
		// crosses a solid face, so it sits inert until the rock melts or erodes back open. Same rule
		// atmos_transport_sphere3d.glsl already applies to moisture.
		//
		// WHY TRAPPED AND NOT PUSHED INTO THE NEIGHBOURS, which is the more obvious physical picture:
		// MaterialField3D seeds these channels over EVERY cell, bedrock included, so roughly 20,000 interior
		// rock cells start holding gas that has no business being inside stone. Displacing a solid cell's gas
		// into its open neighbours would pump that fake seed straight into the live atmosphere — measured on
		// the O2 channel, the displacing version raised o2_first from 37141.88 to 43420.87 in one step.
		// Holding it keeps the bogus seed inert while still never destroying anything. THE SEED IS THE ACTUAL
		// DEFECT and it is not fixed here.
		gas_out[g] = gas_in[g];
		return;
	}

	uint base = g * 6u;
	int nb_d = nbr[base + 0u];
	int nb_u = nbr[base + 5u];
	bool has_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool has_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	float s = settle();
	float scale_g = out_scale(g);
	float vyi = vel_y[g];
	float out_u = has_u ? share(vyi) : 0.0;
	float out_d = has_d ? (share(-vyi) + s) : 0.0;

	float out_lat = 0.0;
	float in_lat = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[base + uint(l + 1)];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		out_lat += share(toward_link(g, l));
		in_lat += gas_in[m] * share(toward_link(uint(m), l ^ 1)) * out_scale(uint(m));
	}

	float keep = 1.0 - (out_lat + out_u + out_d) * scale_g;
	float acc = gas_in[g] * keep + in_lat;

	if (has_u) { acc += gas_in[nb_u] * (share(-vel_y[nb_u]) + s) * out_scale(uint(nb_u)); }
	if (has_d) { acc += gas_in[nb_d] * share(vel_y[nb_d]) * out_scale(uint(nb_d)); }

	gas_out[g] = acc;
}
