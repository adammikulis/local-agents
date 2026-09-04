@tool
extends RefCounted

## One temperature for a cell of rock, water and air in ONE volume: T -> H -> T, the fusion jump, and the
## saturation split at fixed volume.

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

const TOL_K: float = 1.0e-6
const P_ATM: float = 101325.0
## The gas room of a cubic-metre cell with a little condensed matter in it, m^3.
const ROOM_M3: float = 1.0


func _round_trip(masses: Dictionary, room_m3: float, t_c: float, label: String) -> bool:
	var h: float = LAMixtureEnthalpy.enthalpy_at(masses, room_m3, t_c, P_ATM)
	if not is_finite(h):
		push_error("mixture enthalpy at %.3f C (%s) is not finite." % [t_c, label])
		return false
	var st: Dictionary = LAMixtureEnthalpy.state(masses, room_m3, h, P_ATM)
	var back: float = float(st["t_c"])
	if absf(back - t_c) > TOL_K:
		push_error("%s: %.4f C goes in as %s J and comes back %.4f C. The cell's enthalpy curve and its "
			% [label, t_c, String.num_scientific(h), back] + "inverse are not the same curve.")
		return false
	return true


## The vapour a puddle raises over itself in a room, mol: p_sat(T) room / (R T), never more than it has.
func _expected_vapour_mol(m_kg: float, room_m3: float, t_c: float) -> float:
	var p_v: float = LASubstances.saturation_p_at("h2o", t_c)
	var n: float = p_v * room_m3 / (PC.GAS_CONSTANT_J_MOL_K * (t_c + PC.KELVIN_OFFSET))
	return minf(n, m_kg / PC.MOLAR_MASS_WATER_KG_MOL)


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = true

	var wet_rock: Dictionary = {"silicate": 2000.0, "h2o": 50.0}
	var dry_rock: Dictionary = {"silicate": 2000.0}
	var puddle: Dictionary = {"h2o": 10.0}

	# Every rung, with a room to evaporate into and without.
	for t in [-40.0, -0.5, 20.0, 90.0, 150.0, 900.0, 1050.0, 1100.0, 1199.0, 1400.0]:
		ok = _round_trip(wet_rock, ROOM_M3, float(t), "wet rock with room at %.1f C" % t) and ok
		ok = _round_trip(wet_rock, 0.0, float(t), "wet rock, no room, at %.1f C" % t) and ok
		ok = _round_trip(dry_rock, ROOM_M3, float(t), "dry rock at %.1f C" % t) and ok

	# The fusion jump pins the temperature; half the latent heat is half melted.
	var melt: float = LASubstances.melt_c_at("h2o", P_ATM)
	var h_bottom: float = LAMixtureEnthalpy.enthalpy_at(puddle, 0.0, melt, P_ATM)
	var jump: float = float(LAMixtureEnthalpy.jump_at(puddle, 0.0, melt, P_ATM)["total"])
	var want_jump: float = 10.0 * float(LASubstances.table()["h2o"]["latent_fusion_j_kg"])
	if absf(jump - want_jump) > 1.0e-6 * want_jump:
		push_error("ten kilos of ice cost %s J to melt, not the %s the latent heat says."
			% [String.num_scientific(jump), String.num_scientific(want_jump)])
		ok = false
	var mid: Dictionary = LAMixtureEnthalpy.state(puddle, 0.0, h_bottom + 0.5 * jump, P_ATM)
	if not bool(mid["pinned"]) or absf(float(mid["t_c"]) - melt) > TOL_K:
		push_error("half-melted ice reads %.4f C (pinned=%s), not the %.4f C the boundary sits at."
			% [float(mid["t_c"]), str(mid["pinned"]), melt])
		ok = false
	if absf(float(mid["melted"]["h2o"]) - 0.5) > 1.0e-6:
		push_error("half the latent heat of fusion leaves the melt fraction at %.4f, not 0.5."
			% float(mid["melted"]["h2o"]))
		ok = false

	# Wet rock on dry rock's energy comes out colder.
	var t_probe: float = 300.0
	var h_dry: float = LAMixtureEnthalpy.enthalpy_at(dry_rock, ROOM_M3, t_probe, P_ATM)
	var t_wet: float = float(LAMixtureEnthalpy.state(wet_rock, ROOM_M3, h_dry, P_ATM)["t_c"])
	if t_wet >= t_probe:
		push_error("adding 50 kg of water to the cell left it at %.2f C on the same energy that put dry "
			% t_wet + "rock at %.2f C. The water absorbed nothing." % t_probe)
		ok = false

	# A fixed volume has no boiling plateau, with or without room.
	var boil: float = LASubstances.boil_c_at("h2o", P_ATM)
	for room in [ROOM_M3, 0.0]:
		var jump_boil: float = float(LAMixtureEnthalpy.jump_at(puddle, float(room), boil, P_ATM)["total"])
		if jump_boil != 0.0:
			push_error("water in a %.1f m^3 room has a %s J boiling plateau. At fixed volume the vapour "
				% [float(room), String.num_scientific(jump_boil)] + "share climbs with the saturation pressure instead.")
			ok = false

	# The split IS the saturation law over the room: p_sat(T) room / (R T) moles of vapour.
	for t in [20.0, 150.0]:
		var h_t: float = LAMixtureEnthalpy.enthalpy_at(puddle, ROOM_M3, float(t), P_ATM)
		var st: Dictionary = LAMixtureEnthalpy.state(puddle, ROOM_M3, h_t, P_ATM)
		var f_v: float = float(st["vaporised"]["h2o"])
		var want: float = _expected_vapour_mol(10.0, ROOM_M3, float(t)) * PC.MOLAR_MASS_WATER_KG_MOL / 10.0
		if absf(f_v - want) > 1.0e-6 * maxf(want, 1.0e-12) or f_v <= 0.0 or f_v >= 1.0:
			push_error("ten kilos of water in a cubic metre at %.0f C report a vapour fraction of %s, not "
				% [float(t), String.num_scientific(f_v)] + "the %s the saturation pressure over the room fills." % String.num_scientific(want))
			ok = false
	# A trace of water in a large room is all vapour.
	var trace: Dictionary = {"h2o": 1.0e-3}
	var h_tr: float = LAMixtureEnthalpy.enthalpy_at(trace, 1000.0, 20.0, P_ATM)
	var f_tr: float = float(LAMixtureEnthalpy.state(trace, 1000.0, h_tr, P_ATM)["vaporised"]["h2o"])
	if f_tr != 1.0:
		push_error("a gram of water in a thousand cubic metres at 20 C keeps a condensed share of %s."
			% String.num_scientific(1.0 - f_tr))
		ok = false
	print("MIXTURE_SPLIT={\"t_c\":20.0,\"vapour_frac\":%s}" % String.num_scientific(
		float(LAMixtureEnthalpy.state(puddle, ROOM_M3, LAMixtureEnthalpy.enthalpy_at(puddle, ROOM_M3, 20.0, P_ATM), P_ATM)["vaporised"]["h2o"])))

	return ok
