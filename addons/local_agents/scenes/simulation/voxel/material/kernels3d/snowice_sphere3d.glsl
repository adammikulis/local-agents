#[compute]
#version 450

// CUBED-SPHERE SNOW phase — the sphere port of snowice3d.glsl. The box kernel dispatched one invocation per XZ
// COLUMN, found the column's topmost SOLID (ground) cell and took the OPEN air cell directly above it (giy+1)
// as the surface, accreting precipitation there when cold and melting the pack to meltwater when warm. On the
// sphere there are no columns, so we dispatch PER CELL (like heat_sphere3d, `if (idx >= cell_count) return;`)
// and let each GROUND-SURFACE air cell run the phase in place. The phase math is copied VERBATIM.
//
// SURFACE cell on the sphere: snow must accrete ON THE TERRAIN, not at the top of the atmosphere, so the
// surface here is the exact sphere analogue of the box's giy+1 — the GROUND-RESTING air cell: a cell that is
// OPEN (solid == 0) whose INWARD-radial neighbour (nbr slot 0) is solid ground. (Walking slot 5 outward to the
// outermost open cell — the generic sky surface — would put snow at the top of the atmosphere, which is wrong
// for a snowpack; this is the documented deviation from the generic outermost-open rule, chosen to preserve the
// box's terrain-surface physics.) Meltwater is deposited into that same cell's water (box: water[si]); the water
// CA then carries it inward/downhill on later steps. Each surface cell touches only its own snow[idx]/water[idx]
// → race-free.
//
// Buffer keying: snow depth is PER CELL (snow[idx], sized cell_count), keyed by the ground-surface cell — the
// sphere replacement for the box's per-column depth. The WATER FREEZE/THAW geometry phase (marking cells solid +
// SDF stamps + mask re-upload) stays a capped CPU tail exactly as in the box. Constants copied EXACTLY from
// MaterialSnowIce3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Snow { float snow[]; };          // per-cell depth (cell_count), in place
layout(set = 0, binding = 1, std430) restrict readonly buffer Temp { float temp[]; }; // per-cell
layout(set = 0, binding = 2, std430) restrict buffer Water { float water[]; };        // per-cell (+= meltwater)
layout(set = 0, binding = 3, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };  // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
	float precip;
	float pad3;
	float pad4;
	float pad5;
} params;

// Constants — MUST match MaterialSnowIce3D.gd exactly.
const float SNOW_T = 0.0;
const float MELT_T = 2.0;
const float SNOW_FALL_RATE = 0.03;
const float SNOW_MIN = 0.001;
const float MELT_RATE = 0.02;
const float MELT_MAX_PER_STEP = 0.15;
const float SNOW_WATER_YIELD = 0.3;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.cell_count) {
		return;
	}
	if (solid[idx] != 0.0) {
		return;                                            // rock is not the surface air cell
	}
	// GROUND-SURFACE air cell: open, and its inward-radial neighbour (slot 0) is solid ground.
	int down = nbr[idx * 6u + 0u];
	if (down < 0 || solid[down] == 0.0) {
		return;                                            // no ground directly below -> not a snow surface
	}

	float st = temp[idx];
	float depth = snow[idx];
	float falling = params.precip * SNOW_FALL_RATE;
	if (falling > 0.0 && st < SNOW_T) {
		depth += falling;                                  // cold + precipitating -> precip becomes snowpack
	} else if (st > MELT_T && depth > 0.0) {
		float melted = min(depth, min(MELT_MAX_PER_STEP, (st - MELT_T) * MELT_RATE));
		if (melted > 0.0) {
			depth -= melted;
			water[idx] += melted * SNOW_WATER_YIELD;       // meltwater feeds the river CA at this surface cell
		}
	}
	if (depth < SNOW_MIN) {
		depth = 0.0;
	}
	snow[idx] = depth;
}
