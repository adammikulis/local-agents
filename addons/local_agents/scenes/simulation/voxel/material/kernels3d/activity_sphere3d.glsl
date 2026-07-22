#[compute]
#version 450

// CUBED-SPHERE ACTIVITY-BUBBLE LOD (Keystone C / "Lane B3", first slice). A per-cell wake signal that lets
// gated kernels skip cells with nothing happening: `activity[g]` decays to 0 when quiescent and rises to 1
// when a cell is doing something worth computing OR sits near a cell that is. Runs GATHER-style (every cell
// reads its own prior value + its 6 neighbours' prior values — order-independent, no atomics), matching the
// existing GATHER convention (fire_sphere3d.glsl, atmos kernels) and the ping-pong `nbr` addressing (idx*6 +
// slot; slot 0 = inward/radial-DOWN, 1-4 = LATERAL, 5 = outward/radial-UP; -1 = boundary → skipped).
//
// SELF-SEED (this slice gates FireDustPass only): a cell seeds itself active if it is currently burning, or
// hot/fuelled enough that it could cross the ignition threshold before the gate is next re-evaluated. The
// IGNITE_MARGIN gives headroom so a cell wakes BEFORE it actually needs to ignite, not the step it crosses.
//
// BUBBLE PROPAGATION: `activity_out[g] = max(self_seed, max_over_neighbours(activity_in) - DECAY)`. An active
// cell radiates activity 1.0 → its neighbours see ~1.0-DECAY next step → theirs ~1.0-2*DECAY, etc. — a bubble
// that grows outward at one cell/step and shrinks the moment nothing feeds it, with zero cross-cell writes
// (every cell only ever writes its own output). On a fire-free planet self_seed is 0 everywhere and no
// neighbour ever reports activity > 0, so the buffer stays exactly 0.0 (fully quiescent, the common case).
//
// KNOWN GAP (first slice, follow-up owed): an instantaneous injected event (meteor impact, lava injection)
// that pushes a cold cell straight past IGNITE_TEMP in one step, faster than the bubble can reach it from a
// neighbour, is only caught if IGNITE_MARGIN already covers the jump. Injection call sites (add_lava, impact
// heat) should explicitly wake their target region once this gates more than fire — not done in this slice.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ActivityIn  { float activity_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ActivityOut { float activity_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Fire  { float fire_ch[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Fuel  { float fuel_ch[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Temp  { float temp_ch[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint pad0;
	uint pad1;
	uint pad2;
} params;

// MUST match fire_sphere3d.glsl's FIRE_MIN/FUEL_MIN/IGNITE_TEMP exactly — this is what decides whether a
// cell is "the same as fire_sphere3d.glsl would treat it," not an independent threshold.
const float FIRE_MIN = 0.02;
const float FUEL_MIN = 0.02;
const float IGNITE_TEMP = 450.0;
const float IGNITE_MARGIN = 100.0;   // wake this many degrees before actual ignition — see KNOWN GAP above
const float DECAY = 0.34;            // ~3-cell bubble radius per wake pulse

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}

	float self_seed = 0.0;
	if (fire_ch[g] > FIRE_MIN) {
		self_seed = 1.0;
	} else if (fuel_ch[g] > FUEL_MIN && temp_ch[g] >= (IGNITE_TEMP - IGNITE_MARGIN)) {
		self_seed = 1.0;
	}

	float bubble = 0.0;
	uint base = g * 6u;
	for (int d = 0; d < 6; d++) {
		int n = nbr[base + uint(d)];
		if (n >= 0) {
			bubble = max(bubble, activity_in[n]);
		}
	}
	bubble = max(0.0, bubble - DECAY);

	activity_out[g] = max(self_seed, bubble);
}
