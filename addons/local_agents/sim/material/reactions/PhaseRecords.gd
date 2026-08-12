class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Phase behaviour the enthalpy ladder does NOT already own.
##
## H2O is one channel whose solid / liquid / vapour shares are derived per cell from its enthalpy, so
## freezing, melting, evaporation from a free surface, condensation, sublimation and deposition have no
## record here: they are what the ladder says the cell's energy bought, and the latent heat is the
## difference between the two phases' enthalpies.

# --- BEDROCK phase transfers — molten LAVA <-> fractional bedrock ROCK_FILL --------------------------------
const SOLIDIFY_TEMP: float = LAPhysical.BASALT_SOLIDUS_C   # 1000 °C — lava below the solidus freezes to bedrock
const SOLIDIFY_RATE: float = 0.02        # per-step k on x = max(0, SOLIDIFY_TEMP - temp) * k (capped by lava)
const ROCK_MELT_TEMP: float = LAPhysical.BASALT_LIQUIDUS_C # 1200 °C — bedrock above the liquidus is fully molten
const ROCK_MELT_RATE: float = 0.02       # per-step k on x = max(0, temp - ROCK_MELT_TEMP) * k (capped by rock_fill)

# --- EVAPORATION FROM PORE WATER: the one h2o flux no transport row carries --------------------------------
# Rock holds no non-condensable gas, so its pore water has no vapour share for the wind to advect. It leaves
# across the soil surface, through the aerodynamic resistance r_a = 1/(C_E U) and the surface resistance r_s
# IN SERIES (Monteith 1965): E = (q_sat - q_air) / (r_a + r_s).
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3      # C_E, neutral-stability bulk transfer coefficient for moisture
const SOIL_SURFACE_RESISTANCE_S_M: float = 1000.0  # r_s of a well-watered soil surface


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var h: float = maxf(cell_size_m, 0.001)
	return [
		# Pore water of the regolith cell below, into the air of this one. The mass carries the enthalpy it
		# held in the soil, so no latent term is declared here.
		rec(RM_RESISTANCE_SERIES, VAPOUR_TRANSFER_COEFF * dt / h, VAPOUR_DEFICIT,
			[[SOIL_TOP, 1.0]], [[H2O, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_AIR_ABOVE, 0.0, WINDSPEED,
			VAPOUR_TRANSFER_COEFF * SOIL_SURFACE_RESISTANCE_S_M),

		# M5 / M6 — rock melts and freezes INSIDE rock. `solid` is derived from rock_fill, so an
		# open-cell-only gate gives the melt leg no reachable domain and leaves the freeze leg running alone,
		# which creates the crystallisation enthalpy once per cycle. Both legs are GATE_BURIED.
		rec(RM_DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			GATE_BURIED, SOLIDIFY_TEMP, -1, 0.0, -1, 0.0, 0.0, _latent_rock_j_m3()),

		rec(RM_EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			GATE_BURIED, ROCK_MELT_TEMP, -1, 0.0, -1, 0.0, 0.0, -_latent_rock_j_m3()),
	]


## Basalt's crystallisation enthalpy, J/m3. POSITIVE IS EXOTHERMIC. `density` is the REFERENCE value on
## purpose: an extent is one CHANNEL UNIT, and the kilograms a unit carries is the unit's definition.
static func _latent_rock_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("silicate", {})
	return float(t.get("density", 0.0)) * float(t.get("latent_fusion_j_kg", 0.0))
