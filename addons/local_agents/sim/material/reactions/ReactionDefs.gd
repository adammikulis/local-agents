class_name LAReactionDefs
extends RefCounted

## the product targets, and the record authoring + std430 serialisation. It holds no records itself.

# --- Channel slot enum (MUST match the #defines in reactions_sphere3d.glsl) --------------------------------
const TEMP: int = 0
const WATER: int = 1
const MOISTURE: int = 2
const O2: int = 3
const CO2: int = 4
# DETRITUS (LAReactionBalance.SLOT_SUBSTANCE maps all four to `cellulose`). It was declared here and in the
# kernel's #defines with NO branch in either switch-ladder, so it read 0 and any write to it vanished; the
# branches now and CombustionRecords.gd oxidises it.
const FUEL: int = 5
const FIRE: int = 6
const DETRITUS: int = 7
const FUNGUS: int = 8
const FERT: int = 9
const LAVA: int = 10
const BIOMASS: int = 11
const SNOW: int = 12                  # frozen H₂O (snowpack/ice) — the same conserved substance as WATER + MOISTURE
# MINERAL phases (rock unification): ONE conserved mineral substance, phase = state. loose SEDIMENT, airborne
# DUST, waterborne SUSP are channels; loft/settle are same-cell mass TRANSFERS between them (records below).
const SEDIMENT: int = 13
const DUST: int = 14
const SUSP: int = 15
const WINDSPEED: int = 16             # DERIVED driver only (sqrt(vel_x²+vel_z²)); never a product/reactant
# BEDROCK (rock unification Stage B): fractional bedrock mineral mass. `solid` is DERIVED (rock_fill >= 0.5). Molten
# LAVA and bedrock ROCK_FILL are the SAME mineral substance — M5 solidify + M6 melt are conserving own-cell transfers.
const ROCK_FILL: int = 17
const LIGHT: int = 18                 # DERIVED driver only; never a product/reactant target
const SOIL_ROOT: int = 19
# air holds: `sat(T) - moisture`, where sat is LAPhysical.saturation_mass_fraction — the Clausius-Clapeyron
# phase: positive means the air is unsaturated and liquid in contact with it evaporates; negative means the
const VAPOUR_DEFICIT: int = 20
# SOIL_TOP is the shallow DRYING FRONT: the soil of the first regolith cell beneath an open cell. Roots reach
# the whole rooting column (SOIL_ROOT above); evaporation does not, because vapour has to diffuse out through
# the pores and the water below the surface layer is simply out of reach. DERIVED, WRITABLE.
const SOIL_TOP: int = 21
const OVERBURDEN: int = 22
const BEDROCK_BELOW: int = 23
const CARBONATE: int = 24             # CaCO3 — where weathered carbon goes, and the only place it can go
const SILICA: int = 25                # SiO2 — the weathering residue; nothing weathers it further
# NOTE: the slot enum and the kernel's BINDING numbers alias only up to 26. Bindings 24/25/26 are already
# convenience, never a contract; `check_kernel()` verifies the #define VALUES, which is the thing that matters.

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const CONST_FRAC: int = 0             # x = k * driver
const BILINEAR: int = 1               # x = k * driver * driver2
const EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k   (fires when driver is ABOVE threshold)
const DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k  (fires when driver is BELOW threshold)
#   x = k * driver * max(0, 1 - ((driver2 - threshold) / param2)^2)
const OPTIMUM_BAND: int = 5
#   x = k * driver * driver2 * exp(-(Ea/R) * (1/T_K - 1/T_ref_K))
# from the TEMP channel directly rather than through a slot, because Arrhenius is BY DEFINITION about
# kernel used to evaluate every Arrhenius exponential at min(T, LAPhysical.WATER_BOIL_C), because a reaction
# WATER that had been baked into the rate law itself. The same constant applied to every future Arrhenius
const ARRHENIUS: int = 6

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_OPEN_ABOVE: int = 1
const GATE_SURFACE: int = 2           # OUTERMOST open cell (outward nbr is space/rock). On a shell that is the
                                      # TOP OF THE ATMOSPHERE — correct for sky gas exchange, wrong for ground.
const GATE_NEAR_GROUND: int = 4       # GROUND-HUGGING open cell (INWARD nbr is rock) — where a plant, a snowpack
                                      # and the altitude lapse all actually are. Distinct set from GATE_SURFACE.
const GATE_DAYLIGHT: int = 8          # insolation above DAYLIGHT_MIN (the lit hemisphere). NO RECORD USES THIS,
const GATE_DRY: int = 16              # cell water <= WET_MAX_LOFT (dry surface) — sand only lofts when not wet
# parity with the deleted dust_loft kernel, and redundant with GATE_DRY which tests the cell's own
# water.)*
const GATE_FREEZING: int = 32         # cell temp below LAPhysical.WATER_FREEZE_C. Deposition needs it: the
                                      # condensate driver says HOW MUCH water is out of solution, not which
                                      # phase it lands in, and above 0 C that condensate is rain, not snow.
                                      # Retires with the enthalpy channel, which derives phase from energy
                                      # and so has no phase branch to gate.
const GATE_AIR_ABOVE: int = 128       # THE FREE SURFACE — the air/liquid interface. True when the OUTWARD radial
                                      # `static` cells that are deliberately never simulated (MaterialField3D
                                      # ._seed_sphere_sea), so per-cell chemistry there is meaningless.

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 144         # std430 size of one Reaction (see layout in serialize())


# --- A RATE LAW'S TEMPERATURE CEILING (ARRHENIUS) ----------------------------------------------------------

# --- THE ONE LENGTH SCALE A RECORD MAY NEED ----------------------------------------------------------------
static var cell_size_m: float = 16.0


static func rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0,
		cap_slot: int = -1, cap_coeff: float = 0.0, t_ceiling_k: float = 0.0,
		enthalpy_j_m3: float = 0.0, quench_slot: int = -1, quench_min: float = 0.0) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"cap_slot": cap_slot, "cap_coeff": cap_coeff, "t_ceiling_k": t_ceiling_k,
		"enthalpy_j_m3": enthalpy_j_m3, "quench_slot": quench_slot, "quench_min": quench_min,
		"reactants": reactants, "products": products,
	}


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
		buf.encode_s32(base + 0, int(rec.get("rate_model", CONST_FRAC)))
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
	return buf
