#[compute]
#version 450

// CUBED-SPHERE OXYGEN — TRANSPORT pass. Sphere port of o2_transport3d.glsl. The box kernel gathered its six
// neighbours by idx arithmetic (±1, ±dim_x, ±layer) with dim-bounds ifs + a solid[] wall test, and biased the
// diffusion share by the wind blowing TOWARD each neighbour (share(toward) = DIFFUSE + ADVECT * ...). On the
// cubed sphere every cell gathers its six neighbours from the precomputed INDEX TABLE nbr[idx*6 + d]
// (nbr == -1 → boundary, skipped); a solid neighbour donates AND receives nothing, so O₂ never crosses stone
// (this is what emergently SEALS caves).
//
// NON-MECHANICAL: the wind ADVECTION term is DROPPED here. The box kernel projects the world-space wind vector
// onto each neighbour direction (share(vxi) for +x, share(-vxi) for -x, …). The sphere neighbour table carries
// only indices, not per-slot world directions, and on a cubed sphere the lateral neighbours point in varying
// world directions — so the directional bias cannot be mechanically preserved. This pass keeps the SYMMETRIC
// diffusion share only (DIFFUSE per open neighbour), i.e. exactly the box kernel with wind = 0: still
// mass-conserving and pairwise-symmetric. DIFFUSE is copied EXACTLY from MaterialGas3D.gd. Reads only the OLD
// o2 snapshot (o2_in) + solid, writes o2_out[g] → order-independent.
//
// CONSERVATION (2026-08-03). "Still mass-conserving" above was true of the DIFFUSION and false of the kernel:
// a cell that turned to rock had its oxygen set to zero, which DESTROYED OXYGEN — see the solid branch below,
// which now displaces it into the open cells around instead. Measured before the fix on a --planet-only
// 600-frame run at seed 4242: o2_first 37141.88 -> o2_total 36855.73, a run-long drift of -0.364 units/step.
// The diffusion itself was and remains exactly conserving: what a cell gives a neighbour is what that
// neighbour takes, and the openness test is symmetric so both ends always agree a face exists.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer O2In  { float o2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer O2Out { float o2_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Transport tunable — MUST match MaterialGas3D.gd exactly. (ADVECT/wind dropped on the sphere; see header.)
const float DIFFUSE = 0.12;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		// ROCK GREW OVER A POCKET OF AIR: TRAP THE O₂, DO NOT DELETE IT. This used to be a bare
		// `o2_out[g] = 0.0`, which DESTROYED OXYGEN every time a cell crossed the rock threshold — `solid` is
		// re-derived from rock_fill every step (solid_derive_sphere3d.glsl), so a solidifying lava front or a
		// filling crater annihilated the air in its way, unaccounted. The gas is now held in place: no
		// transport path moves matter across a solid face, so it sits inert until the rock melts or erodes
		// back open, and then rejoins the atmosphere. This is the same rule atmos_transport_sphere3d.glsl
		// already applies to moisture (`q_out[g] = q_in[g]` on a solid cell).
		//
		// WHY TRAPPED IN PLACE AND NOT PUSHED INTO THE NEIGHBOURS, which is the more obvious physical picture:
		// MaterialField3D.gd:442-443 seeds this channel with `_o2.fill(O2_AMBIENT)` over EVERY cell, bedrock
		// included — roughly 20,000 interior rock cells each start holding 1.0 units of free oxygen that has no
		// business being inside stone. (The comment at MaterialField3D.gd:110 says the seed covers "every OPEN
		// cell". It does not; the fill is unconditional.) Displacing a solid cell's gas into its open
		// neighbours therefore does not just move real buried air, it pumps that fake seed straight into the
		// live atmosphere: measured on this tree, the displacing version raised o2_first from 37141.88 to
		// 43420.87 in one step. Holding it in place keeps the bogus seed inert and out of the air while still
		// never destroying anything. The seed itself is the actual defect and it is NOT fixed here — see the
		// track report; it belongs to whoever owns MaterialField3D.gd.
		o2_out[g] = o2_in[g];
		return;
	}
	// Symmetric diffusion: each OPEN neighbour exchanges a fixed DIFFUSE share (pairwise-conserving).
	float acc = o2_in[g];
	for (int d = 0; d < 6; d++) {
		int nb = nbr[g * 6u + uint(d)];
		if (nb >= 0 && solid[nb] == 0.0) {
			acc += DIFFUSE * (o2_in[nb] - o2_in[g]);
		}
	}

	// The `max(0.0, ...)` that used to wrap this write is GONE, and it was unreachable, not load-bearing.
	// Worst case this cell donates DIFFUSE to all six neighbours at once, leaving a self coefficient of
	// 1 - 6*0.12 = 0.28, and every inflow term DIFFUSE*o2_in[nb] is non-negative because o2 never goes negative.
	// So acc >= 0.28 * o2_in[g] >= 0 always. Unlike the co2 kernel — whose shares reached 1.25 and whose clamp
	// therefore fired and MINTED CARBON — this one could never bite, so removing it changes no value; it is
	// removed so that a future edit which DOES push the shares past 1 fails loudly instead of quietly minting.
	o2_out[g] = acc;
}
