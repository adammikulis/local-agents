#[compute]
#version 450

// CUBED-SPHERE MAGMA buoyant overpressure up-flow — the sphere port of magma_buoy3d.glsl. IDENTICAL two-pass
// GATHER logic and IDENTICAL constants/math; only neighbour addressing changes. The box read the cell ABOVE
// via `+layer` (guarded by iy<dim_y-1) and the cell BELOW via `-layer` (iy>0); here both come from the
// precomputed INDEX TABLE `nbr[idx*6 + slot]` — slot 5 = outward/UP (above), slot 0 = inward/DOWN (below);
// -1 = boundary → no flow. Only OVERPRESSURE (mass beyond MAX_MASS) is buoyed; carry-heat rides up with
// received lava, VERBATIM. Constants copied EXACTLY from magma_buoy3d.glsl / MaterialMagma3D.gd.
//   PASS 0 (copy):   scratch[i] = lava[i]  (stable snapshot for the gather).
//   PASS 1 (gather): lava[i] = scratch[i] - buoy_up(scratch[i], above open) + buoy_up(scratch[below], we open).

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

// Constants — MUST match magma_buoy3d.glsl / MaterialMagma3D.gd exactly.
const float MAX_MASS = 1.0;
const float BUOY_FRAC = 0.55;
const float K_P = 0.6;
const float MAX_UP_FLOW = 0.4;
const float MIN_OP = 0.0001;
const float MOLTEN_FLOOR = 950.0;
const float LAVA_EMPLACE_TEMP = 1150.0;

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
	lava[g] = base_mass - out_up + in_below;

	// Molten heat rides up with received lava so the climbing front stays liquid (bounded < MELT_TEMP).
	if (in_below > 0.0 && ib >= 0) {
		float carried = min(temp[uint(ib)], LAVA_EMPLACE_TEMP);
		if (carried < MOLTEN_FLOOR) {
			carried = MOLTEN_FLOOR;
		}
		if (temp[g] < carried) {
			temp[g] = carried;
		}
	}
}
