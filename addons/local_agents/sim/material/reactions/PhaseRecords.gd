class_name LAPhaseRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## Phase behaviour the enthalpy ladder does not already own.

# Evaporation from pore water: aerodynamic and surface resistance in series (Monteith 1965),
# E = (c_sat - c_air) / (r_a + r_s), in mol/m2/s with the deficit in mol/m3.
const VAPOUR_TRANSFER_COEFF: float = 1.2e-3      # C_E, neutral-stability bulk transfer coefficient for moisture
## r_s of a soil surface at or above field capacity, s/m — Van de Griend & Owe 1994, Water Resour. Res.
## 30:181. The record fires only where the cell below still holds pore water, so this is the branch it is
## on; the dry branch rises exponentially as the water content falls and needs a per-cell r_s.
const SOIL_SURFACE_RESISTANCE_S_M: float = 10.0


## Reaction records this domain contributes to the live table.
static func records() -> Array:
	var h: float = cell_height_m()
	if h <= 0.0:
		return []
	return [
		# Pore water of the regolith cell below, into the air of this one. Direction is the sign of the
		# vapour deficit off the saturation curve — the same dG the ladder derives phase from.
		LAReactionThermo.priced(rec(TB_PER_SECOND, "mol m^-3 driver^-1 driver2^-1 s^-1",
			RM_RESISTANCE_SERIES, VAPOUR_TRANSFER_COEFF / h, VAPOUR_DEFICIT,
			[[SOIL_TOP, 1.0]], [[H2O, 1.0]],
			GATE_NEAR_GROUND | GATE_AIR_ABOVE, 0.0, WINDSPEED,
			VAPOUR_TRANSFER_COEFF * SOIL_SURFACE_RESISTANCE_S_M)),
	]
