class_name LAMaterialReactions3D
extends RefCounted

## DATA TABLE for the generic DEFS reaction engine (Phase B3 §2). Every hand-coded "clean same-cell"
## chemical/phase reaction on the sphere path (gas sky-exchange, CO₂ vent, fungus decompose, …) is expressed
## HERE as a fixed-size Reaction RECORD instead of a bespoke kernel. `reactions_sphere3d.glsl` loops these
## records per cell; ReactionsPass uploads them once as a read-only SSBO. Adding a future reaction is adding a
## record to `records()` — NOT writing a kernel. (dissolve-don't-patch: success = bespoke kernels deleted.)
##
## The kernel binds every reactable CHANNEL at a fixed binding and a record names a channel by a SLOT enum
## (below), resolved through the kernel's read_ch/add_ch switch-ladders. Only the channels the live records
## touch need be bound (o2/co2/detritus/fungus + the fungus-fert SCRATCH here); the ladder covers the rest so
## a later record can reference them by adding the one binding.

# --- Channel slot enum (MUST match the #defines in reactions_sphere3d.glsl) --------------------------------
const TEMP: int = 0
const WATER: int = 1
const AIRWATER: int = 2
const O2: int = 3
const CO2: int = 4
const FUEL: int = 5
const FIRE: int = 6
const DETRITUS: int = 7
const FUNGUS: int = 8
const FERT: int = 9
const LAVA: int = 10
const BIOMASS: int = 11
const SNOW: int = 12                  # frozen H₂O (snowpack/ice) — the same conserved substance as WATER + AIRWATER
# MINERAL phases (rock unification): ONE conserved mineral substance, phase = state. loose SEDIMENT, airborne
# DUST, waterborne SUSP are channels; loft/settle are same-cell mass TRANSFERS between them (records below).
const SEDIMENT: int = 13
const DUST: int = 14
const SUSP: int = 15
const WINDSPEED: int = 16             # DERIVED driver only (sqrt(vel_x²+vel_z²)); never a product/reactant

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const CONST_FRAC: int = 0             # x = k * driver
const BILINEAR: int = 1               # x = k * driver * driver2
const EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k   (fires when driver is ABOVE threshold)
const RELAX_TARGET: int = 3           # x = k * (threshold - driver)  (signed; no reactant; product = driver)
# DEFICIT_BELOW_THRESHOLD is the mirror of EXCESS_OVER_THRESHOLD: it fires when the driver is BELOW the
# threshold instead of above it, so a single scalar driver (temperature) can drive a reaction in BOTH
# directions. EXCESS handles "when hot/wet/high" (melt at T>MELT_TEMP); DEFICIT handles "when cold/dry/low"
# (freeze at T<FREEZE_TEMP). Both still cap the extent by their reactants, so they stay mass-conserving
# transfers — the ONLY difference is the sign of (driver − threshold). Any future "when cold/dry/low"
# reaction (frost, dew, condensation onto a cold surface) reuses this without a new kernel.
const DEFICIT_BELOW_THRESHOLD: int = 4  # x = max(0, threshold - driver) * k  (fires when driver is BELOW threshold)

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_OPEN_ABOVE: int = 1
const GATE_SURFACE: int = 2
const GATE_NEAR_GROUND: int = 4
const GATE_DAYLIGHT: int = 8
const GATE_DRY: int = 16              # cell water <= WET_MAX_LOFT (dry surface) — sand only lofts when not wet
const GATE_NOT_RAINING: int = 32      # global precipitation off — rain pins all dust down (loft parity)

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 128         # std430 size of one Reaction (see layout in serialize())

# Constants copied VERBATIM from the kernels being dissolved (MaterialGas3D.gd / MaterialFungus3D.gd).
const SKY_EXCHANGE: float = 0.5
const O2_AMBIENT: float = 1.0
const CO2_SKY_VENT: float = 0.25
const DECOMPOSE_RATE: float = 0.05
const CO2_PER_DECOMPOSE: float = 1.0
const O2_PER_DECOMPOSE: float = 0.8
const FERT_PER_DECOMPOSE: float = 1.5

# --- Biomass / plant carbon exchange (Phase B3 §1 R19) ----------------------------------------------------
# Trace atmospheric CO₂ the sky maintains at every exposed surface cell (the ~400ppm baseline). Photosynthesis
# draws it DOWN locally, respiration/combustion push it UP — the sky exchange relaxes it back to this trace.
# Without it the carbon loop can't start: biomass, detritus, fungus and the combustion CO₂ all begin at ~0, so
# there is no carbon anywhere for a plant to fix (chicken-and-egg). This trace IS that ambient carbon source.
const CO2_AMBIENT_TRACE: float = 0.05
# Photosynthesis: CO₂ + H₂O + light → biomass + O₂. Rate scales with local CO₂ (the scarce input, and the
# reactant cap) × surface TEMPERATURE (the daylight/insolation stand-in — the solar terminator warms the day
# side to ~24°C and lets the night side relax to ~6°C, so warmth is a real per-cell day proxy, no light channel
# needed). Extent is capped by the CO₂ actually present, so biomass is CO₂-limited and cannot explode.
const PHOTO_RATE: float = 0.02           # per-step k on x = PHOTO_RATE * co2 * temp (capped by co2)
const PHOTO_O2_YIELD: float = 1.0        # O₂ released per unit CO₂ fixed (stoichiometric ~1:1)
const PHOTO_BIOMASS_YIELD: float = 1.0   # biomass grown per unit CO₂ fixed
# Respiration + decay: biomass + O₂ → CO₂ + detritus. Living matter slowly oxidizes everywhere it exists,
# returning carbon to the air (CO₂) and shedding litter (detritus) that the fungus-decompose record then rots
# into CO₂ + soil fertility. Proportional to biomass → self-limiting (as biomass rises, respiration rises to
# match fixation), which BOUNDS the loop, and it closes the carbon cycle entirely on the GPU.
const RESP_RATE: float = 0.01            # per-step k on x = RESP_RATE * biomass * o2
const RESP_O2_COST: float = 0.5          # O₂ consumed per unit biomass respired (aerobic)
const RESP_CO2_YIELD: float = 0.6        # CO₂ returned to air per unit biomass respired
const RESP_DET_YIELD: float = 0.4        # detritus (litter) shed per unit biomass respired

# --- H₂O PHASE CHANGE (freeze / melt) — one conserved substance, phase from temperature (Phase 2c) --------
# Liquid WATER, atmospheric AIRWATER and frozen SNOW are the SAME H₂O; only the PHASE differs, and the phase
# is emergent from a cell's TEMPERATURE. Freeze/melt are pure mass-conserving TRANSFERS: debit one phase by x,
# credit the other by x (coeff 1:1), so H₂O total = water + airwater + snow is conserved by every transition.
# FREEZE_TEMP / MELT_TEMP MUST match snowice_sphere3d.glsl (the sat(T)-aware snowfall/deposition kernel that
# freezes the CONDENSED atmospheric water directly — the primary snow source). Hysteresis (FREEZE_TEMP <
# MELT_TEMP) leaves a stable band where snow neither grows nor melts → a clean, non-flickering snow line.
# TUNED to the sim's ACTUAL open-cell temperature range (~11–21 °C: this world's static terminator never drops
# the night/pole floor near 0 °C), so freezing happens in the coldest ~1–2 °C cap instead of NEVER. A literal
# 0 °C freeze can never fire here — see the task temp-range note; raise these with the real climate range.
const FREEZE_TEMP: float = 12.5          # WATER (and, in the kernel, condensed AIRWATER) at T below this freezes → SNOW
const MELT_TEMP: float = 14.0            # SNOW at T above this melts → liquid WATER
const FREEZE_RATE: float = 0.05          # per-step k on the below-threshold liquid-freeze extent
const MELT_RATE: float = 0.05            # per-step k on the above-threshold snow-melt extent

# --- MINERAL phase transfers (rock unification Stage A) — same-cell, conserving, own-cell writes only -------
# LOFT (M4, replaces dust_loft_sphere3d.glsl): wind over LOFT_WIND scours dry loose SEDIMENT into the SAME
# cell's airborne DUST (the box/sphere loft kernel scattered into the cell ABOVE — a cross-cell write that
# forbade a DEFS record; re-aiming to own-cell makes it a clean record and dust_transport lofts it up next
# step, design-blessed as near-identical). Constants copied from dust_loft_sphere3d.glsl. The reactant cap on
# SEDIMENT enforces "can't loft more than present"; the LOFT_MAX per-step cap is dropped (perf-over-parity —
# it only bit at hspeed>~22, and sediment-capped extent stays bounded regardless).
const LOFT_WIND: float = 6.0             # horizontal wind speed a dry surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per unit wind OVER the threshold
# SETTLE (M3, susp→sediment): turbid water drops its load when calm. susp is a DEAD phase today (no erosion
# source on the sphere populates it), so this record is a NO-OP that is authored now so the clean transition
# exists by construction; when Stage D erosion feeds susp, it settles without a new kernel. CONST_FRAC.
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles out when calm


## Author one record as a Dictionary (unspecified fields default to the ungated/no-op values). Reactant and
## product entries are Arrays of [slot, coeff] (products carry an optional 3rd element = target, default SELF).
static func _rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot,
		"reactants": reactants, "products": products,
	}


## The live reaction table (Phase B3 §1 "clean same-cell" set that folds now). Order is irrelevant — every
## record writes only its own cell, so the per-cell loop is order-independent.
static func records() -> Array:
	return [
		# R11 — Gas O₂ SKY-REFILL: relax O₂ toward ambient at sky-exposed surface cells (gas_sky_sphere3d:55).
		# RELAX_TARGET: x = SKY_EXCHANGE*(O2_AMBIENT - o2); product = O2 itself, no reactant.
		_rec(RELAX_TARGET, SKY_EXCHANGE, O2, [], [[O2, 1.0, TGT_SELF]], GATE_SURFACE, O2_AMBIENT),

		# R12 — Gas CO₂ SKY-EXCHANGE: relax CO₂ toward a small ambient TRACE at sky-exposed surface cells
		# (mirrors the O₂ sky refill R11 exactly). RELAX_TARGET: x = CO2_SKY_VENT*(CO2_AMBIENT_TRACE - co2);
		# product = CO₂ itself, no reactant. Excess combustion CO₂ still vents DOWN toward the trace (x<0), and
		# clean surface air refills UP to it (x>0) — the trace is the atmosphere's baseline carbon that seeds
		# the whole loop (photosynthesis draws it below the trace locally; see R19).
		_rec(RELAX_TARGET, CO2_SKY_VENT, CO2, [], [[CO2, 1.0, TGT_SELF]], GATE_SURFACE, CO2_AMBIENT_TRACE),

		# R15 — Fungus DECOMPOSE: detritus + O₂ → CO₂ (self) + fertility (scratch) (fungus_sphere3d:100-118).
		# BILINEAR: x = DECOMPOSE_RATE*fungus*detritus, capped by the detritus + O₂ reactants (the aerobic cap
		# falls out of listing O₂ as a reactant, coeff O2_PER_DECOMPOSE). Fert → SCRATCH (fungus_fert reduce).
		_rec(BILINEAR, DECOMPOSE_RATE, FUNGUS,
			[[DETRITUS, 1.0], [O2, O2_PER_DECOMPOSE]],
			[[CO2, CO2_PER_DECOMPOSE, TGT_SELF], [FERT, FERT_PER_DECOMPOSE, TGT_SCRATCH]],
			0, 0.0, DETRITUS),

		# R19 — PHOTOSYNTHESIS: CO₂ + light → biomass + O₂ at sky-exposed surface cells (the plant carbon-fix leg,
		# dissolved from Plant.gd's CPU `field.photosynthesize`). BILINEAR: x = PHOTO_RATE*co2*temp (temp = the
		# daylight proxy; the day side is warmer → fixes more). The single CO₂ reactant caps the extent, so growth
		# is CO₂-limited (bounded). Products: O₂ + BIOMASS into the own surface cell. GATE_SURFACE = sky-exposed.
		_rec(BILINEAR, PHOTO_RATE, CO2, [[CO2, 1.0]],
			[[O2, PHOTO_O2_YIELD, TGT_SELF], [BIOMASS, PHOTO_BIOMASS_YIELD, TGT_SELF]],
			GATE_SURFACE, 0.0, TEMP),

		# R20 — RESPIRATION + DECAY: biomass + O₂ → CO₂ + detritus, everywhere biomass exists (ungated).
		# BILINEAR: x = RESP_RATE*biomass*o2; BIOMASS reactant caps the extent (can't respire more than present),
		# O₂ reactant makes it aerobic. Products: CO₂ back to air + DETRITUS litter (which the fungus-decompose
		# R15 then rots into CO₂ + fertility) → the full carbon loop closes on the GPU, no CPU carcass bridge.
		_rec(BILINEAR, RESP_RATE, BIOMASS, [[BIOMASS, 1.0], [O2, RESP_O2_COST]],
			[[CO2, RESP_CO2_YIELD, TGT_SELF], [DETRITUS, RESP_DET_YIELD, TGT_SELF]],
			0, 0.0, O2),

		# R21 — FREEZE (liquid → snow): standing/melt WATER at a cell colder than FREEZE_TEMP crystallizes to
		# SNOW. DEFICIT_BELOW_THRESHOLD: x = max(0, FREEZE_TEMP - temp) * FREEZE_RATE, capped by the WATER present
		# → a pure conserving transfer (water -= x; snow += x). The PRIMARY snowfall path (freezing the CONDENSED
		# atmospheric water at cold ground, which needs sat(T)) is the snowice deposition kernel; this record is
		# the liquid leg — it refreezes meltwater/puddles/rivers so the H₂O phase tracks temperature everywhere,
		# not only in the air. It is also the exemplar of the new below-threshold rate model.
		_rec(DEFICIT_BELOW_THRESHOLD, FREEZE_RATE, TEMP, [[WATER, 1.0]], [[SNOW, 1.0, TGT_SELF]], 0, FREEZE_TEMP),

		# R22 — MELT (snow → water): SNOW at a cell warmer than MELT_TEMP thaws to liquid WATER (meltwater the
		# water CA then routes downhill on the next step). EXCESS_OVER_THRESHOLD: x = max(0, temp - MELT_TEMP) *
		# MELT_RATE, capped by the SNOW present → conserving transfer (snow -= x; water += x). REPLACES the melt
		# branch of snowice_sphere3d.glsl (which is now deposition-only).
		_rec(EXCESS_OVER_THRESHOLD, MELT_RATE, TEMP, [[SNOW, 1.0]], [[WATER, 1.0, TGT_SELF]], 0, MELT_TEMP),

		# M4 — DUST LOFT (loose → airborne): wind over LOFT_WIND scours dry loose SEDIMENT into the OWN cell's
		# airborne DUST. EXCESS_OVER_THRESHOLD on WINDSPEED (sqrt(vel_x²+vel_z²), the derived driver), gated
		# GATE_DRY (water<=WET_MAX_LOFT) + GATE_NOT_RAINING. Reactant cap on SEDIMENT. REPLACES + DELETES
		# dust_loft_sphere3d.glsl (the cross-cell scatter into the cell above → re-aimed own-cell; transport
		# lofts it up next step). A conserving sediment→dust transfer of the ONE mineral substance.
		_rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY | GATE_NOT_RAINING, LOFT_WIND),

		# M3 — SUSP SETTLE (suspended → loose): calm turbid water drops its load. CONST_FRAC on SUSP →
		# SEDIMENT (own-cell, conserving). susp is a DEAD phase until Stage D erosion populates it, so this is
		# an inert forward-looking record today (fires on all-zero susp → no-op); it makes the clean transition
		# exist by construction so erosion needs no new settle kernel.
		_rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),
	]


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (128 bytes, 16-aligned):
##   0 rate_model(i) 4 rate_k(f) 8 threshold(f) 12 gate_mask(i) | 16 driver_slot(i) 20 driver2_slot(i)
##   24 cap_slot(i) 28 cap_coeff(f) | 32 n_react(i) 36 n_prod(i) 40 pad 44 pad |
##   48 react_slot[4](i) | 64 react_coeff[4](f) | 80 prod_slot[4](i) | 96 prod_coeff[4](f) | 112 prod_target[4](i)
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
		buf.encode_s32(base + 40, 0)
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
