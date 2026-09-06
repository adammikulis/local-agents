extends SceneTree

## THE FAINT-YOUNG-SUN GATE. Under the epoch's dimmed sun the seed's own surface must stand above
## 273.15 K — the Jack Hills zircons' liquid water — through the balance LABodySeeds solves and the
## band table the sim runs. The no-greenhouse arm stands the same column in a gas with no dipole and
## must read BELOW freezing, so the gate cannot pass with the feature disabled.


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


func _init() -> void:
	var t_c: float = LABodySeeds.surface_temp_c()
	var r_m: float = LABodySeeds.seed_radius_m("planet")
	var mass_kg: float = float(LABodySeeds.of("planet").get("mass_kg", 0.0))
	if not (is_finite(t_c) and r_m > 0.0 and mass_kg > 0.0):
		_fail("FAINT_YOUNG_SUN: the planet seed solves no surface balance, so nothing was checked.")
		return
	var g_m_s2: float = LAPhysical.GRAVITATIONAL_CONSTANT * mass_kg / (r_m * r_m)
	var p_s: float = LABodySeeds.surface_pressure_pa()
	var s0: float = LABodySeeds.irradiance_w_m2(
		LABodySeeds.luminosity_at_epoch_w(), LABodySeeds.astronomical_unit_m())
	var net_in: float = (1.0 - LABodySeeds.surface_albedo()) * s0 / 4.0 \
		+ LAPlanetComposition.surface_heat_flux_w_m2(mass_kg, r_m)
	# The same column in a gas that cannot absorb in the thermal infrared: N2 has no dipole and carries
	# no band, so this is the seed's air with its greenhouse taken out and nothing else changed.
	var bare: Dictionary = {"n2": 1.0}
	var ts_bare: float = LAColumnRadiation.equilibrium_temp_k(net_in, bare, p_s, g_m_s2)

	var ts: float = t_c + LAPhysical.KELVIN_OFFSET
	var freeze_k: float = LAPhysical.WATER_FREEZE_C + LAPhysical.KELVIN_OFFSET
	var fails: int = 0
	if ts <= freeze_k:
		fails += 1
	if not is_finite(ts_bare) or ts_bare >= freeze_k:
		fails += 1
	print('FAINT_YOUNG_SUN={"solar_w_m2":%.2f,"ts_k":%.2f,"ts_no_greenhouse_k":%.2f,"freeze_k":%.2f,"failures":%d}'
		% [s0, ts, ts_bare, freeze_k, fails])
	quit(1 if fails > 0 else 0)
