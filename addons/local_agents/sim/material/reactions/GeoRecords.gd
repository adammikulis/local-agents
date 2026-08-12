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

# --- D1b THE UREY REACTION, BOTH WAYS: CaSiO3 + CO2 <-> CaCO3 + SiO2 --------------------------------------
# THE RATE LAW is unchanged and is Arrhenius, first order in the solvent (WATER, the driver) and first order
#     x = DISSOLUTION_K * water * co2 * exp(-(Ea/R) * (1/T - 1/T_ref))
# laboratory mol/m^2/s through to a per-cell per-step extent. DISSOLUTION_K is the model's timescale for the
const DISSOLUTION_K: float = 2.0e-5

# --- D2 LITHIFICATION (loose SEDIMENT → bedrock) -----------------------------------------------------------
const LITH_RATE_PER_PA: float = 1.0e-9   # per-step k on x = max(0, P - P_lith) * k


# --- COALIFICATION: BURIAL DRIVES ORGANIC MATTER TOWARD CARBON ---------------------------------------------
# Peat, lignite, coal and oil are not fuels this substrate has to name. They are one dead organic pool losing
# H and O as it is buried and heated, and what is left is the C:H:O ratio the two records below leave behind.
# Both are Arrhenius on the pool's own element stocks; `_rate_k` puts the frequency factor on the field clock.
static func _rate_k(ea_over_r_k: float) -> float:
	var t_ref: float = LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET
	return LAPhysical.VITRINITE_FREQUENCY_FACTOR_PER_S \
		* LAMaterialFieldSphereStep3D.real_seconds_per_step() * exp(-ea_over_r_k / t_ref)


## Heat released per unit of extent, per m3 of cell, when the pool loses these moles of each element: the
## chemical energy it no longer holds (LASubstances.organic_energy_j_mol) has to go somewhere, and it goes to
## the cell. Coalification comes out exothermic, which is why coal seams self-heat.
static func _coal_enthalpy_j_m3(mol_c: float, mol_h: float, mol_o: float) -> float:
	return LASubstances.ORGANIC_MOL_PER_M3 * (mol_c * LASubstances.organic_energy_j_mol("C")
		+ mol_h * LASubstances.organic_energy_j_mol("H")
		+ mol_o * LASubstances.organic_energy_j_mol("O"))


## The records this domain contributes to the live table (see LAMaterialReactions3D).
static func records() -> Array:
	var w_per_org_o: float = LAReactionBalance.unit_ratio(MOISTURE, ORG_O)
	var co2_per_org_c: float = LAReactionBalance.unit_ratio(CO2, DETRITUS)
	var fert_per_org_c: float = LAReactionBalance.unit_ratio(FERT, DETRITUS)
	var organic_n: float = float(LAReactionBalance.composition()[DETRITUS]["N"])
	return [
		# DEHYDRATION, the lowest-activation-energy leg: 2 H + O leave as water. It is the fast one, so the
		# pool's path across the van Krevelen plane runs toward the origin — toward carbon.
		rec(ARRHENIUS, _rate_k(LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K), ORG_O,
			[[ORG_H, 2.0], [ORG_O, 1.0]],
			[[MOISTURE, w_per_org_o, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DEHYDRATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(0.0, 2.0, 1.0)),

		# DECARBOXYLATION: a carbon and two oxygens leave as CO2, taking the backbone's nitrogen with them.
		# It strips oxygen twice as fast per unit of extent as dehydration does, which is what separates the
		# O:C fall from the H:C fall instead of walking one straight line.
		rec(ARRHENIUS, _rate_k(LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K), DETRITUS,
			[[DETRITUS, 1.0], [ORG_O, 2.0]],
			[[CO2, co2_per_org_c, TGT_SELF], [FERT, organic_n * fert_per_org_c, TGT_SELF]],
			GATE_BURIED, LAPhysical.COAL_DECARBOXYLATION_EA_OVER_R_K, -1,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, 0.0, _coal_enthalpy_j_m3(1.0, 0.0, 2.0)),

		rec(EXCESS_OVER_THRESHOLD, LOFT_RATE, WINDSPEED, [[SEDIMENT, 1.0]], [[DUST, 1.0, TGT_SELF]],
			GATE_DRY, LOFT_WIND),

		rec(CONST_FRAC, SUSP_SETTLE_RATE, SUSP, [[SUSP, 1.0]], [[SEDIMENT, 1.0, TGT_SELF]], 0),

		rec(DEFICIT_BELOW_THRESHOLD, LAPhaseRecords.FREEZE_RATE, TEMP,
			[[WATER, 1.0], [BEDROCK_BELOW, FROST_ROCK_PER_ICE]],
			[[SNOW, 1.0, TGT_SELF], [SEDIMENT, FROST_ROCK_PER_ICE, TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.WATER_FREEZE_C, -1, 0.0, BEDROCK_BELOW, FROST_PORE_CAP_COEFF),

		# REVERSIBLE. CaSiO3 + CO2 <-> CaCO3 + SiO2 is ONE reaction; decarbonation is this record running
		# backwards, and which way it goes is dG(T, p_CO2), not a threshold. CO2 is the one varying activity.
		LAReactionThermo.reversible(rec(ARRHENIUS, DISSOLUTION_K, WATER,
			[[BEDROCK_BELOW, 1.0], [CO2, LAReactionBalance.unit_ratio(CO2, BEDROCK_BELOW)]],
			[[CARBONATE, LAReactionBalance.unit_ratio(CARBONATE, BEDROCK_BELOW), TGT_SELF],
				[SILICA, LAReactionBalance.unit_ratio(SILICA, BEDROCK_BELOW), TGT_SELF]],
			GATE_NEAR_GROUND, LAPhysical.SILICATE_DISSOLUTION_EA_OVER_R_K, CO2,
			LAPhysical.LAB_REFERENCE_TEMP_C + LAPhysical.KELVIN_OFFSET,
			-1, 0.0, LAPhysical.WATER_BOIL_C + LAPhysical.KELVIN_OFFSET), CO2),

		# x = max(0, P - LITHIFICATION_PRESSURE_PA) * LITH_RATE_PER_PA, capped by the SEDIMENT present →
		rec(EXCESS_OVER_THRESHOLD, LITH_RATE_PER_PA, OVERBURDEN, [[SEDIMENT, 1.0]],
			[[ROCK_FILL, 1.0, TGT_SELF]], 0, LAPhysical.LITHIFICATION_PRESSURE_PA),
	]
