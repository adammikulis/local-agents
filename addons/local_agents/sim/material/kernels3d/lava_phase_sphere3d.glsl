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
//     face at all) is left ENTIRELY ALONE here — it radiates to nothing, so its only heat loss is conduction
//     into the surrounding rock, which heat_sphere3d.glsl performs conservatively. We only change WHERE/how
//     fast EXPOSED lava sheds heat; we never INJECT heat (the update can only ever lower temperature).
//     *(2026-08-03: the buried case used to cool toward an invented HOT_ROCK_AMBIENT = 780 C with no cell
//     receiving the heat, which DELETED HEAT at every buried lava cell every step. See the constant block.)*
// Neighbour reads use the precomputed INDEX TABLE nbr[idx*6 + d] (slot 0 = inward/down, 1-4 lateral, 5 =
// outward/up; -1 = boundary). Constants copied EXACTLY from MaterialLava3D.gd.

layout(local_size_x = 64) in;

// COMPACTED DISPATCH. This kernel is dispatched INDIRECTLY, with one invocation per ACTIVE cell rather than
// one per grid cell: it reads its cell id out of `active_idx` and its loop bound out of `active_args[3]`, both
// built the same step by cell_list_lava_sphere3d.glsl. That kernel evaluates, verbatim, the two
// side-effect-free early-outs this one used to open with (lava < LAVA_MIN_MASS, solid != 0), which is why they
// are gone from below. The predicate is PHYSICAL — "this cell holds molten rock in open space" — so the list
// is the same at any camera position.
//
// THE WRITER SET IS UNCHANGED, which is the honest claim — not "bit-identical". The shell-first cooling
// loop below READS neighbours (lava[nb], temp[nb], solid[nb]) while other threads write temp[g] to the
// same buffer, so this kernel's output was never bit-reproducible and compaction changes which threads
// are co-resident. That race is pre-existing and the distribution is unaffected because exactly the same
// cells write exactly the same values; what compaction cannot do is introduce NEW nondeterminism.
layout(set = 0, binding = 0, std430) restrict buffer Lava { float lava[]; };
layout(set = 0, binding = 1, std430) restrict buffer Temp { float temp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Solid { float solid[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer ActiveIdx { uint active_idx[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer ActiveArgs { uint active_args[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };   // idx*6 + slot

layout(push_constant, std430) uniform Params {
	uint cell_count;   // only a defensive bound on the id read out of active_idx
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
// HOT_ROCK_AMBIENT = 780.0 used to live here — the temperature a fully buried lava cell was cooled toward.
// Deleted 2026-08-03: it was a prescribed target with no cell on the receiving end, so it DELETED HEAT every
// step. A buried cell now cools only by conduction, in heat_sphere3d.glsl, which gives the heat to the rock.

void main() {
	// One invocation per ACTIVE cell. `active_args[3]` is the compacted list length; the trailing invocations
	// of the last workgroup (and the single idle group dispatched when the list is empty) fall out here.
	uint t = gl_GlobalInvocationID.x;
	if (t >= active_args[3]) {
		return;
	}
	uint g = active_idx[t];
	if (g >= params.cell_count) {
		return;                     // defensive: a corrupt list must not scribble outside the grid
	}
	// lava >= LAVA_MIN_MASS and solid == 0 were both applied by cell_list_lava_sphere3d.glsl when it appended
	// this cell, so a listed cell has already passed them.
	float d = lava[g];
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

	// A CELL BURIED IN ROCK DOES NOT COOL HERE AT ALL. It has no open face, so it radiates to nothing; the only
	// way its heat leaves is by CONDUCTION into the rock around it, and heat_sphere3d.glsl already does that
	// with the real thermal conductivities — conserving, because the rock it warms gains exactly what the lava
	// loses.
	//
	// WHAT THIS REPLACES: a buried cell used to be cooled toward HOT_ROCK_AMBIENT = 780 C, a temperature
	// invented so that "a truly-sealed pocket still eventually freezes (no immortal heat source) but SLOWLY".
	// Nothing anywhere received that heat, so THIS DELETED HEAT, every step, at every buried lava cell. It was
	// also doing conduction's job badly: a sealed pocket's real fate depends on the rock around it, which the
	// thermal kernel knows and this one does not. Deleting the target does not make the pocket immortal — it
	// hands it to the kernel that can cool it honestly.
	if (open_faces == 0) {
		return;
	}
	// An EXPOSED cell does radiate: its open faces see air and sky, and that outgoing radiation is a genuine
	// loss from the planet's surface energy budget, which is why this leg stays. Newtonian cool toward the air
	// ambient, its rate scaled UP by exposed-face count (shell-first). A deep pool (large d) retains heat longer
	// than a thin crust; a live vent re-heats via re-emplacement, so the active vent stays molten while a
	// stranded flow's rind hardens first.
	float cool_k = LAVA_COOL_RATE * clamp(EMPLACE_DEPTH / d, 0.25, 3.0) * (1.0 + EXPOSURE_GAIN * float(exposed));
	// Update can ONLY ever lower temperature; clamp at the ambient floor when cooling.
	float cooled = max(LAVA_AMBIENT, temp[g] - cool_k * (temp[g] - LAVA_AMBIENT));
	temp[g] = min(temp[g], cooled);
}
