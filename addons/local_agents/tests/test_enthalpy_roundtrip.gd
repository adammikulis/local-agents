@tool
extends RefCounted

## T -> h -> T through enthalpy_at() and enthalpy_to_state(), on every rung and at every pressure.

const S: GDScript = preload("res://addons/local_agents/sim/material/Substances.gd")
const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## Round-trip tolerance, kelvin.
const TOL_K: float = 1.0e-6

## Murphy & Koop 2005, ice saturation.
const FROST_POINT_AT_100PA_C: float = -20.3
const FROST_POINT_TOL_C: float = 2.0

const P_ATM: float = 101325.0
const P_BELOW_TRIPLE: float = 100.0
const P_ABOVE_CRITICAL: float = 5.0e7


## Every rung of the ladder at this pressure, plus a point either side of every boundary.
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
	var liquidus: float = S.liquidus_c_at(id, p_pa)
	if liquidus > melt:
		out.append_array([0.5 * (melt + liquidus), liquidus - 1.0, liquidus, liquidus + 1.0]
			as Array[float])
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


## Both ends of a plateau read its temperature, and its width is the latent heat.
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


## Solidus to liquidus: ends read the boundaries, melt fraction runs 0 -> 1, cost is the lever rule.
func _check_interval(id: String, p_pa: float, label: String) -> bool:
	var solidus: float = S.melt_c_at(id, p_pa)
	var liquidus: float = S.liquidus_c_at(id, p_pa)
	if liquidus <= solidus:
		push_error("%s at %s melts at a point, not over an interval." % [id, label])
		return false
	var ok: bool = true
	var h_sol: float = S.enthalpy_at(id, solidus, p_pa)
	var h_liq: float = S.enthalpy_at(id, liquidus, p_pa)
	var c_liq: float = float(S.table()[id]["specific_heat"])
	var l_fus: float = float(S.table()[id]["latent_fusion_j_kg"])
	var want: float = l_fus + c_liq * (liquidus - solidus)
	if absf((h_liq - h_sol) - want) > 1.0e-6 * want:
		push_error("%s %s: crossing the mush costs %s J/kg, not the %s the lever rule says."
			% [id, label, String.num_scientific(h_liq - h_sol), String.num_scientific(want)])
		ok = false
	var prev: float = solidus - 1.0
	for f in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var st: Dictionary = S.enthalpy_to_state(id, h_sol + float(f) * (h_liq - h_sol), p_pa)
		var t: float = float(st["t_c"])
		if t <= prev:
			push_error("%s %s: temperature stopped rising through the mush at %.4f C." % [id, label, t])
			ok = false
		prev = t
		if t < solidus - TOL_K or t > liquidus + TOL_K:
			push_error("%s %s: the mush reached %.4f C, outside %.1f..%.1f C."
				% [id, label, t, solidus, liquidus])
			ok = false
		if float(st["melted"]) < -TOL_K or float(st["melted"]) > 1.0 + TOL_K:
			push_error("%s %s: melt fraction %.4f is not a fraction." % [id, label, float(st["melted"])])
			ok = false
	return ok


## enthalpy.glsli and mixture_enthalpy.glsli compile, read off enthalpy_selftest.glsl's SPIR-V.
func _check_glsl_compiles() -> bool:
	var path: String = "res://addons/local_agents/sim/material/kernels3d/enthalpy_selftest.glsl"
	var f: RDShaderFile = load(path)
	if f == null:
		push_error("%s did not load. The GPU half of the enthalpy curve is unverified." % path)
		return false
	var err: String = f.get_spirv().compile_error_compute
	if err != "":
		push_error("enthalpy.glsli / mixture_enthalpy.glsli do not compile:\n%s" % err)
		return false
	return true


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = _check_glsl_compiles()

	ok = _check_sweep("h2o", P_ATM, "1 atm") and ok
	ok = _check_sweep("h2o", P_BELOW_TRIPLE, "100 Pa") and ok
	ok = _check_sweep("h2o", P_ABOVE_CRITICAL, "500 bar") and ok
	ok = _check_sweep("silicate", P_ATM, "1 atm") and ok
	ok = _check_sweep("silicate", P_ABOVE_CRITICAL, "500 bar") and ok

	var l_fus_h2o: float = float(S.table()["h2o"]["latent_fusion_j_kg"])
	var melt_h2o: float = S.melt_c_at("h2o", P_ATM)
	ok = _check_plateau("h2o", P_ATM, melt_h2o, l_fus_h2o, "fusion") and ok
	var boil_h2o: float = S.boil_c_at("h2o", P_ATM)
	ok = _check_plateau("h2o", P_ATM, boil_h2o, S.latent_vaporisation_at("h2o", boil_h2o), "boiling") and ok
	var t_sub: float = S.sublimation_c_at("h2o", P_BELOW_TRIPLE)
	ok = _check_plateau("h2o", P_BELOW_TRIPLE, t_sub, S.latent_sublimation_j_kg("h2o"), "sublimation") and ok
	ok = _check_interval("silicate", P_ATM, "1 atm") and ok
	ok = _check_interval("silicate", P_ABOVE_CRITICAL, "500 bar") and ok

	print("FROST_POINT={\"p_pa\":%.1f,\"t_c\":%.3f,\"published_c\":%.1f}"
		% [P_BELOW_TRIPLE, t_sub, FROST_POINT_AT_100PA_C])
	if absf(t_sub - FROST_POINT_AT_100PA_C) > FROST_POINT_TOL_C:
		push_error("water frosts out at %.2f C under 100 Pa, against the measured %.1f C. The solid-vapour "
			% [t_sub, FROST_POINT_AT_100PA_C] + "boundary is not the one reality has.")
		ok = false

	var h_warm: float = S.enthalpy_at("h2o", t_sub + 50.0, P_BELOW_TRIPLE)
	var st: Dictionary = S.enthalpy_to_state("h2o", h_warm, P_BELOW_TRIPLE)
	if int(st["phase"]) != int(S.GAS) or float(st["melted"]) != 0.0:
		push_error("ice under 100 Pa reaches %.1f C as phase %d with melted=%.2f. Below the triple point it "
			% [t_sub + 50.0, int(st["phase"]), float(st["melted"])] + "must go straight to vapour.")
		ok = false

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
