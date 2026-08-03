class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## PHASE-CHANGE records — one substance, phase from temperature (R21 freeze, R22 melt,
## M5 lava solidify, M6 rock melt).

# --- H₂O PHASE CHANGE (freeze / melt) — one conserved substance, phase from temperature (Phase 2c) --------
# Liquid WATER, atmospheric MOISTURE and frozen SNOW are the SAME H₂O; only the PHASE differs, and the phase
# is emergent from a cell's TEMPERATURE. Freeze/melt are pure mass-conserving TRANSFERS: debit one phase by x,
# credit the other by x (coeff 1:1), so H₂O total = water + moisture + snow is conserved by every transition.
# WATER'S PHASE BOUNDARY. Ice and liquid water coexist at exactly ONE temperature, and it is 0 °C, so freeze
# and melt are the SAME number. Must match snowice_sphere3d.glsl (the sat(T)-aware kernel that freezes the
# CONDENSED atmospheric water — the primary snow source); scripts/check_physical_constants.sh gates that.
#
# THE COMMENT THAT WAS HERE IS DELETED, and what it SAID matters more than what it set: "TUNED to the sim's
# ACTUAL open-cell temperature range (~11–21 °C …) so freezing happens in the coldest ~1–2 °C cap instead of
# NEVER. A literal 0 °C freeze can never fire here … raise these with the real climate range." The planet
# could not get cold, so a previous pass moved THE FREEZING POINT OF WATER up to meet it — 12.5 here, 12.5 in
# snowice, 13.0 in charge_accum and activity, melt at 14.0. Every measurement taken against that was
# meaningless, and it left the deep ocean at 10 °C, below its own freezing point, not freezing. The comment
# OUTLIVED the value being corrected and still told the next reader to raise it again, so it goes entirely.
#
# The 1.5 °C freeze/melt hysteresis went with it. It existed to stop the snow line flickering — a NUMERICAL
# concern, which does not license separating a phase boundary that is not separated in nature. If flicker
# returns, damp FREEZE_RATE / MELT_RATE or hold a cell's state across a few steps; do not re-split these.
const FREEZE_TEMP: float = LAPhysical.WATER_FREEZE_C   # 0.0 °C — liquid WATER (and condensed MOISTURE) → SNOW
const MELT_TEMP: float = LAPhysical.WATER_MELT_C       # 0.0 °C — SNOW → liquid WATER. The same boundary.
const FREEZE_RATE: float = 0.05          # per-step k on the below-threshold liquid-freeze extent
const MELT_RATE: float = 0.05            # per-step k on the above-threshold snow-melt extent

# --- BEDROCK phase transfers (rock unification Stage B) — molten LAVA <-> fractional bedrock ROCK_FILL ------------
# ONE conserved mineral: solidify and melt are own-cell, mass-conserving transfers between the molten and bedrock
# phases (reactant-capped debit + equal credit → conserving by construction). `solid` is DERIVED (rock_fill>=0.5),
# so as lava solidifies the accreted rock_fill crosses 0.5 and the cell becomes bedrock (terrain grows); as rock
# melts it crosses back and the cell opens. The 0.5 crossing is what Stage C will stamp into the SDF mesh.
# M5 SOLIDIFY (molten -> bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. REPLACES the direct
# `solid=1; lava=0` write dissolved out of lava_phase_sphere3d.glsl (which fabricated an invisible GPU-only solid
# cell and LOST the lava mass — non-conserving); now it is a conserving lava->rock_fill transfer. lava_phase keeps
# only its SUSTAIN leg and no longer re-heats a sub-solidus cell, so this record sees the genuine post-thermal cold.
const SOLIDIFY_TEMP: float = 800.0       # lava below this (°C) has cooled through the solidus → freezes to bedrock
const SOLIDIFY_RATE: float = 0.02        # per-step k on x = max(0, SOLIDIFY_TEMP - temp) * k (capped by lava)
# M6 MELT (bedrock -> molten): rock hotter than ROCK_MELT_TEMP melts to lava. Reactions run in OPEN cells only
# (the engine skips solid cells for race-freedom), so this record melts the BOUNDARY rock — a hot open cell that
# still carries partial rock_fill (0 < rock_fill < 0.5), e.g. at a lava/bedrock interface. FULL bedrock melt of a
# deep magma-core cell (which is solid, hence skipped) stays a special case: it is driven instead by the real
# add_lava injection (converting bedrock->lava at the vent) and, later, the Stage-C hot-bore. Conserving either way.
const ROCK_MELT_TEMP: float = 1200.0     # open-cell rock hotter than this (°C, above the lava emplace temp) melts
const ROCK_MELT_RATE: float = 0.02       # per-step k on x = max(0, temp - ROCK_MELT_TEMP) * k (capped by rock_fill)

# --- H₂O EVAPORATION: ONE RULE, WHEREVER LIQUID WATER MEETS AIR --------------------------------------------
# THERE IS NO SUCH THING AS AN "EVAPORATION SINK". There is a phase change, and it runs in whichever direction
# the SATURATION VAPOUR PRESSURE says: liquid becomes vapour while the local air is below saturation, and the
# part above saturation is suspended condensate. The VAPOUR_DEFICIT driver (LAReactionDefs) is that one rule —
# `LAPhysical.saturation_mass_fraction(T) - moisture` — and the three records below are the same rule reading
# three different reservoirs. Nothing about them is specific to "the ocean" or "soil" or "snow".
#
# WHAT THIS REPLACED. `atmos_evap_sphere3d.glsl` was a hand-built evaporation feature: an EVAP_RATE, an
# EVAP_WARM_K exponential fitted "so cold land water barely evaporates", an EVAP_COND_CEIL humidity brake, a
# separate BOIL_TEMP branch, an un-debited infinite static-sea source, and a global static_brake driven by
# AtmospherePass.MOIST_TARGET = 0.11, "avg moisture/cell the atmosphere settles at". That last one is what
# actually decided how much water this planet's sky held — a target humidity, which is not a fact about
# anything — and it held the atmosphere at 30% of the planet's mobile water where Earth holds 0.001%. The
# kernel and all of those constants are DELETED. The temperature dependence they were approximating is
# Clausius-Clapeyron, which the driver now carries exactly; boiling needs no branch because e_sat reaches one
# atmosphere at 100 °C and the deficit goes with it.
#
# THE RATE IS A REAL FLUX, NOT A KNOB. Bulk aerodynamic mass transfer over a water surface:
#     E = rho_air * C_E * U * (q_sat - q_air)   [kg/m²/s]
# and dividing by rho_air turns the specific-humidity difference into the vapour-density difference the
# VAPOUR_DEFICIT driver already is, so the air density cancels and E = C_E * U * delta_rho_v. Spread over a
# cell of height H for a step of dt seconds, the extent in the field's cell-fill unit is
#     x = (C_E * U * dt / H) * deficit
# — no free parameter. C_E = 1.2e-3 at neutral stability (Large & Pond 1981, 1982); U = 7 m/s is the global
# mean 10 m ocean wind. dt is the substrate's own step (LAMaterialFieldSphereStep3D.real_seconds_per_step,
# 43.2 s at the shipped 200 s day) and H is the grid cell (LAReactionDefs.cell_size_m). At the shipped grid
# that is 0.0227 per step, i.e. an unsaturated cell holding open water brings its own air to saturation in
# about 44 steps — and never past it, because the extent is the deficit itself times a number below 1.
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3      # C_E, neutral-stability bulk transfer coefficient for moisture
const SURFACE_WIND_M_S: float = 7.0              # global mean 10 m wind over ocean

# BARE-SOIL EVAPORATION is the SAME transfer seen through the ground. Soil is not a free water surface: vapour
# has to diffuse up through the pores, and that resistance is in series with the aerodynamic one —
#     E_soil = E_potential * r_a / (r_a + r_s),  r_a = 1 / (C_E * U) = 119 s/m
# with the soil surface resistance r_s measured from ~10 s/m on a wet soil to >5000 s/m on a dry one (van de
# Griend & Owe 1994; Camillo & Gurney 1986). 1000 s/m is a drying-soil mid value and gives a factor of 0.106.
#
# The wetness dependence is not applied as a curve on top of that: it IS the record's second driver. R24 is
# BILINEAR on (VAPOUR_DEFICIT x SOIL_ROOT), so a saturated column evaporates at the resistance limit and a
# dry one evaporates in proportion to what it still holds — supply-limited stage-2 drying (Ritchie 1972) as
# an emergent consequence of the reservoir, with no threshold and no separate dry-soil branch. `k` is
# normalised so the reference state is a SATURATED SURFACE SHELL (its porosity at zero burial, 0.36).
const SOIL_SURFACE_RESISTANCE_S_M: float = 1000.0
const SATURATED_SURFACE_LAYER: float = 0.36      # a saturated surface shell = its porosity at zero burial


## Per-step evaporation extent per unit of vapour deficit — see the block above. Derived from the substrate's
## own clock and cell size, so it tracks a changed day length or grid resolution instead of going stale.
static func _evap_k() -> float:
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var h: float = maxf(cell_size_m, 0.001)
	return VAPOUR_TRANSFER_COEFF * SURFACE_WIND_M_S * dt / h


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	var evap_k: float = _evap_k()
	var r_a: float = 1.0 / (VAPOUR_TRANSFER_COEFF * SURFACE_WIND_M_S)
	var soil_k: float = evap_k * (r_a / (r_a + SOIL_SURFACE_RESISTANCE_S_M)) / SATURATED_SURFACE_LAYER
	return [
		# R23 — EVAPORATION (liquid water → atmospheric moisture). The phase rule at a free water surface:
		# x = max(0, sat(T) - moisture) * evap_k, capped by the WATER present. The extent can never exceed the
		# deficit itself, so a cell's own air is brought TO saturation and never past it — the bound is the
		# saturation curve, not a ceiling anybody chose. One record covers the sea, a lake, a river and a
		# puddle; it covers BOILING too, because e_sat reaches one atmosphere at 100 °C and the deficit with it.
		rec(EXCESS_OVER_THRESHOLD, evap_k, VAPOUR_DEFICIT, [[WATER, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_AIR_ABOVE, 0.0),

		# R24 — BARE-SOIL EVAPORATION (soil water → atmospheric moisture). THE SAME RULE, read through the
		# ground: wet soil in unsaturated air evaporates for exactly the reason the sea does. This is the leg
		# that was missing entirely — root uptake was the only path out of the aquifer, measured at 0.03 per
		# step against a 3400-unit reservoir, which is why the water table could only ever fill.
		# BILINEAR on (deficit x surface-layer water): supply-limited, so a saturated surface evaporates at the
		# soil-resistance limit and a drying one tapers with what it still holds — no threshold anywhere. The
		# reservoir is SOIL_TOP, the shallow drying front, not the whole rooting column: roots lift water from
		# metres down, evaporation only pulls what is within diffusion reach of the surface.
		rec(BILINEAR, soil_k, VAPOUR_DEFICIT, [[SOIL_TOP, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_AIR_ABOVE, 0.0, SOIL_TOP),

		# R25 — SUBLIMATION (snow → atmospheric moisture). The same rule a third time, over ice. It REPLACES
		# snowice_sphere3d.glsl's SUBLIMATE_FRAC = 0.004, a flat per-step fraction added to stop the snowpack
		# growing without bound: a rate that ran at the same speed in dry desert air and in saturated polar
		# air, and that could not be switched off by humidity because it never looked at any. Now a snowpack in
		# saturated air does not sublimate at all and one in dry air does, which is also why alpine sublimation
		# is a large share of ablation and polar sublimation is not.
		# (The Magnus curve is over LIQUID water; over ice e_sat is lower — 1.5% at -5 °C, 10% at -20 °C — so
		# this slightly overstates sublimation in the coldest cells. That very difference drives the Bergeron
		# process, and it earns its own curve the day mixed-phase cloud microphysics matters here.)
		rec(EXCESS_OVER_THRESHOLD, evap_k, VAPOUR_DEFICIT, [[SNOW, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_AIR_ABOVE, 0.0),

		# R21 — FREEZE (liquid → snow): standing/melt WATER at a cell colder than FREEZE_TEMP crystallizes to
		# SNOW. DEFICIT_BELOW_THRESHOLD: x = max(0, FREEZE_TEMP - temp) * FREEZE_RATE, capped by the WATER present
		# → a pure conserving transfer (water -= x; snow += x). The PRIMARY snowfall path (freezing the CONDENSED
		# atmospheric water at cold ground, which needs sat(T)) is the snowice deposition kernel; this record is
		# the liquid leg — it refreezes meltwater/puddles/rivers so the H₂O phase tracks temperature everywhere,
		# not only in the air. It is also the exemplar of the new below-threshold rate model.
		rec(DEFICIT_BELOW_THRESHOLD, FREEZE_RATE, TEMP, [[WATER, 1.0]], [[SNOW, 1.0, TGT_SELF]], 0, FREEZE_TEMP),

		# R22 — MELT (snow → water): SNOW at a cell warmer than MELT_TEMP thaws to liquid WATER (meltwater the
		# water CA then routes downhill on the next step). EXCESS_OVER_THRESHOLD: x = max(0, temp - MELT_TEMP) *
		# MELT_RATE, capped by the SNOW present → conserving transfer (snow -= x; water += x). REPLACES the melt
		# branch of snowice_sphere3d.glsl (which is now deposition-only).
		rec(EXCESS_OVER_THRESHOLD, MELT_RATE, TEMP, [[SNOW, 1.0]], [[WATER, 1.0, TGT_SELF]], 0, MELT_TEMP),

		# M5 — LAVA SOLIDIFY (molten → bedrock): lava colder than SOLIDIFY_TEMP freezes to rock. Runs in the open
		# cells lava occupies. DEFICIT_BELOW_THRESHOLD on the post-thermal TEMP: x = max(0, SOLIDIFY_TEMP - temp) *
		# SOLIDIFY_RATE, capped by the LAVA present → a conserving lava→rock_fill transfer. DISSOLVES the direct
		# `solid=1; lava=0` write formerly in lava_phase_sphere3d.glsl (which lost the lava mass); the accreted
		# rock_fill crossing 0.5 is what turns the cell to derived bedrock (and, in Stage C, stamps the SDF).
		rec(DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			0, SOLIDIFY_TEMP),

		# M6 — ROCK MELT (bedrock → molten): open-cell rock hotter than ROCK_MELT_TEMP melts to lava.
		# EXCESS_OVER_THRESHOLD on TEMP: x = max(0, temp - ROCK_MELT_TEMP) * ROCK_MELT_RATE, capped by ROCK_FILL →
		# conserving rock_fill→lava transfer. Only fires in OPEN cells (engine skips solid), so it melts partial
		# boundary rock; deep full-bedrock melt is driven by add_lava / the Stage-C bore (see the const note).
		rec(EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			0, ROCK_MELT_TEMP),
	]
