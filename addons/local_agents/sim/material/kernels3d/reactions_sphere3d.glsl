#[compute]
#version 450

// CUBED-SPHERE GENERIC REACTION ENGINE (Phase B3 §3). ONE data-driven kernel that dissolves a pile of
// bespoke "clean same-cell" reaction kernels (gas sky-exchange/vent, fungus decompose, …) into a single
// per-cell loop over an array of Reaction RECORDS uploaded as a read-only SSBO (authored in
// MaterialReactions3D.gd). Each record names its channels by a SLOT enum resolved through the read_ch/add_ch
// switch-ladders below, applies an optional gate + a rate model, caps the extent by its reactants, then
// debits reactants + credits products — all on the OWN cell (own-cell writes only → order-independent across
// cells, race-free). Adding a reaction = adding a record, not a kernel.
//
// The reactions run AFTER Atmosphere and Soil in the sphere pipeline, so temp/water/o2/co2/moisture/soil are
// all in their settled post-step buffers (one-step coupling lag is the accepted norm — MaterialSphereGPU3D.gd
// :19-20). ReactionsPass binds o2/co2/temp/water/moisture/soil to their BACK (producer-output) halves and
// fungus/fert to their LIVE halves (their producers run later), so each read is the freshest at this slot.
//
// DERIVED slots cost no memory and no readback: they are computed from geometry the kernel already has.
// WINDSPEED is sqrt(vel²); LIGHT is max(0, dot(radial, sun_dir)) — the SAME per-cell insolation
// heat3d_solar_sphere3d uses, so one sun drives both the temperature field and the chemistry; SOIL_ROOT is the
// water of the regolith column beneath an open cell, which is where roots actually reach.

layout(local_size_x = 64) in;

// --- Reactable channels (binding == slot for the resolved ones; see read_ch/add_ch) -----------------------
layout(set = 0, binding = 0, std430) restrict buffer Temp     { float temp[]; };
layout(set = 0, binding = 1, std430) restrict buffer Water    { float water[]; };
layout(set = 0, binding = 2, std430) restrict buffer Moisture { float moisture[]; };
layout(set = 0, binding = 3, std430) restrict buffer O2       { float o2[]; };
layout(set = 0, binding = 4, std430) restrict buffer CO2      { float co2[]; };
// FUEL — cured cellulosic litter, the SAME substance as biomass and detritus. Bound and reactable as of
// 2026-08-09: combustion is a record now (CombustionRecords.gd), not fire_sphere3d.glsl, so this is where
// fuel is oxidised. Slot 5 was declared in both enums for months with no ladder branch on either side, so it
// read 0 and every write to it vanished.
layout(set = 0, binding = 5, std430) restrict buffer Fuel     { float fuel[]; };
// FIRE — an INSTRUMENT, not a channel and not a reactable slot. Assigned at the bottom of main() as the
// fraction of this cell's fuel that combustion consumed this step, for `fire_cells` / `fire_peak` /
// `is_burning`. NOTHING in the physics reads it; it has no read_ch/add_ch branch on purpose, and
// LAReactionBalance.driver_only() refuses it as a reactant or product, which is what keeps a derived
// quantity from turning back into stored state.
layout(set = 0, binding = 6, std430) restrict buffer Fire     { float fire[]; };
layout(set = 0, binding = 7, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 9, std430) restrict buffer Fert { float fert[]; };           // soil nutrient (R15 fungus-decompose + creature excretion feed it; R19 uptake now debits it — LIVE half, its diffuse/leach producer runs later this step, same convention as Fungus above)
layout(set = 0, binding = 11, std430) restrict buffer Biomass { float biomass[]; };    // living plant matter (photosynthesis grows it, respiration/decay oxidizes it)
layout(set = 0, binding = 12, std430) restrict buffer Snow { float snow[]; };          // frozen H₂O (freeze credits it, melt debits it) — SAME substance as water/moisture
// --- MINERAL phases (rock unification): loose sediment, airborne dust, waterborne suspension. Loft (M4) moves
// SEDIMENT→DUST own-cell; settle (M3) moves SUSP→SEDIMENT own-cell — same conserved mineral substance. ---------
layout(set = 0, binding = 13, std430) restrict buffer Sediment { float sediment[]; };  // loose granular regolith
layout(set = 0, binding = 14, std430) restrict buffer Dust { float dust[]; };           // airborne wind-lofted dust
layout(set = 0, binding = 16, std430) restrict buffer Susp { float susp[]; };           // waterborne suspended sediment
layout(set = 0, binding = 17, std430) restrict readonly buffer VelX { float vel_x[]; }; // horizontal wind (WINDSPEED driver)
layout(set = 0, binding = 18, std430) restrict readonly buffer VelZ { float vel_z[]; };
// --- BEDROCK phase (rock unification Stage B): molten LAVA <-> fractional bedrock ROCK_FILL are the SAME mineral.
// M5 solidify (cold lava -> rock_fill) and M6 melt (hot rock_fill -> lava) are own-cell conserving transfers. -----
layout(set = 0, binding = 22, std430) restrict buffer Lava { float lava[]; };            // molten rock (mass/cell)
layout(set = 0, binding = 23, std430) restrict buffer RockFill { float rock_fill[]; };   // fractional bedrock mass (solid iff >= 0.5)
// --- SUBSURFACE WATER: the aquifer the roots drink from. `soil` is non-zero ONLY in REGOLITH cells —
// soil_sphere3d.glsl:223-229 keys on the regolith mask and zeroes soil in every non-regolith open cell — so a
// plant's water is the soil in the permeable column BENEATH it, read/debited through the SOIL_ROOT slot below,
// never at the reacting cell itself. NOTE "regolith", not "solid": an eroded or carved regolith cell is open
// AND still an aquifer, which is exactly the case the walk used to get wrong. -------------------------------
layout(set = 0, binding = 24, std430) restrict buffer Soil { float soil[]; };
// --- Gate inputs + scratch product target + the record table ----------------------------------------------
layout(set = 0, binding = 10, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };        // idx*6 + slot
layout(set = 0, binding = 20, std430) restrict buffer Scratch { float scratch[]; };         // SCRATCH product target (fungus_fert)
layout(set = 0, binding = 25, std430) restrict readonly buffer Radial { float radial[]; };  // per-cell outward unit vec, flat c*3+{0,1,2}
// AQUIFER PERMEABILITY MASK (1 = groundwater-bearing regolith). The mask root_soil() walks — soil lives here,
// not "wherever the rock is solid". Bound at 27, past the end of the slot-alias range (bindings 0..26 shadow
// the slot enum; 5 and 6 are FUEL and the FIRE instrument as of 2026-08-09, 19 is derived SOIL_ROOT and needs
// no buffer), because regolith is not a reactable channel. Same buffer soil_sphere3d.glsl binds at its own
// binding 6.
layout(set = 0, binding = 27, std430) restrict readonly buffer Regolith { float regolith[]; };
// --- THE TWO NON-SILICATE MINERAL SPECIES (2026-08-08). Every mineral channel above is calcium silicate
// CaSiO3; the Urey reaction CaSiO3 + CO2 -> CaCO3 + SiO2 has two products that are not, so each gets a
// channel. OWN-CELL stocks in the near-ground open cell that weathered — they do not advect, and no kernel
// other than this one reads or writes them. Bound at 28/29 because the slot<->binding alias runs out at 26
// (24/25/26 are Soil/Radial/Static above); the slot NUMBERS are 24 and 25, which is what check_kernel()
// verifies against the #defines below. ------------------------------------------------------------------
layout(set = 0, binding = 28, std430) restrict buffer Carbonate { float carbonate[]; };  // CaCO3 — the carbon sink
layout(set = 0, binding = 29, std430) restrict buffer Silica { float silica[]; };        // SiO2 — the residue
// Athy pore fraction (0 outside regolith). Declared HERE, with the other buffers, and not beside the
// rc_shared.glsli include at the bottom: `overburden()` reads it ~30 lines above that point, and GLSL
// requires declaration before use — putting it by the include made this whole kernel fail to compile,
// and the sim then ran to completion and printed a normal-looking SIM_REPORT with the entire reaction
// engine silently absent.
layout(set = 0, binding = 38, std430) restrict readonly buffer Porosity { float porosity[]; };

// Slot enum — MUST match MaterialReactions3D.gd.
#define TEMP     0
#define WATER    1
#define MOISTURE 2
#define O2       3
#define CO2      4
#define FUEL     5
#define FIRE     6
#define DETRITUS 7
#define FUNGUS   8
#define FERT     9
#define LAVA     10
#define BIOMASS  11
#define SNOW     12
#define SEDIMENT  13
#define DUST      14
#define SUSP      15
#define WINDSPEED 16   // derived driver: sqrt(vel_x^2 + vel_z^2) — not a stored channel, read-only
#define ROCK_FILL 17   // fractional bedrock mineral mass (solid iff >= 0.5); M5/M6 transfer it with LAVA
#define LIGHT     18   // DERIVED driver: max(0, dot(cell_radial, sun_dir)) — REAL per-cell insolation, the same
                       // quantity heat3d_solar_sphere3d computes, with sun_dir's magnitude carrying intensity
                       // (orbit distance² × atmospheric transmission, so dust/impact-winter dim it directly).
                       // Not a stored buffer: no memory, no readback. Read-only — never a product.
#define SOIL_ROOT 19   // DERIVED, WRITABLE: the plant-available water of the ROOTING COLUMN — the soil summed
                       // over the permeable REGOLITH cells directly beneath this open cell (the regolith mask,
                       // not the solidity mask; they diverge). See root_soil().
#define VAPOUR_DEFICIT 20  // DERIVED driver: sat(T) - moisture, SIGNED. The phase rule — see sat_mass_frac().
#define SOIL_TOP  21   // DERIVED, WRITABLE: the soil of the FIRST regolith cell beneath this open cell — the
                       // shallow DRYING FRONT. Roots reach the whole rooting column (SOIL_ROOT); evaporation
                       // does not. Vapour has to diffuse out through the pores, so bare-soil evaporation
                       // draws from the surface layer and the water below it is simply out of reach — which
                       // is why a real profile dries top-down and why the exposed shell is the one that
                       // thins. Using SOIL_ROOT here would have evaporated the bottom of the aquifer.

// --- THE PHASE RULE ----------------------------------------------------------------------------------------
// How much water air holds is the SATURATION VAPOUR PRESSURE at its temperature, and nothing else. Written
// once here, in the field's own unit (a fraction of a cell full of liquid water), it governs the sea, a
// puddle, wet soil and a snowbank identically — the records differ only in which liquid they name.
// August-Roche-Magnus with Alduchov & Eskridge (1996) coefficients, then the ideal gas law for vapour.
const float WATER_FREEZE_C = 0.0;        // LAPhysical.WATER_FREEZE_C
const float MAGNUS_A_PA = 610.94;        // LAPhysical.MAGNUS_A_PA
const float MAGNUS_B = 17.625;           // LAPhysical.MAGNUS_B
const float MAGNUS_C_C = 243.04;         // LAPhysical.MAGNUS_C_C
const float VAPOUR_R = 461.52;           // LAPhysical.VAPOUR_GAS_CONST_J_KGK
const float KELVIN_0 = 273.15;           // LAPhysical.KELVIN_OFFSET
const float RHO_WATER = 997.0;           // LAPhysical.WATER_DENSITY_KG_M3

float sat_mass_frac(float t_c) {
	float t = max(t_c, -80.0);           // the Magnus fit's pole is at -243.04 C
	float e_sat = MAGNUS_A_PA * exp(MAGNUS_B * t / (t + MAGNUS_C_C));
	return (e_sat / (VAPOUR_R * max(t + KELVIN_0, 1.0))) / RHO_WATER;
}
#define OVERBURDEN 22  // DERIVED driver: LITHOSTATIC pressure (Pa) of the SOLID column above. See overburden().
#define BEDROCK_BELOW 23 // DERIVED, WRITABLE: the bedrock of the SOLID cell directly beneath this open one —
                       // the rock a surface process actually attacks. Unique per thread; see bedrock_below().
#define CARBONATE 24   // CaCO3, bound at 28 — the only place weathered carbon can go (D1b), and the only
                       // thing D1c can give back to the air. Own-cell stock; nothing advects it.
#define SILICA    25   // SiO2, bound at 29 — the weathering residue. Nothing weathers it further.

#define WET_MAX_LOFT 0.05   // water mass above which a surface is WET and can't loft dust (dust_loft parity)
#define REGOLITH_CELLS 4    // rooting depth = the permeable regolith band (MUST match MaterialField3D.REGOLITH_CELLS)
#define DAYLIGHT_MIN 0.02   // insolation above which GATE_DAYLIGHT considers a cell to be in daylight
// OVERBURDEN_MAX_CELLS bounds the outward walk. The lithification threshold is reached at four cells of full
// rock, so twelve covers three times it and anything deeper cannot change a record's answer. It is a loop
// bound, not a physical claim.
#define OVERBURDEN_MAX_CELLS 12
const float ROCK_DENSITY = 2900.0;      // LAPhysical.ROCK_DENSITY_KG_M3 — basalt / crustal rock
const float SEDIMENT_DENSITY = 2000.0;  // LAPhysical.SEDIMENT_DENSITY_KG_M3 — unconsolidated wet sediment
                                        // (absolute temperature for Arrhenius comes from KELVIN_0 above —
                                        // one name for one constant, so it cannot drift into two)
// (BOIL_TEMP is GONE from this kernel, 2026-08-09. It was the ARRHENIUS branch's hard-coded aqueous ceiling —
// a fact about WATER applied to every Arrhenius record there will ever be. It is `t_ceiling_k` on the record
// now, so D1b still stops at its solvent's boiling point and combustion, which has no solvent, does not.)

// --- A CELL'S VOLUMETRIC HEAT CAPACITY [J/m3/K] ------------------------------------------------------------
// What an ENTHALPY of reaction has to be divided by to become a temperature change: the same reaction warms
// dry air by thousands of kelvin and a waterlogged cell by tens, which is the whole of why wet fuel resists
// lighting and why a flame in a swamp is not a flame in dry litter — with no per-case code and no wet-cell
// gate anywhere.
//
// SHARED, 2026-08-09. This block used to declare its own RC_* and its own rc_of, above a comment claiming it
// was "deliberately the SAME expression heat3d_cool_sphere3d.glsl:93-102 uses". IT WAS NOT: this copy carried
// an ORGANIC term that one did not, and that one carried lava while this one had no SNOW. Five copies, four
// different formulas. See rc_shared.glsli for the table and for why the `solid` early-return is gone.
// The `#include` itself is further down, because it is TEXTUAL and reads the carrier buffers by name, so it
// has to land after the last `layout(...) buffer` declaration rather than up here with the other constants.
// The oxygen concentration below which a flame goes out however hot it is, in this channel's units of
// ambient air: the measured limiting oxygen concentration over air's own mole fraction.
const float LOC_MOLE_FRAC = 0.15;          // LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC
const float AIR_O2_MOLE_FRAC_K = 0.20946;  // LAPhysical.AIR_MOLE_FRAC_O2
const float O2_FLAMMABILITY_LIMIT = LOC_MOLE_FRAC / AIR_O2_MOLE_FRAC_K;

#define CONST_FRAC             0
#define BILINEAR               1
#define EXCESS_OVER_THRESHOLD  2
// 3 IS RETIRED AND STAYS UNUSED — it was RELAX_TARGET, whose own definition ("signed; no reactant; product =
// driver") describes matter appearing from nothing. The main loop below used to SKIP the entire cap-and-debit
// block for it, so only the product credit ran. See LAReactionDefs for the full account; an unknown rate
// model now yields no extent at all rather than an unbounded source.
#define DEFICIT_BELOW_THRESHOLD 4   // mirror of EXCESS: fires when driver is BELOW threshold (freeze at T<FREEZE_TEMP)
#define OPTIMUM_BAND           5    // x = k * driver * max(0, 1 - ((driver2 - threshold)/param2)^2) — a rate that
                                    // PEAKS at an optimum and falls off BOTH ways. See MaterialReactions3D.gd.
#define ARRHENIUS              6    // x = k * driver * driver2 * exp(-(Ea/R)(1/T - 1/T_ref)) — the temperature
                                    // law of chemistry. threshold = Ea/R (K), param2 = T_ref (K). See ReactionDefs.gd.

#define GATE_OPEN_ABOVE  1
#define GATE_SURFACE     2
#define GATE_NEAR_GROUND 4
#define GATE_DAYLIGHT    8
#define GATE_DRY         16   // cell is DRY (water <= WET_MAX_LOFT) — sand only lofts when not wet
#define GATE_FREEZING    32   // cell temp below WATER_FREEZE_C — see LAReactionDefs.GATE_FREEZING
                              // water=1 and is deliberately not simulated) — real per-cell chemistry only
#define GATE_AIR_ABOVE   128  // THE FREE SURFACE: the outward neighbour is air (not rock, not drowned). A
                              // submerged cell has no air touching it and cannot evaporate. See ReactionDefs.

#define DROWNED_WATER 0.5     // half a cell of standing water in the neighbour above = no free surface here

#define TGT_SELF    0
#define TGT_SCRATCH 3

struct Reaction {
	int   rate_model;
	float rate_k;
	float threshold;
	int   gate_mask;
	int   driver_slot;
	int   driver2_slot;
	int   cap_slot;
	float cap_coeff;
	int   n_react;
	int   n_prod;
	float param2;      // second rate-model scalar (OPTIMUM_BAND: the half-width of the band around `threshold`)
	float t_ceiling_k; // ARRHENIUS: absolute T above which the law stops applying (its phase is gone). 0 = none.
	int   react_slot[4];
	float react_coeff[4];
	int   prod_slot[4];
	float prod_coeff[4];
	int   prod_target[4];
	// --- the 16-byte block the record grew by, 2026-08-09 (see LAReactionDefs.serialize) ---
	float enthalpy_j_m3;  // heat RELEASED (>0) or absorbed (<0) per unit of extent, J per m3 of cell
	int   quench_slot;    // a REACTANT this reaction goes out before exhausting; -1 = none
	float quench_min;     // ...the amount of it the reaction may not draw below (flammability limit)
	int   pad2;
};

layout(set = 0, binding = 21, std430) restrict readonly buffer Defs { Reaction recs[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint n_records;
	float dt;
	// *(Slot 3 held `uint raining` until 2026-08-10 — a GLOBAL boolean that suppressed dust loft over the
	// WHOLE PLANET whenever it rained anywhere, so a rain shower pinned the dust down in a desert on the far
	// side of the world. Its own comment called it "dust_loft raining flag parity", i.e. parity with a
	// kernel that had already been deleted. It was also REDUNDANT: the same record carries GATE_DRY, which
	// tests THIS cell's own water, and a wet cell not lofting is the actual physics. Kept as a pad so the
	// 32-byte layout is unchanged.)*
	uint pad_was_raining;
	float sun_x;    // world-space vector TOWARD the sun; MAGNITUDE carries insolation (same value ThermalPass
	float sun_y;    // hands heat3d_solar_sphere3d, so light and heat are driven by ONE quantity)
	float sun_z;
	// Pascals of lithostatic pressure per unit of (mass x density) in the column above — i.e. g times the model
	// metres one cell represents. ReactionsPass derives it from the field's own vertical scale (the same
	// GROUNDWATER_CIRCULATION_M / REGOLITH_CELLS the geotherm uses), so it re-derives at any grid resolution
	// and nobody types a depth. Replaces a spare pad.
	float overburden_pa;
} params;

// REAL per-cell insolation — the LIGHT slot. Identical to the solar kernel's term, so the terminator that
// warms the day side is the SAME terminator that feeds the plants; no proxy, no second sun model.
float light_at(uint i) {
	uint rb = i * 3u;
	vec3 cell_radial = vec3(radial[rb + 0u], radial[rb + 1u], radial[rb + 2u]);
	return max(0.0, dot(cell_radial, vec3(params.sun_x, params.sun_y, params.sun_z)));
}

// ROOTING-COLUMN water. `soil` lives in REGOLITH cells, so an open cell's plant-available water is the soil
// summed over the permeable column beneath it: walk INWARD (slot 0) while the cell is REGOLITH, at most
// REGOLITH_CELLS deep (below that is impermeable bedrock, which soil_sphere3d leaves inert anyway).
//
// WALK THE REGOLITH MASK, NOT THE SOLID MASK — they diverge, and the divergence made FAKE DESERTS. `solid` is
// re-derived from rock_fill every step (SolidDerivePass), while `regolith` is seeded once at world-gen and
// never updated, so any cell that erosion, a MineralStamp3D shrink or world-gen river carving has opened is
// `solid = 0` with `regolith = 1`. soil_sphere3d.glsl:223 keys on regolith, so such a cell KEEPS its soil and
// keeps being simulated as aquifer, while a solid-masked walk broke BEFORE counting it and the plant above read
// a drier column than it stands on. Emergent desert formation is what the photosynthesis work exists to
// produce, so a spurious desert is the one failure that looks exactly like the intended result.
//
// WHAT THIS DOES AND DOES NOT RECOVER — be precise, because the obvious reading overstates it. The walk still
// STOPS at that opened cell; it just counts it first. It does not carry on into the shells below, and it must
// not: an opened aquifer cell whose own inward neighbour is solid is itself a GATE_NEAR_GROUND rooting cell,
// so the column beneath it belongs to the plant standing IN it, not to the one on the ledge above. Every
// regolith cell therefore still has exactly one owner. The gain per affected column is one shell of soil, and
// since carving and erosion cut from the surface DOWN while the water table sits on the bedrock floor
// (measured root_d1 0.00026, root_d2 0.00024, root_d3 0.137, root_d4 0.422), that shell is usually a dry one.
// Whether this moves the dryness statistics at all is an empirical question, which is why the mirror gauge
// LAMaterialFieldPhotoStats3D reports root_col_open_frac / root_col_open_soil: measure it, do not assume it.
//
// RACE-FREEDOM (this is the ONE place the engine touches a cell other than its own, so the argument matters).
// The walk INCLUDES the first open cell it reaches and then STOPS there. Every reacting cell is itself open,
// so for any two reacting cells A (outer) and B (inner) in one column, A's walk either halts before reaching B
// or reaches B, counts it, and halts — either way A covers only cells strictly outward of B, and B covers only
// cells strictly inward of itself. The columns are DISJOINT by construction, exactly as before, and this is
// the step that keeps them so: without the stop-on-open rule the regolith walk would run straight THROUGH an
// opened aquifer cell into a column another thread is already writing.
// The FIRST regolith cell beneath an open cell, or -1. Race-free for writes: the inward-neighbour mapping is
// injective, so no two reacting cells share one, and the column below it still belongs to root_soil's walk.
int top_regolith(uint i) {
	int c = nbr[i * 6u + 0u];
	if (c < 0 || regolith[c] == 0.0) {
		return -1;
	}
	return c;
}


float root_soil(uint i) {
	float sum = 0.0;
	int c = nbr[i * 6u + 0u];
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		sum += soil[uint(c)];
		if (solid[c] == 0.0) {
			break;                          // an OPEN aquifer cell terminates the walk (see RACE-FREEDOM above)
		}
		c = nbr[uint(c) * 6u + 0u];
	}
	return sum;
}

// Draw `amount` of water out of the rooting column, taken from each cell in proportion to what it holds (roots
// drink where the water is). Exactly conserving: the fractions sum to `amount`, and `amount` is already capped
// at the column total by the reactant cap, so no cell can go negative.
//
// The walk MUST mirror root_soil()'s cell-for-cell — same regolith test, same stop-on-open — or the fraction
// `f` is computed over one set of cells and applied to another, which both breaks conservation and breaks the
// disjointness that makes the write race-free.
void root_soil_draw(uint i, float amount) {
	if (amount <= 0.0) {
		return;
	}
	float total = root_soil(i);
	if (total <= 0.0) {
		return;
	}
	float f = min(amount / total, 1.0);
	int c = nbr[i * 6u + 0u];
	for (int k = 0; k < REGOLITH_CELLS; k++) {
		if (c < 0 || regolith[c] == 0.0) {
			break;
		}
		soil[uint(c)] = max(0.0, soil[uint(c)] * (1.0 - f));
		if (solid[c] == 0.0) {
			break;
		}
		c = nbr[uint(c) * 6u + 0u];
	}
}

// LITHOSTATIC PRESSURE of the column above, in pascals — the OVERBURDEN slot. Walk radially OUTWARD summing
// the SOLID mass (bedrock at rock density, sediment at sediment density) and convert with params.overburden_pa,
// which carries g times the model metres one cell stands for.
//
// ONLY SOLID MASS COUNTS. That is Terzaghi's effective-stress principle, not an omission: pore fluid carries
// its own weight and does not compact the grain framework, so the ocean over a seabed does not lithify it.
//
// THE RACE HERE IS HARMLESS BY CONSTRUCTION, and that is worth stating rather than assuming. This reads
// neighbours' `sediment` and `rock_fill` while other threads may be writing their own — but every record that
// touches those two channels moves mass BETWEEN them in ONE cell (weathering rock->sediment, lithification
// sediment->rock), and this sum is over rock+sediment, so their own writes leave it invariant. What can move
// it are M4 loft (sediment->dust) and M3 settle (susp->sediment), whose per-step extents are ~1e-2 against an
// overburden sum of order 4 — under a percent, and not a systematic direction.
float overburden(uint i) {
	float m = 0.0;
	int c = nbr[i * 6u + 5u];
	for (int k = 0; k < OVERBURDEN_MAX_CELLS; k++) {
		if (c < 0) {
			break;
		}
		// `rock_fill` is a matrix SATURATION, so the mineral actually present is rock_fill * (1 - phi).
		// Terzaghi effective stress counts the SOLID weight only (LAPhysical's lithification note says so
		// outright), which is why the pore water is correctly absent — but the pore VOLUME was being weighed
		// as if it were basalt, overstating the shallowest few kilometres of every column by ~1/(1-phi).
		// porosity[] is 0 outside regolith, so this is unchanged for bedrock.
		m += rock_fill[uint(c)] * (1.0 - clamp(porosity[uint(c)], 0.0, 1.0)) * ROCK_DENSITY
			+ sediment[uint(c)] * SEDIMENT_DENSITY;
		c = nbr[uint(c) * 6u + 5u];
	}
	return m * params.overburden_pa;
}

// The bedrock of the cell directly BENEATH this open one — the BEDROCK_BELOW slot. Returns 0 when there is no
// inward neighbour or it is not rock, so a record that forgets GATE_NEAR_GROUND simply gets nothing rather
// than reaching into open air. Race-free because nbr[c*6+0] == c-1 is a bijection within a column: each bed
// cell is the down-neighbour of exactly one open cell (the same argument erosion_pickup_sphere3d.glsl uses).
float bedrock_below(uint i) {
	int d = nbr[i * 6u + 0u];
	if (d < 0 || solid[d] == 0.0) {
		return 0.0;
	}
	return rock_fill[uint(d)];
}

void bedrock_below_add(uint i, float v) {
	int d = nbr[i * 6u + 0u];
	if (d < 0 || solid[d] == 0.0) {
		return;
	}
	rock_fill[uint(d)] = max(0.0, rock_fill[uint(d)] + v);
}

// See the RC_* block above. Air, rock (bedrock plus whatever is molten) and liquid water by volume fraction.
// A CELL'S VOLUMETRIC HEAT CAPACITY — one definition, shared by every kernel that books heat.
// Must sit below the buffer declarations: the include is textual and binds rock_fill/lava/water/snow/
// fuel/biomass/detritus by NAME.
#include "rc_shared.glsli"

// Resolve a channel slot to its per-cell value. Unbound slots read 0 (a record must not reference them).
float read_ch(int slot, uint i) {
	if (slot == TEMP)     return temp[i];
	if (slot == WATER)    return water[i];
	if (slot == MOISTURE) return moisture[i];
	if (slot == O2)       return o2[i];
	if (slot == CO2)      return co2[i];
	if (slot == FUEL)     return fuel[i];
	if (slot == DETRITUS) return detritus[i];
	if (slot == FUNGUS)   return fungus[i];
	if (slot == FERT)     return fert[i];
	if (slot == BIOMASS)  return biomass[i];
	if (slot == SNOW)     return snow[i];
	if (slot == SEDIMENT) return sediment[i];
	if (slot == DUST)     return dust[i];
	if (slot == SUSP)     return susp[i];
	if (slot == WINDSPEED) return sqrt(vel_x[i] * vel_x[i] + vel_z[i] * vel_z[i]);
	if (slot == LAVA)     return lava[i];
	if (slot == ROCK_FILL) return rock_fill[i];
	if (slot == LIGHT)     return light_at(i);
	if (slot == SOIL_ROOT) return root_soil(i);
	if (slot == VAPOUR_DEFICIT) return sat_mass_frac(temp[i]) - moisture[i];
	if (slot == SOIL_TOP) { int c = top_regolith(i); return (c < 0) ? 0.0 : soil[uint(c)]; }
	if (slot == OVERBURDEN) return overburden(i);
	if (slot == BEDROCK_BELOW) return bedrock_below(i);
	if (slot == CARBONATE) return carbonate[i];
	if (slot == SILICA)    return silica[i];
	return 0.0;
}

// Add v to a channel slot (own cell). Mass channels clamp at 0. FUNGUS/LIGHT/unbound slots are not writable as
// SELF (fungus is produced by its own kernel; LIGHT is geometry) → no-op here. FERT is a real reactant (R19
// uptake debits it in place on its LIVE half — safe because its own diffuse/leach/decompose-deposit producer
// runs later this step in EcoSurfacePass, so this write is the freshest value by the time that kernel reads it,
// same one-step ordering already used for FUNGUS as a read-only driver). SOIL_ROOT is the one slot whose write
// lands outside this cell — into the private rooting column beneath it; see root_soil_draw for why that is
// still race-free. (That column may now include ONE open aquifer cell, which is itself a reacting thread; its
// own walk starts one cell further in, so the two never share a cell, and `soil` has no readable slot in
// read_ch, so nothing else reads what either of them writes.) SOIL was previously bound NOWHERE and had NO
// add_ch branch at all, so any write to it silently vanished; SOIL_ROOT is the branch that closes that hole.
void add_ch(int slot, uint i, float v) {
	if      (slot == TEMP)     { temp[i]     += v; }
	else if (slot == WATER)    { water[i]     = max(0.0, water[i] + v); }
	else if (slot == MOISTURE) { moisture[i] += v; }
	else if (slot == O2)       { o2[i]        = max(0.0, o2[i] + v); }
	else if (slot == CO2)      { co2[i]       = max(0.0, co2[i] + v); }
	else if (slot == FUEL)     { fuel[i]      = max(0.0, fuel[i]     + v); }   // combustion is fuel's only sink
	else if (slot == DETRITUS) { detritus[i]  = max(0.0, detritus[i] + v); }
	else if (slot == FERT)     { fert[i]      = max(0.0, fert[i] + v); }
	else if (slot == BIOMASS)  { biomass[i]   = max(0.0, biomass[i]  + v); }
	else if (slot == SNOW)     { snow[i]      = max(0.0, snow[i]     + v); }
	else if (slot == SEDIMENT) { sediment[i]  = max(0.0, sediment[i] + v); }
	else if (slot == DUST)     { dust[i]      = max(0.0, dust[i]     + v); }
	else if (slot == SUSP)     { susp[i]      = max(0.0, susp[i]     + v); }
	else if (slot == LAVA)     { lava[i]      = max(0.0, lava[i]     + v); }
	else if (slot == ROCK_FILL) { rock_fill[i] = max(0.0, rock_fill[i] + v); }  // may exceed 1.0 (accreted rock); clamp only at 0
	else if (slot == SOIL_ROOT) { root_soil_draw(i, -v); }                     // roots draw water OUT of the column (v < 0)
	else if (slot == SOIL_TOP)  { int c = top_regolith(i); if (c >= 0) { soil[uint(c)] = max(0.0, soil[uint(c)] + v); } }
	else if (slot == BEDROCK_BELOW) { bedrock_below_add(i, v); }               // weathering eats the outcrop it stands on
	else if (slot == CARBONATE) { carbonate[i] = max(0.0, carbonate[i] + v); } // D1b credits, D1c debits
	else if (slot == SILICA)    { silica[i]    = max(0.0, silica[i]    + v); }
}

// Gate helpers reuse the exact neighbour tests proven in the dissolved kernels.
bool gate_ok(int mask, uint i) {
	if (mask == 0) {
		return true;
	}
	if ((mask & GATE_SURFACE) != 0) {
		// SKY-EXPOSED surface = outermost open cell (outward-radial neighbour is space or rock). gas_sky:50-51.
		int up = nbr[i * 6u + 5u];
		bool is_surface = (up < 0) || (solid[up] != 0.0);
		if (!is_surface) {
			return false;
		}
	}
	if ((mask & GATE_OPEN_ABOVE) != 0) {
		int au = nbr[i * 6u + 5u];
		bool open_above = (au < 0) || (solid[au] == 0.0);
		if (!open_above) {
			return false;
		}
	}
	if ((mask & GATE_DRY) != 0) {
		if (water[i] > WET_MAX_LOFT) {
			return false;                   // wet sand / puddle never lofts (dust_loft:53 parity)
		}
	}
	if ((mask & GATE_FREEZING) != 0) {
		if (temp[i] >= WATER_FREEZE_C) {
			return false;                   // above the phase boundary the condensate is liquid, not ice
		}
	}
	if ((mask & GATE_NEAR_GROUND) != 0) {
		// GROUND-HUGGING: an open cell resting directly ON terrain (its INWARD neighbour, slot 0, is rock).
		// This is where a plant physically is, where snow deposits, and the surface the altitude lapse cools —
		// the same `ground_hug` set heat3d_solar_sphere3d already distinguishes. It is NOT the same set as
		// GATE_SURFACE, which on a shell is the TOP OF THE ATMOSPHERE (outward neighbour is space).
		int dn = nbr[i * 6u + 0u];
		if (dn < 0 || solid[dn] == 0.0) {
			return false;
		}
	}
	if ((mask & GATE_DAYLIGHT) != 0) {
		if (light_at(i) <= DAYLIGHT_MIN) {
			return false;                   // night side / grazing-incidence terminator
		}
	}
	if ((mask & GATE_AIR_ABOVE) != 0) {
		// FREE SURFACE: the outward-radial neighbour must be AIR — open rock-free and not itself drowned.
		// At the outward boundary (slot 5 == -1) the cell faces open space, which is air enough.
		int au = nbr[i * 6u + 5u];
		if (au >= 0 && (solid[au] != 0.0 || water[au] >= DROWNED_WATER)) {
			return false;
		}
	}
	return true;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cell_count) {
		return;
	}
	scratch[i] = 0.0;                       // reset per-cell SCRATCH each step (replaces fungus kernel's fert reset)
	fire[i] = 0.0;                          // the burning INSTRUMENT — assigned from this step's fuel loss below
	if (solid[i] != 0.0) {
		return;                             // reactions run in OPEN cells only
	}
	float fuel_before = fuel[i];            // combustion is fuel's only sink
	float o2_before = o2[i];                // the cell's USABLE-oxygen denominator for the fire instrument
	float o2_burn = 0.0;                    // ...and its NUMERATOR: oxygen drawn by COMBUSTION alone, summed below

	for (uint r = 0u; r < params.n_records; r++) {
		Reaction rc = recs[r];
		if (!gate_ok(rc.gate_mask, i)) {
			continue;
		}
		float drv = read_ch(rc.driver_slot, i);
		float x = 0.0;
		if (rc.rate_model == CONST_FRAC) {
			x = rc.rate_k * drv;
		} else if (rc.rate_model == BILINEAR) {
			x = rc.rate_k * drv * read_ch(rc.driver2_slot, i);
		} else if (rc.rate_model == EXCESS_OVER_THRESHOLD) {
			x = max(0.0, drv - rc.threshold) * rc.rate_k;
		} else if (rc.rate_model == DEFICIT_BELOW_THRESHOLD) {
			x = max(0.0, rc.threshold - drv) * rc.rate_k;   // mirror of EXCESS: fires when driver < threshold
		} else if (rc.rate_model == OPTIMUM_BAND) {
			// A rate that PEAKS in the middle and falls off BOTH ways: proportional to `driver`, modulated by a
			// parabolic band in `driver2` centred on `threshold` with half-width `param2`, clipped at 0 outside.
			// The four threshold models above can only express monotone "more is more" or "less is more"; this is
			// the shape any process with an OPTIMUM needs (enzyme kinetics, a comfort range, a melt band), which
			// is exactly why temperature got misused as a linear driver before it existed.
			float v = read_ch(rc.driver2_slot, i);
			float t = (v - rc.threshold) / max(rc.param2, 1e-6);
			x = rc.rate_k * drv * max(0.0, 1.0 - t * t);
		} else if (rc.rate_model == ARRHENIUS) {
			// The temperature law of chemistry: rate rises exponentially with T at a rate set by the measured
			// activation energy in `threshold` (Ea/R, kelvin), referenced to `param2` (the temperature k is
			// quoted at). First order in `driver` and, when it names a slot, in `driver2`.
			//
			// THE CEILING IS THE PHYSICS OF A PHASE, AND IT BELONGS TO THE RECORD. An AQUEOUS reaction needs
			// liquid water, so D1b stops climbing at water's boiling point rather than extrapolating solution
			// chemistry into a cell with no solution in it. That was written HERE as a literal until
			// 2026-08-09, which applied WATER's boiling point to every Arrhenius record there will ever be —
			// and would have capped combustion at 100 C, where cellulose does not pyrolyse at all. A record
			// with `t_ceiling_k == 0` describes no such phase and gets no ceiling.
			float conc2 = (rc.driver2_slot >= 0) ? read_ch(rc.driver2_slot, i) : 1.0;
			float t_k = temp[i] + KELVIN_0;
			if (rc.t_ceiling_k > 0.0) {
				t_k = min(t_k, rc.t_ceiling_k);
			}
			float t_ref = max(rc.param2, 1.0);
			x = rc.rate_k * drv * conc2 * exp(-rc.threshold * (1.0 / max(t_k, 1.0) - 1.0 / t_ref));
		}
		// An UNKNOWN rate model now yields x = 0 and the record simply does nothing. It used to fall through
		// to RELAX_TARGET, so a typo'd model id became an unbounded source of whatever channel it named.

		if (x <= 0.0) {
			continue;
		}
		// Reactant caps: the extent can't drive any reactant (or the aux cap) negative.
		//
		// THIS BLOCK IS NOW UNCONDITIONAL, and that is the fix. It used to be wrapped in
		// `if (rc.rate_model != RELAX_TARGET)`, so ONE rate model skipped the cap and the debit entirely and
		// ran only the product credit below. That is matter from nothing by construction, and two shipped
		// records used it: R11 pinned O2 and R12 pinned CO2 at the top of the atmosphere. R12 was the origin
		// of every carbon atom that ever existed in this simulation.
		//
		// THE QUENCH IS A FLOOR ON ONE REACTANT, and it is a different statement from the cap around it. The
		// cap says an extent cannot outrun its supply. The quench says a reaction stops before its supply is
		// gone: a flame goes out below the limiting oxygen concentration and leaves most of the oxygen in the
		// room behind it, which is why a fire in a sealed space self-extinguishes and why an anoxic planet
		// cannot burn. Written as a gate on the concentration it would only bind on the NEXT step, and a cell
		// could still take its air to zero in this one — so it is the amount of that species the reaction is
		// not allowed to touch. See LAReactionDefs.
		for (int k = 0; k < rc.n_react; k++) {
			float coeff = max(rc.react_coeff[k], 1e-6);
			float avail = read_ch(rc.react_slot[k], i);
			if (rc.react_slot[k] == rc.quench_slot) {
				avail = max(0.0, avail - rc.quench_min);
			}
			x = min(x, avail / coeff);
		}
		if (rc.cap_slot >= 0) {
			x = min(x, read_ch(rc.cap_slot, i) / max(rc.cap_coeff, 1e-6));
		}
		if (x <= 0.0) {
			continue;
		}
		// ATTRIBUTION FOR THE BURNING INSTRUMENT, and it has to happen HERE, inside the loop, against THIS
		// record. `rc.driver_slot == FUEL` identifies combustion uniquely: R26 in CombustionRecords.gd is the
		// only record in the whole table driven by FUEL, and add_ch calls fuel "combustion's only sink" for
		// the same reason. This is a snapshot of a channel around one record's application — NOT a read of
		// `rc` after the loop, which is the mistake documented at the bottom of this file that melted the
		// planet. `rc` is live and correct on this line.
		bool is_combustion = (rc.driver_slot == FUEL);
		float o2_pre_rec = is_combustion ? o2[i] : 0.0;

		for (int k = 0; k < rc.n_react; k++) {
			add_ch(rc.react_slot[k], i, -rc.react_coeff[k] * x);
		}

		for (int k = 0; k < rc.n_prod; k++) {
			if (rc.prod_target[k] == TGT_SCRATCH) {
				scratch[i] += rc.prod_coeff[k] * x;
			} else {
				add_ch(rc.prod_slot[k], i, rc.prod_coeff[k] * x);
			}
		}

		if (is_combustion) {
			o2_burn += max(0.0, o2_pre_rec - o2[i]);
		}

		// THE ENTHALPY, and it is an ENERGY rather than a mass coefficient for a reason: how hot a cell gets
		// depends on ITS OWN heat capacity, so the same combustion raises dry air thousands of kelvin and a
		// waterlogged cell tens. That is where "a damp fuel resists lighting" comes from here — the water is in
		// rc_of, not in a gate. `temp` is a DEGREES channel, which is why this cannot be a TEMP product (the
		// balance gate refuses one); see LAReactionDefs on what this leaves open in the energy books.
		if (rc.enthalpy_j_m3 != 0.0) {
			temp[i] += rc.enthalpy_j_m3 * x / max(rc_of(i), 1.0);
		}
	}

	// THE BURNING INSTRUMENT. `fire` is not a state any more: a cell is burning if its combustion RATE is
	// high, which is derived, exactly as cloud is derived from moisture against saturation. It is read by the
	// gauges (`fire_cells` / `fire_peak` / `is_burning`) and, as of 2026-08-09, BY NO PHYSICS ANYWHERE —
	// fungus_sphere3d.glsl was the last mechanism gating on it and that gate is deleted.
	if (fuel_before > 0.0) {
		// FIRE IS THE FRACTION OF THIS CELL'S USABLE OXYGEN THAT COMBUSTION CONSUMED THIS STEP.
		//
		// Usable means above the flammability limit — the concentration below which a flame goes out however
		// hot it is (LAPhysical.LIMITING_OXYGEN_CONCENTRATION_FRAC, ~15 vol% for cellulosic fuel, which in
		// this channel's units of ambient air is 0.716). So 1.0 means "burning as hard as this cell's air
		// allows", which is what an intensity should mean and what a threshold on it can test.
		//
		// *(Corrected three times, and the third is the one that mattered. It was first
		// `(fuel_before - fuel) / fuel_before`, which the oxygen cap bounds at 3.2e-3 against the 0.02 that
		// MaterialFieldQueries3D.FIRE_PRESENT calls burning — so every fire gauge would have read "nothing
		// is alight" through an entire burn, and a well-stocked fire read LOWER than an exhausted one. The
		// second repair read the coefficients off `rc` AFTER the record loop, where `rc` holds whichever
		// record ran last rather than combustion; that wrote garbage into a channel fungus_sphere3d gated
		// spread on, and the planet melted — magma_cells 3 -> 191, lava_cells 1 -> 425, snow and biomass to
		// zero. The third took the WHOLE STEP's oxygen delta, `o2_before - o2[i]`, which is not combustion:
		// R15 decomposition and respiration draw oxygen too, so ordinary rot read as fire. Since
		// fungus_sphere3d gated on this, a decomposer suppressed itself by decomposing. The numerator is now
		// attributed per record, inside the loop, to the one record whose driver is FUEL.)*
		float o2_usable = max(0.0, o2_before - O2_FLAMMABILITY_LIMIT);
		fire[i] = (o2_usable > 0.0) ? clamp(o2_burn / o2_usable, 0.0, 1.0) : 0.0;
	}
}
