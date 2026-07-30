#[compute]
#version 450

// CUBED-SPHERE CARBON DIOXIDE — TRANSPORT pass. The sphere port of co2_transport3d.glsl: IDENTICAL
// diffusion + wind advection + downward CO2_SETTLE bias and IDENTICAL constants; only neighbour addressing
// changes. The box gathered its 6 neighbours by idx±offset with bounds ifs; here every cell reads them from
// the precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 0 = inward/DOWN (-y), 1 = -x, 2 = +x, 3 = -z,
// 4 = +z, 5 = outward/UP (+y); -1 = boundary → skipped (matches the box's world-axis lateral convention,
// same as water_sphere3d). CO₂ is denser than air: it carries an extra CO2_SETTLE share DOWN (added to this
// cell's own outflow into slot 0 AND to the inflow it gathers from the cell ABOVE, slot 5 — mass-conserving).
// Reads only the OLD co2 snapshot + wind + solid, writes co2_out[g]. Constants copied EXACTLY from
// co2_transport3d.glsl / MaterialGas3D.gd.
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

// Outflow/inflow share toward a neighbour the wind blows toward at speed `toward` (>=0): diffusion + advection.
float share(float toward) {
	return DIFFUSE + ADVECT * clamp(max(0.0, toward) * INV_WIND_REF, 0.0, 1.0);
}

// Speed of cell `c` toward its lateral link `l` (0..3 == neighbour slots 1..4), in that cell's tangent frame.
float toward_link(uint c, int l) {
	uint b = ((c / max(params.depth, 1u)) * 4u + uint(l)) * 2u;
	return vel_x[c] * ltan[b] + vel_z[c] * ltan[b + 1u];
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (solid[g] != 0.0) {
		co2_out[g] = 0.0;
		return;
	}
	uint base = g * 6u;

	int nb_d = nbr[base + 0u];   // DOWN (inward)
	int nb_u = nbr[base + 5u];   // UP (outward)
	bool has_d = (nb_d >= 0) && (solid[nb_d] == 0.0);
	bool has_u = (nb_u >= 0) && (solid[nb_u] == 0.0);

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
		in_lat += co2_in[m] * share(toward_link(uint(m), l ^ 1));
	}

	float keep = 1.0 - (out_lat + out_u + out_d);
	float acc = co2_in[g] * max(0.0, keep) + in_lat;

	// Vertical inflow: the cell ABOVE also settles CO2_SETTLE down into us.
	if (has_u) { acc += co2_in[nb_u] * (share(-vel_y[nb_u]) + CO2_SETTLE); }
	if (has_d) { acc += co2_in[nb_d] * share(vel_y[nb_d]); }

	co2_out[g] = max(0.0, acc);
}
