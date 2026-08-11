class_name LAGeoRecords
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


# --- MINERAL phase transfers (rock unification Stage A) — same-cell, conserving, own-cell writes only -------
const LOFT_WIND: float = 6.0             # horizontal wind speed a dry surface must exceed to loft sand
const LOFT_RATE: float = 0.003           # sediment lofted per step per unit wind OVER the threshold
# every open cell, still or racing, which is what a constant Stokes settling velocity looks like on a fixed
# timestep: how fast a grain falls to the bed is a property of the GRAIN, not of the flow. What varies is how
const SUSP_SETTLE_RATE: float = 0.05     # per-step fraction of suspended sediment that settles out

# --- D1a FROST SHATTERING (bedrock below → loose SEDIMENT here) --------------------------------------------
#     dV = ICE_FREEZE_EXPANSION * m / rho_water   ->   dm_rock = dV * rho_rock
const FROST_ROCK_PER_ICE: float = LAPhysical.ICE_FREEZE_EXPANSION \
	* (LAPhysical.ROCK_DENSITY_KG_M3 / LAPhysical.WATER_DENSITY_0C_KG_M3)
# HOW MUCH WATER CAN BE IN THE ROCK AT ALL: its POROSITY. Only pore water is confined, and only confined water
# breaks anything — a puddle freezing on a flat slab just makes ice. The aux cap therefore limits the extent to
# ROCK_POROSITY_NEAR_SURFACE of the bedrock mass beneath, expressed as the divisor the record's cap applies.
const FROST_PORE_CAP_COEFF: float = 1.0 / LAPhysical.ROCK_POROSITY_NEAR_SURFACE

# --- D1b THE UREY REACTION: CHEMICAL WEATHERING AS A CARBON SINK -------------------------------------------
# THE RATE LAW is unchanged and is Arrhenius, first order in the solvent (WATER, the driver) and first order
#     x = DISSOLUTION_K * water * co2 * exp(-(Ea/R) * (1/T - 1/T_ref))
# laboratory mol/m^2/s through to a per-cell per-step extent. DISSOLUTION_K is the model's timescale for the
const DISSOLUTION_K: float = 2.0e-5

# --- D1c METAMORPHIC DECARBONATION: THE RETURN LEG ---------------------------------------------------------

# --- D2 LITHIFICATION (loose SEDIMENT → bedrock) -----------------------------------------------------------
const LITH_RATE_PER_PA: float = 1.0e-9   # per-step k on x = max(0, P - P_lith) * k


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	return [
		rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY, LOFT_WIND),

		rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		rec(DEFICIT_BELOW_THRESHOLD, LAPhaseRecords.FREEZE_RATE, TEMP,
			[[WATER, 1.0], [BEDROCK_BELOW, FROST_ROCK_PER_ICE]],
			[[SNOW, 1.0, TGT_SELF], [SEDIMENT, FROST_ROCK_PER_ICE, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.WATER_FREEZE_C, -1, 0.0, BEDROCK_BELOW, FROST_PORE_CAP_COEFF),

		# which applied WATER's phase boundary to every Arrhenius record there will ever be. It is the
		rec(ARRHENIUS, DISSOLUTION_K, WATER,
			[[BEDROCK_BELOW, 1.0], [CO2, LAReactionBalance.unit_ratio(CO2, BEDROCK_BELOW)]],
			[[CARBONATE, LAReactionBalance.unit_ratio(CARBONATE, BEDROCK_BELOW), TGT_SELF],
				[SILICA, LAReactionBalance.unit_ratio(SILICA, BEDROCK_BELOW), TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET),

		# not made yet — and no futile cycle results, because the Arrhenius ceiling at boiling plus the
		rec(EXCESS_OVER_THRESHOLD, LAPhaseRecords.ROCK_MELT_RATE, TEMP,
			[[CARBONATE, 1.0], [SILICA, LAReactionBalance.unit_ratio(SILICA, CARBONATE)]],
			[[BEDROCK_BELOW, LAReactionBalance.unit_ratio(BEDROCK_BELOW, CARBONATE), TGT_SELF],
				[CO2, LAReactionBalance.unit_ratio(CO2, CARBONATE), TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.DECARBONATION_TEMP_C),

		# x = max(0, P - LITHIFICATION_PRESSURE_PA) * LITH_RATE_PER_PA, capped by the SEDIMENT present →
		rec(EXCESS_OVER_THRESHOLD, LITH_RATE_PER_PA, OVERBURDEN, [[SEDIMENT, 1.0]],
			[[ROCK_FILL, 1.0, TGT_SELF]], 0, LAPhysical.LITHIFICATION_PRESSURE_PA),
	]
