@tool
extends RefCounted

## Checks the radiative model against measured planets: Earth clear-sky OLR, the forcing of a CO2
## doubling, and the CO2 share of Venus's greenhouse at 92 bar. All three run LARadiativeColumn, which
## is the CPU counterpart of kernels3d/heat3d_solar_sphere3d.glsl.

const Rad: GDScript = preload("res://addons/local_agents/sim/material/RadiativeColumn.gd")
const Bands: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")

const LAYERS: int = 60
const TOP_PRESSURE_RATIO: float = 1.0e-4     # column top, as a fraction of the surface pressure

# --- EARTH (measured) --------------------------------------------------------------------------------
## This suite validates the solver against EARTH's measured column, so Earth's surface gravity is a
## FIXTURE of the test, not this planet's gravity. The planet's g is solved per cell (LAFieldGravity).
const EARTH_G_M_S2: float = 9.80665
const EARTH_SURFACE_PA: float = 1.0e5
const EARTH_SURFACE_K: float = 288.15
const EARTH_LAPSE_K_PER_KM: float = 6.5           # ICAO standard troposphere
const EARTH_TROPOPAUSE_K: float = 216.65
const EARTH_CO2_PPMV: float = 400.0
const EARTH_RH: float = 0.75                      # global-mean tropospheric relative humidity
const EARTH_CLEAR_SKY_OLR: float = 265.0          # Trenberth, Fasullo & Kiehl 2009 (BAMS 90:311)
const EARTH_OLR_TOLERANCE: float = 25.0
const CO2_DOUBLING_FORCING: float = 3.7           # IPCC AR6 ch.7; assessments give 3.7-4.0 W/m^2
const FORCING_TOLERANCE: float = 1.2

# --- VENUS (measured) --------------------------------------------------------------------------------
const VENUS_SURFACE_PA: float = 9.2e6
const VENUS_GRAVITY: float = 8.87
const VENUS_ADIABAT_EXPONENT: float = 0.176       # fits the VIRA sounding: 340 K at 1 bar, 240 K at 0.1 bar
const VENUS_TOP_K: float = 170.0
const VENUS_ABSORBED_W_M2: float = 157.0          # 2601 W/m^2 * (1 - 0.77) / 4, Bond albedo 0.77
const VENUS_EFFECTIVE_K: float = 232.0            # (157/sigma)^(1/4)
## Pollack et al. 1980 (JGR 85:8223): about 300 K of Venus's 505 K greenhouse is CO2 alone, the rest SO2,
## H2O and the sulfuric-acid clouds, which this substrate does not carry.
const VENUS_CO2_WARMING_K: float = 300.0
const VENUS_WARMING_TOLERANCE_K: float = 60.0


func run_test(_tree) -> bool:
	var ok: bool = true
	print("RADIATIVE_BANDS={\"bands\":%d,\"temps\":%d,\"ref_pa\":%.0f}"
		% [Bands.BAND_COUNT, Bands.TEMP_COUNT, Bands.REF_PRESSURE_PA])

	var e1: Dictionary = _earth(EARTH_CO2_PPMV)
	var e2: Dictionary = _earth(EARTH_CO2_PPMV * 2.0)
	var olr1: float = float(e1["olr"])
	var forcing: float = olr1 - float(e2["olr"])
	print("EARTH_OLR={\"co2_ppmv\":%.0f,\"olr\":%.1f,\"measured\":%.1f,\"back_radiation\":%.1f}"
		% [EARTH_CO2_PPMV, olr1, EARTH_CLEAR_SKY_OLR, float(e1["lw_down_surface"])])
	print("CO2_DOUBLING={\"forcing_w_m2\":%.2f,\"measured\":%.2f}" % [forcing, CO2_DOUBLING_FORCING])
	if absf(olr1 - EARTH_CLEAR_SKY_OLR) > EARTH_OLR_TOLERANCE:
		push_error("Earth clear-sky OLR is %.1f W/m^2 against a measured %.1f. A 1 bar, 400 ppm CO2, "
			% [olr1, EARTH_CLEAR_SKY_OLR] + "moist column has to radiate near the measured value.")
		ok = false
	if absf(forcing - CO2_DOUBLING_FORCING) > FORCING_TOLERANCE:
		push_error("doubling CO2 changes the OLR by %.2f W/m^2 against a measured %.2f. The band model "
			% [forcing, CO2_DOUBLING_FORCING] + "must reproduce the forcing of a doubling; if it does "
			+ "not, the wings of the 667 cm^-1 band are the wrong width and no CO2 result means anything.")
		ok = false

	var t_eq: float = _venus_equilibrium()
	var warming: float = t_eq - VENUS_EFFECTIVE_K
	print("VENUS_CO2_ONLY={\"surface_k\":%.0f,\"warming_k\":%.0f,\"pollack_co2_share_k\":%.0f,"
		% [t_eq, warming, VENUS_CO2_WARMING_K] + "\"observed_surface_k\":737}")
	if absf(warming - VENUS_CO2_WARMING_K) > VENUS_WARMING_TOLERANCE_K:
		push_error("a 92 bar CO2 column in radiative-convective balance with 157 W/m^2 warms its surface "
			+ "by %.0f K over the %.0f K effective temperature, against the %.0f K Pollack et al. 1980 "
			% [warming, VENUS_EFFECTIVE_K, VENUS_CO2_WARMING_K]
			+ "attribute to CO2. Pressure broadening and collision-induced absorption are the whole "
			+ "reason this is a band model; if the hundred-bar case is wrong the model is not finished.")
		ok = false
	return ok


## Hydrostatic column of `LAYERS` slabs, even in log pressure, ordered OUTWARD from the surface.
func _column(p_surf: float, g: float, t_of_p: Callable, q_co2: Callable,
		q_h2o: Callable) -> Dictionary:
	var t_k: PackedFloat32Array = PackedFloat32Array()
	var p_pa: PackedFloat32Array = PackedFloat32Array()
	var u_co2: PackedFloat32Array = PackedFloat32Array()
	var u_h2o: PackedFloat32Array = PackedFloat32Array()
	var p_co2: PackedFloat32Array = PackedFloat32Array()
	var p_h2o: PackedFloat32Array = PackedFloat32Array()
	for j in LAYERS:
		var f_lo: float = p_surf * pow(TOP_PRESSURE_RATIO, float(j) / float(LAYERS))
		var f_hi: float = p_surf * pow(TOP_PRESSURE_RATIO, float(j + 1) / float(LAYERS))
		var dp: float = f_lo - f_hi
		var p_mid: float = 0.5 * (f_lo + f_hi)
		var t: float = float(t_of_p.call(p_mid))
		var qc: float = float(q_co2.call(p_mid))
		var qw: float = float(q_h2o.call(p_mid, t))
		t_k.append(t)
		p_pa.append(p_mid)
		u_co2.append(qc * dp / g)
		u_h2o.append(qw * dp / g)
		# Partial pressure from the MASS mixing ratio: x = q * M_air / M_gas.
		p_co2.append(qc * p_mid * LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL / LAPhysical.MOLAR_MASS_CO2_KG_MOL)
		p_h2o.append(qw * p_mid * LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL / LAPhysical.MOLAR_MASS_WATER_KG_MOL)
	return {"t_k": t_k, "p_pa": p_pa, "u_co2": u_co2, "u_h2o": u_h2o,
		"p_co2": p_co2, "p_h2o": p_h2o}


func _solve(col: Dictionary, t_s: float, emis: float, albedo: float) -> Dictionary:
	return Rad.solve(col["t_k"], col["p_pa"], col["u_co2"], col["u_h2o"], col["p_co2"], col["p_h2o"],
		t_s, emis, albedo, 0.0, 1.0)


func _earth(ppmv: float) -> Dictionary:
	var scale_h: float = LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK * EARTH_SURFACE_K \
		/ EARTH_G_M_S2
	var t_of_p: Callable = func(p: float) -> float:
		var z_km: float = scale_h * log(EARTH_SURFACE_PA / maxf(p, 1.0)) / 1000.0
		return maxf(EARTH_SURFACE_K - EARTH_LAPSE_K_PER_KM * z_km, EARTH_TROPOPAUSE_K)
	var q_co2: Callable = func(_p: float) -> float:
		return ppmv * 1.0e-6 * LAPhysical.MOLAR_MASS_CO2_KG_MOL / LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL
	var q_h2o: Callable = func(p: float, t: float) -> float:
		var tc: float = t - LAPhysical.KELVIN_OFFSET
		var e_sat: float = LAPhysical.MAGNUS_A_PA * exp(LAPhysical.MAGNUS_B * tc
			/ (tc + LAPhysical.MAGNUS_C_C))
		var x: float = minf(EARTH_RH * e_sat / maxf(p, 1.0), 1.0)
		return x * LAPhysical.MOLAR_MASS_WATER_KG_MOL / LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL
	return _solve(_column(EARTH_SURFACE_PA, EARTH_G_M_S2, t_of_p, q_co2, q_h2o),
		EARTH_SURFACE_K, LAPhysical.EMISSIVITY_WATER, LAPhysical.ALBEDO_OCEAN)


func _venus_olr(t_s: float) -> float:
	var t_of_p: Callable = func(p: float) -> float:
		return maxf(t_s * pow(maxf(p, 1.0) / VENUS_SURFACE_PA, VENUS_ADIABAT_EXPONENT), VENUS_TOP_K)
	var col: Dictionary = _column(VENUS_SURFACE_PA, VENUS_GRAVITY, t_of_p,
		func(_p: float) -> float: return 1.0,
		func(_p: float, _t: float) -> float: return 0.0)
	return float(_solve(col, t_s, LAPhysical.BASALT_EMISSIVITY, LAPhysical.ALBEDO_BARE_GROUND)["olr"])


## Surface temperature at which the column's OLR balances what Venus absorbs, on Venus's own adiabat.
func _venus_equilibrium() -> float:
	var lo: float = 250.0
	var hi: float = 900.0
	for _i in 24:
		var mid: float = 0.5 * (lo + hi)
		if _venus_olr(mid) > VENUS_ABSORBED_W_M2:
			hi = mid
		else:
			lo = mid
	return 0.5 * (lo + hi)
