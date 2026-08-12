@tool
extends RefCounted

## A CELL of rock and water and air has ONE temperature, and the inverter has to find it from the cell's
## total energy. What is asserted: the round trip T -> H -> T; that the fusion jump pins the temperature and
## reports where in the jump the energy sits; that a mixture's answer is bracketed by what each substance
## alone would read; and that non-condensable gas removes the boiling plateau, because with air present the
## water leaves progressively instead of all at one temperature.

const M: GDScript = preload("res://addons/local_agents/sim/material/MixtureEnthalpy.gd")
const S: GDScript = preload("res://addons/local_agents/sim/material/Substances.gd")
const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

const TOL_K: float = 1.0e-6
const P_ATM: float = 101325.0

## Moles of dry air in a cubic metre at 1 atm and 15 C, straight out of the ideal gas law. The cell this
## stands for is one voxel of rock, water and air.
const AIR_MOL: float = PC.STANDARD_PRESSURE_PA / (PC.GAS_CONSTANT_J_MOL_K * (15.0 + PC.KELVIN_OFFSET))


func _round_trip(masses: Dictionary, n_gas_mol: float, t_c: float, label: String) -> bool:
	var h: float = M.enthalpy_at(masses, n_gas_mol, t_c, P_ATM)
	if not is_finite(h):
		push_error("mixture enthalpy at %.3f C (%s) is not finite." % [t_c, label])
		return false
	var st: Dictionary = M.state(masses, n_gas_mol, h, P_ATM)
	var back: float = float(st["t_c"])
	if absf(back - t_c) > TOL_K:
		push_error("%s: %.4f C goes in as %s J and comes back %.4f C. The cell's enthalpy curve and its "
			% [label, t_c, String.num_scientific(h), back] + "inverse are not the same curve.")
		return false
	return true


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = true

	var wet_rock: Dictionary = {"silicate": 2000.0, "h2o": 50.0}
	var dry_rock: Dictionary = {"silicate": 2000.0}
	var puddle: Dictionary = {"h2o": 10.0}

	# EVERY RUNG, with air present and without: cold rock, ice, the mush, magma, the boiling range.
	for t in [-40.0, -0.5, 20.0, 90.0, 150.0, 900.0, 1050.0, 1100.0, 1199.0, 1400.0]:
		ok = _round_trip(wet_rock, AIR_MOL, float(t), "wet rock in air at %.1f C" % t) and ok
		ok = _round_trip(wet_rock, 0.0, float(t), "wet rock, no gas, at %.1f C" % t) and ok
		ok = _round_trip(dry_rock, AIR_MOL, float(t), "dry rock at %.1f C" % t) and ok

	# THE FUSION JUMP PINS THE TEMPERATURE. Ice at 0 C takes its whole latent heat before it warms, so half
	# that energy must read 0 C with the melt half done.
	var melt: float = S.melt_c_at("h2o", P_ATM)
	var h_bottom: float = M.enthalpy_at(puddle, 0.0, melt, P_ATM)
	var jump: float = float(M.jump_at(puddle, 0.0, melt, P_ATM)["total"])
	var want_jump: float = 10.0 * float(S.table()["h2o"]["latent_fusion_j_kg"])
	if absf(jump - want_jump) > 1.0e-6 * want_jump:
		push_error("ten kilos of ice cost %s J to melt, not the %s the latent heat says."
			% [String.num_scientific(jump), String.num_scientific(want_jump)])
		ok = false
	var mid: Dictionary = M.state(puddle, 0.0, h_bottom + 0.5 * jump, P_ATM)
	if not bool(mid["pinned"]) or absf(float(mid["t_c"]) - melt) > TOL_K:
		push_error("half-melted ice reads %.4f C (pinned=%s), not the %.4f C the boundary sits at."
			% [float(mid["t_c"]), str(mid["pinned"]), melt])
		ok = false
	if absf(float(mid["melted"]["h2o"]) - 0.5) > 1.0e-6:
		push_error("half the latent heat of fusion leaves the melt fraction at %.4f, not 0.5."
			% float(mid["melted"]["h2o"]))
		ok = false

	# A MIXTURE IS NOT ITS BIGGEST COMPONENT. Wet rock given the energy dry rock would need must come out
	# COLDER, because the water took a share of it.
	var t_probe: float = 300.0
	var h_dry: float = M.enthalpy_at(dry_rock, AIR_MOL, t_probe, P_ATM)
	var t_wet: float = float(M.state(wet_rock, AIR_MOL, h_dry, P_ATM)["t_c"])
	if t_wet >= t_probe:
		push_error("adding 50 kg of water to the cell left it at %.2f C on the same energy that put dry "
			% t_wet + "rock at %.2f C. The water absorbed nothing." % t_probe)
		ok = false

	# NON-CONDENSABLE GAS REMOVES THE BOILING PLATEAU. With air in the cell the water leaves across a range
	# as its saturation pressure climbs; with no gas at all the plateau is the full latent heat.
	var boil: float = S.boil_c_at("h2o", P_ATM)
	var jump_air: float = float(M.jump_at(puddle, AIR_MOL, boil, P_ATM)["total"])
	var jump_vac: float = float(M.jump_at(puddle, 0.0, boil, P_ATM)["total"])
	var want_vac: float = 10.0 * S.latent_vaporisation_at("h2o", boil)
	if jump_air != 0.0:
		push_error("water in air still has a %s J boiling plateau. With a non-condensable gas present it "
			% String.num_scientific(jump_air) + "evaporates across a range instead.")
		ok = false
	if absf(jump_vac - want_vac) > 1.0e-6 * want_vac:
		push_error("with no gas present the boiling plateau is %s J, not the %s the latent heat says."
			% [String.num_scientific(jump_vac), String.num_scientific(want_vac)])
		ok = false

	# THE SATURATION SPLIT IS REAL BELOW BOILING. A puddle in air at 20 C is not entirely liquid.
	var warm: Dictionary = M.state(puddle, AIR_MOL, M.enthalpy_at(puddle, AIR_MOL, 20.0, P_ATM), P_ATM)
	var f_v: float = float(warm["vaporised"]["h2o"])
	print("MIXTURE_SPLIT={\"t_c\":%.3f,\"vapour_frac\":%s}" % [float(warm["t_c"]),
		String.num_scientific(f_v)])
	if f_v <= 0.0 or f_v >= 1.0:
		push_error("a puddle in air at 20 C reports a vapour fraction of %.6f. The saturation curve is not "
			% f_v + "splitting it at all.")
		ok = false

	return ok
