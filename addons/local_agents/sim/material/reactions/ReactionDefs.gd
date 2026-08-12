class_name LAReactionDefs
extends RefCounted

## the product targets, and the record authoring + std430 serialisation. It holds no records itself.

# --- Channel slot enum -------------------------------------------------------------------------------------
const TEMP: int = 0
# H2O — ONE channel for the substance in every phase. Solid / liquid / vapour are DERIVED per cell from the
# enthalpy ladder, so no record may move mass between phases.
const H2O: int = 1
const O2: int = 3
const CO2: int = 4
# DETRITUS (LAReactionBalance.SLOT_SUBSTANCE maps all four to `cellulose`). CombustionRecords.gd oxidises it.
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
# DERIVED driver only: the saturation amount at this cell's temperature minus the vapour it actually holds,
# both as a volume fraction of the cell. Positive = unsaturated air.
const VAPOUR_DEFICIT: int = 20
# SOIL_TOP is the shallow DRYING FRONT: the pore water of the first regolith cell beneath an open cell. Roots reach
# the whole rooting column (SOIL_ROOT above); evaporation does not, because vapour has to diffuse out through
# the pores and the water below the surface layer is simply out of reach. DERIVED, WRITABLE.
const SOIL_TOP: int = 21
const BEDROCK_BELOW: int = 23
const CARBONATE: int = 24             # CaCO3 — where weathered carbon goes, and the only place it can go
const SILICA: int = 25                # SiO2 — the weathering residue; nothing weathers it further
const N2: int = 26                    # dinitrogen, 78.084% of the air by mole — the planet's nitrogen reservoir
# DISCHARGE is the electrostatic energy (J/m^3) a lightning return stroke released in this cell THIS step,
# stamped by LAMaterialFieldInject3D.deplete_charge. DRIVER ONLY — it is energy, not matter, so it is in
# LAReactionBalance.driver_only() and may never be a reactant or a product.
const DISCHARGE: int = 27
# DEAD ORGANIC MATTER IS THREE STOCKS, NOT ONE FORMULA. DETRITUS and FUEL carry its CARBON; ORG_H and ORG_O
# carry the hydrogen and oxygen bound in that same pool. All three hold LASubstances.ORGANIC_MOL_PER_M3 moles
const ORG_H: int = DISCHARGE + 1
const ORG_O: int = ORG_H + 1
const ORG_C: int = ORG_O + 1          # DERIVED driver only: DETRITUS + FUEL, the pool the ratios divide by
# DERIVED driver only: the LIQUID share of the cell's h2o. A solvent is liquid water, not ice and not vapour.
const H2O_LIQUID: int = ORG_C + 1
# NOTE: the slot enum and the kernel's BINDING numbers alias only up to 26. Bindings 24/25/26 are already
# convenience, never a contract; `check_kernel()` verifies the #define VALUES, which is the thing that matters.

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const RM_CONST_FRAC: int = 0             # x = k * driver
const RM_BILINEAR: int = 1               # x = k * driver * driver2
const RM_EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k   (fires when driver is ABOVE threshold)
const RM_DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k  (fires when driver is BELOW threshold)
#   x = k * driver * max(0, 1 - ((driver2 - threshold) / param2)^2)
const RM_OPTIMUM_BAND: int = 5
#   x = k * driver * driver2 * exp(-(Ea/R) * (1/T_K - 1/T_ref_K))
# Reads temperature from the TEMP channel directly rather than through a slot.
const RM_ARRHENIUS: int = 6
# TWO RESISTANCES IN SERIES across an interface: conductance g = driver2 / (1 + param2 * driver2), so
#   x = k * driver * driver2 / (1 + param2 * driver2)
const RM_RESISTANCE_SERIES: int = 7

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
                                      # TOP OF THE ATMOSPHERE — correct for sky gas exchange, wrong for ground.
const GATE_NEAR_GROUND: int = 4       # GROUND-HUGGING open cell (INWARD nbr is rock) — where a plant, a snowpack
const GATE_FREEZING: int = 32         # cell temp below LAPhysical.WATER_FREEZE_C. Deposition needs it: the
                                      # condensate driver says HOW MUCH water is out of solution, not which
                                      # phase it lands in, and above 0 C that condensate is rain, not snow.
const GATE_AIR_ABOVE: int = 128       # THE FREE SURFACE — the air/liquid interface. True when the OUTWARD radial
                                      # `static` cells that are deliberately never simulated (MaterialField3D
                                      # ._seed_sphere_sea), so per-cell chemistry there is meaningless.
const GATE_BURIED: int = GATE_AIR_ABOVE * 2   # ALSO runs in SOLID cells. Everything else is open-cell only;
                                      # coalification is not, because buried organic matter is inside rock.

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

# --- Record layout ---------------------------------------------------------------------------------------
const RECORD_BYTES: int = 240         # std430 size of one Reaction (see layout in serialize())

# --- THE ONE LENGTH SCALE A RECORD MAY NEED ----------------------------------------------------------------
static var cell_size_m: float = 16.0


static func rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0,
		cap_slot: int = -1, cap_coeff: float = 0.0, t_ceiling_k: float = 0.0,
		enthalpy_j_m3: float = 0.0, quench_slot: int = -1, quench_min: float = 0.0,
		enthalpy_h_j_m3: float = 0.0, enthalpy_o_j_m3: float = 0.0) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"cap_slot": cap_slot, "cap_coeff": cap_coeff, "t_ceiling_k": t_ceiling_k,
		"enthalpy_j_m3": enthalpy_j_m3, "quench_slot": quench_slot, "quench_min": quench_min,
		"enthalpy_h_j_m3": enthalpy_h_j_m3, "enthalpy_o_j_m3": enthalpy_o_j_m3,
		"reactants": reactants, "products": products,
	}


## The composition-scaled parts of one participant's coefficient. Reactant entries are [slot, base, h, o];
## product entries are [slot, base, target, h, o]; both fall back to 0 when the entry is the short form.
static func comp_parts(entry: Array, is_product: bool) -> Vector2:
	var at: int = 3 if is_product else 2
	var h: float = float(entry[at]) if entry.size() > at else 0.0
	var o: float = float(entry[at + 1]) if entry.size() > at + 1 else 0.0
	return Vector2(h, o)


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (144 bytes, 16-aligned):
## scalars and scalar arrays, so std430's array stride is the struct size and 144 is already 16-aligned.
static func serialize(recs: Array) -> PackedByteArray:
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(recs.size() * RECORD_BYTES)
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var base: int = r * RECORD_BYTES
		var reactants: Array = rec.get("reactants", [])
		var products: Array = rec.get("products", [])
		buf.encode_s32(base + 0, int(rec.get("rate_model", RM_CONST_FRAC)))
		buf.encode_float(base + 4, float(rec.get("rate_k", 0.0)))
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
		buf.encode_float(base + 128, float(rec.get("enthalpy_j_m3", 0.0)))
		buf.encode_s32(base + 132, int(rec.get("quench_slot", -1)))
		buf.encode_float(base + 136, float(rec.get("quench_min", 0.0)))
		buf.encode_s32(base + 140, 0)
		# Direction from thermodynamics (LAReactionThermo). q_slot < 0 = no equilibrium, record is one-way.
		buf.encode_float(base + 144, float(rec.get("dg_h_j_mol", 0.0)))
		buf.encode_float(base + 148, float(rec.get("dg_s_j_molk", 0.0)))
		buf.encode_s32(base + 152, int(rec.get("q_slot", -1)))
		buf.encode_float(base + 156, float(rec.get("q_pa_per_unit_k", 0.0)))
		for k in range(4):
			var rs: int = int(reactants[k][0]) if k < reactants.size() else -1
			var rc: float = float(reactants[k][1]) if k < reactants.size() else 0.0
			buf.encode_s32(base + 48 + k * 4, rs)
			buf.encode_float(base + 64 + k * 4, rc)
		for k in range(4):
			var ps: int = -1
			var pc: float = 0.0
			var pt: int = TGT_SELF
			if k < products.size():
				ps = int(products[k][0])
				pc = float(products[k][1])
				pt = int(products[k][2]) if products[k].size() > 2 else TGT_SELF
			buf.encode_s32(base + 80 + k * 4, ps)
			buf.encode_float(base + 96 + k * 4, pc)
			buf.encode_s32(base + 112 + k * 4, pt)
		# The composition-scaled halves of every coefficient (see comp_parts): 160 reactant-h, 176 reactant-o,
		# 192 product-h, 208 product-o, then the two enthalpy scalings. Zero everywhere = a constant record.
		for k in range(4):
			var rp: Vector2 = comp_parts(reactants[k], false) if k < reactants.size() else Vector2.ZERO
			buf.encode_float(base + 160 + k * 4, rp.x)
			buf.encode_float(base + 176 + k * 4, rp.y)
			var pp: Vector2 = comp_parts(products[k], true) if k < products.size() else Vector2.ZERO
			buf.encode_float(base + 192 + k * 4, pp.x)
			buf.encode_float(base + 208 + k * 4, pp.y)
		buf.encode_float(base + 224, float(rec.get("enthalpy_h_j_m3", 0.0)))
		buf.encode_float(base + 228, float(rec.get("enthalpy_o_j_m3", 0.0)))
		buf.encode_s32(base + 232, 0)
		buf.encode_s32(base + 236, 0)
	return buf
