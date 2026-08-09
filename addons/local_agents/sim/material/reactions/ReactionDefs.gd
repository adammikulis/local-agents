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
# VAPOUR_DEFICIT is the PHASE RULE, and it is the only thing in this substrate that decides how much water
# air holds: `sat(T) - moisture`, where sat is LAPhysical.saturation_mass_fraction — the Clausius-Clapeyron
# saturation vapour density expressed in the field's own cell-fill unit. It is SIGNED, and its sign is the
# phase: positive means the air is unsaturated and liquid in contact with it evaporates; negative means the
# air is supersaturated and the excess is suspended condensate (cloud), which is what precipitation removes.
#
# ONE driver, so ONE rule covers the sea, a puddle, wet soil and a snowbank — they differ only in which
# reservoir the record names as its reactant. It REPLACES atmos_evap_sphere3d.glsl entirely (deleted), along
# with EVAP_RATE, EVAP_WARM_K, EVAP_TEMP_REF, EVAP_COND_CEIL, the humidity brake, the separate BOIL_TEMP
# branch and AtmospherePass's MOIST_TARGET = 0.11 "avg moisture/cell the atmosphere settles at" — a target
# humidity is not a fact, and it was what actually bounded this planet's sky water.
# DERIVED driver only; never a product or reactant target.
const VAPOUR_DEFICIT: int = 20
# SOIL_TOP is the shallow DRYING FRONT: the soil of the first regolith cell beneath an open cell. Roots reach
# the whole rooting column (SOIL_ROOT above); evaporation does not, because vapour has to diffuse out through
# the pores and the water below the surface layer is simply out of reach. DERIVED, WRITABLE.
const SOIL_TOP: int = 21
# OVERBURDEN is the LITHOSTATIC PRESSURE (Pa) of the SOLID column above this cell — the weight of the rock and
# sediment burying it. DERIVED and READ-ONLY, computed in the kernel by walking radially outward and summing
# (rock_fill * rock density + sediment * sediment density), converted to pascals by g times the model metres a
# cell represents (ReactionsPass supplies that scalar). Only SOLID mass counts: by Terzaghi's effective-stress
# principle the pore fluid carries its own weight and does not compact the grain framework, so the ocean above
# a seabed does not lithify it. This is the driver lithification needs, and the substrate's `pressure` channel
# is NOT it — that one is the weight of the AIR (wind_pressure_sphere3d), six orders of magnitude smaller and
# an answer to a different question.
const OVERBURDEN: int = 22
# BEDROCK_BELOW is the bedrock of the SOLID cell directly beneath this open one — DERIVED, and WRITABLE.
#
# It exists because a surface process has no rock in its own cell to work on. Reactions run in OPEN cells only
# (the engine skips solid cells so every write is own-cell and race-free) and `rock_fill` is seeded 1.0/0.0
# from solidity, so an open cell's own ROCK_FILL is zero almost everywhere. The rock that weathering attacks is
# the cell it stands on, and this slot is how a record reaches it.
#
# RACE-FREEDOM, and it is stronger than SOIL_ROOT's: the radial neighbour table is a bijection within a column
# (nbr[c*6+0] == c-1), so each solid bed cell is the DOWN-neighbour of EXACTLY ONE open cell and no two threads
# can ever address the same rock_fill entry. erosion_pickup_sphere3d.glsl already makes this exact cross-cell
# move for river scour and rests on the same argument. A record using this slot should gate GATE_NEAR_GROUND,
# which is what guarantees the cell below is rock at all.
const BEDROCK_BELOW: int = 23
# --- THE TWO NON-SILICATE MINERAL SPECIES (2026-08-08) -----------------------------------------------------
# Every mineral phase above is ONE species — calcium silicate, CaSiO3 — and it has to be, because they all
# exchange mass with each other at 1:1 and nothing in a transfer may change composition: LAVA <-> ROCK_FILL
# (M5/M6), BEDROCK_BELOW -> SEDIMENT (D1a), SEDIMENT -> ROCK_FILL (D2), SEDIMENT <-> DUST (M4 + the transport
# kernel's leeward deposit), SUSP -> SEDIMENT (M3) and ROCK_FILL -> SUSP (erosion pickup). Those five phases
# are one connected component under composition-preserving transfers, so they carry one composition.
#
# The Urey reaction CaSiO3 + CO2 -> CaCO3 + SiO2 has two products that are NOT that species, and a channel
# holds one composition, so each needs a channel of its own. TWO new channels, and two is the minimum: fewer
# is impossible (the reaction has two distinct non-silicate products) and more would be a channel with no
# record. There is deliberately no `dust_carbonate`, no `susp_silica` and no limestone BEDROCK phase — no
# record in this table lofts, scours, settles or melts either species, and a channel nothing writes is a
# channel that lies about what the substrate models. What that omits is stated in GeoRecords.gd.
#
# Both are OWN-CELL stocks in the near-ground open cell where weathering happens, exactly as loose SEDIMENT
# is. They do not advect: the weathering rind and the carbonate crust stay on the outcrop that made them.
const CARBONATE: int = 24             # CaCO3 — where weathered carbon goes, and the only place it can go
const SILICA: int = 25                # SiO2 — the weathering residue; nothing weathers it further
# NOTE: the slot enum and the kernel's BINDING numbers alias only up to 26. Bindings 24/25/26 are already
# Soil/Radial/Static, so these two slots bind at 28 and 29 in reactions_sphere3d.glsl. The alias was always a
# convenience, never a contract; `check_kernel()` verifies the #define VALUES, which is the thing that matters.

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
# ARRHENIUS is the temperature law of CHEMISTRY, and it is the shape none of the five above can express: a
# rate that rises EXPONENTIALLY with temperature at a rate set by a measured activation energy.
#   x = k * driver * driver2 * exp(-(Ea/R) * (1/T_K - 1/T_ref_K))
# `threshold` carries Ea/R in kelvin, `param2` carries the reference temperature T_ref in kelvin (the
# temperature the rate constant k is quoted at), `driver` and `driver2` are the concentrations the reaction is
# first order in (driver2_slot < 0 means "no second concentration", i.e. treat it as 1). Temperature is read
# from the TEMP channel directly rather than through a slot, because Arrhenius is BY DEFINITION about
# temperature and letting a record point it elsewhere would only invite a mistake.
#
# It was added for silicate dissolution (chemical weathering), where the alternative was another monotone
# threshold model standing in for a real rate law — which is how the record it replaced ended up with a
# backwards temperature sign and a fitted constant. Every reaction rate in nature has this shape; nothing
# about it is specific to rock.
#
# THE AQUEOUS CEILING IS PHYSICS, NOT A CLAMP. The kernel evaluates the exponential at min(T, water's boiling
# point) because a reaction between rock and LIQUID WATER cannot proceed where there is no liquid water. The
# substrate agrees: atmos_evap_sphere3d flashes water to steam at LAPhysical.WATER_BOIL_C. Without it, an
# extrapolation to a 154 C lava-adjacent cell asks for a rate 1000x the reference and the record dissolves a
# whole bedrock cell in one step, which is an artefact of extrapolating a law past the phase it describes.
const ARRHENIUS: int = 6

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
const GATE_AIR_ABOVE: int = 128       # THE FREE SURFACE — the air/liquid interface. True when the OUTWARD radial
                                      # neighbour exists, is not rock, and is not itself drowned (water below
                                      # half a cell). It is what makes a phase change happen at the TOP of a
                                      # water column rather than throughout it: a submerged cell has no air in
                                      # contact with it and cannot evaporate, however dry the sky is. Promoted
                                      # from atmos_evap_sphere3d.glsl's `open_above` test when that kernel was
                                      # dissolved — it was never an evaporation detail, it is where any
                                      # liquid/gas exchange can occur, and the next such record gets it free.
const GATE_NOT_STATIC: int = 64       # NOT an infinite static reservoir cell. The sea/lake is seeded as water=1
                                      # `static` cells that are deliberately never simulated (MaterialField3D
                                      # ._seed_sphere_sea), so per-cell chemistry there is meaningless.

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 128         # std430 size of one Reaction (see layout in serialize())

# --- THE ONE LENGTH SCALE A RECORD MAY NEED ----------------------------------------------------------------
# A rate derived from a real physical FLUX (per square metre per second) becomes a per-cell, per-step extent
# only once you know how tall a cell is and how long a step is. The step is already derived once for the whole
# substrate (LAMaterialFieldSphereStep3D.real_seconds_per_step); the cell height is grid geometry, so
# LAMaterialSphereGPU3D writes it here from `_grid.cell_size` immediately before it builds the record table.
# The default is the shipped sphere's cell size, so a headless caller that never sets it still gets the right
# order of magnitude rather than a divide-by-zero.
static var cell_size_m: float = 16.0


## Author one record as a Dictionary (unspecified fields default to the ungated/no-op values). Reactant and
## product entries are Arrays of [slot, coeff] (products carry an optional 3rd element = target, default SELF).
##
## `cap_slot` / `cap_coeff` are the AUXILIARY CAP: an extra ceiling `x <= read_ch(cap_slot) / cap_coeff` that
## limits the extent by a channel the reaction does not consume. It is for a CAPACITY rather than a supply —
## frost weathering uses it to say that only the POROSITY fraction of the bedrock beneath can hold pore water,
## so only that much can freeze in a step however cold it gets, even though the rock itself is not the thing
## being used up at that ratio. (The kernel and serialize() have always supported it; `rec()` had no parameters
## for it, so no record could ever author one. Wired up 2026-08-03.)
##
## --- `enthalpy_j_m3` — THE ENERGY A REACTION COSTS, AND THE ONE CONVENTION FOR ITS SIGN --------------------
## Every phase change moves mass between two states of one substance and every one of them costs or releases a
## measured enthalpy. Until 2026-08-07 exactly one was charged anywhere in this substrate — vaporisation at the
## boiling point, in heat3d_cool_sphere3d.glsl, at a rate that "MUST match atmos_evap_sphere3d.glsl", a file
## that had already been deleted. So the kernel charged heat for a transfer it did not perform while R23
## performed a transfer it did not charge for, and freeze, melt, sublimation, deposition and basalt
## crystallisation all ran for free. Heat appeared from nothing at every one of them.
##
## SIGN: POSITIVE IS ENDOTHERMIC. This is the ordinary chemical convention for a reaction enthalpy ΔH —
## positive means the reaction ABSORBS heat from its surroundings, so THE CELL COOLS. The kernel applies
##     temp[i] -= x * enthalpy_j_m3 / rc_of(i)
## so evaporation, melting, sublimation and rock melting carry a POSITIVE enthalpy and condensation, freezing,
## deposition and crystallisation carry a NEGATIVE one. Every forward/reverse pair must be equal and opposite
## or the substrate has a temperature ratchet: if evaporation cools and condensation never warms, the planet
## cools without bound.
##
## UNITS: VOLUMETRIC, J per cubic metre of the substance moved (rho_substance x H), NOT per kilogram. A record
## is authored as an explicit product of the two facts, e.g.
##     LAPhysical.WATER_DENSITY_KG_M3 * LAPhysical.LATENT_HEAT_VAPORISATION_J_KG
## Volumetric because the extent `x` is in CELL-FILL units and the kernel divides by the cell's volumetric heat
## capacity (J/m³/K), so the cell size cancels on both sides and no length scale is needed — and because the
## record has exactly one spare field, so it cannot also carry a density. A per-slot density table in the
## kernel would be a second place for the same fact to live, which is how the freezing point of water ended up
## declared in five files at three values.
##
## TEMP IS STILL NOT A PRODUCT. LAReactionBalance refuses TEMP as a reactant or a product — "a record that
## produces degrees is not a reaction" — and that gate stays exactly as it was. Enthalpy is a SEPARATE field
## precisely because the temperature change depends on the receiving cell's heat capacity, which is a property
## of the cell rather than a stoichiometric coefficient.
static func rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1, param2: float = 0.0,
		cap_slot: int = -1, cap_coeff: float = 0.0, enthalpy_j_m3: float = 0.0) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot, "param2": param2,
		"cap_slot": cap_slot, "cap_coeff": cap_coeff, "enthalpy_j_m3": enthalpy_j_m3,
		"reactants": reactants, "products": products,
	}


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (128 bytes, 16-aligned):
##   0 rate_model(i) 4 rate_k(f) 8 threshold(f) 12 gate_mask(i) | 16 driver_slot(i) 20 driver2_slot(i)
##   24 cap_slot(i) 28 cap_coeff(f) | 32 n_react(i) 36 n_prod(i) 40 param2(f) 44 enthalpy_j_m3(f) |
##   48 react_slot[4](i) | 64 react_coeff[4](f) | 80 prod_slot[4](i) | 96 prod_coeff[4](f) | 112 prod_target[4](i)
## The record had two spare pads. OPTIMUM_BAND claimed offset 40 as `param2` (its band half-width) and
## `enthalpy_j_m3` now claims the last one at 44, so the record stays exactly 128 bytes and every existing
## offset is untouched. THERE ARE NO PADS LEFT: the next field needs a stride change here and a matching
## `struct Reaction` change in reactions_sphere3d.glsl, and the two must be edited together.
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
		buf.encode_float(base + 44, float(rec.get("enthalpy_j_m3", 0.0)))
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
