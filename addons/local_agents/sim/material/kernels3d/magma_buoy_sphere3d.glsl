#[compute]
#version 450

// precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 5 = outward/UP (above), slot 0 = inward/DOWN (below);

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };       // lava[back] (rw)
layout(set = 0, binding = 1, std430) restrict buffer Scratch { float scratch[]; }; // stable snapshot
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };       // temp[back] (carry-heat)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pass_id;   // 0 = copy snapshot, 1 = gather/apply
	uint pad0;
	uint pad1;
} params;

// The substrate's cell-fill unit — authority LAMaterialField3D (MaterialField3D.gd:26). That file exists.
const float MAX_MASS = 1.0;

// --- MODEL PARAMETERS. Properties of THIS kernel's overpressure rule; this file is their only declaration.
// DENSE than the rock around it, and that density contrast is measurable — basaltic melt is 2600-2800 kg/m^3
const float BUOY_FRAC = 0.55;
const float K_P = 0.6;
const float MAX_UP_FLOW = 0.4;
const float MIN_OP = 0.0001;
// This kernel prescribes and caps no temperature: it mixes the arriving enthalpy with the destination's own.

// Buoyant up-transfer a cell contributes given its lava mass — mirrors _buoy_up exactly.
float buoy_up(float mass) {
	float op = mass - MAX_MASS;
	if (op < MIN_OP) {
		return 0.0;
	}
	float flow = op * (BUOY_FRAC + K_P * op);
	return clamp(flow, 0.0, min(MAX_UP_FLOW, op));
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	uint base = g * 6u;

	if (params.pass_id == 0u) {
		scratch[g] = lava[g];
		return;
	}

	// PASS 1: gather. Solid cells hold no lava — pass the snapshot through unchanged.
	if (solid[g] != 0.0) {
		lava[g] = scratch[g];
		return;
	}
	float base_mass = scratch[g];
	float out_up = 0.0;
	float in_below = 0.0;

	// UP (radially outward = slot 5): overpressure we shed into the open cell above.
	int iu = nbr[base + 5u];
	if (iu >= 0 && solid[iu] == 0.0) {
		out_up = buoy_up(scratch[g]);
	}
	// DOWN (radially inward = slot 0): overpressure the open cell below buoys up into us.
	int ib = nbr[base + 0u];
	if (ib >= 0 && solid[ib] == 0.0) {
		in_below = buoy_up(scratch[uint(ib)]);
	}
	float kept = base_mass - out_up;
	float total = kept + in_below;
	lava[g] = total;

	// Mass-weighted enthalpy mix against the RETAINED mass, the same form as gravity_flow_sphere3d.glsl:167.
	// It weighted this cell's own heat by the constant MAX_MASS instead. buoy_up only fires on overpressure, so
	// `kept` is >= MAX_MASS in every cell this runs on and the constant always under-weighted the destination:
	// arriving magma dominated the mix by more than its mass, creating heat on every buoyant transfer.
	if (in_below > 0.0 && ib >= 0 && total > 0.0) {
		temp[g] = (kept * temp[g] + in_below * temp[uint(ib)]) / total;
	}
}
