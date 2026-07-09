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
// The reactions run AFTER Atmosphere in the sphere pipeline, so temp/water/o2/co2/airwater are all in their
// settled post-step buffers (one-step coupling lag is the accepted norm — MaterialSphereGPU3D.gd:19-20).
// ReactionsPass binds o2/co2/temp/water/airwater to their BACK (producer-output) halves and fungus to its
// LIVE half (its producer runs later), so each read is the freshest value available at this slot.

layout(local_size_x = 64) in;

// --- Reactable channels (binding == slot for the resolved ones; see read_ch/add_ch) -----------------------
layout(set = 0, binding = 0, std430) restrict buffer Temp     { float temp[]; };
layout(set = 0, binding = 1, std430) restrict buffer Water    { float water[]; };
layout(set = 0, binding = 2, std430) restrict buffer AirWater { float airwater[]; };
layout(set = 0, binding = 3, std430) restrict buffer O2       { float o2[]; };
layout(set = 0, binding = 4, std430) restrict buffer CO2      { float co2[]; };
layout(set = 0, binding = 7, std430) restrict buffer Detritus { float detritus[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Fungus { float fungus[]; };
layout(set = 0, binding = 11, std430) restrict buffer Biomass { float biomass[]; };    // living plant matter (photosynthesis grows it, respiration/decay oxidizes it)
layout(set = 0, binding = 12, std430) restrict buffer Snow { float snow[]; };          // frozen H₂O (freeze credits it, melt debits it) — SAME substance as water/airwater
// --- MINERAL phases (rock unification): loose sediment, airborne dust, waterborne suspension. Loft (M4) moves
// SEDIMENT→DUST own-cell; settle (M3) moves SUSP→SEDIMENT own-cell — same conserved mineral substance. ---------
layout(set = 0, binding = 13, std430) restrict buffer Sediment { float sediment[]; };  // loose granular regolith
layout(set = 0, binding = 14, std430) restrict buffer Dust { float dust[]; };           // airborne wind-lofted dust
layout(set = 0, binding = 16, std430) restrict buffer Susp { float susp[]; };           // waterborne suspended sediment
layout(set = 0, binding = 17, std430) restrict readonly buffer VelX { float vel_x[]; }; // horizontal wind (WINDSPEED driver)
layout(set = 0, binding = 18, std430) restrict readonly buffer VelZ { float vel_z[]; };
// --- Gate inputs + scratch product target + the record table ----------------------------------------------
layout(set = 0, binding = 10, std430) restrict readonly buffer Solid { float solid[]; };
layout(set = 0, binding = 15, std430) restrict readonly buffer Neigh { int nbr[]; };        // idx*6 + slot
layout(set = 0, binding = 20, std430) restrict buffer Scratch { float scratch[]; };         // SCRATCH product target (fungus_fert)

// Slot enum — MUST match MaterialReactions3D.gd.
#define TEMP     0
#define WATER    1
#define AIRWATER 2
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

#define WET_MAX_LOFT 0.05   // water mass above which a surface is WET and can't loft dust (dust_loft parity)

#define CONST_FRAC             0
#define BILINEAR               1
#define EXCESS_OVER_THRESHOLD  2
#define RELAX_TARGET           3
#define DEFICIT_BELOW_THRESHOLD 4   // mirror of EXCESS: fires when driver is BELOW threshold (freeze at T<FREEZE_TEMP)

#define GATE_OPEN_ABOVE  1
#define GATE_SURFACE     2
#define GATE_NEAR_GROUND 4
#define GATE_DAYLIGHT    8
#define GATE_DRY         16   // cell is DRY (water <= WET_MAX_LOFT) — sand only lofts when not wet
#define GATE_NOT_RAINING 32   // global precipitation is off (params.raining == 0) — rain pins ALL dust down

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
	int   pad0;
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
} params;

// Resolve a channel slot to its per-cell value. Unbound slots read 0 (a record must not reference them).
float read_ch(int slot, uint i) {
	if (slot == TEMP)     return temp[i];
	if (slot == WATER)    return water[i];
	if (slot == AIRWATER) return airwater[i];
	if (slot == O2)       return o2[i];
	if (slot == CO2)      return co2[i];
	if (slot == DETRITUS) return detritus[i];
	if (slot == FUNGUS)   return fungus[i];
	if (slot == BIOMASS)  return biomass[i];
	if (slot == SNOW)     return snow[i];
	if (slot == SEDIMENT) return sediment[i];
	if (slot == DUST)     return dust[i];
	if (slot == SUSP)     return susp[i];
	if (slot == WINDSPEED) return sqrt(vel_x[i] * vel_x[i] + vel_z[i] * vel_z[i]);
	return 0.0;
}

// Add v to a channel slot (own cell). Mass channels clamp at 0. FUNGUS/FERT/unbound slots are not writable
// as SELF (FERT is a SCRATCH-only product; fungus is produced by its own kernel) → no-op here.
void add_ch(int slot, uint i, float v) {
	if      (slot == TEMP)     { temp[i]     += v; }
	else if (slot == WATER)    { water[i]     = max(0.0, water[i] + v); }
	else if (slot == AIRWATER) { airwater[i] += v; }
	else if (slot == O2)       { o2[i]        = max(0.0, o2[i] + v); }
	else if (slot == CO2)      { co2[i]       = max(0.0, co2[i] + v); }
	else if (slot == DETRITUS) { detritus[i]  = max(0.0, detritus[i] + v); }
	else if (slot == BIOMASS)  { biomass[i]   = max(0.0, biomass[i]  + v); }
	else if (slot == SNOW)     { snow[i]      = max(0.0, snow[i]     + v); }
	else if (slot == SEDIMENT) { sediment[i]  = max(0.0, sediment[i] + v); }
	else if (slot == DUST)     { dust[i]      = max(0.0, dust[i]     + v); }
	else if (slot == SUSP)     { susp[i]      = max(0.0, susp[i]     + v); }
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
	// NEAR_GROUND / DAYLIGHT: no live record needs them yet (would require radial+sun_dir bindings).
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
