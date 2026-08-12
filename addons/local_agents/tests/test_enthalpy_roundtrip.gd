@tool
extends RefCounted

## The enthalpy curve has two halves and they must be one curve. enthalpy_at() takes a temperature to a
## specific enthalpy, enthalpy_to_state() takes it back; a substance heated and then read must report the
## temperature it was given, on every rung and at every pressure. When the halves disagree, energy silently
## changes value on a round trip through the field.
##
## PLATEAUS ARE ONE-WAY BY CONSTRUCTION: a whole range of enthalpy maps to one temperature, so h -> T -> h
## cannot hold there. What is asserted instead is T -> h -> T (which does hold, enthalpy_at returning the
## plateau's lower end) plus the plateau's two ENDPOINTS both reading the plateau temperature.

const S: GDScript = preload("res://addons/local_agents/sim/material/Substances.gd")
const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## Kelvin. The round trip is exact arithmetic apart from _invert_gas_enthalpy's bisection, which halves a
## 1e5 K bracket 60 times (~1e-13 K), and double round-off on ~1e8 J/kg (~1e-11 K). This sits seven orders
## above both and eight below the smallest real defect: mixing up the two latent-heat sources moves the gas
## ramp by ~140 K at one atmosphere.
const TOL_K: float = 1.0e-6

## Murphy & Koop 2005, ice saturation. The frost point at 1 mbar is near -20.3 C. The 2 K band is the error
## of integrating Clausius-Clapeyron with a temperature-independent latent heat over 20 K, not a fudge.
const FROST_POINT_AT_100PA_C: float = -20.3
const FROST_POINT_TOL_C: float = 2.0

const P_ATM: float = 101325.0
const P_BELOW_TRIPLE: float = 100.0
const P_ABOVE_CRITICAL: float = 5.0e7


## Every rung of the ladder at this pressure, plus a point either side of every boundary so a branch that
## fires one rung early or late cannot hide between samples.
func _sweep_points(id: String, p_pa: float) -> Array[float]:
	var out: Array[float] = []
	var melt: float = S.melt_c_at(id, p_pa)
	if not is_finite(melt):
		return [-200.0, 0.0, 500.0, 3000.0] as Array[float]
	if S.sublimes_at(id, p_pa):
		var t_sub: float = S.sublimation_c_at(id, p_pa)
		for d in [-200.0, -1.0, 0.0, 1.0, 100.0, 1000.0, 3000.0]:
			out.append(t_sub + float(d))
		return out
	for d in [-200.0, -1.0, 0.0, 1.0]:
		out.append(melt + float(d))
	var boil: float = S.boil_c_at(id, p_pa)
	if not is_finite(boil):
		out.append_array([melt + 500.0, melt + 2000.0] as Array[float])
		return out
	out.append(0.5 * (melt + boil))
	for d in [-1.0, 0.0, 1.0, 100.0, 1000.0, 3000.0]:
		out.append(boil + float(d))
	return out


func _check_sweep(id: String, p_pa: float, label: String) -> bool:
	var ok: bool = true
	var worst: float = 0.0
	var worst_t: float = 0.0
	for t in _sweep_points(id, p_pa):
		var h: float = S.enthalpy_at(id, t, p_pa)
		if not is_finite(h):
			push_error("enthalpy_at(%s, %.3f C, %s) is not finite. The forward curve has a hole in it."
				% [id, t, label])
			ok = false
			continue
		var back: float = float(S.enthalpy_to_state(id, h, p_pa)["t_c"])
		var err: float = absf(back - t)
		if err > worst:
			worst = err
			worst_t = t
		if err > TOL_K:
			push_error(("%s at %s: %.4f C goes in as %s J/kg and comes back %.4f C, off by %s K. The "
				% [id, label, t, String.num_scientific(h), back, String.num_scientific(err)])
				+ "two halves of the enthalpy curve are not the same curve on this rung.")
			ok = false
	print("ENTHALPY_ROUNDTRIP={\"id\":\"%s\",\"at\":\"%s\",\"worst_err_k\":%s,\"at_t_c\":%.3f}"
		% [id, label, String.num_scientific(worst), worst_t])
	return ok


## A plateau absorbs its latent heat with the temperature pinned. Both ends must read the plateau
## temperature, and the far end must be exactly the latent heat above the near one — a plateau of the wrong
## width is a phase change that skips part of its latent heat.
func _check_plateau(id: String, p_pa: float, t_plateau: float, latent: float, label: String) -> bool:
	if latent <= 0.0:
		push_error("%s at %s has no latent heat, so there is no plateau to cross." % [id, label])
		return false
	var ok: bool = true
	var h_lo: float = S.enthalpy_at(id, t_plateau, p_pa)
	var h_hi: float = h_lo + latent
	for probe in [h_lo, h_lo + 0.5 * latent, h_hi - 1.0e-3]:
		var t_back: float = float(S.enthalpy_to_state(id, float(probe), p_pa)["t_c"])
		if absf(t_back - t_plateau) > TOL_K:
			push_error("%s %s plateau: %s J/kg reads %.4f C, not the %.4f C the boundary sits at."
				% [id, label, String.num_scientific(float(probe)), t_back, t_plateau])
			ok = false
	var past: float = float(S.enthalpy_to_state(id, h_hi + 1.0, p_pa)["t_c"])
	if past < t_plateau - TOL_K:
		push_error("%s %s plateau: one joule past the top of it the temperature has fallen to %.4f C."
			% [id, label, past])
		ok = false
	if absf(past - t_plateau) > 100.0:
		push_error(("%s %s plateau: one joule past the top the temperature jumps to %.4f C. The plateau "
			% [id, label, past]) + "is not the width of its latent heat.")
		ok = false
	return ok


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = true

	# WATER, the full ladder: solid ramp, fusion plateau, liquid ramp, boiling plateau, dissociating gas.
	ok = _check_sweep("h2o", P_ATM, "1 atm") and ok
	# BELOW THE TRIPLE POINT there is no liquid at all: solid ramp, sublimation plateau, gas.
	ok = _check_sweep("h2o", P_BELOW_TRIPLE, "100 Pa") and ok
	# ABOVE THE CRITICAL PRESSURE the boiling plateau has zero width and must not be charged.
	ok = _check_sweep("h2o", P_ABOVE_CRITICAL, "500 bar") and ok
	# SILICATE never boils on this planet, so the liquid ramp has no upper end.
	ok = _check_sweep("silicate", P_ATM, "1 atm") and ok
	ok = _check_sweep("silicate", P_ABOVE_CRITICAL, "500 bar") and ok

	var l_fus_h2o: float = float(S.table()["h2o"]["latent_fusion_j_kg"])
	var melt_h2o: float = S.melt_c_at("h2o", P_ATM)
	ok = _check_plateau("h2o", P_ATM, melt_h2o, l_fus_h2o, "fusion") and ok
	var boil_h2o: float = S.boil_c_at("h2o", P_ATM)
	ok = _check_plateau("h2o", P_ATM, boil_h2o, S.latent_vaporisation_at("h2o", boil_h2o), "boiling") and ok
	var t_sub: float = S.sublimation_c_at("h2o", P_BELOW_TRIPLE)
	ok = _check_plateau("h2o", P_BELOW_TRIPLE, t_sub, S.latent_sublimation_j_kg("h2o"), "sublimation") and ok
	ok = _check_plateau("silicate", P_ATM, S.melt_c_at("silicate", P_ATM),
		float(S.table()["silicate"]["latent_fusion_j_kg"]), "fusion") and ok

	# THE FROST POINT IS A MEASURED CURVE, not whatever the fusion line extrapolates to. Ice below the
	# triple-point pressure leaves at its own temperature; reading the melting point here put it at 0 C.
	print("FROST_POINT={\"p_pa\":%.1f,\"t_c\":%.3f,\"published_c\":%.1f}"
		% [P_BELOW_TRIPLE, t_sub, FROST_POINT_AT_100PA_C])
	if absf(t_sub - FROST_POINT_AT_100PA_C) > FROST_POINT_TOL_C:
		push_error("water frosts out at %.2f C under 100 Pa, against the measured %.1f C. The solid-vapour "
			% [t_sub, FROST_POINT_AT_100PA_C] + "boundary is not the one reality has.")
		ok = false

	# NO LIQUID BELOW THE TRIPLE POINT, on either half of the curve: the solid's only exit is the vapour.
	var h_warm: float = S.enthalpy_at("h2o", t_sub + 50.0, P_BELOW_TRIPLE)
	var st: Dictionary = S.enthalpy_to_state("h2o", h_warm, P_BELOW_TRIPLE)
	if int(st["phase"]) != int(S.GAS) or float(st["melted"]) != 0.0:
		push_error("ice under 100 Pa reaches %.1f C as phase %d with melted=%.2f. Below the triple point it "
			% [t_sub + 50.0, int(st["phase"]), float(st["melted"])] + "must go straight to vapour.")
		ok = false

	# ABOVE THE CRITICAL PRESSURE there is no vaporisation plateau to charge. Two temperatures a degree
	# apart across the (absent) boundary may differ only by sensible heat.
	var t_crit: float = float(S.table()["h2o"]["critical_t_c"])
	var h_lo: float = S.enthalpy_at("h2o", t_crit - 0.5, P_ABOVE_CRITICAL)
	var h_hi: float = S.enthalpy_at("h2o", t_crit + 0.5, P_ABOVE_CRITICAL)
	var l_ref: float = float(S.table()["h2o"]["latent_vaporisation_j_kg"])
	print("SUPERCRITICAL_STEP={\"dh_j_kg\":%s,\"latent_ref_j_kg\":%s}"
		% [String.num_scientific(h_hi - h_lo), String.num_scientific(l_ref)])
	if h_hi - h_lo > 0.01 * l_ref:
		push_error("crossing the critical temperature at 500 bar costs %s J/kg. Above the critical "
			% String.num_scientific(h_hi - h_lo)
			+ "pressure the latent heat is exactly zero — there is no boundary to cross.")
		ok = false

	return ok
