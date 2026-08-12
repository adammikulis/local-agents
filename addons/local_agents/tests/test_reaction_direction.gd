@tool
extends RefCounted

## The equilibrium temperature of calcite + quartz = wollastonite + CO2 is a function of the CO2 activity, so
## no one temperature can be its threshold. CPU oracle of reactions_sphere3d.glsl's direction_scale, through
## LAReactionThermo, which is where both sides read the arithmetic from.

const GeoScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/GeoRecords.gd")
const ThermoScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionThermo.gd")

# Conditions of the sweep, measured off this planet, not constants of the model.
const CO2_AT_CELL: float = 0.277           # mean ground CO2 in channel units
const FIELD_HOTTEST_C: float = 256.0       # hottest cell the field reaches
# Robie & Hemingway 1995; CODATA for CO2. Derived from the table, so this is the cross-check.
const DECARB_DH_J_MOL: float = 89890.0
const DECARB_DS_J_MOL_K: float = 162.32


func _reversible_record() -> Dictionary:
	for r in GeoScript.records():
		if int(r.get("q_slot", -1)) >= 0:
			return r
	return {}


func run_test(_tree: SceneTree) -> bool:
	var rec: Dictionary = _reversible_record()
	if rec.is_empty():
		push_error("no record in LAGeoRecords carries a reaction quotient, so nothing takes its direction "
			+ "from dG. The Urey reaction is supposed to be reversible.")
		return false
	var sigma: float = ThermoScript.quotient_sign(rec)
	if sigma == 0.0:
		push_error("the reversible record's q_slot is neither a reactant nor a product of it.")
		return false

	var ok: bool = true

	# `sigma` states the record in its CO2-PRODUCING (decarbonation) direction.
	var dh: float = sigma * float(rec["dg_h_j_mol"])
	var ds: float = sigma * float(rec["dg_s_j_molk"])
	print("REACTION_DIRECTION={\"decarb_dh_j_mol\":%.1f,\"decarb_ds_j_mol_k\":%.2f}" % [dh, ds])
	if absf(dh - DECARB_DH_J_MOL) > 1.0 or absf(ds - DECARB_DS_J_MOL_K) > 0.02:
		push_error("the record's dH/dS come out %.1f J/mol and %.2f J/mol/K against the measured %.1f and "
			% [dh, ds, DECARB_DH_J_MOL] + "%.2f. Either a formation enthalpy or a standard entropy in "
			% DECARB_DS_J_MOL_K + "LASubstances is wrong, or the record's stoichiometry is.")
		ok = false

	var t_1bar: float = ThermoScript.equilibrium_temperature_k(rec, sigma, 1.0) - LAPhysical.KELVIN_OFFSET
	var acts: PackedFloat64Array = PackedFloat64Array([1.0, 0.1, 0.0558, 0.01, 4.0e-4, 1.0e-6])
	print("DECARB_EQUILIBRIUM={\"note\":\"temperature at which dG = 0, by CO2 activity (bar/bar)\"}")
	var prev: float = INF
	for a in acts:
		var t_eq: float = ThermoScript.equilibrium_temperature_k(rec, sigma, float(a)) - LAPhysical.KELVIN_OFFSET
		print("  a_CO2=%12s   T_eq=%8.1f C" % [String.num_scientific(a), t_eq])
		if t_eq > prev + 1.0e-9:
			push_error("the equilibrium temperature RISES as CO2 falls. Removing a product must make a "
				+ "reaction that produces it easier, not harder.")
			ok = false
		prev = t_eq
	if absf(t_1bar - 280.7) > 0.5:
		push_error("at 1 bar of CO2 the equilibrium temperature is %.1f C, not the 280.7 C the four measured "
			% t_1bar + "phases give. The standard-state data has drifted.")
		ok = false

	# The claim: at the planet's own CO2 it turns round at a temperature the field reaches.
	var t_k_cell: float = FIELD_HOTTEST_C + LAPhysical.KELVIN_OFFSET
	var a_cell: float = ThermoScript.activity_of(rec, CO2_AT_CELL, t_k_cell)
	var t_eq_cell: float = ThermoScript.equilibrium_temperature_k(rec, sigma, a_cell) - LAPhysical.KELVIN_OFFSET
	print("DECARB_AT_PLANET_CO2={\"co2_units\":%.3f,\"activity\":%.4f,\"t_eq_c\":%.1f,\"hottest_c\":%.1f}"
		% [CO2_AT_CELL, a_cell, t_eq_cell, FIELD_HOTTEST_C])
	if t_eq_cell >= FIELD_HOTTEST_C:
		push_error("at this planet's CO2 the reaction still cannot turn round below %.1f C (needs %.1f C). "
			% [FIELD_HOTTEST_C, t_eq_cell] + "The carbonate sink is one-way again.")
		ok = false

	var f_cold: float = ThermoScript.direction_factor(rec, sigma, LAPhysical.KELVIN_OFFSET + 15.0,
		ThermoScript.activity_of(rec, CO2_AT_CELL, LAPhysical.KELVIN_OFFSET + 15.0))
	var f_hot: float = ThermoScript.direction_factor(rec, sigma, t_k_cell, a_cell)
	var f_eq: float = ThermoScript.direction_factor(rec, sigma, t_eq_cell + LAPhysical.KELVIN_OFFSET, a_cell)
	print("DECARB_DIRECTION={\"f_15c\":%.4f,\"f_hot\":%.4f,\"f_at_equilibrium\":%s}"
		% [f_cold, f_hot, String.num_scientific(f_eq)])
	if f_cold <= 0.0:
		push_error("weathering does not run forward at 15 C, where it is the dominant long-term carbon sink.")
		ok = false
	if f_hot >= 0.0:
		push_error("the record does not run BACKWARDS at %.1f C, above its own equilibrium temperature of "
			% FIELD_HOTTEST_C + "%.1f C. dG > 0 means the reverse reaction, not a stalled forward one."
			% t_eq_cell)
		ok = false
	if absf(f_eq) > 1.0e-6:
		push_error("the direction factor is %s at equilibrium, not zero. Both directions must go quiet "
			% String.num_scientific(f_eq) + "where dG = 0, or the reaction cycles through its own point.")
		ok = false

	# The extent may not carry CO2 past the activity where dG = 0.
	var t_k_cold: float = LAPhysical.KELVIN_OFFSET + 15.0
	var a_eq_cold: float = ThermoScript.equilibrium_activity(rec, sigma, t_k_cold)
	var ch_eq: float = a_eq_cold * LAPhysical.STANDARD_PRESSURE_PA \
		/ (float(rec["q_pa_per_unit_k"]) * t_k_cold)
	print("DECARB_FLOOR={\"a_eq_15c\":%s,\"co2_units_at_equilibrium\":%s}"
		% [String.num_scientific(a_eq_cold), String.num_scientific(ch_eq)])
	if ch_eq <= 0.0 or ch_eq >= CO2_AT_CELL:
		push_error("the equilibrium CO2 floor at 15 C is %s channel units against the air's %.3f. A floor "
			% [String.num_scientific(ch_eq), CO2_AT_CELL] + "at or above ambient means the sink cannot run.")
		ok = false
	var a_back: float = ThermoScript.activity_of(rec, ch_eq, t_k_cold)
	if absf(a_back - a_eq_cold) > a_eq_cold * 1.0e-6:
		push_error("the channel amount and the activity do not invert each other, so the kernel's "
			+ "equilibrium bound lands on the wrong extent.")
		ok = false
	return ok
