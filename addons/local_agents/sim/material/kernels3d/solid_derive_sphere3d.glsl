#[compute]
#version 450

// CUBED-SPHERE SOLID DERIVE (rock unification Stage B). `solid` is no longer an independent source of truth
// seeded once from the SDF and never updated — it is a cheap per-cell DERIVED CACHE of the authoritative
// fractional mineral channel `rock_fill`: a cell is bedrock iff it holds at least half a cell of rock mass.
//   solid[g] = (rock_fill[g] >= SOLID_THRESHOLD) ? 1.0 : 0.0
// This runs FIRST every step (before any pass reads `solid`), so all ~10 downstream kernels that gate on
// `solid == 0.0` (water/lava flow, slump, dust/gas transport, thermal, atmos, reactions, …) see the current
// derived value without any change to their code. When nothing melts/solidifies, rock_fill stays exactly the
// seeded {0.0, 1.0} mask, so this reproduces the old `solid` mask bit-for-bit and the sim is unchanged.
// When lava solidifies (M5 record: lava -> rock_fill) rock_fill crosses 0.5 UP → the cell becomes solid; when
// rock melts (M6 record / add_lava: rock_fill -> lava) it crosses DOWN → the cell opens. The 0.5 crossing is
// exactly what Stage C will stamp into the SDF mesh; this kernel exposes it as the `solid` flag today.

layout(local_size_x = 64) in;

// --- WHAT HAPPENS TO THE LOOSE MATERIAL WHEN A CELL TURNS TO ROCK ------------------------------------------
// Every downstream kernel skips solid cells, so anything still sitting in a cell at the moment it crosses the
// threshold stops being simulated — forever, or until the cell melts back open. For the mineral phases that
// was most of `susp`: suspended sediment sealed inside new rock, conserved in the ledger but permanently out
// of the cycle. Matter that can never move again is not really conserved in any sense that matters.
//
// The physical answer is that it does not get sealed BESIDE the rock, it BECOMES the rock. Sediment buried and
// cemented is lithification; suspended load trapped in a solidifying flow is part of the flow. So a cell that
// is solid folds its loose mineral phases into `rock_fill` — the same conserved mineral substance, one phase
// transfer, exactly the way M5 already turns lava into bedrock. Airborne DUST goes with them: rock closing
// around a dust-laden void entombs the dust identically.
//
// WATER IS A LOOSE PHASE TOO, and it was the larger half of the same defect. A cell that closes over standing
// water, snow or humid air takes all of it out of the H2O cycle: the mass stays in the buffer (the ledger's
// `all` total is exactly flat) but no kernel touches a solid cell, so it never moves again. Measured on this
// planet at 873 units out of 5331 by field step 154 — one unit in six of the world's water, sealed in rock.
//
// What really happens when sediment or lava closes around water is that it becomes PORE WATER: connate water
// in a fresh clastic deposit, or the groundwater of a young volcanic aquifer, which are among the most
// permeable rocks there are. So the water phases fold into `soil`, the cell is marked REGOLITH — it is now
// water-bearing rock, which is exactly what `regolith` means — and it gets a coarse grain size, because a
// fresh deposit is unconsolidated. From the next step the aquifer kernel simulates it like any other aquifer
// cell, so the water can flow, seep and daylight again instead of being gone.
//
// This runs FIRST every step (before any pass reads `solid`), so the fold happens on the same step the cell
// closes and no other kernel ever sees the orphaned mass.
layout(set = 0, binding = 0, std430) restrict buffer RockFill { float rock_fill[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Solid { float solid[]; };
layout(set = 0, binding = 2, std430) restrict buffer Sediment { float sediment[]; };
layout(set = 0, binding = 3, std430) restrict buffer Susp { float susp[]; };
layout(set = 0, binding = 4, std430) restrict buffer Dust { float dust[]; };
layout(set = 0, binding = 5, std430) restrict buffer Water { float water[]; };
layout(set = 0, binding = 6, std430) restrict buffer Moisture { float moisture[]; };
layout(set = 0, binding = 7, std430) restrict buffer Snow { float snow[]; };
layout(set = 0, binding = 8, std430) restrict buffer Soil { float soil[]; };
layout(set = 0, binding = 9, std430) restrict buffer Regolith { float regolith[]; };
layout(set = 0, binding = 10, std430) restrict buffer Grain { float grain[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float fresh_grain_m;   // grain diameter given to newly-closed rock — LAPhysical.GRAIN_D_LOWLAND_M, the
	                       // valley-fill alluvium end member, because a fresh deposit is unconsolidated clastic
	uint pad1;
	uint pad2;
} params;

// Half a cell of mineral mass = bedrock. A MODEL PARAMETER — where a continuous fill fraction is declared to
// have become rock — not a property of the rock.
//
// *(Corrected 2026-08-09. This said "MUST match MaterialField3D / Stage C stamp". MaterialField3D.gd declares
// no SOLID_THRESHOLD and never did; the comment named a file rather than the thing to match, which reads as a
// checkable contract and is not one. What the value really has to agree with is every OTHER place the same
// 0.5 is written, and it is written as a BARE LITERAL in all of them: LAMaterialFieldInject3D.gd:604 and :789
// (walk outward to the first non-bedrock cell), LAPlateTectonics.gd:57, and the SDF stamp trigger described at
// Volcano.gd:11. Five copies of one threshold with no owner is the drift pattern this repo already paid for
// once with the freezing point of water; naming them is the cheap half of the fix, giving them one owner is
// the other half and is a code change.)*
const float SOLID_THRESHOLD = 0.5;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	float rf = rock_fill[g];
	if (rf >= SOLID_THRESHOLD) {
		// LITHIFY the loose phases into the bedrock they are now inside. Own-cell, mass-for-mass, so the
		// mineral ledger (which sums rock_fill + lava + sediment + susp + dust) does not move.
		float loose = sediment[g] + susp[g] + dust[g];
		if (loose > 0.0) {
			rock_fill[g] = rf + loose;
			sediment[g] = 0.0;
			susp[g] = 0.0;
			dust[g] = 0.0;
		}
		// The water phases become the new rock's PORE WATER, and the rock becomes aquifer.
		float trapped = water[g] + moisture[g] + snow[g];
		if (trapped > 0.0) {
			soil[g] += trapped;
			water[g] = 0.0;
			moisture[g] = 0.0;
			snow[g] = 0.0;
			regolith[g] = 1.0;
			grain[g] = max(grain[g], params.fresh_grain_m);
		}
		solid[g] = 1.0;
		return;
	}
	solid[g] = 0.0;
}
