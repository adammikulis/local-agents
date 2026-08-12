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
const LAVA: int = 10
const BIOMASS: int = 11
const SEDIMENT: int = 13
const DUST: int = 14
const SUSP: int = 15
const WINDSPEED: int = 16             # derived driver only: speed tangential to the local vertical, m/s
const ROCK_FILL: int = 17             # fractional bedrock mineral mass
const LIGHT: int = 18                 # derived driver only
const SOIL_ROOT: int = 19
const VAPOUR_DEFICIT: int = 20        # derived driver only: saturation minus held vapour, volume fraction
const SOIL_TOP: int = 21              # derived, writable: pore water of the first regolith cell below
const OVERBURDEN: int = 22
const BEDROCK_BELOW: int = 23
const CARBONATE: int = 24             # CaCO3
const SILICA: int = 25                # SiO2
const N2: int = 26
const DISCHARGE: int = 27             # driver only: lightning energy released this step, J/m^3
const ORG_H: int = DISCHARGE + 1      # hydrogen bound in the dead organic pool
const ORG_O: int = ORG_H + 1          # oxygen bound in the dead organic pool
const ORG_C: int = ORG_O + 1          # derived driver only: DETRITUS + FUEL
const H2O_LIQUID: int = ORG_C + 1     # derived driver only: liquid share of the cell's h2o

# --- Rate models
const RM_CONST_FRAC: int = 0             # x = k * driver
const RM_BILINEAR: int = 1               # x = k * driver * driver2
const RM_EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k
const RM_DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k
const RM_OPTIMUM_BAND: int = 5           # x = k * driver * max(0, 1 - ((driver2 - threshold) / param2)^2)
const RM_ARRHENIUS: int = 6              # x = k * driver * driver2 * exp(-(Ea/R) * (1/T_K - 1/T_ref_K))
const RM_RESISTANCE_SERIES: int = 7      # x = k * driver * driver2 / (1 + param2 * driver2)

# --- Gate bitflags
const GATE_NEAR_GROUND: int = 4       # open cell whose inward neighbour is rock
const GATE_DRY: int = 16              # cell water <= WET_MAX_LOFT
const GATE_FREEZING: int = 32         # cell temp below LAPhysical.WATER_FREEZE_C
const GATE_AIR_ABOVE: int = 128       # outward radial neighbour is air
const GATE_BURIED: int = GATE_AIR_ABOVE * 2   # also runs in solid cells

# --- Product targets
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer

# --- Record layout
const RECORD_BYTES: int = 240         # std430 size of one Reaction

# Cell height in metres, set from the grid before the record table is built. 0 means unset.
static var cell_size_m: float = 0.0


## Cell height in metres. Returns 0.0 and names the absence when nothing set it.
static func cell_height_m() -> float:
	if cell_size_m <= 0.0:
		push_error("LAReactionDefs.cell_size_m unset — a flux-derived rate has no layer to spread through")
		return 0.0
	return cell_size_m


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


## Serialize the records into a std430 SSBO byte buffer, RECORD_BYTES per record.
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
		# q_slot < 0 = no equilibrium, record is one-way.
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
		# Composition-scaled coefficient halves: 160 reactant-h, 176 reactant-o, 192/208 product.
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
