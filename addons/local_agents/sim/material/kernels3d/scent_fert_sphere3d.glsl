#[compute]
#version 450

// CUBED-SPHERE SCENT — soil FERTILITY pass. Sphere port of scent_fert3d.glsl. This is a per-SURFACE-CELL 2D
// field: one invocation per surface cell (dispatch over surf_count). The box kernel blurred toward its 4 lateral
// column-neighbours by idx arithmetic (±1, ±dim_x) with dim-bounds ifs, then leached a slow fraction (faster in
// rain). On the sphere each surface cell blurs toward its 4 LATERAL neighbours from the surface index table
// nbr[cell*6 + d], slots 1..4 (radial slots 0 and 5 SKIPPED for this 2D surface field); a boundary slot -1 is
// skipped.
//
// This is a fully MECHANICAL conversion — the box already had no wind, only an isotropic FERT_BLUR. Reads only
// the OLD fertility snapshot (fert_in), writes fert_out → order-independent.
//
// THIS FILE IS THE ONLY DECLARATION OF THESE THREE RATES. *(Corrected 2026-08-08. The line above used to end
// "Constants copied EXACTLY from MaterialScent3D.gd", and the const block below said "MUST match
// MaterialScent3D.gd exactly". Both are false: LAMaterialScent3D holds SCENT_ACTIVE and
// SEED_NEIGHBOUR_FRACTION and nothing else — it has no FERT_DECAY, no FERT_BLUR and no FERT_RAIN_LEACH, and a
// grep for those three names returns this file alone. The stale pointer is worse than no pointer: it invites
// the next reader to "restore parity" by copying them back into the GDScript module, which would create
// exactly the two-declarations-of-one-quantity drift this repo has already been bitten by.)* These are process
// RATES of this substrate, not measured properties of matter, so they do not belong in LAPhysical and carry no
// `// LAPhysical.<NAME>` binding comment.
//
// CONSERVATION (2026-08-03). The line above used to continue "The self weight stays 1 - 4*FERT_BLUR (four blur
// contributions on the closed surface)", which was a leak whenever a cell had fewer than four links: the
// gather skips a -1 slot but the self weight assumed four, so the cell gave away more than anyone received.
// The self weight now counts the links the cell actually has. The LEACH term is still non-conservative and is
// still unfixed — it deletes nitrogen with nothing receiving it; see the note at the write below.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FertIn  { float fert_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FertOut { float fert_out[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh  { int nbr[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;   // = surf_count
	uint pad0;
	uint pad1;
	float precip;
} params;

// Tunables — declared HERE and nowhere else (see the header). What each is a rate OF:
//   FERT_BLUR       soil creep / bioturbation mixing nitrate between adjacent surface cells. CONSERVATIVE.
//   FERT_RAIN_LEACH nitrate carried out of the root zone by percolating rain. NOT conservative — see below.
//   FERT_DECAY      the no-rain floor of the same removal. Nitrate does not "decay": nothing in soil chemistry
//                   destroys a nitrogen atom, so the name describes the arithmetic and not the mechanism. The
//                   two real processes it stands in for are baseline drainage below the root zone (which ends
//                   in groundwater, still nitrogen) and denitrification (NO3- -> N2, which ends in the
//                   ATMOSPHERE, still nitrogen). Both have a destination; this kernel has neither.
const float FERT_DECAY = 0.0015;
const float FERT_RAIN_LEACH = 0.02;
const float FERT_BLUR = 0.04;

void main() {
	uint cell = gl_GlobalInvocationID.x;
	if (cell >= params.cell_count) {
		return;
	}
	float leach = FERT_DECAY + params.precip * FERT_RAIN_LEACH;
	float here = fert_in[cell];
	// SOIL CREEP: blur toward the 4 LATERAL neighbours (table slots 1..4).
	//
	// The self weight counts the links this cell ACTUALLY has. It used to be a flat `1 - 4*FERT_BLUR` while the
	// gather loop below skipped any slot the table marks -1, so a cell short of a link kept less than it gave
	// away and nothing anywhere gained the difference — THAT DELETED NITROGEN at every such cell, every step.
	// Counting first makes the exchange balance for any link count: this cell gives FERT_BLUR to each real
	// neighbour and takes FERT_BLUR from each, so the blur alone moves nitrogen around without changing the
	// total. (On a closed cubed sphere every surface cell should have all four, in which case this is
	// arithmetically the old line -- but the loop was already written to tolerate -1, and a self weight that
	// disagrees with the gather is a leak waiting for the first cell that hits one.)
	float acc = 0.0;
	int links = 0;
	for (int d = 1; d < 5; d++) {
		int nb = nbr[cell * 6u + uint(d)];
		if (nb >= 0) {
			acc += FERT_BLUR * fert_in[uint(nb)];
			links += 1;
		}
	}
	acc += here * (1.0 - FERT_BLUR * float(links));

	// LEACHING — THIS DESTROYS NITROGEN, AND IT IS STILL LIVE. `leach` removes FERT_DECAY +
	// precip*FERT_RAIN_LEACH of the cell's nitrogen every step and NO channel receives it, so those atoms cease
	// to exist. In the world every one of them has somewhere to be: leached nitrate rides groundwater downhill
	// to the sea, and denitrified nitrogen goes to the air as N2. Both destinations are still nitrogen.
	//
	// WHY IT IS NOT FIXED HERE, precisely, so the next reader does not re-derive it. `fert` is the substrate's
	// ONLY mineral-nitrogen pool: there is no dissolved-nutrient channel in the water and no N2 channel in the
	// air (MaterialSphereGPU3D's PAIR_CHANNELS/SINGLE_CHANNELS carry neither), so there is no existing buffer
	// that could receive this mass. This kernel binds exactly three things — FertIn, FertOut and the neighbour
	// table — so it cannot reach a receiver even if one existed, and it cannot resolve a DIRECTION either:
	// routing the loss downhill needs elevation, and pooling it in the sea needs the water/solid mask. Every
	// one of those is a new binding, which lives in EcoSurfacePass's uniform sets, not in this file.
	//
	// WHAT WOULD ACTUALLY CLOSE IT: add a dissolved-N channel (or an atmospheric N2 channel) to the driver's
	// channel list, bind it here, and make this line a TRANSFER rather than a subtraction. Turning the rate
	// down or to zero is not a fix — it deletes a real process to flatter a gauge.
	//
	// HOW TO SEE IT MEANWHILE: it is the residual in `nitrogen_run_drift_per_step`, which
	// LAMaterialFieldElementInventory3D takes off the MASK-FREE `nitrogen_all` as of 2026-08-08. Before that
	// the same gauge was masked to open cells, so this destruction was mixed in with ordinary burial and
	// neither was legible.
	fert_out[cell] = max(0.0, acc * (1.0 - leach));
}
