class_name LAReactionDefs
extends RefCounted

## Channel slots, rate models, gates, product targets and std430 record serialisation.

# --- Channel slot enum
const TEMP: int = 0
const H2O: int = 1
const O2: int = 3
const CO2: int = 4
const FUEL: int = 5
const FIRE: int = 6
const DETRITUS: int = 7
const FUNGUS: int = 8
const FERT: int = 9
# SILICATE — ONE channel; melt and suspended shares are DERIVED, so no record moves mass between them.
const SILICATE: int = 10
const BIOMASS: int = 11
const WINDSPEED: int = 16             # DERIVED driver only: speed TANGENTIAL to the local vertical, m/s
const LIGHT: int = 18                 # DERIVED driver only; never a product/reactant target
const SOIL_ROOT: int = 19
# Derived driver only: sat(T) minus the vapour held, mol/m^3. Positive = unsaturated.
const VAPOUR_DEFICIT: int = 20
# Drying front: pore water of the first regolith cell under an open one. Derived, writable.
const SOIL_TOP: int = 21
const BEDROCK_BELOW: int = 23
const CARBONATE: int = 24             # CaCO3
const SILICA: int = 25                # SiO2
const N2: int = 26
const DISCHARGE: int = 27             # driver only: lightning energy released this step, J/m^3
const ORG_H: int = DISCHARGE + 1      # hydrogen bound in the dead organic pool
const ORG_O: int = ORG_H + 1          # oxygen bound in the dead organic pool
const ORG_C: int = ORG_O + 1          # derived driver only: DETRITUS + FUEL
const H2O_LIQUID: int = ORG_C + 1     # derived driver only: liquid share of the cell's h2o
# The differentiated planet's phases. No record consumes them yet; the slots carry their composition.
const METAL: int = H2O_LIQUID + 1
const OLIVINE: int = METAL + 1
const PYROXENE: int = OLIVINE + 1
const PLAGIOCLASE: int = PYROXENE + 1
const HALITE: int = PLAGIOCLASE + 1
const APATITE: int = HALITE + 1
# The 4.4 Ga atmosphere's minor gases: volcanic outgassing and abiotic CH4. No record consumes them yet.
const H2: int = APATITE + 1
const CO: int = H2 + 1
const SO2: int = CO + 1
const H2S: int = SO2 + 1
const CH4: int = H2S + 1
# Derived driver only: the bedrock surface under an open cell that its liquid wets, m^2 per m^3 of cell.
const ROCK_SURFACE_WET: int = CH4 + 1

# --- Rate models
const RM_CONST_FRAC: int = 0             # x = k * driver
const RM_BILINEAR: int = 1               # x = k * driver * driver2
const RM_EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k
const RM_DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k
const RM_OPTIMUM_BAND: int = 5           # x = k * driver * driver2 * max(0, 1 - ((T_c - threshold) / param2)^2)
const RM_ARRHENIUS: int = 6              # x = k * driver * driver2 * exp(-(Ea/R) * (1/T_K - 1/T_ref_K))
const RM_RESISTANCE_SERIES: int = 7      # x = k * driver * driver2 / (1 + param2 * driver2)

# --- Rate units. Extent is mol/m^3 per dispatch; a record declares k_units and k_timebase against its
# model, gated by scripts/check_reaction_rate_units.sh. RM_ARRHENIUS appends driver2^-1 when driver2 is set.
const TB_PER_SECOND: String = "per_real_second"   # serialize() folds the step quantum, ONCE
const TB_PER_STEP: String = "per_step"
const RATE_K_UNITS: Dictionary = {
	RM_CONST_FRAC: "mol m^-3 driver^-1", RM_BILINEAR: "mol m^-3 driver^-1 driver2^-1",
	RM_EXCESS_OVER_THRESHOLD: "mol m^-3 driver^-1", RM_DEFICIT_BELOW_THRESHOLD: "mol m^-3 driver^-1",
	RM_OPTIMUM_BAND: "mol m^-3 driver^-1 driver2^-1", RM_ARRHENIUS: "mol m^-3 driver^-1",
	RM_RESISTANCE_SERIES: "mol m^-3 driver^-1 driver2^-1",
}

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_NEAR_GROUND: int = 4       # open cell whose inward neighbour is rock
const GATE_FREEZING: int = 32         # cell temp below LAPhysical.WATER_FREEZE_C
const GATE_AIR_ABOVE: int = 128       # free surface: outward neighbour open, rock-free, not drowned
const GATE_BURIED: int = GATE_AIR_ABOVE * 2   # ALSO runs in SOLID cells; everything else is open-cell only

# --- Record layout
const RECORD_BYTES: int = 224         # std430 size of one Reaction
const MAX_RECORDS: int = 24           # kernel-side extent array bound; ReactionsPass refuses a larger table

# Cell height in metres, set from the grid before the record table is built. 0 means unset.
static var cell_size_m: float = 0.0


## Cell height in metres. Returns 0.0 and names the absence when nothing set it.
static func cell_height_m() -> float:
	if cell_size_m <= 0.0:
		push_error("LAReactionDefs.cell_size_m unset — a flux-derived rate has no layer to spread through")
		return 0.0
	return cell_size_m


# `quench_min` is a MOLE FRACTION of the cell's gas; the kernel converts it against p/(R T) per cell.
static func rec(k_timebase: String, k_units: String, rate_model: int, rate_k: float, driver_slot: int,
		reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0,
		cap_slot: int = -1, cap_coeff: float = 0.0, t_ceiling_k: float = 0.0,
		enthalpy_j_mol: float = 0.0, quench_slot: int = -1, quench_min: float = 0.0,
		enthalpy_h_j_mol: float = 0.0, enthalpy_o_j_mol: float = 0.0) -> Dictionary:
	return {
		"k_timebase": k_timebase, "k_units": k_units,
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"cap_slot": cap_slot, "cap_coeff": cap_coeff, "t_ceiling_k": t_ceiling_k,
		"enthalpy_j_mol": enthalpy_j_mol, "quench_slot": quench_slot, "quench_min": quench_min,
		"enthalpy_h_j_mol": enthalpy_h_j_mol, "enthalpy_o_j_mol": enthalpy_o_j_mol,
		"reactants": reactants, "products": products,
	}


## The composition-scaled parts of one participant's coefficient. An entry is [slot, base, h, o],
## falling back to 0 when it is the short form.
static func comp_parts(entry: Array) -> Vector2:
	var h: float = float(entry[2]) if entry.size() > 2 else 0.0
	var o: float = float(entry[3]) if entry.size() > 3 else 0.0
	return Vector2(h, o)


## Serialize the records into a std430 SSBO byte buffer, RECORD_BYTES per record.
static func serialize(recs: Array) -> PackedByteArray:
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(recs.size() * RECORD_BYTES)
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var base: int = r * RECORD_BYTES
		var reactants: Array = rec.get("reactants", [])
		var products: Array = rec.get("products", [])
		# THE ONE PLACE the step quantum enters a rate; the kernel has no dt and record modules may not fold it.
		var k_folded: float = float(rec.get("rate_k", 0.0))
		if String(rec.get("k_timebase", "")) == TB_PER_SECOND:
			k_folded *= LAMaterialFieldSphereStep3D.seconds_per_step()
		buf.encode_s32(base + 0, int(rec.get("rate_model", RM_CONST_FRAC)))
		buf.encode_float(base + 4, k_folded)
		buf.encode_float(base + 8, float(rec.get("threshold", 0.0)))
		buf.encode_s32(base + 12, int(rec.get("gate_mask", 0)))
		buf.encode_s32(base + 16, int(rec.get("driver_slot", 0)))
		buf.encode_s32(base + 20, int(rec.get("driver2_slot", -1)))
		buf.encode_s32(base + 24, int(rec.get("cap_slot", -1)))
		buf.encode_float(base + 28, float(rec.get("cap_coeff", 0.0)))
		buf.encode_s32(base + 32, reactants.size())
		buf.encode_s32(base + 36, products.size())
		buf.encode_float(base + 40, float(rec.get("param2", 0.0)))
		buf.encode_float(base + 44, float(rec.get("t_ceiling_k", 0.0)))
		buf.encode_float(base + 112, float(rec.get("enthalpy_j_mol", 0.0)))
		buf.encode_s32(base + 116, int(rec.get("quench_slot", -1)))
		buf.encode_float(base + 120, float(rec.get("quench_min", 0.0)))
		buf.encode_s32(base + 124, 0)
		# q_slot < 0 = no equilibrium, record is one-way.
		buf.encode_float(base + 128, float(rec.get("dg_h_j_mol", 0.0)))
		buf.encode_float(base + 132, float(rec.get("dg_s_j_molk", 0.0)))
		buf.encode_s32(base + 136, int(rec.get("q_slot", -1)))
		buf.encode_float(base + 140, float(rec.get("dn_gas", 0.0)))
		for k in range(4):
			var rs: int = int(reactants[k][0]) if k < reactants.size() else -1
			var rc: float = float(reactants[k][1]) if k < reactants.size() else 0.0
			buf.encode_s32(base + 48 + k * 4, rs)
			buf.encode_float(base + 64 + k * 4, rc)
		for k in range(4):
			buf.encode_s32(base + 80 + k * 4, int(products[k][0]) if k < products.size() else -1)
			buf.encode_float(base + 96 + k * 4, float(products[k][1]) if k < products.size() else 0.0)
		# Composition-scaled coefficient halves: 144 reactant-h, 160 reactant-o, 176/192 product.
		for k in range(4):
			var rp: Vector2 = comp_parts(reactants[k]) if k < reactants.size() else Vector2.ZERO
			buf.encode_float(base + 144 + k * 4, rp.x)
			buf.encode_float(base + 160 + k * 4, rp.y)
			var pp: Vector2 = comp_parts(products[k]) if k < products.size() else Vector2.ZERO
			buf.encode_float(base + 176 + k * 4, pp.x)
			buf.encode_float(base + 192 + k * 4, pp.y)
		buf.encode_float(base + 208, float(rec.get("enthalpy_h_j_mol", 0.0)))
		buf.encode_float(base + 212, float(rec.get("enthalpy_o_j_mol", 0.0)))
		buf.encode_float(base + 216, float(rec.get("dn_gas_h", 0.0)))
		buf.encode_float(base + 220, float(rec.get("dn_gas_o", 0.0)))
	return buf
