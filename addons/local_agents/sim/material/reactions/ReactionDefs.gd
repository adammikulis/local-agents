class_name LAReactionDefs
extends RefCounted

## The DEFS reaction engine's VOCABULARY: the channel slot enum, the rate models, the gate bitflags,
## the product targets, and the record authoring + std430 serialisation. It holds no records itself.
##
## Every per-domain record module EXTENDS this, so a record line can name `RELAX_TARGET`, `GATE_SURFACE`
## and `rec(...)` unqualified — the table reads exactly as it did when it was one file. The registry that
## composes the modules is LAMaterialReactions3D.
##
## Split out 2026-08-03. One flat `records()` in one file was the serialization bottleneck for the whole
## 0.4 planet effort: the nitrogen, carbon and geology workstreams all had to edit the same function, so
## they could not run as concurrent one-owner units. Splitting by DOMAIN is what makes them parallel.

# --- Channel slot enum (MUST match the #defines in reactions_sphere3d.glsl) --------------------------------
const TEMP: int = 0
const WATER: int = 1
const MOISTURE: int = 2
const O2: int = 3
const CO2: int = 4
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
# DERIVED slots — computed in the kernel from geometry it already has, so they cost no buffer, no upload and no
# readback (WINDSPEED was the first of these; these two are the same idea).
# LIGHT is REAL per-cell insolation, max(0, dot(cell_radial, sun_dir)) — the exact term
# heat3d_solar_sphere3d.glsl uses for the terminator, with sun_dir's MAGNITUDE carrying intensity (orbit
# distance² × atmospheric transmission). One sun drives the temperature field and the chemistry.
const LIGHT: int = 18                 # DERIVED driver only; never a product/reactant target
# SOIL_ROOT is the plant-available water of the ROOTING COLUMN: the `soil` channel summed over the permeable
# regolith cells directly beneath an open cell. It has to be a column, not the cell itself, because
# soil_sphere3d.glsl writes soil = 0 for every OPEN cell — subsurface water only ever exists in regolith rock,
# so reading `soil` at the reacting cell reads a structural zero, not a dry world. Writable (transpiration
# draws from it, proportionally to what each cell holds); see the kernel's root_soil/root_soil_draw.
const SOIL_ROOT: int = 19

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const CONST_FRAC: int = 0             # x = k * driver
const BILINEAR: int = 1               # x = k * driver * driver2
const EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k   (fires when driver is ABOVE threshold)
# 3 IS RETIRED AND MUST STAY UNUSED. It was RELAX_TARGET — "x = k * (threshold - driver); signed; NO
# REACTANT; product = driver" — and that definition is a description of matter appearing from nothing.
# reactions_sphere3d.glsl skipped its whole cap-and-debit block, so only the product credit ever ran. Two
# records used it (R11 pinning O₂ and R12 pinning CO₂ at the top of the atmosphere) and R12 was the origin of
# every carbon atom that has ever existed in this simulation: +6.5 units per field step, `carbon_total` grown
# from 720 to ~5820 over a 600-frame run. Both records and the model are deleted. The planet now starts with
# a real finite atmosphere at Earth's measured composition (LAPhysical.AIR_MOLE_FRAC_*), so "relax toward
# ambient" has nothing left to do: the air above a cell genuinely holds the gas, and moving it there is an
# ordinary conserving transfer that o2_transport/co2_transport already perform.
# The number stays burned rather than reused so an old serialised table cannot silently mean something new.
const DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k  (fires when driver is BELOW threshold)
# DEFICIT_BELOW_THRESHOLD is the mirror of EXCESS_OVER_THRESHOLD: it fires when the driver is BELOW the
# threshold instead of above it, so a single scalar driver (temperature) can drive a reaction in BOTH
# directions. EXCESS handles "when hot/wet/high" (melt at T>MELT_TEMP); DEFICIT handles "when cold/dry/low"
# (freeze at T<FREEZE_TEMP). Both still cap the extent by their reactants, so they stay mass-conserving
# transfers — the ONLY difference is the sign of (driver − threshold). Any future "when cold/dry/low"
# reaction (frost, dew, condensation onto a cold surface) reuses this without a new kernel.
# OPTIMUM_BAND is the shape none of the four above can express: a rate that PEAKS in the middle and falls off in
# BOTH directions. All four threshold models are monotone — "more is more" (EXCESS) or "less is more" (DEFICIT) —
# so anything with a best value in the middle had no way to be written as a record. That gap is exactly why
# TEMPERATURE ended up as a linear driver on photosynthesis: a linear driver was the only way to make warmth
# matter, and it says a hotter cell always fixes more carbon, right through boiling.
#   x = k * driver * max(0, 1 - ((driver2 - threshold) / param2)^2)
# `driver` is the thing being scaled (light, a concentration, a flow); `driver2` is the variable with an
# optimum; `threshold` is the optimum; `param2` is the half-width, i.e. the distance from the optimum at which
# the rate reaches zero. Deliberately a general substrate capability, not a plant rule — enzyme kinetics, a
# creature's comfort range, a melt/refreeze band and a habitability window are all this same shape.
const OPTIMUM_BAND: int = 5

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_OPEN_ABOVE: int = 1
const GATE_SURFACE: int = 2           # OUTERMOST open cell (outward nbr is space/rock). On a shell that is the
                                      # TOP OF THE ATMOSPHERE — correct for sky gas exchange, wrong for ground.
const GATE_NEAR_GROUND: int = 4       # GROUND-HUGGING open cell (INWARD nbr is rock) — where a plant, a snowpack
                                      # and the altitude lapse all actually are. Distinct set from GATE_SURFACE.
const GATE_DAYLIGHT: int = 8          # insolation above DAYLIGHT_MIN (the lit hemisphere). NO RECORD USES THIS,
                                      # and that is deliberate rather than an oversight: R19 drives on LIGHT
                                      # directly, so a dark cell already yields x = 0 with no gate needed, and a
                                      # hard daylight cutoff would replace that smooth falloff with a seam at the
                                      # terminator. The bit and its kernel branch are kept because they are a
                                      # correct, tested implementation that a future THRESHOLD record (something
                                      # that must not fire at all below an insolation floor) can use — but if you
                                      # are reaching for it to gate a rate, drive on LIGHT instead.
const GATE_DRY: int = 16              # cell water <= WET_MAX_LOFT (dry surface) — sand only lofts when not wet
const GATE_NOT_RAINING: int = 32      # global precipitation off — rain pins all dust down (loft parity)
const GATE_NOT_STATIC: int = 64       # NOT an infinite static reservoir cell. The sea/lake is seeded as water=1
                                      # `static` cells that are deliberately never simulated (MaterialField3D
                                      # ._seed_sphere_sea), so per-cell chemistry there is meaningless.

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 128         # std430 size of one Reaction (see layout in serialize())


## Author one record as a Dictionary (unspecified fields default to the ungated/no-op values). Reactant and
## product entries are Arrays of [slot, coeff] (products carry an optional 3rd element = target, default SELF).
static func rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"reactants": reactants, "products": products,
	}


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (128 bytes, 16-aligned):
##   0 rate_model(i) 4 rate_k(f) 8 threshold(f) 12 gate_mask(i) | 16 driver_slot(i) 20 driver2_slot(i)
##   24 cap_slot(i) 28 cap_coeff(f) | 32 n_react(i) 36 n_prod(i) 40 param2(f) 44 pad |
##   48 react_slot[4](i) | 64 react_coeff[4](f) | 80 prod_slot[4](i) | 96 prod_coeff[4](f) | 112 prod_target[4](i)
## Offset 40 was one of two spare pads; OPTIMUM_BAND claims it as `param2` (its band half-width), so the record
## stays exactly 128 bytes and every existing offset is untouched. One pad remains at 44 for the next model.
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
		buf.encode_s32(base + 44, 0)
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
