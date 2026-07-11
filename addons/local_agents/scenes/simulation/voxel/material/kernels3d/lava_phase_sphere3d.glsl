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
// Radiative cooling of exposed molten rock toward the air/surface ambient. This is the FIX for the thermal
// runaway: the old unconditional re-pin to MOLTEN_FLOOR made subaerial lava an IMMORTAL heat source (never
// cooled below the 800C solidus, never solidified, conducted heat into the crust forever -> the planet baked).
// Now lava sheds heat each step, so a flow that is no longer SUPPLIED crosses the solidus and the M5 record
// freezes it to rock (a FINITE source that also BUILDS land above sea). A fresh vent re-emplaces at 1150C each
// step so the active vent stays molten; a thin crust cools faster than a deep pool.
const float LAVA_AMBIENT = 40.0;
const float LAVA_COOL_RATE = 0.05;

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
	// COOL toward the ambient each step (Newtonian) instead of re-pinning to a molten floor, so lava that stops
	// being supplied loses heat and eventually crosses the 800C solidus (then the M5 record freezes it to rock).
	// A deep pool (large d) retains heat longer than a thin crust; a live vent re-heats its cell to 1150C each
	// step via re-emplacement, so the active vent stays molten while stranded flows harden -> a FINITE heat source.
	float cool_k = LAVA_COOL_RATE * clamp(EMPLACE_DEPTH / d, 0.25, 3.0);
	temp[g] = max(LAVA_AMBIENT, temp[g] - cool_k * (temp[g] - LAVA_AMBIENT));
}
