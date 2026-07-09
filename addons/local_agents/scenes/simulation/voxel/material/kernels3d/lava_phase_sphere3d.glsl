#[compute]
#version 450

// CUBED-SPHERE lava PHASE — SUSTAIN only. Runs AFTER lava_flow_sphere3d, in place on the post-flow lava + temp
// buffers. Rock unification Stage B DISSOLVED the SOLIDIFY leg into the M5 DEFS reaction record (cold lava ->
// rock_fill, a conserving own-cell transfer), so this kernel no longer writes `solid` (which is now DERIVED from
// rock_fill by solid_derive_sphere3d.glsl) and no longer zeroes lava. It keeps ONLY:
//   SUSTAIN: lava that remains is kept molten, scaled by DEPTH (mass), floored at MOLTEN_FLOOR and capped at
//     LAVA_EMPLACE_TEMP via max() so it only ever RAISES temperature — EXCEPT it now LEAVES a sub-solidus cell
//     (temp < SOLIDIFY_TEMP) cold instead of re-heating it, so the M5 record (which reads the post-thermal temp
//     downstream in ReactionsPass) sees the genuine cold and can freeze the lava to rock. Without this guard the
//     sustain floor (>= MOLTEN_FLOOR) would keep every lava cell hot and M5 could never fire.
// This pass has NO neighbour reads (own cell only). Constants copied EXACTLY from MaterialLava3D.gd.

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
		// Cooled below the solidus: leave it cold (do NOT sustain) so the M5 solidify record freezes the
		// lava to rock_fill downstream. (Was: solid=1; lava=0 — dissolved into the conserving M5 record.)
		return;
	}
	// SUSTAIN — keep the remaining lava molten, depth-scaled.
	float span = LAVA_EMPLACE_TEMP - MOLTEN_FLOOR;
	float molten = MOLTEN_FLOOR + span * clamp(d / EMPLACE_DEPTH, 0.0, 1.0);
	if (temp[g] < molten) {
		temp[g] = molten;
	}
}
