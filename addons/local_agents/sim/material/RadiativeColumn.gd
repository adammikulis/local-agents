class_name LARadiativeColumn
extends RefCounted

## Two-stream band radiative transfer over one radial column. CPU counterpart of
## kernels3d/heat3d_solar_sphere3d.glsl — same bands, same paths, same sweeps.
##
## Optical depth is a sum over absorbers, tau_b = sum_i kappa_b_i(p, T) * u_i, with u_i the layer mass
## path (kg/m^2) and kappa from LAAbsorptionBands. Lorentz collisional broadening makes kappa proportional
## to the broadener's pressure: the line terms and the air-induced continuum scale with the total
## pressure, the CO2-CO2 collision-induced term with the CO2 partial pressure, the water continuum with
## the water partial pressure. N2, O2 and Ar have no dipole transitions here and appear nowhere.

const Bands: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")

const DIFFUSIVITY: float = LAPhysical.TWO_STREAM_DIFFUSIVITY

static var _cdf: PackedFloat32Array = PackedFloat32Array()


## Fraction of blackbody power emitted above dimensionless frequency x = c2*nu/T. Siegel & Howell series;
## planck_above(0) == 1.
static func planck_above(x: float) -> float:
	if x <= 0.0:
		return 1.0
	if x > 60.0:
		return 0.0
	var sum: float = 0.0
	for n in range(1, 40):
		var fn: float = float(n)
		sum += exp(-fn * x) * (x * x * x / fn + 3.0 * x * x / (fn * fn)
			+ 6.0 * x / (fn * fn * fn) + 6.0 / (fn * fn * fn * fn))
	return 15.0 / pow(PI, 4.0) * sum


## The same, sampled on the table the GPU is handed, so both sides read the same curve.
static func planck_above_lut(x: float) -> float:
	if _cdf.is_empty():
		_cdf.resize(Bands.CDF_COUNT)
		for i in Bands.CDF_COUNT:
			_cdf[i] = planck_above(Bands.CDF_XMAX * float(i) / float(Bands.CDF_COUNT - 1))
	if x <= 0.0:
		return 1.0
	if x >= Bands.CDF_XMAX:
		return 0.0
	var t: float = x / Bands.CDF_XMAX * float(Bands.CDF_COUNT - 1)
	var i: int = int(t)
	return lerpf(_cdf[i], _cdf[i + 1], t - float(i))


## Share of a blackbody's sigma*T^4 falling in band `b`. The outermost band carries everything above its
## lower edge, so the weights sum to exactly 1 and no emission is lost off the end of the table.
static func band_weight(b: int, t_k: float) -> float:
	var edges: PackedFloat32Array = Bands.edges_cm1()
	var c2: float = LAPhysical.PLANCK_C2_CM_K
	var lo: float = planck_above_lut(c2 * edges[b] / maxf(t_k, 1.0))
	if b >= Bands.BAND_COUNT - 1:
		return lo
	return maxf(lo - planck_above_lut(c2 * edges[b + 1] / maxf(t_k, 1.0)), 0.0)


## Partial pressure of an ideal gas of density `rho` at `t_k`, given its specific gas constant.
static func partial_pressure_pa(rho: float, t_k: float, gas_const: float) -> float:
	return rho * gas_const * maxf(t_k, 1.0)


## Solve one column. Layer arrays run OUTWARD from the first cell above the surface.
##   t_k, p_pa, u_co2, u_h2o, p_co2_pa, p_h2o_pa : per layer (K, Pa, kg/m^2, kg/m^2, Pa, Pa)
##   s_toa : solar flux on the horizontal at the top of the column, W/m^2
##   mu    : cosine of the solar zenith angle, floored at the horizon air mass
## Returns net radiative flux convergence per layer and at the surface, W/m^2, plus the OLR.
static func solve(t_k: PackedFloat32Array, p_pa: PackedFloat32Array, u_co2: PackedFloat32Array,
		u_h2o: PackedFloat32Array, p_co2_pa: PackedFloat32Array, p_h2o_pa: PackedFloat32Array,
		t_surface_k: float, emissivity: float, albedo: float,
		s_toa: float, mu: float) -> Dictionary:
	var n: int = t_k.size()
	var nb: int = Bands.BAND_COUNT
	var net: PackedFloat32Array = PackedFloat32Array()
	net.resize(n)
	var net_surface: float = 0.0
	var olr: float = 0.0
	var lw_down_surface: float = 0.0
	var sw_atm: float = 0.0
	var sw_surface: float = 0.0
	var sigma: float = LAPhysical.STEFAN_BOLTZMANN
	var tr: PackedFloat32Array = PackedFloat32Array()
	var bl: PackedFloat32Array = PackedFloat32Array()
	tr.resize(n)
	bl.resize(n)

	# Per layer: the four pressure-weighted mass paths, the temperature slice, and sigma*T^4.
	var a_co2: PackedFloat32Array = PackedFloat32Array()
	var a_cia: PackedFloat32Array = PackedFloat32Array()
	var a_h2o: PackedFloat32Array = PackedFloat32Array()
	var a_hc: PackedFloat32Array = PackedFloat32Array()
	var t4: PackedFloat32Array = PackedFloat32Array()
	var slice_lo: PackedInt32Array = PackedInt32Array()
	var slice_f: PackedFloat32Array = PackedFloat32Array()
	var r: float = 1.0 / Bands.REF_PRESSURE_PA
	for j in n:
		a_co2.append(p_pa[j] * r * u_co2[j])
		a_cia.append(p_co2_pa[j] * r * u_co2[j])
		a_h2o.append(p_pa[j] * r * u_h2o[j])
		a_hc.append(p_h2o_pa[j] * r * u_h2o[j])
		t4.append(pow(maxf(t_k[j], 1.0), 4.0))
		var sl: Vector2 = Bands.slice_of(t_k[j])
		slice_lo.append(int(sl.x))
		slice_f.append(sl.y)
	var t4s: float = pow(maxf(t_surface_k, 1.0), 4.0)

	var kcl: Array = Bands.CO2_LINE
	var kcc: Array = Bands.CO2_CONT
	var kci: Array = Bands.CO2_CIA
	var kwl: Array = Bands.H2O_LINE
	var kwc: Array = Bands.H2O_CONT

	for b in nb:
		# --- longwave: down through the layers, off the surface, back up ---
		var fdn: float = 0.0
		for j in range(n - 1, -1, -1):
			var i0: int = slice_lo[j] * nb + b
			var i1: int = i0 + nb
			var f: float = slice_f[j]
			var dtau: float = (lerpf(float(kcl[i0]), float(kcl[i1]), f)
					+ lerpf(float(kcc[i0]), float(kcc[i1]), f)) * a_co2[j] \
				+ lerpf(float(kci[i0]), float(kci[i1]), f) * a_cia[j] \
				+ lerpf(float(kwl[i0]), float(kwl[i1]), f) * a_h2o[j] \
				+ lerpf(float(kwc[i0]), float(kwc[i1]), f) * a_hc[j]
			var trans: float = exp(-DIFFUSIVITY * dtau)
			var emit: float = band_weight(b, t_k[j]) * sigma * t4[j]
			tr[j] = trans
			bl[j] = emit
			var out_f: float = fdn * trans + (1.0 - trans) * emit
			net[j] += fdn - out_f
			fdn = out_f
		lw_down_surface += fdn
		var b_surf: float = band_weight(b, t_surface_k) * sigma * t4s
		net_surface += emissivity * (fdn - b_surf)
		var fup: float = emissivity * b_surf + (1.0 - emissivity) * fdn
		for j in n:
			var out_u: float = fup * tr[j] + (1.0 - tr[j]) * bl[j]
			net[j] += fup - out_u
			fup = out_u
		olr += fup

		# --- shortwave: the direct beam down the slant path, then what the ground reflects back out ---
		var w_sun: float = Bands.solar_weight(b)
		if s_toa <= 0.0 or w_sun <= 0.0:
			continue
		var beam: float = s_toa * w_sun
		for j in range(n - 1, -1, -1):
			var slant: float = pow(maxf(tr[j], 1.0e-30), 1.0 / (DIFFUSIVITY * maxf(mu, 1.0e-3)))
			var take: float = beam * (1.0 - slant)
			net[j] += take
			sw_atm += take
			beam -= take
		var refl: float = beam * albedo
		net_surface += beam - refl
		sw_surface += beam - refl
		for j in n:
			var back: float = refl * (1.0 - tr[j])
			net[j] += back
			sw_atm += back
			refl -= back

	return {"net": net, "net_surface": net_surface, "olr": olr,
		"lw_down_surface": lw_down_surface, "sw_atm": sw_atm, "sw_surface": sw_surface}
