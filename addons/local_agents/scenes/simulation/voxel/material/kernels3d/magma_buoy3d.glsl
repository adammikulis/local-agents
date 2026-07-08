#[compute]
#version 450

// GPU 3D MAGMA buoyant overpressure up-flow — a race-free two-pass GATHER port of MaterialMagma3D._buoy_flow()
// (the deep driver that pushes over-pressured lava UP its rock-walled conduit, beyond the lava CA's own
// overflow, so a fed column climbs + stays full/hot as it rises). Runs AFTER the lava flow+phase passes, on
// the resident lava[back] + temp[back]:
//   PASS 0 (copy):   scratch[i] = lava[i]  (stable snapshot for the gather).
//   PASS 1 (gather): new lava[i] = scratch[i] - buoy_up(scratch[i], above open) + buoy_up(scratch[below], we open),
//                    and molten heat rides UP with received lava (floored to MOLTEN_FLOOR, capped at
//                    LAVA_EMPLACE_TEMP < MELT_TEMP so carried heat alone never melts rock).
// Only the OVERPRESSURE (mass beyond MAX_MASS) is buoyed. The DIRECTIONAL-UP PRESSURE-MELT (rock roof bored
// open + SDF carve + solid-mask edit) and the deep-source feed/seed stay a capped CPU tail
// (MaterialMagma3D.step_scene_only). Constants copied EXACTLY from MaterialMagma3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };       // lava[back] (rw)
layout(set = 0, binding = 1, std430) restrict buffer Scratch { float scratch[]; }; // stable snapshot
layout(set = 0, binding = 2, std430) restrict buffer Temp { float temp[]; };       // temp[back] (carry-heat)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
	uint pass_id;   // 0 = copy snapshot, 1 = gather/apply
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialMagma3D.gd exactly.
const float MAX_MASS = 1.0;
const float BUOY_FRAC = 0.55;
const float K_P = 0.6;
const float MAX_UP_FLOW = 0.4;
const float MIN_OP = 0.0001;
const float MOLTEN_FLOOR = 950.0;
const float LAVA_EMPLACE_TEMP = 1150.0;

// Buoyant up-transfer a cell contributes given its lava mass: only the OVERPRESSURE (mass beyond MAX_MASS) is
// buoyed, scaled by (BUOY_FRAC + K_P*op), capped at both `op` and MAX_UP_FLOW. Mirrors _buoy_up exactly.
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
	int dim_x = int(params.dim_x);
	int dim_y = int(params.dim_y);
	int dim_z = int(params.dim_z);
	int layer = dim_x * dim_z;
	int idx = int(g);
	int iy = idx / layer;

	if (params.pass_id == 0u) {
		scratch[g] = lava[g];
		return;
	}

	// PASS 1: gather. Solid cells hold no lava — pass the snapshot through unchanged.
	if (solid[g] != 0.0) {
		lava[g] = scratch[g];
		return;
	}
	float base = scratch[g];
	float out_up = 0.0;
	float in_below = 0.0;
	if (iy < dim_y - 1) {
		int iu = idx + layer;
		if (solid[iu] == 0.0) {
			out_up = buoy_up(scratch[g]);
		}
	}
	if (iy > 0) {
		int ib = idx - layer;
		if (solid[ib] == 0.0) {
			in_below = buoy_up(scratch[ib]);
		}
	}
	lava[g] = base - out_up + in_below;

	// Molten heat rides up with received lava so the climbing front stays liquid (bounded < MELT_TEMP).
	if (in_below > 0.0 && iy > 0) {
		int src = idx - layer;
		float carried = min(temp[src], LAVA_EMPLACE_TEMP);
		if (carried < MOLTEN_FLOOR) {
			carried = MOLTEN_FLOOR;
		}
		if (temp[g] < carried) {
			temp[g] = carried;
		}
	}
}
