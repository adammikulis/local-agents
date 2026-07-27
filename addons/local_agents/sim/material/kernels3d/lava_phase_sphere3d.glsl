#[compute]
#version 450

// CUBED-SPHERE lava PHASE — SUSTAIN + SHELL-FIRST edge cooling. Runs AFTER lava_flow_sphere3d, in place on the
// post-flow lava + temp buffers. Rock unification Stage B DISSOLVED the SOLIDIFY leg into the M5 DEFS reaction
// record (cold lava -> rock_fill, a conserving own-cell transfer), so this kernel does NOT write `solid` (now
// DERIVED from rock_fill by solid_derive_sphere3d.glsl) and does NOT zero lava. It keeps:
//   SUSTAIN: lava that remains >= SOLIDIFY_TEMP is kept molten (it sheds heat; a sub-solidus cell is LEFT cold
//     so the downstream M5 record freezes it to rock — without a temp floor the M5 record can fire).
//   SHELL-FIRST COOLING (the LAVA-TUBE piece): lava does NOT cool uniformly. A cell sheds heat at a rate that
//     scales with how many of its 6 faces are EXPOSED to open air/void (or a cold neighbour). A flow's outer
//     RIND (top + sides open to air = many exposed faces) crosses SOLIDIFY_TEMP fast and M5 freezes it to a
//     thin rock SHELL, while an INTERIOR cell (surrounded by hot lava = zero exposed faces) stays > 800 and
//     molten — so the core stays liquid long enough to DRAIN downhill (lava_flow drains into non-solid cells),
//     leaving a hollow inside the solidified flow: a LAVA TUBE. A cell fully enclosed by SOLID rock (no open
//     face at all) cools toward a HOT geothermal ambient instead of the cold air ambient, so a buried core does
//     not flash-freeze — it stays molten until it drains (or, if truly sealed, freezes only slowly). We only
//     change WHERE/how fast lava sheds heat; we never INJECT heat (the update can only ever lower temperature).
// Neighbour reads use the precomputed INDEX TABLE nbr[idx*6 + d] (slot 0 = inward/down, 1-4 lateral, 5 =
// outward/up; -1 = boundary). Constants copied EXACTLY from MaterialLava3D.gd.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Relevance { float relevance[]; };  // Keystone C
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint step_index;   // monotonic field-step counter, for the relevance-gated update stride
	uint pad1;
	uint pad2;
} params;

// Constants — MUST match MaterialLava3D.gd exactly.
const float LAVA_MIN_MASS = 0.0001;
const float SOLIDIFY_TEMP = 800.0;
const float MOLTEN_FLOOR = 950.0;
const float LAVA_EMPLACE_TEMP = 1150.0;
const float EMPLACE_DEPTH = 1.0;
// Radiative cooling of exposed molten rock toward the air/surface ambient. Lava sheds heat each step so a flow
// that is no longer SUPPLIED crosses the solidus and the M5 record freezes it to rock (a FINITE source that
// also BUILDS land above sea). A fresh vent re-emplaces at 1150C each step so the active vent stays molten.
const float LAVA_AMBIENT = 40.0;
const float LAVA_COOL_RATE = 0.05;
// SHELL-FIRST tuning (the lava-tube physics). EXPOSURE_GAIN scales the Newtonian cool rate UP by exposed-face
// count: a rind cell (up to ~5 exposed faces) cools ~(1 + 5*gain)x faster than an interior cell (0 exposed),
// so the outer skin freezes to a shell while the core stays molten and drains. HOT_ROCK_AMBIENT is the
// geothermal target a FULLY BURIED lava cell (no open face) cools toward — set just under the solidus so a
// truly-sealed pocket still eventually freezes (no immortal heat source) but SLOWLY (base rate), giving a
// buried core time to drain before it hardens.
const float EXPOSURE_GAIN = 1.0;
const float HOT_ROCK_AMBIENT = 780.0;

// GLSL mirror of LALodStride.stride_for/should_run (runtime/LALodStride.gd) -- MUST match exactly.
int stride_for(float rel, int max_stride, int base_stride) {
	float r = max(rel, float(base_stride) / float(max_stride));
	return clamp(int(round(float(base_stride) / r)), base_stride, max_stride);
}
bool should_run(uint tick, uint phase, int stride) {
	return (tick + phase) % uint(stride) == 0u;
}
const int MAX_STRIDE = 16;

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
	// RELEVANCE-GATED (Keystone C): a true no-op skip is safe here — this kernel has no neighbour reads, so
	// leaving lava/temp untouched on a skipped step is exactly what the ungated kernel would produce for a
	// cell that hasn't crossed the (own-cell-only) sustain/solidify tests since its last real run.
	int stride = stride_for(relevance[g], MAX_STRIDE, 1);
	if (!should_run(params.step_index, g, stride)) {
		return;
	}
	if (temp[g] < SOLIDIFY_TEMP) {
		// Cooled below the solidus: leave it cold (do NOT sustain) so the M5 solidify record freezes the
		// lava to rock_fill downstream.
		return;
	}

	// Classify this lava cell's 6 faces: an EXPOSED face borders open air/void or a cold neighbour (sheds heat
	// fast); a face touching hot lava is interior (no shedding); a face touching SOLID rock is buried/insulating.
	uint base = g * 6u;
	int exposed = 0;
	int open_faces = 0;
	for (int i = 0; i < 6; i++) {
		int nb = nbr[base + uint(i)];
		if (nb < 0) {
			// Domain boundary (space / air): treat as an exposed, open face — radiates freely.
			exposed += 1;
			open_faces += 1;
			continue;
		}
		if (solid[nb] != 0.0) {
			// Rock neighbour: buried face, insulating — neither exposed nor open.
			continue;
		}
		open_faces += 1;
		// Open neighbour: hot lava = interior (no shedding); cold/void = an exposed surface.
		bool hot_lava = (lava[nb] >= LAVA_MIN_MASS) && (temp[nb] >= SOLIDIFY_TEMP);
		if (!hot_lava) {
			exposed += 1;
		}
	}

	// A cell with NO open face at all is buried in solid rock: cool toward the hot geothermal ambient (stays
	// molten to drain), NOT the cold air ambient. Otherwise cool toward the air ambient, radiating.
	float ambient = (open_faces == 0) ? HOT_ROCK_AMBIENT : LAVA_AMBIENT;
	// Newtonian cool, its rate scaled UP by exposed-face count (shell-first). A deep pool (large d) retains heat
	// longer than a thin crust; a live vent re-heats to 1150C via re-emplacement, so the active vent stays molten
	// while a stranded flow's rind hardens first.
	float cool_k = LAVA_COOL_RATE * clamp(EMPLACE_DEPTH / d, 0.25, 3.0) * (1.0 + EXPOSURE_GAIN * float(exposed));
	// Update can ONLY ever lower temperature (min with the current value guards against injecting heat when the
	// buried ambient sits above the cell's temperature); clamp at the ambient floor when cooling.
	float cooled = max(ambient, temp[g] - cool_k * (temp[g] - ambient));
	temp[g] = min(temp[g], cooled);
}
