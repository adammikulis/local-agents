#[compute]
#version 450

// GPU 3D OXYGEN — TRANSPORT pass. A race-free GATHER port of LAMaterialGas3D._transport(): each non-solid
// cell keeps its un-emitted fraction, then sums the O₂ shares flowing in from its six OPEN neighbours (a
// symmetric diffusion share + a downwind advection share scaled by the neighbour's wind blowing TOWARD this
// cell). A rock/boundary neighbour donates AND receives nothing (the outflow share drops for that direction),
// so O₂ never crosses stone — this is what emergently SEALS caves. Reads only the OLD o2 snapshot (o2_in) +
// wind + solid, writes o2_out[g], so it is order-independent and mass-aware.
//
// Runs AFTER the fire kernel consumed O₂ in place (fire pass, THEN transport spreads/refills it). The per-
// column SKY EXCHANGE that re-oxygenates each surface cell is a SEPARATE pass (gas_sky3d.glsl), dispatched
// after this one. Constants copied EXACTLY from MaterialGas3D.gd (perf-over-parity: math mirrored, order
// differs from the CPU oracle). Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer O2In  { float o2_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer O2Out { float o2_out[]; };
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
		o2_out[g] = 0.0;
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
	float out_d = has_d ? share(-vyi) : 0.0;
	float keep = 1.0 - (out_e + out_w + out_s + out_n + out_u + out_d);
	float acc = o2_in[g] * keep;

	// Inflow: each neighbour's share flowing TOWARD this cell (its wind toward us + diffusion).
	if (has_e) { acc += o2_in[g + 1u] * share(-vel_x[g + 1u]); }
	if (has_w) { acc += o2_in[g - 1u] * share(vel_x[g - 1u]); }
	if (has_s) { acc += o2_in[g + dx] * share(-vel_z[g + dx]); }
	if (has_n) { acc += o2_in[g - dx] * share(vel_z[g - dx]); }
	if (has_u) { acc += o2_in[g + layer] * share(-vel_y[g + layer]); }
	if (has_d) { acc += o2_in[g - layer] * share(vel_y[g - layer]); }

	o2_out[g] = max(0.0, acc);
}
