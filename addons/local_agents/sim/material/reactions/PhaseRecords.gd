class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

const SOLIDIFY_TEMP: float = LAPhysical.BASALT_SOLIDUS_C
const SOLIDIFY_RATE: float = 0.02        # per-step k
const ROCK_MELT_TEMP: float = LAPhysical.BASALT_LIQUIDUS_C
const ROCK_MELT_RATE: float = 0.02       # per-step k
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3        # C_E, bulk moisture transfer coefficient
const SOIL_SURFACE_RESISTANCE_S_M: float = 1000.0  # r_s, s/m


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var h: float = maxf(cell_size_m, 0.001)
	return [
		# Pore water of the regolith cell below, into the air of this one.
		rec(RM_RESISTANCE_SERIES, VAPOUR_TRANSFER_COEFF * dt / h, VAPOUR_DEFICIT,
			[[SOIL_TOP, 1.0]], [[H2O, 1.0, TGT_SELF]],
			GATE_NEAR_GROUND | GATE_AIR_ABOVE, 0.0, WINDSPEED,
			VAPOUR_TRANSFER_COEFF * SOIL_SURFACE_RESISTANCE_S_M),

		rec(RM_DEFICIT_BELOW_THRESHOLD, SOLIDIFY_RATE, TEMP, [[LAVA, 1.0]], [[ROCK_FILL, 1.0, TGT_SELF]],
			GATE_BURIED, SOLIDIFY_TEMP, -1, 0.0, -1, 0.0, 0.0, _latent_rock_j_m3()),

		rec(RM_EXCESS_OVER_THRESHOLD, ROCK_MELT_RATE, TEMP, [[ROCK_FILL, 1.0]], [[LAVA, 1.0, TGT_SELF]],
			GATE_BURIED, ROCK_MELT_TEMP, -1, 0.0, -1, 0.0, 0.0, -_latent_rock_j_m3()),
	]


## Basalt's crystallisation enthalpy, J/m3; positive is exothermic.
static func _latent_rock_j_m3() -> float:
	var t: Dictionary = LASubstances.table().get("silicate", {})
	return float(t.get("density", 0.0)) * float(t.get("latent_fusion_j_kg", 0.0))
