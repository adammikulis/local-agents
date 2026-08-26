extends SceneTree

## THE FAINT-YOUNG-SUN GATE. Under the epoch's dimmed sun (Gough 1981) the seeded atmosphere must
## hold the surface above 273.15 K — the Jack Hills zircons' liquid water — through the same data the
## sim runs: the native band table, the PREBIOTIC_MOLE_FRAC_* seed composition, and the
## pressure-weighted equivalent path of Pierrehumbert ch. 4. The no-greenhouse arm must read BELOW
## freezing, so the gate cannot pass with the feature disabled.

const COEFFS: int = 11
const LAYERS: int = 40
const DIFF: float = 1.66            # LAPhysical.TWO_STREAM_DIFFUSIVITY
const STANDARD_GRAVITY_M_S2: float = 9.80665   # CODATA standard acceleration of gravity

var _nb: int = 0
var _nt: int = 0
var _edges: PackedFloat32Array = PackedFloat32Array()
var _temps: PackedFloat32Array = PackedFloat32Array()
var _kappa: PackedFloat32Array = PackedFloat32Array()
var _cdf: PackedFloat32Array = PackedFloat32Array()
var _cdf_xmax: float = 0.0


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


## Fraction of blackbody power above x = c2*nu/T, off the packed Planck cumulative table.
func _planck_above(x: float) -> float:
	if x <= 0.0:
		return 1.0
	if x >= _cdf_xmax:
		return 0.0
	var t: float = x / _cdf_xmax * float(_cdf.size() - 1)
	var i: int = int(t)
	return lerpf(_cdf[i], _cdf[mini(i + 1, _cdf.size() - 1)], t - float(i))


## Share of sigma*T^4 in band b at temperature tk. The outermost band keeps everything above its edge.
func _band_weight(b: int, tk: float) -> float:
	var c2: float = LAPhysical.PLANCK_C2_CM_K
	var lo: float = _planck_above(c2 * _edges[b] / tk)
	if b + 1 >= _nb:
		return lo
	return maxf(lo - _planck_above(c2 * _edges[b + 1] / tk), 0.0)


func _kappa_at(b: int, k: int, tk: float) -> float:
	var i: int = 0
	var f: float = 0.0
	if tk <= _temps[0]:
		i = 0
	elif tk >= _temps[_nt - 1]:
		i = _nt - 2
	else:
		while i < _nt - 2 and tk > _temps[i + 1]:
			i += 1
		f = (tk - _temps[i]) / (_temps[i + 1] - _temps[i])
	var o: int = b * COEFFS + k
	var stride: int = _nb * COEFFS
	return lerpf(_kappa[o + i * stride], _kappa[o + (i + 1) * stride], f)


## Band optical depth of a layer holding `du` of each absorber path (the kernel's band_tau, column form).
func _layer_tau(b: int, tk: float, du: PackedFloat64Array) -> float:
	var tau: float = (_kappa_at(b, 0, tk) + _kappa_at(b, 1, tk)) * du[0] \
		+ _kappa_at(b, 2, tk) * du[1] + _kappa_at(b, 3, tk) * du[2] + _kappa_at(b, 4, tk) * du[3] \
		+ _kappa_at(b, 5, tk) * du[4] + _kappa_at(b, 6, tk) * du[5]
	tau += _kappa_at(b, 7, tk) * du[6] + _kappa_at(b, 8, tk) * du[7] \
		+ _kappa_at(b, 9, tk) * du[8] + _kappa_at(b, 10, tk) * du[9]
	return tau


## Outgoing longwave, W/m^2, for surface temperature ts_k: N layers on the dry adiabat of the seeded gas
## mix, floored at the grey skin temperature (Pierrehumbert, Principles of Planetary Climate, ch. 3-4).
func _olr(ts_k: float, paths: PackedFloat64Array, r_over_cp: float, t_skin: float) -> float:
	var sigma: float = LAPhysical.STEFAN_BOLTZMANN
	# Layer k spans equal pressure increments; its path share of the p^2-weighted column is quadratic.
	var t_layer: PackedFloat64Array = PackedFloat64Array()
	var frac: PackedFloat64Array = PackedFloat64Array()
	for k in LAYERS:
		var p_mid: float = (float(k) + 0.5) / float(LAYERS)
		t_layer.append(maxf(ts_k * pow(p_mid, r_over_cp), t_skin))
		var hi: float = (float(k) + 1.0) / float(LAYERS)
		var lo: float = float(k) / float(LAYERS)
		frac.append(hi * hi - lo * lo)
	var olr: float = 0.0
	for b in _nb:
		# k ascends from the top of the atmosphere down, so `above` is the depth between layer and space.
		var above: float = 0.0
		var flux: float = 0.0
		for k in LAYERS:
			var du: PackedFloat64Array = PackedFloat64Array()
			for a in paths.size():
				du.append(paths[a] * frac[k])
			var tk: float = t_layer[k]
			var dtau: float = _layer_tau(b, tk, du)
			var emis: float = 1.0 - exp(-DIFF * dtau)
			flux += _band_weight(b, tk) * sigma * pow(tk, 4.0) * emis * exp(-DIFF * above)
			above += dtau
		flux += _band_weight(b, ts_k) * sigma * pow(ts_k, 4.0) * exp(-DIFF * above)
		olr += flux
	return olr


## Surface temperature at which OLR balances absorbed sunlight, by bisection. OLR is monotonic in ts.
func _solve_ts(absorbed: float, paths: PackedFloat64Array, r_over_cp: float, t_skin: float) -> float:
	var lo: float = 150.0
	var hi: float = 500.0
	for _i in 60:
		var mid: float = 0.5 * (lo + hi)
		if _olr(mid, paths, r_over_cp, t_skin) < absorbed:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


func _init() -> void:
	var packed: PackedFloat32Array = LAAbsorptionBands.packed()
	if packed.is_empty():
		_fail("LAAbsorptionBands.packed() is empty — the native band table did not load.")
		return
	_nb = int(packed[0])
	var cdf_count: int = int(packed[1])
	_cdf_xmax = packed[2]
	_nt = int(packed[3])
	var want: int = 4 + (_nb + 1) + _nt + _nb + _nt * _nb * COEFFS + cdf_count
	if packed.size() != want:
		_fail("LAAbsorptionBands.packed() holds %d floats, not the %d an %d-coefficient table packs — "
			% [packed.size(), want, COEFFS]
			+ "the compiled extension disagrees with the emitted table. Rebuild the GDExtension.")
		return
	var o: int = 4
	_edges = packed.slice(o, o + _nb + 1)
	o += _nb + 1
	_temps = packed.slice(o, o + _nt)
	o += _nt
	o += _nb   # solar weights: the shortwave side; this column balances at TOA so only the total enters
	_kappa = packed.slice(o, o + _nt * _nb * COEFFS)
	o += _nt * _nb * COEFFS
	_cdf = packed.slice(o, o + cdf_count)

	# The seeded surface: 1 atm total, the PREBIOTIC composition, dry (the field seeds no vapour aloft).
	var p_s: float = LAPhysical.STANDARD_PRESSURE_PA
	var g: float = STANDARD_GRAVITY_M_S2
	var p_ref: float = LAPhysical.ABSORPTION_REF_PRESSURE_PA
	var x: Dictionary = {
		"co2": LAPhysical.PREBIOTIC_MOLE_FRAC_CO2, "n2": LAPhysical.PREBIOTIC_MOLE_FRAC_N2,
		"h2": LAPhysical.PREBIOTIC_MOLE_FRAC_H2, "co": LAPhysical.PREBIOTIC_MOLE_FRAC_CO,
		"ch4": LAPhysical.PREBIOTIC_MOLE_FRAC_CH4, "so2": LAPhysical.PREBIOTIC_MOLE_FRAC_SO2,
		"h2s": LAPhysical.PREBIOTIC_MOLE_FRAC_H2S,
	}
	var table: Dictionary = LASubstances.table()
	var m_air: float = 0.0
	var cp_mol: float = 0.0
	for id in x:
		var mm: float = float(table[id]["molar_mass"])
		m_air += float(x[id]) * mm
		cp_mol += float(x[id]) * float(table[id]["specific_heat_gas"]) * mm
	var r_over_cp: float = LAPhysical.GAS_CONSTANT_J_MOL_K / cp_mol
	# Pressure-weighted equivalent path of a well-mixed absorber: q * p_s^2 / (2 g p_ref), kg/m^2
	# (Pierrehumbert 4.2.2 — the reduction the band coefficients are stated in). CO2-CO2 CIA scales with
	# the CO2 partial pressure, adding a factor x_co2.
	var col: float = p_s * p_s / (2.0 * g * p_ref)
	var q_co2: float = float(x["co2"]) * float(table["co2"]["molar_mass"]) / m_air
	# Path order matches the kappa columns: CO2 line, CO2 CIA, H2O line, H2O cont, O3 line, O3 xsc,
	# CH4, CO, SO2, H2S. The seed atmosphere is dry and ozone-free, so those four legs are zero.
	var paths: PackedFloat64Array = PackedFloat64Array()
	paths.append(q_co2 * col)
	paths.append(q_co2 * float(x["co2"]) * col)
	paths.append(0.0)
	paths.append(0.0)
	paths.append(0.0)
	paths.append(0.0)
	for id in ["ch4", "co", "so2", "h2s"]:
		paths.append(float(x[id]) * float(table[id]["molar_mass"]) / m_air * col)

	# The flux this planet actually receives: the epoch star's luminosity over the sphere it has spread
	# across by the time it arrives. No solar constant, because a constant is a fact about one orbit.
	var s0: float = LABodySeeds.irradiance_w_m2(
		LABodySeeds.luminosity_at_epoch_w(), LABodySeeds.ASTRONOMICAL_UNIT_M)
	var albedo: float = LAPhysical.ALBEDO_BARE_GROUND
	var absorbed: float = (1.0 - albedo) * s0 / 4.0
	var t_skin: float = pow(absorbed / LAPhysical.STEFAN_BOLTZMANN, 0.25) * pow(0.5, 0.25)
	var ts: float = _solve_ts(absorbed, paths, r_over_cp, t_skin)
	var bare: PackedFloat64Array = PackedFloat64Array()
	for _a in paths.size():
		bare.append(0.0)
	var ts_bare: float = _solve_ts(absorbed, bare, r_over_cp, t_skin)

	var freeze_k: float = LAPhysical.WATER_FREEZE_C + LAPhysical.KELVIN_OFFSET
	var fails: int = 0
	if ts <= freeze_k:
		fails += 1
	if ts_bare >= freeze_k:
		fails += 1
	print('FAINT_YOUNG_SUN={"solar_w_m2":%.2f,"ts_k":%.2f,"ts_no_greenhouse_k":%.2f,"freeze_k":%.2f,"failures":%d}'
		% [s0, ts, ts_bare, freeze_k, fails])
	quit(1 if fails > 0 else 0)
