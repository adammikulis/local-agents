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
layout(set = 0, binding = 26, std430) restrict readonly buffer Static { float static_cells[]; }; // 1 = infinite sea/lake reservoir
// AQUIFER PERMEABILITY MASK (1 = groundwater-bearing regolith). The mask root_soil() walks — soil lives here,
// not "wherever the rock is solid". Bound at 27, past the end of the slot-alias range (bindings 0..26 shadow
// the slot enum, and 5/6/19 stay reserved for FUEL/FIRE/SOIL_ROOT), because regolith is not a reactable
// channel. Same buffer + same declaration ActivityPass binds at activity_sphere3d.glsl:58.
layout(set = 0, binding = 27, std430) restrict readonly buffer Regolith { float regolith[]; };

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

#define WET_MAX_LOFT 0.05   // water mass above which a surface is WET and can't loft dust (dust_loft parity)
#define REGOLITH_CELLS 4    // rooting depth = the permeable regolith band (MUST match MaterialField3D.REGOLITH_CELLS)
#define DAYLIGHT_MIN 0.02   // insolation above which GATE_DAYLIGHT considers a cell to be in daylight

#define CONST_FRAC             0
#define BILINEAR               1
#define EXCESS_OVER_THRESHOLD  2
#define RELAX_TARGET           3
#define DEFICIT_BELOW_THRESHOLD 4   // mirror of EXCESS: fires when driver is BELOW threshold (freeze at T<FREEZE_TEMP)
#define OPTIMUM_BAND           5    // x = k * driver * max(0, 1 - ((driver2 - threshold)/param2)^2) — a rate that
                                    // PEAKS at an optimum and falls off BOTH ways. See MaterialReactions3D.gd.

#define GATE_OPEN_ABOVE  1
#define GATE_SURFACE     2
#define GATE_NEAR_GROUND 4
#define GATE_DAYLIGHT    8
#define GATE_DRY         16   // cell is DRY (water <= WET_MAX_LOFT) — sand only lofts when not wet
#define GATE_NOT_RAINING 32   // global precipitation is off (params.raining == 0) — rain pins ALL dust down
#define GATE_NOT_STATIC  64   // cell is NOT an infinite static reservoir (the sea/lake abstraction, which carries
                              // water=1 and is deliberately not simulated) — real per-cell chemistry only

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
	int   pad1;
	int   react_slot[4];
	float react_coeff[4];
	int   prod_slot[4];
	float prod_coeff[4];
	int   prod_target[4];
};

layout(set = 0, binding = 21, std430) restrict readonly buffer Defs { Reaction recs[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	uint n_records;
	float dt;
	uint raining;   // 1 = precipitation on → GATE_NOT_RAINING records (dust loft) are suppressed globally
	float sun_x;    // world-space vector TOWARD the sun; MAGNITUDE carries insolation (same value ThermalPass
	float sun_y;    // hands heat3d_solar_sphere3d, so light and heat are driven by ONE quantity)
	float sun_z;
	float pad0;
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
// keeps being simulated as aquifer — but a solid-masked walk broke at it and threw away every shell BELOW it
// too. The water is deep (measured root_d1 0.00026, root_d2 0.00024, root_d3 0.137, root_d4 0.422), so a break
// in the top two shells discards essentially the whole aquifer and the plant reads bone-dry ground sitting on
// a full water table. Emergent desert formation is what the photosynthesis work exists to produce, so a
// spurious desert is the one failure that looks exactly like the intended result.
//
// RACE-FREEDOM (this is the ONE place the engine touches a cell other than its own, so the argument matters).
// The walk INCLUDES the first open cell it reaches and then STOPS there. Every reacting cell is itself open,
// so for any two reacting cells A (outer) and B (inner) in one column, A's walk either halts before reaching B
// or reaches B, counts it, and halts — either way A covers only cells strictly outward of B, and B covers only
// cells strictly inward of itself. The columns are DISJOINT by construction, exactly as before, and this is
// the step that keeps them so: without the stop-on-open rule the regolith walk would run straight THROUGH an
// opened aquifer cell into a column another thread is already writing.
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

// Resolve a channel slot to its per-cell value. Unbound slots read 0 (a record must not reference them).
float read_ch(int slot, uint i) {
	if (slot == TEMP)     return temp[i];
	if (slot == WATER)    return water[i];
	if (slot == MOISTURE) return moisture[i];
	if (slot == O2)       return o2[i];
	if (slot == CO2)      return co2[i];
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
	if ((mask & GATE_NOT_RAINING) != 0) {
		if (params.raining != 0u) {
			return false;                   // rain pins ALL dust down globally (dust_loft raining flag parity)
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
	if ((mask & GATE_NOT_STATIC) != 0) {
		if (static_cells[i] != 0.0) {
			return false;                   // the infinite sea/lake reservoir is an abstraction, not real chemistry
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
	if (solid[i] != 0.0) {
		return;                             // reactions run in OPEN cells only
	}

	for (uint r = 0u; r < params.n_records; r++) {
		Reaction rc = recs[r];
		if (!gate_ok(rc.gate_mask, i)) {
			continue;
		}
		float drv = read_ch(rc.driver_slot, i);
		float x;
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
		} else {                            // RELAX_TARGET — signed, no reactant, product = driver channel
			x = rc.rate_k * (rc.threshold - drv);
		}

		if (rc.rate_model != RELAX_TARGET) {
			if (x <= 0.0) {
				continue;
			}
			// Reactant caps: the extent can't drive any reactant (or the aux cap) negative.
			for (int k = 0; k < rc.n_react; k++) {
				float coeff = max(rc.react_coeff[k], 1e-6);
				x = min(x, read_ch(rc.react_slot[k], i) / coeff);
			}
			if (rc.cap_slot >= 0) {
				x = min(x, read_ch(rc.cap_slot, i) / max(rc.cap_coeff, 1e-6));
			}
			if (x <= 0.0) {
				continue;
			}
			for (int k = 0; k < rc.n_react; k++) {
				add_ch(rc.react_slot[k], i, -rc.react_coeff[k] * x);
			}
		}

		for (int k = 0; k < rc.n_prod; k++) {
			if (rc.prod_target[k] == TGT_SCRATCH) {
				scratch[i] += rc.prod_coeff[k] * x;
			} else {
				add_ch(rc.prod_slot[k], i, rc.prod_coeff[k] * x);
			}
		}
	}
}
