#[compute]
#version 450

// CUBED-SPHERE FUNGUS — the emergent DECOMPOSER CA's cross-cell GROWTH / SPREAD / DEATH half. Sphere port of
// fungus3d.glsl. The SAME-CELL DECOMPOSE CHEMISTRY (detritus + O₂ → CO₂ + fertility, with the aerobic O₂ cap)
// DISSOLVED into the generic ReactionsPass as a BILINEAR reaction record (fungus × detritus) — see
// MaterialReactions3D.gd. It runs one pass earlier, so detritus arrives here already debited by this step's rot.
// What stays bespoke here is the genuinely cross-cell part: the SPORE exchange (loops the precomputed INDEX
// TABLE nbr[idx*6 + d], skipping boundary -1 and solid neighbours so spores never cross stone), the population
// GROWTH, and the DEATH/DECAY dieback.
//
// Reads fung_in (self + neighbours for spores), reads AND WRITES detritus, writes fung_out (ping-pong).
//
// CONSERVATION (2026-08-03). This block used to describe the three legs above as "the genuinely cross-cell /
// NON-CONSERVATIVE part", and that was an accurate label for code that leaked in four separate directions.
// All four are closed now, each documented at the site:
//   * GROWTH credited fungus out of detritus it never debited — THIS MADE LIVING MATTER APPEAR FROM NOTHING.
//     It now debits detritus one-for-one, capped by the substrate present and by the headroom to FUNGUS_MAX.
//   * SPREAD gathered a share of all six neighbours' mycelium without debiting any of them, compounding at
//     roughly +12%/step — A COLONY COPIED ITSELF. It is now a two-sided transfer: the sender subtracts what
//     the receiver adds, and a cell only sends when IT is favourable.
//   * The FUNGUS_MAX truncation silently DELETED any mass above the cap. Gone; the cap bounds growth instead.
//   * DECAY destroyed dead mycelium outright. It now returns that mass to detritus, which is what dead
//     mycelium is.
// Plus the burial case: a cell turning to rock had its colony zeroed, which DESTROYED LIVING MATTER; the mass
// is now buried in place and inert until the rock reopens.
//
// LEDGER NOTE for anyone comparing before/after numbers: `carbon_total` in SIM_REPORT is co2 + biomass +
// detritus and does NOT include fungus, which is a memo line (`fungus_total`) in MaterialFieldMassBudget3D.
// So making growth debit detritus moves mass OUT of the carbon sum and into the memo. A drop in carbon_total
// with a matching rise in fungus_total is the fix working, not a new leak — read the two together.
//
// THIS KERNEL IS THE AUTHORITY FOR THE CONSTANTS BELOW. The two comments here used to say they were "copied
// EXACTLY from MaterialFungus3D.gd" / "MUST match MaterialFungus3D.gd exactly", and that file WAS DELETED
// when the CPU oracle was retired (docs/0.4_PARALLELIZATION_GUIDE.md:32) — so both pointed the reader at a
// file that does not exist, which is how a constant quietly becomes unowned. One other file mirrors two of
// them: LAMaterialFieldChannels3D's FUNGUS_PRESENT / DETRITUS_PRESENT gauge thresholds, which cite these
// lines. They are model thresholds, not properties of matter, so they do not belong in LAPhysical.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FungIn  { float fung_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer FungOut { float fung_out[]; };
// DETRITUS IS READ-WRITE AS OF 2026-08-03 (it was `restrict readonly`). Growth below now DEBITS it, and decay
// CREDITS it back — see the conservation note in the header. Each thread touches only its OWN cell's detritus,
// so this is race-free, and the decompose record in ReactionsPass ran a whole pass earlier, so nothing else is
// writing this buffer while this kernel runs. The uniform set is unchanged: `readonly` is a shader-side memory
// qualifier, not a binding type, so EcoSurfacePass needs no edit.
layout(set = 0, binding = 2, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer Temp  { float temp[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer Vapor { float vapor[]; };
// BINDING 7 (Fire) IS GONE ON PURPOSE, 2026-08-09 — see the FIRE note below. The gap is deliberate; the
// remaining bindings keep their numbers so no other kernel or pass has to move.
layout(set = 0, binding = 8, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };

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

// Substrate thresholds + rates. Declared here and owned here (see the header).
const float DETRITUS_MIN = 0.05;
// FUNGUS_MIN is not read by this kernel — its consumer is LAMaterialFieldChannels3D.FUNGUS_PRESENT, the
// "this cell has a live colony" threshold the SIM_REPORT fungus_cells gauge counts against. Kept here so the
// gauge and the physics agree on what a colony is by construction.
const float FUNGUS_MIN = 0.02;
const float FUNGUS_MAX = 3.0;
const float MOIST_MIN = 0.02;
const float MOIST_REF = 0.06;
const float VAPOR_MOIST = 1.0;
const float RAIN_MOIST = 0.5;
const float DETRITUS_DAMP = 0.15;
// Thermal death of a mesophilic fungus. Real mesophiles top out around 40-45 C (thermophiles reach 60, which
// this single generic decomposer channel does not model). A property of the organism, not of matter.
const float TEMP_WARM = 42.0;
// Growth stops when the water in and around the mycelium turns to ice, so this IS the freezing point of
// water and is bound to the authority rather than left free. It is exactly the kind of constant that was
// once moved to 12.5 in five files because the planet could not get cold; the annotation makes that fail.
const float TEMP_COLD = 0.0;    // LAPhysical.WATER_FREEZE_C
// FIRE: THIS KERNEL NO LONGER READS IT, AND `const float FIRE_MIN = 0.02;` IS DELETED WITH THE TWO TESTS
// THAT USED IT (2026-08-09). Growth and spread both used to carry `|| fire[c] > FIRE_MIN`, and that was
// wrong three times over.
//   * IT WAS PHYSICS READING A GAUGE. ReactionDefs.gd declares `fire` an INSTRUMENT "read by no physics
//     anywhere"; this kernel was the counterexample that made the sentence false. A mechanism may never
//     depend on a diagnostic.
//   * THE GAUGE WAS NOT MEASURING FIRE. reactions_sphere3d.glsl captures `o2_before` BEFORE the whole
//     record loop, so `fire` is the fraction of usable oxygen drawn by EVERY oxidation in the step —
//     R15 decomposition and respiration included, not only R26 combustion.
//   * SO IT MADE THE DECOMPOSER SUPPRESS ITSELF. Fungus rots litter -> the rot draws O2 -> `fire` rises
//     past 0.02 -> the fungus reads itself as burning and stops growing and stops spreading, hardest
//     exactly where decomposition is most vigorous. Nobody designed that loop; it fell out of the gauge.
// Fire still kills fungus, through the term that actually represents it: a cell alight is far past
// TEMP_WARM, and thermal death is a measured property of a mesophile rather than a threshold on an
// instrument. The 0.02 now has ONE owner, LAMaterialFieldQueries3D.FIRE_PRESENT, beside the gauge that
// reads it.
const float GROW_RATE = 0.06;
const float SPREAD = 0.02;
const float DECAY = 0.02;
const float DRY_DECAY = 0.06;

// Is cell `c` DISPERSING spores this step? A cell only SENDS along a face when it is itself spreading, so the
// receiver has to evaluate the DONOR's condition rather than its own — that asymmetry is exactly what used to
// let spread mint fungus.
//
// DELIBERATELY READS NO CHANNEL THIS KERNEL WRITES. It tests only temp and vapor, both readonly here.
// The obvious version of this function also required `detritus[c] > DETRITUS_MIN`, matching the growth test
// below — but `detritus` is read-write in this kernel (growth debits it, decay credits it), so a neighbour
// reading detritus[c] while thread c writes it is a DATA RACE, and the spread would have become
// nondeterministic near the DETRITUS_MIN boundary. Dropping the food term also happens to be the better
// model: a mycelium disperses spores when its surroundings are LIVABLE, and if anything disperses harder as
// local food runs out, so keying dispersal to the local larder was never right. Building new tissue still
// requires substrate — that stays in `favourable` below, which only ever reads cell i's own detritus.
bool spreads_at(uint c) {
	float moist_c = VAPOR_MOIST * vapor[c] + RAIN_MOIST * params.precip;
	float tc = temp[c];
	return tc <= TEMP_WARM && tc >= TEMP_COLD && moist_c >= MOIST_MIN;
}

// How many of cell `c`'s six neighbours are OPEN — the divisor both ends of a spore transfer agree on.
int open_neighbours(uint c) {
	uint b = c * 6u;
	int n = 0;
	for (int d = 0; d < 6; ++d) {
		int m = nbr[b + uint(d)];
		if (m >= 0 && solid[m] == 0.0) { n += 1; }
	}
	return n;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	if (solid[i] != 0.0) {
		// ROCK GREW OVER A LIVE COLONY: BURY IT, DO NOT DELETE IT. This used to be a bare `fung_out[i] = 0.0`,
		// which DESTROYED LIVING MATTER whenever a cell crossed the rock threshold (`solid` is re-derived from
		// rock_fill every step by solid_derive_sphere3d.glsl). The mycelium is now held in place — buried and
		// inert, since no path grows or spreads it while the cell is solid — and it is there again if the rock
		// erodes or melts back open. `fungus_total` in SIM_REPORT sums OPEN cells only, so buried colonies
		// correctly stop counting as live without their mass being destroyed. Same rule the o2/co2 transport
		// kernels use for buried gas.
		fung_out[i] = fung_in[i];
		return;
	}

	float d = detritus[i];
	float g = fung_in[i];
	// Moisture: air humidity + active rain + the dampness of the rotting matter itself.
	float moist = VAPOR_MOIST * vapor[i] + RAIN_MOIST * params.precip + DETRITUS_DAMP * clamp(d, 0.0, 1.0);
	float t = temp[i];
	bool scorched = t > TEMP_WARM;
	bool frozen = t < TEMP_COLD;
	bool dry = moist < MOIST_MIN;
	bool favourable = d > DETRITUS_MIN && !scorched && !frozen && !dry;
	float gnew = g;
	float det_delta = 0.0;      // net change to THIS cell's detritus; applied once at the end.

	// 1) GROWTH — new mycelium is BUILT OUT OF DETRITUS, one unit of mass per unit of mass. This used to read
	// `d` and credit `GROW_RATE * d * mfac` to fungus WITHOUT debiting anything, which MADE LIVING MATTER
	// APPEAR FROM NOTHING. The old comment defended it with "this step's decompose already debited it", but
	// that debit is the RESPIRATION leg — the ReactionsPass bilinear record turns detritus into CO₂ and
	// fertility — and respiring carbon away is not the same as building a body out of it. The assimilation leg
	// was simply missing. Growth is now capped by the cell's remaining headroom to FUNGUS_MAX and by the
	// detritus actually present, so it can never draw more substrate than there is.
	if (favourable) {
		float mfac = clamp(moist / MOIST_REF, 0.0, 1.0);
		float want = GROW_RATE * d * mfac;
		float headroom = max(0.0, FUNGUS_MAX - gnew);
		float grown = min(min(want, headroom), max(0.0, d));
		gnew += grown;
		det_delta -= grown;
	}

	// 2) SPREAD — a CONSERVING two-sided transfer. Each favourable cell sends SPREAD of its own mycelium along
	// every open face; each cell gathers what its favourable neighbours sent it. The old code did only the
	// GATHER half: `gnew += SPREAD * spore` credited this cell with a share of the sum of all six neighbours'
	// fungus while debiting none of them, so every colony copied itself into its surroundings roughly 12% per
	// step and compounded. Now the send is subtracted from the sender, and both ends use the same SPREAD and
	// the same open-face test, so the exchange balances face by face. Total outgoing fraction is at most
	// 6*SPREAD = 0.12, so a sender can never send more mycelium than it has.
	if (spreads_at(i)) {
		gnew -= SPREAD * float(open_neighbours(i)) * g;
	}
	for (int dd = 0; dd < 6; dd++) {
		int nb = nbr[i * 6u + uint(dd)];
		if (nb >= 0 && solid[nb] == 0.0 && spreads_at(uint(nb))) {
			gnew += SPREAD * fung_in[uint(nb)];
		}
	}

	// NOTE: there is no truncation to FUNGUS_MAX here any more. It used to sit at the end of the growth block
	// as `if (gnew > FUNGUS_MAX) gnew = FUNGUS_MAX;`, which silently DELETED whatever mass sat above the cap.
	// FUNGUS_MAX is a carrying capacity — a limit on how much new mycelium a cell can BUILD — so it now bounds
	// the growth term above and nothing else. Spore inflow may carry a cell transiently over the cap; decay
	// brings it back down, and no mass disappears on the way.

	// 3) DEATH / DECAY — dies back fast where hot/frozen/dry or the food is exhausted. DEAD MYCELIUM IS
	// DETRITUS: the mass returns to the substrate pool it came from. This used to be a bare subtraction that
	// DESTROYED the dead fungus outright, with no product anywhere — which is why the decay leg leaked in the
	// opposite direction to the growth leg.
	float died = ((scorched || frozen || dry || d <= DETRITUS_MIN) ? DRY_DECAY : DECAY) * max(0.0, gnew);
	gnew -= died;
	det_delta += died;

	detritus[i] = max(0.0, d + det_delta);
	fung_out[i] = max(0.0, gnew);
}
