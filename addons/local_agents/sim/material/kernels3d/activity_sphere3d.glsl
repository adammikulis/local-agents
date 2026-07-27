#[compute]
#version 450

// CUBED-SPHERE RELEVANCE (Keystone C / "Lane B3"). A per-cell 0..1 relevance signal that lets gated kernels
// throttle their own update rate: relevance decays smoothly toward 0 when nothing local is happening and the
// camera is far away, and rises toward 1 when a cell is doing something worth computing OR sits near the
// viewer OR near a cell that is. There is NO binary "active/inactive" cutoff anywhere downstream — every gated
// kernel converts this same continuous relevance into a continuous update STRIDE (LALodStride.stride_for's
// GLSL mirror, duplicated per gated kernel — see fire_sphere3d.glsl for the canonical worked example), so the
// whole system reads as one smooth gradient of compute, never a hard-edged region.
//
// TWO INDEPENDENT SOURCES, composed by max() (either is sufficient, neither depends on the other):
//   1. ACTIVITY BUBBLE — runs GATHER-style (every cell reads its own prior value + its 6 neighbours' prior
//      values — order-independent, no atomics), matching the existing GATHER convention (fire_sphere3d.glsl,
//      atmos kernels) and the ping-pong `nbr` addressing (idx*6 + slot; slot 0 = inward/radial-DOWN, 1-4 =
//      LATERAL, 5 = outward/radial-UP; -1 = boundary -> skipped). A cell SELF-SEEDS if it is (or is about to
//      become) non-trivial work for one of the gated kernels — see SELF-SEED below — then radiates that as a
//      decaying bubble: `bubble = max_over_neighbours(activity_in) - DECAY`, so an active cell's neighbours see
//      ~1.0-DECAY next step, theirs ~1.0-2*DECAY, etc. On a fully quiescent planet self_seed is 0 everywhere and
//      no neighbour ever reports activity > 0, so the buffer stays exactly 0.0 (the common case, zero extra work).
//   2. CAMERA PROXIMITY — a smooth, non-propagated, purely-geometric falloff of distance from the current
//      camera to the cell's own world position (LALodStride.relevance_from_distance's GLSL mirror below): the
//      field's half of the same "active OR near the viewer" relevance principle Creature.gd's distance-LOD
//      already applies. Computed fresh every step directly from `pos` + the camera-position push-constant —
//      it needs no propagation (already continuous everywhere by construction), so it feeds SELF-SEED
//      directly rather than the bubble, and is exactly correct for THIS cell even though `bubble` (built from
//      last step's ping-ponged values) would under-represent it by one step's DECAY if it were routed through
//      the bubble instead. No camera (headless run) -> camera_pos arrives as +INF, which the falloff formula
//      naturally resolves to 0 (no special-case branch needed).
//
// SELF-SEED (per gated kernel — only the self_seed inputs change per pass; the union below covers every
// kernel gated so far): fire/fuel/temp (fire_sphere3d.glsl's own combustion state); flowing water over an
// erodible bed (erosion_pickup_sphere3d.glsl's own scour predicate, ocean-excluded via `static`); wet
// regolith / infiltrating surface water (soil_sphere3d.glsl's own aquifer predicate); a molten cell
// (lava_phase_sphere3d.glsl); an updraft carrying moisture below freezing (charge_accum_sphere3d.glsl's own
// storm-driver predicate); airborne dust (dust_outscale/dust_transport_sphere3d.glsl — needed as its own term
// since dust drifts outside every other predicate's decay radius; without it a stride gate would freeze
// ambient dust mid-air instead of letting it settle). Each predicate is a cheap, deliberately loose
// OVER-approximation of its kernel's real activity test (same margin-of-safety spirit as fire's
// IGNITE_MARGIN) — better to keep a borderline cell awake a little longer than to miss real activity.
//
// KNOWN GAP (inherited from the first slice, still owed): an instantaneous injected event (meteor impact,
// lava injection) that pushes a cold cell straight past a self-seed threshold in one step, faster than the
// bubble can reach it from a neighbour, is only caught if that predicate's margin already covers the jump.
// Injection call sites (add_lava, add_heat, impact heat) should explicitly wake their target region as gated
// kernels multiply — not done in this slice.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ActivityIn  { float activity_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer ActivityOut { float activity_out[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Fire  { float fire_ch[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Fuel  { float fuel_ch[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Temp  { float temp_ch[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Static { float static_ch[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Water { float water_ch[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer RockFill { float rock_fill_ch[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Soil { float soil_ch[]; };
layout(set = 0, binding = 9, std430) restrict readonly buffer Regolith { float regolith_ch[]; };
layout(set = 0, binding = 10, std430) restrict readonly buffer Lava { float lava_ch[]; };
layout(set = 0, binding = 11, std430) restrict readonly buffer VelY { float vel_y_ch[]; };
layout(set = 0, binding = 12, std430) restrict readonly buffer Moisture { float moisture_ch[]; };
layout(set = 0, binding = 13, std430) restrict readonly buffer Dust { float dust_ch[]; };
layout(set = 0, binding = 14, std430) restrict readonly buffer Pos { float pos_ch[]; };   // per-cell world position, flat c*3+{0,1,2}
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };      // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint step_index;         // monotonic field-step counter (unused here; ActivityPass only WRITES relevance,
	                          // the gated kernels are what read it back for their own should_run test)
	uint force_full_rate;    // LA_NO_ACTIVITY_LOD bypass: nonzero -> relevance=1.0 everywhere
	uint pad2;
	float camera_x;          // world-space camera position, field-local frame (+INF on all 3 axes = no camera)
	float camera_y;
	float camera_z;
	float camera_characteristic_distance;   // distance at which camera relevance has fallen to 0.5
} params;

// MUST match fire_sphere3d.glsl's FIRE_MIN/FUEL_MIN/IGNITE_TEMP exactly — this is what decides whether a
// cell is "the same as fire_sphere3d.glsl would treat it," not an independent threshold.
const float FIRE_MIN = 0.02;
const float FUEL_MIN = 0.02;
const float IGNITE_TEMP = 450.0;
const float IGNITE_MARGIN = 100.0;   // wake this many degrees before actual ignition — see KNOWN GAP above
// MUST match erosion_pickup_sphere3d.glsl's WATER_MIN/ROCK_MIN exactly.
const float EROSION_WATER_MIN = 0.02;
const float EROSION_ROCK_MIN = 1.0e-4;
// MUST match soil_sphere3d.glsl's MIN_W exactly (soil's own "s <= 0.0" is reproduced literally, no epsilon).
const float SOIL_WATER_MIN = 0.002;
// MUST match lava_phase_sphere3d.glsl's LAVA_MIN_MASS exactly.
const float LAVA_MIN_MASS = 0.0001;
// MUST match charge_accum_sphere3d.glsl's own storm-driver predicate exactly.
const float CHARGE_FREEZE_T = 13.0;
// No existing kernel names a dust epsilon; picked as a small fraction consistent with the other MIN constants.
const float DUST_MIN = 0.001;
const float DECAY = 0.34;            // ~3-cell bubble radius per wake pulse

// GLSL mirror of LALodStride.relevance_from_distance (runtime/LALodStride.gd) -- MUST match exactly. Smooth
// 0..1 relevance: 1 at distance 0, asymptotically -> 0 as distance grows, no hard cutoff.
float relevance_from_distance(float distance_, float characteristic_distance) {
	return characteristic_distance / (characteristic_distance + max(distance_, 0.0));
}

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	if (params.force_full_rate != 0u) {
		activity_out[g] = 1.0;
		return;
	}

	uint base = g * 6u;
	int down = nbr[base + 0u];

	float self_seed = 0.0;
	if (fire_ch[g] > FIRE_MIN) {
		self_seed = 1.0;
	} else if (fuel_ch[g] > FUEL_MIN && temp_ch[g] >= (IGNITE_TEMP - IGNITE_MARGIN)) {
		self_seed = 1.0;
	}

	// EROSION: flowing water over an erodible bed, ocean-excluded (mirrors erosion_pickup_sphere3d.glsl's own
	// static-sea guard — without it the predicate would self-seed the entire seafloor).
	if (self_seed < 1.0 && static_ch[g] == 0.0 && water_ch[g] > EROSION_WATER_MIN
			&& down >= 0 && rock_fill_ch[uint(down)] > EROSION_ROCK_MIN) {
		self_seed = 1.0;
	}

	// SOIL: a wet regolith cell, or a dry-land cell infiltrating surface water into regolith below it.
	if (self_seed < 1.0 && static_ch[g] == 0.0) {
		if (regolith_ch[g] != 0.0 && soil_ch[g] > 0.0) {
			self_seed = 1.0;
		} else if (down >= 0 && regolith_ch[uint(down)] != 0.0 && water_ch[g] > SOIL_WATER_MIN) {
			self_seed = 1.0;
		}
	}

	// LAVA: any cell still carrying molten mass.
	if (self_seed < 1.0 && lava_ch[g] >= LAVA_MIN_MASS) {
		self_seed = 1.0;
	}

	// STORM CHARGE: an updraft carrying moisture below freezing (the charge_accum build predicate).
	if (self_seed < 1.0 && vel_y_ch[g] > 0.0 && moisture_ch[g] > 0.0 && temp_ch[g] < CHARGE_FREEZE_T) {
		self_seed = 1.0;
	}

	// DUST: airborne dust drifts outside every other predicate's decay radius and needs its own term or a
	// stride gate would freeze it mid-air instead of letting it settle.
	if (self_seed < 1.0 && dust_ch[g] > DUST_MIN) {
		self_seed = 1.0;
	}

	// CAMERA PROXIMITY: fresh per-cell geometric falloff, not propagated (already continuous everywhere).
	if (self_seed < 1.0) {
		vec3 cell_pos = vec3(pos_ch[g * 3u], pos_ch[g * 3u + 1u], pos_ch[g * 3u + 2u]);
		vec3 cam_pos = vec3(params.camera_x, params.camera_y, params.camera_z);
		float d = distance(cell_pos, cam_pos);
		float cam_relevance = relevance_from_distance(d, params.camera_characteristic_distance);
		self_seed = max(self_seed, cam_relevance);
	}

	float bubble = 0.0;
	for (int d = 0; d < 6; d++) {
		int n = nbr[base + uint(d)];
		if (n >= 0) {
			bubble = max(bubble, activity_in[n]);
		}
	}
	bubble = max(0.0, bubble - DECAY);

	activity_out[g] = max(self_seed, bubble);
}
