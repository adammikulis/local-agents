class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Phase behaviour the enthalpy ladder does not already own.

# Evaporation from pore water: aerodynamic and surface resistance in series (Monteith 1965),
# E = (q_sat - q_air) / (r_a + r_s).
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3      # C_E, neutral-stability bulk transfer coefficient for moisture
const SOIL_SURFACE_RESISTANCE_S_M: float = 1000.0  # r_s of a well-watered soil surface


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
	]
