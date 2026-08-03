#[compute]
#version 450

// CUBED-SPHERE CARBON DIOXIDE — TRANSPORT pass. The sphere port of co2_transport3d.glsl: IDENTICAL
// diffusion + wind advection + downward CO2_SETTLE bias and IDENTICAL constants; only neighbour addressing
// changes. The box gathered its 6 neighbours by idx±offset with bounds ifs; here every cell reads them from
// the precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 0 = inward/DOWN (-y), 1 = -x, 2 = +x, 3 = -z,
// 4 = +z, 5 = outward/UP (+y); -1 = boundary → skipped (matches the box's world-axis lateral convention,
// same as water_sphere3d). CO₂ is denser than air: it carries an extra CO2_SETTLE share DOWN (added to this
// cell's own outflow into slot 0 AND to the inflow it gathers from the cell ABOVE, slot 5).
// Reads only the OLD co2 snapshot + wind + solid, writes co2_out[g]. Constants copied EXACTLY from
// co2_transport3d.glsl / MaterialGas3D.gd.
//
// CONSERVATION (2026-08-03). The line above used to end "— mass-conserving", and the kernel WAS NOT. Two
// separate leaks, both fixed below and both described where they are fixed:
//   * the outgoing shares were never scaled to sum to at most 1, so a windy cell's donor floored at zero while
//     its neighbours gathered full shares — THIS MADE CARBON APPEAR FROM NOTHING. Now out-scaled, the
//     dust_outscale_sphere3d.glsl pattern, recomputed inline.
//   * a cell that turned to rock had its CO₂ set to zero — THIS DESTROYED CARBON. The gas is now trapped in
//     place instead, inert until the rock reopens.
// The kernel is conserving as of that change: what a cell sends is exactly what its neighbours gather, and no
// path writes a value that is not accounted on the other side. Measured effect on a --planet-only 600-frame
// run at seed 4242: carbon run-long drift +6.4872 units/step -> see the commit message for the after-figure.
//
// LATERAL WIND (2026-07-30): the horizontal velocity is stored in the CELL'S OWN TANGENT FRAME, which is a
// separate table from the neighbour slots (see wind_step_sphere3d for why one table cannot be both). So "how
// fast is this cell blowing toward that neighbour" is a dot with the link's direction in that frame (`ltan`),
// not the signed velocity component the slot used to stand for. Both ends of a face evaluate the same
// expression — a cell reads its neighbour's flow back at itself from the neighbour's REVERSE link (l ^ 1) —
// so the exchange stays conservative to the face. In a face interior it is arithmetically the old code.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CO2In  { float co2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer CO2Out { float co2_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX   { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelY   { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelZ   { float vel_z[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot
layout(set = 0, binding = 16, std430) restrict readonly buffer LinkTan { float ltan[]; };  // per-column link dirs

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint depth;        // radial shells per column — turns a cell index into its column for the ltan lookup
	uint pad1;
	uint pad2;
} params;

// Transport tunables — MUST match co2_transport3d.glsl / MaterialGas3D.gd exactly.
const float DIFFUSE = 0.12;
const float ADVECT = 0.08;
const float INV_WIND_REF = 1.0 / 6.0;
const float CO2_SETTLE = 0.05;   // extra downward outflow share (buoyancy: CO₂ sinks)

// CFL cap on a cell's TOTAL outgoing share, exactly the role OUT_MAX plays in dust_outscale_sphere3d.glsl.
// A cell cannot send more CO₂ than it holds, so the physical ceiling is 1.0; 0.9 keeps a 10% stability margin
// on this first-order upwind scheme. This is a NUMERICAL limit, not a property of carbon dioxide, so it does
// not belong in LAPhysical. A calm cell's raw total is 4*0.12 + 0.12 + 0.12+0.05 = 0.77, below the cap, so
// still air is scaled by exactly 1.0 and behaves as it always did; only genuinely windy cells are limited.
const float OUT_MAX = 0.9;

// Outflow/inflow share toward a neighbour the wind blows toward at speed `toward` (>=0): diffusion + advection.
float share(float toward) {
	return DIFFUSE + ADVECT * clamp(max(0.0, toward) * INV_WIND_REF, 0.0, 1.0);
}

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

// TOTAL outgoing share of cell `c`, before scaling. Reads ONLY c's own velocity and the solid flags of c's
// neighbours, so c and every neighbour of c compute the SAME number — which is what makes the scaled exchange
// below conservative to the face without a precomputed buffer.
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
	if (cd >= 0 && solid[cd] == 0.0) { t += share(-vel_y[c]) + CO2_SETTLE; }
	return t;
}

// Uniform scale that holds a cell's total outgoing share at or below OUT_MAX (the dust_outscale pattern,
// recomputed inline because this pass has no spare buffer binding to precompute it into).
float out_scale(uint c) {
	float t = raw_out(c);
	return (t > OUT_MAX) ? (OUT_MAX / t) : 1.0;
}


void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;

	if (solid[g] != 0.0) {
		// ROCK GREW OVER A POCKET OF AIR: TRAP THE CO₂, DO NOT DELETE IT. This used to be a bare
		// `co2_out[g] = 0.0`, which DESTROYED CARBON every time a cell crossed the rock threshold — `solid` is
		// re-derived from rock_fill every step (solid_derive_sphere3d.glsl), so a solidifying lava front or a
		// filling crater annihilated whatever CO₂ stood in the way, unaccounted. The gas is now held in place:
		// no transport path moves matter across a solid face, so it sits inert until the rock melts or erodes
		// back open, and then rejoins the atmosphere. Same rule atmos_transport_sphere3d.glsl already applies
		// to moisture. (Held in place rather than pushed into the open neighbours, for the reason spelled out
		// in o2_transport_sphere3d.glsl's matching branch: the initial seed writes gas into bedrock, and
		// displacing would pump that fake mass into the live atmosphere. CO₂ starts at 0 everywhere so it does
		// not suffer from that seed today, but the two channels should not disagree about what burial means.)
		co2_out[g] = co2_in[g];
		return;
	}

	int nb_d = nbr[base + 0u];   // DOWN (inward)
	int nb_u = nbr[base + 5u];   // UP (outward)
	bool has_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool has_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

	// OUT-SCALING (the dust_outscale_sphere3d.glsl pattern). Every share this cell sends is multiplied by
	// scale_g, and every neighbour gathers that same scaled share, so the exchange is conservative to the face
	// and `keep` can no longer go negative.
	//
	// WHAT THIS REPLACES, AND WHY IT MATTERED: the old code summed unscaled shares that reach 4*0.20 lateral +
	// 0.20 up + 0.20+0.05 down = 1.25 in the worst case, wrote `keep = 1 - that`, and then floored the donor
	// with `max(0.0, keep)`. Above a total of 1.0 the donor stopped at zero while every neighbour still gathered
	// its FULL unscaled share — so the six neighbours between them received more carbon than the donor ever
	// held. THAT MADE CARBON APPEAR FROM NOTHING, on every windy cell, every step. Measured on this tree before
	// the fix: carbon_first 720.0 -> carbon_total 5818.96 over 786 field steps, a run-long drift of
	// +6.4872 units/step, of which carbon_co2 was 5379.31. The trailing `max(0.0, acc)` is gone with it: with
	// the shares scaled, keep >= 1 - OUT_MAX = 0.1 and every inflow term is non-negative, so `acc` cannot be
	// negative and a clamp there could only ever have hidden the same bug.
	float scale_g = out_scale(g);
	float vyi = vel_y[g];
	float out_u = has_u ? share(vyi) : 0.0;
	// Down carries an extra CO2_SETTLE (buoyant sink); up carries none.
	float out_d = has_d ? (share(-vyi) + CO2_SETTLE) : 0.0;

	// The four LATERAL faces, each in the direction the tangent frame says that link points.
	float out_lat = 0.0;
	float in_lat = 0.0;
	for (int l = 0; l < 4; ++l) {
		int m = nbr[base + uint(l + 1)];
		if (m < 0 || solid[m] != 0.0) {
			continue;
		}
		out_lat += share(toward_link(g, l));
		in_lat += co2_in[m] * share(toward_link(uint(m), l ^ 1)) * out_scale(uint(m));
	}

	float keep = 1.0 - (out_lat + out_u + out_d) * scale_g;
	float acc = co2_in[g] * keep + in_lat;

	// Vertical inflow: the cell ABOVE also settles CO2_SETTLE down into us.
	if (has_u) { acc += co2_in[nb_u] * (share(-vel_y[nb_u]) + CO2_SETTLE) * out_scale(uint(nb_u)); }
	if (has_d) { acc += co2_in[nb_d] * share(vel_y[nb_d]) * out_scale(uint(nb_d)); }

	co2_out[g] = acc;
}
