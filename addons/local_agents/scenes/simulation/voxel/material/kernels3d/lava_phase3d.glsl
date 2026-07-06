#[compute]
#version 450

// GPU 3D lava PHASE — ports MaterialLava3D._solidify() + _sustain_heat(), fused into one per-cell pass
// (both are independent per-cell rules; the CPU runs solidify then sustain). Runs AFTER lava_flow3d, in
// place on the post-flow lava + temp buffers:
//   SOLIDIFY: a cell still holding lava but sitting BELOW SOLIDIFY_TEMP (nothing kept it hot — a crusting
//     fringe, a quenched tongue, a force-cooled cell) freezes to rock: mark solid, zero its lava.
//   SUSTAIN: lava that remains is kept molten, scaled by DEPTH (thicker lava stays hotter), floored at
//     MOLTEN_FLOOR and capped at LAVA_EMPLACE_TEMP — via max() so it only ever RAISES temperature.
// NOTE vs the CPU oracle: the oracle CAPS solidify to SOLIDIFY_MAX_EDITS cells/step (cursor-rotated) only
// to bound its per-cell SDF terrain stamps; that stamp is a CPU/terrain concern, so this GPU pass has no
// such cap (it freezes every eligible cell at once). MELT (rock super-heated past MELT_TEMP -> lava) is
// terrain-SDF driven and stays on the CPU. Constants copied EXACTLY from MaterialLava3D.gd.
//
// Index layout: idx = (iy*dim_z + iz)*dim_x + ix.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };

layout(push_constant, std430) uniform Params {
	uint dim_x;
	uint dim_y;
	uint dim_z;
	uint cell_count;
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
