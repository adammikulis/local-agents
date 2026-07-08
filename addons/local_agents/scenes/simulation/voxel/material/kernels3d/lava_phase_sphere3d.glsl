#[compute]
#version 450

// CUBED-SPHERE lava PHASE — sphere port of lava_phase3d.glsl (box). Fuses MaterialLava3D._solidify() +
// _sustain_heat() into one PER-CELL pass (both are independent per-cell rules). Runs AFTER lava_flow_sphere3d,
// in place on the post-flow lava + temp buffers:
//   SOLIDIFY: a cell still holding lava but sitting BELOW SOLIDIFY_TEMP freezes to rock (mark solid, zero lava).
//   SUSTAIN: lava that remains is kept molten, scaled by DEPTH (mass), floored at MOLTEN_FLOOR and capped at
//     LAVA_EMPLACE_TEMP via max() so it only ever RAISES temperature.
// This pass has NO neighbour reads (it reads/writes only its own cell), so the sphere port is a structural
// copy: the box grid dims were used ONLY for the cell_count guard, so nothing geometric remaps and no
// neighbour INDEX TABLE is needed. Only change vs the box: the unused dim_x/dim_y/dim_z push fields are
// dropped. Constants copied EXACTLY from MaterialLava3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialLava3D.gd exactly.
const float LAVA_MIN_MASS = 0.0001;
const float SOLIDIFY_TEMP = 800.0;
const float MOLTEN_FLOOR = 950.0;
const float LAVA_EMPLACE_TEMP = 1150.0;
const float EMPLACE_DEPTH = 1.0;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	float d = lava[g];
	if (d < LAVA_MIN_MASS) {
		return;
	}
	if (solid[g] != 0.0) {
		return;
	}
	if (temp[g] < SOLIDIFY_TEMP) {
		// Cooled below the solidus while still holding lava -> it has frozen to rock.
		solid[g] = 1.0;
		lava[g] = 0.0;
		return;
	}
	// SUSTAIN — keep the remaining lava molten, depth-scaled.
	float span = LAVA_EMPLACE_TEMP - MOLTEN_FLOOR;
	float molten = MOLTEN_FLOOR + span * clamp(d / EMPLACE_DEPTH, 0.0, 1.0);
	if (temp[g] < molten) {
		temp[g] = molten;
	}
}
