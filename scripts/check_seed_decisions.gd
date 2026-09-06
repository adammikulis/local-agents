extends SceneTree

## THE FOUR SEED VALUES, each read back against what it is derived from or cited to: the surface
## temperature against the balance it solves, the mantle potential temperature against the peridotite
## melting interval, the N2 inventory against Marty's partial-pressure bound, and the spin axis against
## the declared obliquity. Every arm carries a CONTROL — a value the same test must reject — so an arm
## that passes has measured something.

## Fraction of the arriving flux the balance may miss by. The solve stops on
## LABodySeeds' own temperature tolerance, and the flux moves with the fourth power of that.
const FLUX_RESIDUAL_REL: float = 1.0e-4
## Offset the control arm displaces the surface by, K: far enough that the residual above must grow.
const CONTROL_OFFSET_K: float = 10.0
## How closely the axis must make the declared angle, degrees. Vector3 is binary32.
const ANGLE_TOL_DEG: float = 1.0e-3

var _failures: int = 0


func _require(ok: bool, msg: String) -> void:
	if ok:
		return
	_failures += 1
	printerr("SEED_DECISIONS_VIOLATION " + msg)


func _init() -> void:
	var t_c: float = LABodySeeds.surface_temp_c()
	var r_m: float = LABodySeeds.seed_radius_m("planet")
	var mass_kg: float = float(LABodySeeds.of("planet").get("mass_kg", 0.0))
	if not (is_finite(t_c) and r_m > 0.0 and mass_kg > 0.0):
		printerr("SEED_DECISIONS: the planet seed solves no surface temperature (%s), radius (%s) or "
			% [t_c, r_m] + "mass (%s), so nothing was checked." % mass_kg)
		quit(2)
		return
	var area_m2: float = 4.0 * PI * r_m * r_m
	var g_m_s2: float = LAPhysical.GRAVITATIONAL_CONSTANT * mass_kg / (r_m * r_m)
	var p_s: float = LABodySeeds.surface_pressure_pa()
	var air: Dictionary = LAFieldLithostaticSeed.seeded_air_mole_fractions()
	var albedo: float = LABodySeeds.surface_albedo()
	var s0: float = LABodySeeds.irradiance_w_m2(
		LABodySeeds.luminosity_at_epoch_w(), LABodySeeds.astronomical_unit_m())
	var q_surf: float = LAPlanetComposition.surface_heat_flux_w_m2(mass_kg, r_m)
	var net_in: float = (1.0 - albedo) * s0 / 4.0 + q_surf

	# --- 1. THE SURFACE RADIATES WHAT REACHES IT ---------------------------------------------------
	var ts_k: float = t_c + LAPhysical.KELVIN_OFFSET
	var skin_k: float = LAColumnRadiation.skin_temp_k(net_in)
	var olr: float = LAColumnRadiation.outgoing_longwave_w_m2(ts_k, skin_k, air, p_s, g_m_s2)
	var residual: float = absf(olr - net_in) / net_in
	_require(residual <= FLUX_RESIDUAL_REL,
		"the seeded column radiates %.4f W/m^2 against the %.4f that reaches it" % [olr, net_in])
	# CONTROL: displaced off the balance, the same reading must miss by more than the bar.
	var olr_off: float = LAColumnRadiation.outgoing_longwave_w_m2(
		ts_k + CONTROL_OFFSET_K, skin_k, air, p_s, g_m_s2)
	_require(absf(olr_off - net_in) / net_in > FLUX_RESIDUAL_REL,
		"a surface %.1f K off the balance still reads inside the residual bar, so the bar measures "
			% CONTROL_OFFSET_K + "nothing")

	# --- 2. A BRIGHTER SURFACE IS A COLDER ONE, and the balance still closes --------------------
	var net_bright: float = (1.0 - 2.0 * albedo) * s0 / 4.0 + q_surf
	var ts_bright: float = LAColumnRadiation.equilibrium_temp_k(net_bright, air, p_s, g_m_s2)
	_require(is_finite(ts_bright) and ts_bright < ts_k,
		"doubling the seeded albedo does not lower the surface: %s against %s" % [ts_bright, ts_k])
	var skin_bright: float = LAColumnRadiation.skin_temp_k(net_bright)
	var olr_bright: float = LAColumnRadiation.outgoing_longwave_w_m2(
		ts_bright, skin_bright, air, p_s, g_m_s2)
	_require(absf(olr_bright - net_bright) / net_bright <= FLUX_RESIDUAL_REL,
		"the balance does not close under a doubled albedo")

	# --- 3. THE MANTLE STANDS INSIDE ITS OWN MELTING INTERVAL --------------------------------------
	var tp_c: float = LAPlanetComposition.mantle_potential_temp_k() - LAPhysical.KELVIN_OFFSET
	var interval: PackedFloat64Array = LAPlanetComposition.peridotite_melting_interval_c()
	var sol: float = interval[0]
	var liq: float = interval[1]
	_require(_between(tp_c, sol, liq),
		"the mantle potential temperature %.2f C is outside the peridotite interval %.1f-%.1f C"
			% [tp_c, sol, liq])
	# CONTROL: the same test must reject a temperature outside that interval.
	_require(not _between(sol - 1.0, sol, liq) and not _between(liq + 1.0, sol, liq),
		"the melting-interval test accepts a temperature outside the interval")
	var lid_m: float = LAPlanetComposition.lid_thickness_m(r_m, t_c)
	_require(is_finite(lid_m) and lid_m > 0.0,
		"the conductive lid never meets the adiabat, so the body has no lithosphere: %s" % lid_m)

	# --- 4. THE N2 INVENTORY WEIGHS MARTY'S PARTIAL PRESSURE ----------------------------------------
	var n2_kg: float = float(LABodySeeds.of("planet").get("atmosphere_n2_kg", 0.0))
	var bound: PackedFloat64Array = LABodySeeds.archean_pn2_bound_bar()
	var pn2_bar: float = _pn2_bar(n2_kg, g_m_s2, area_m2)
	_require(_between(pn2_bar, bound[0], bound[1]),
		"the seeded N2 weighs %.3f bar, outside Marty's %.2f-%.2f bar" % [pn2_bar, bound[0], bound[1]])
	# CONTROL: three times that inventory must fall outside the same bound.
	_require(not _between(_pn2_bar(3.0 * n2_kg, g_m_s2, area_m2), bound[0], bound[1]),
		"the bound accepts three times the seeded N2, so it bounds nothing")

	# --- 5. THE SPIN AXIS MAKES THE DECLARED OBLIQUITY ----------------------------------------------
	var normal: Vector3 = LABodySeeds.orbital_normal()
	var declared: float = LABodySeeds.obliquity_deg()
	var measured: float = _angle_deg(LABodySeeds.spin_axis(), normal)
	_require(absf(measured - declared) <= ANGLE_TOL_DEG,
		"the spin axis makes %.4f deg with the orbital normal, not the declared %.4f"
			% [measured, declared])
	# CONTROL: an axis lying along the normal makes no angle, and the same test must reject it.
	_require(absf(_angle_deg(normal, normal) - declared) > ANGLE_TOL_DEG,
		"the angle test accepts an untilted axis as the declared obliquity")

	print('SEED_DECISIONS={"flux_residual_rel":%s,"lid_m":%.1f,"obliquity_deg":%.4f,"failures":%d}'
		% [residual, lid_m, measured, _failures])
	quit(1 if _failures > 0 else 0)


func _between(v: float, lo: float, hi: float) -> bool:
	return v > lo and v < hi


## Partial pressure of an inventory standing over that surface, bar: m g / A.
func _pn2_bar(kg: float, g_m_s2: float, area_m2: float) -> float:
	return kg * g_m_s2 / area_m2 / 1.0e5   # one bar in pascals, exact by definition


func _angle_deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)))
