#[compute]
#version 450

// GPU 3D CARBON DIOXIDE — TRANSPORT pass. A race-free GATHER port of LAMaterialGas3D._transport_co2(): the
// SAME diffusion + wind advection as O₂ (o2_transport3d.glsl), PLUS a constant downward CO2_SETTLE share —
// CO₂ is denser than air, so it drains DOWN connected air into hollows/valleys and pools there (emergent
// suffocation pockets). The settle is mass-conserving: it is added to a cell's DOWNWARD outflow AND to the
// matching inflow the cell BELOW gathers from above. Rock neighbours donate/receive nothing (a floor holds
// the pool). Reads only the OLD co2 snapshot (co2_in) + wind + solid, writes co2_out[g].
//
// Runs AFTER the fire kernel emitted CO₂ in place (fuel + O₂ → CO₂). The per-column SKY VENT that sheds each
// surface cell's CO₂ toward 0 is a SEPARATE pass (gas_sky3d.glsl), dispatched after this one. Constants copied
// EXACTLY from MaterialGas3D.gd. Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CO2In  { float co2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer CO2Out { float co2_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Solid  { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX   { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelY   { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelZ   { float vel_z[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
} params;

// Transport tunables — MUST match MaterialGas3D.gd exactly.
const float DIFFUSE = 0.12;
const float ADVECT = 0.08;
const float INV_WIND_REF = 1.0 / 6.0;
const float CO2_SETTLE = 0.05;   // extra downward outflow share (buoyancy: CO₂ sinks)

// Outflow/inflow share toward a neighbour the wind blows toward at speed `toward` (>=0): diffusion + advection.
float share(float toward) {
	return DIFFUSE + ADVECT * clamp(max(0.0, toward) * INV_WIND_REF, 0.0, 1.0);
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint dx = params.dim_x;
	uint dy = params.dim_y;
	uint dz = params.dim_z;
	uint layer = dx * dz;
	if (solid[g] != 0.0) {
		co2_out[g] = 0.0;
		return;
	}
	uint iy = g / layer;
	uint rem = g - iy * layer;
	uint iz = rem / dx;
	uint ix = rem - iz * dx;

	bool has_e = (ix < dx - 1u) && (solid[g + 1u] == 0.0);
	bool has_w = (ix > 0u) && (solid[g - 1u] == 0.0);
	bool has_s = (iz < dz - 1u) && (solid[g + dx] == 0.0);
	bool has_n = (iz > 0u) && (solid[g - dx] == 0.0);
	bool has_u = (iy < dy - 1u) && (solid[g + layer] == 0.0);
	bool has_d = (iy > 0u) && (solid[g - layer] == 0.0);

	float vxi = vel_x[g];
	float vyi = vel_y[g];
	float vzi = vel_z[g];
	float out_e = has_e ? share(vxi) : 0.0;
	float out_w = has_w ? share(-vxi) : 0.0;
	float out_s = has_s ? share(vzi) : 0.0;
	float out_n = has_n ? share(-vzi) : 0.0;
	float out_u = has_u ? share(vyi) : 0.0;
	// Down carries an extra CO2_SETTLE (buoyant sink); up carries none.
	float out_d = has_d ? (share(-vyi) + CO2_SETTLE) : 0.0;
	float keep = 1.0 - (out_e + out_w + out_s + out_n + out_u + out_d);
	float acc = co2_in[g] * max(0.0, keep);

	// Inflow: each neighbour's share TOWARD this cell. The cell ABOVE also settles CO2_SETTLE down into us.
	if (has_e) { acc += co2_in[g + 1u] * share(-vel_x[g + 1u]); }
	if (has_w) { acc += co2_in[g - 1u] * share(vel_x[g - 1u]); }
	if (has_s) { acc += co2_in[g + dx] * share(-vel_z[g + dx]); }
	if (has_n) { acc += co2_in[g - dx] * share(vel_z[g - dx]); }
	if (has_u) { acc += co2_in[g + layer] * (share(-vel_y[g + layer]) + CO2_SETTLE); }
	if (has_d) { acc += co2_in[g - layer] * share(vel_y[g - layer]); }

	co2_out[g] = max(0.0, acc);
}
