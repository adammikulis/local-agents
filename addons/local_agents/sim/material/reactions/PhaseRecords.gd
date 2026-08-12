class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## PHASE-CHANGE records — one substance, phase from temperature (R21 freeze, R22 melt,
## M5 lava solidify, M6 rock melt).

# --- H₂O PHASE CHANGE (freeze / melt) — one conserved substance, phase from temperature --------------------
const FREEZE_TEMP: float = LAPhysical.WATER_FREEZE_C   # 0.0 °C — liquid WATER (and condensed MOISTURE) → SNOW
const MELT_TEMP: float = LAPhysical.WATER_MELT_C       # 0.0 °C — SNOW → liquid WATER. The same boundary.
const FREEZE_RATE: float = 0.05          # per-step k on the below-threshold liquid-freeze extent
const MELT_RATE: float = 0.05            # per-step k on the above-threshold snow-melt extent
const DEPOSIT_RATE: float = 0.10         # per-step k on the condensed-moisture deposition extent

# --- BEDROCK phase transfers — molten LAVA <-> fractional bedrock ROCK_FILL --------------------------------
const SOLIDIFY_TEMP: float = LAPhysical.BASALT_SOLIDUS_C   # 1000 °C — lava below the solidus freezes to bedrock
const SOLIDIFY_RATE: float = 0.02        # per-step k on x = max(0, SOLIDIFY_TEMP - temp) * k (capped by lava)
const ROCK_MELT_TEMP: float = LAPhysical.BASALT_LIQUIDUS_C # 1200 °C — bedrock above the liquidus is fully molten
const ROCK_MELT_RATE: float = 0.02       # per-step k on x = max(0, temp - ROCK_MELT_TEMP) * k (capped by rock_fill)

# --- H₂O EVAPORATION: one rule wherever liquid water meets air --------------------------------------------
# E = rho_air * C_E * U * (q_sat - q_air) [kg/m²/s], so x = (C_E * U * dt / H) * deficit — no free parameter.
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3      # C_E, neutral-stability bulk transfer coefficient for moisture
const SURFACE_WIND_M_S: float = 7.0              # global mean 10 m wind over ocean

# E_soil = E_potential * r_a / (r_a + r_s), r_a = 1 / (C_E * U)
const SOIL_SURFACE_RESISTANCE_S_M: float = 1000.0
const SATURATED_SURFACE_LAYER: float = 0.36      # a saturated surface shell = its porosity at zero burial


## Per-step evaporation extent per unit of vapour deficit. Derived from the substrate's own step quantum and
## cell size, so it tracks a changed day length or grid resolution.
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
		# EVAPORATION from open water: x = max(0, sat(T) - moisture) * evap_k, capped by the WATER present.
		rec(EXCESS_OVER_THRESHOLD, evap_k, VAPOUR_DEFICIT, [[WATER, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_AIR_ABOVE, 0.0, -1, 0.0, -1, 0.0, 0.0, -_latent_vaporisation_j_m3()),

		# EVAPORATION from wet soil: the same rule through a surface resistance.
		rec(BILINEAR, soil_k, VAPOUR_DEFICIT, [[SOIL_TOP, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_AIR_ABOVE, 0.0, SOIL_TOP, 0.0, -1, 0.0, 0.0,
			-_latent_vaporisation_j_m3()),

		# SUBLIMATION (snow → vapour): fusion plus vaporisation, absorbed.
		rec(EXCESS_OVER_THRESHOLD, evap_k, VAPOUR_DEFICIT, [[SNOW, 1.0]], [[MOISTURE, 1.0, TGT_SELF]],
			GATE_AIR_ABOVE, 0.0, -1, 0.0, -1, 0.0, 0.0, -_latent_sublimation_j_m3()),

		# R21 — FREEZE (water → snow): fusion released.
		rec(DEFICIT_BELOW_THRESHOLD, FREEZE_RATE, TEMP, [[WATER, 1.0]], [[SNOW, 1.0, TGT_SELF]], 0, FREEZE_TEMP,
			-1, 0.0, -1, 0.0, 0.0, _latent_fusion_j_m3()),

		# DEPOSITION (condensed moisture → snow). Vapour going straight to ice releases fusion PLUS
		# vaporisation. DEFICIT_BELOW_THRESHOLD on the SIGNED VAPOUR_DEFICIT driver (sat(T) − moisture) at
		# threshold 0 gives x = max(0, moisture − sat(T)) · k. GATE_FREEZING keeps it off warm condensate.
		rec(DEFICIT_BELOW_THRESHOLD, DEPOSIT_RATE, VAPOUR_DEFICIT, [[MOISTURE, 1.0]], [[SNOW, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_FREEZING, 0.0, -1, 0.0, -1, 0.0, 0.0, _latent_sublimation_j_m3()),

		# R22 — MELT (snow → water): x = max(0, temp - MELT_TEMP) * k. Fusion absorbed; the water CA routes
		# the meltwater downhill on the next step.
		rec(EXCESS_OVER_THRESHOLD, MELT_RATE, TEMP, [[SNOW, 1.0]], [[WATER, 1.0, TGT_SELF]], 0, MELT_TEMP,
			-1, 0.0, -1, 0.0, 0.0, -_latent_fusion_j_m3()),

		# M5 / M6 — rock melts and freezes INSIDE rock. `solid` is derived from rock_fill, so an
		# open-cell-only gate gives the melt leg no reachable domain and leaves the freeze leg running alone,
		# which creates the crystallisation enthalpy once per cycle. Both legs are GATE_BURIED.
		rec(DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			GATE_BURIED, SOLIDIFY_TEMP, -1, 0.0, -1, 0.0, 0.0, _latent_rock_j_m3()),

		rec(EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			GATE_BURIED, ROCK_MELT_TEMP, -1, 0.0, -1, 0.0, 0.0, -_latent_rock_j_m3()),
	]


## LATENT HEAT PER UNIT OF EXTENT, J/m3, derived from LASubstances. SIGN: POSITIVE IS EXOTHERMIC —
## an absorbing leg (evaporation, sublimation, melting) passes the negated value.
## `density` is the REFERENCE value on purpose: an extent is one CHANNEL UNIT, and the kilograms a unit
## carries is the unit's definition, not a density that may move under it.
static func _latent_fusion_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("h2o", {})
	return float(t.get("density", 0.0)) * float(t.get("latent_fusion_j_kg", 0.0))


static func _latent_vaporisation_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("h2o", {})
	return float(t.get("density", 0.0)) * float(t.get("latent_vaporisation_j_kg", 0.0))


## Sublimation is fusion PLUS vaporisation — derived, never declared, so Hess's law cannot be violated.
static func _latent_sublimation_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("h2o", {})
	return float(t.get("density", 0.0)) * LASubstances.latent_sublimation_j_kg("h2o")


## Basalt's crystallisation enthalpy, same convention.
static func _latent_rock_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("silicate", {})
	return float(t.get("density", 0.0)) * float(t.get("latent_fusion_j_kg", 0.0))
