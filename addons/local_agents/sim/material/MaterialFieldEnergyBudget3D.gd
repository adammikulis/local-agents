class_name LAMaterialFieldEnergyBudget3D
extends RefCounted

## The planet's radiation books, computed with the SAME model the kernel runs — LARadiativeColumn over
## LAAbsorptionBands. There is one radiative authority; this module is its CPU reader, not a second model.

const RadScript: GDScript = preload("res://addons/local_agents/sim/material/RadiativeColumn.gd")

## Columns solved per report. 64 spread over the sphere holds the scan near ten milliseconds.
const SAMPLE_COLUMNS: int = 64
## Condensed fraction at which a cell stops being free atmosphere. Mirrors SURFACE_FILL_MIN in
## the RADIATE row of kernels3d/transport.glsl.
const K_SURFACE_FILL_MIN: float = 0.5
const K_ICE_ALBEDO_GAIN: float = 40.0      # mirrors ICE_ALBEDO_GAIN in the kernel

var _f = null                                # back-reference to the owning LAMaterialField3D
var _samples: int = 0                        # recomputes so far

# Running integrals, against `field_sim_s` — the FIELD's own simulated clock — because the kernel applies
# its flux over one field step.
var _cum_absorbed: float = 0.0
var _cum_emitted: float = 0.0
var _last_sim_s: float = -1.0


func setup(field) -> void:
	_f = field


func report() -> Dictionary:
	return _compute()


func sun_field_dir() -> Vector3:
	if _f == null or _f._sun_light == null:
		return Vector3.ZERO
	var insol: float = float(_f._sun_light.get_meta("insolation", 1.0))
	return _f.dir_to_field(_f._sun_light.global_transform.basis.z * insol)


## Volume fraction of cell `c` that IS condensed matter — solid and liquid, never gas. A "sat" channel is
## a share of the pore space, so it enters as its value times 1 - porosity.
static func _condensed(ch: Dictionary, c: int) -> float:
	var phi: float = 0.0
	var pa = ch.get("porosity")
	if pa is PackedFloat32Array and c < pa.size():
		phi = clampf(pa[c], 0.0, 1.0)
	var total: float = 0.0
	var want: Dictionary = LAChannels.mixture_channels()
	for name in want:
		var a = ch.get(name)
		if not (a is PackedFloat32Array) or c >= a.size():
			continue
		var v: float = clampf(a[c], 0.0, 1.0)
		total += v * (1.0 - phi) if String(want[name].get("unit", "vf")) == "sat" else v
	return clampf(total, 0.0, 1.0)


func _compute() -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._grid == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	if solid.size() != cc or temp.size() != cc:
		return out
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		var want: PackedStringArray = PackedStringArray(["pressure", "co2"])
		want.append_array(PackedStringArray(LAChannels.mixture_channels().keys()))
		_f._gpu.request_probe(want)
	# NO MIRROR FALLBACK on a demand-gated channel: an absent leg stays absent, so `has_pressure`/`has_co2`
	# below read false rather than reporting a stale mirror as a measurement.
	var pressure: PackedFloat32Array = legs.get("pressure", PackedFloat32Array())
	var co2: PackedFloat32Array = legs.get("co2", PackedFloat32Array())
	var rock_fill: PackedFloat32Array = legs.get("rock_fill", PackedFloat32Array())
	# ONE capacity model, shared with the thermal stock this module's output is differenced against.
	var ch: Dictionary = {
		"rock_fill": rock_fill, "lava": legs.get("lava", PackedFloat32Array()),
		"sediment": _f._sediment, "susp": _f._susp, "dust": legs.get("dust", PackedFloat32Array()),
		"carbonate": legs.get("carbonate", PackedFloat32Array()),
		"silica": legs.get("silica", PackedFloat32Array()),
		"h2o": _f._h2o,
		"porosity": _f._porosity,
		"fuel": legs.get("fuel", PackedFloat32Array()), "biomass": legs.get("biomass", PackedFloat32Array()),
		"detritus": legs.get("detritus", PackedFloat32Array()),
		"fungus": legs.get("fungus", PackedFloat32Array()),
	}
	var water: PackedFloat32Array = _f._queries._liquid_mirror()
	var snow: PackedFloat32Array = _f._queries._ice_mirror()
	var biomass: PackedFloat32Array = _f._biomass
	var moisture: PackedFloat32Array = _f._queries._vapour_mirror()
	var has_pressure: bool = pressure.size() == cc
	var has_co2: bool = co2.size() == cc
	var has_moisture: bool = moisture.size() == cc
	var sun: Vector3 = sun_field_dir()
	# One uniform cell, so every layer is one cell thick and every outward face is the same area.
	var dz: float = _f._grid.cell_size
	var face_m2: float = _f._grid.face_area()
	var span: int = _f._grid.max_span()

	# The surfaces this planet has: a cell that is condensed matter with free atmosphere one step UP.
	var surfaces: PackedInt32Array = PackedInt32Array()
	for c in cc:
		var hi: int = LAFieldGeometry.above(_f, c)
		if hi < 0 or solid[hi] != 0:
			continue                                   # nothing above, or rock: not a sky-facing surface
		if _condensed(ch, hi) >= K_SURFACE_FILL_MIN:
			continue                                   # the cell above is condensed matter too
		if solid[c] != 0 or _condensed(ch, c) >= K_SURFACE_FILL_MIN:
			surfaces.append(c)
	var columns: int = surfaces.size()
	if columns <= 0:
		return out
	var stride: int = maxi(1, columns / SAMPLE_COLUMNS)
	var sampled: int = 0
	var absorbed_total: float = 0.0
	var emitted_total: float = 0.0
	var sw_atm: float = 0.0
	var sw_surface: float = 0.0
	var albedo_sum: float = 0.0
	var emis_sum: float = 0.0
	var t_sum: float = 0.0
	var dh_sum: float = 0.0
	var dh_abs_max: float = 0.0
	var lit_cells: int = 0
	var cells_cool: int = 0
	var abs_cool: float = 0.0
	var emit_cool: float = 0.0
	var t_cool_sum: float = 0.0
	var emit_magma: float = 0.0
	var dt_real: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	# Watts, and the area they cross: each column exchanges with space across one cell face.
	var abs_w: float = 0.0
	var emit_w: float = 0.0
	var face_m2_total: float = 0.0

	var s: int = 0
	while s < columns:
		var sc: int = surfaces[s]
		var t_k: PackedFloat32Array = PackedFloat32Array()
		var p_pa: PackedFloat32Array = PackedFloat32Array()
		var u_co2: PackedFloat32Array = PackedFloat32Array()
		var u_h2o: PackedFloat32Array = PackedFloat32Array()
		var p_co2: PackedFloat32Array = PackedFloat32Array()
		var p_h2o: PackedFloat32Array = PackedFloat32Array()
		# The atmosphere over this surface: march UP the local vertical until the march leaves the box.
		var c: int = LAFieldGeometry.above(_f, sc)
		var layers: int = 0
		while c >= 0 and layers < span:
			layers += 1
			var tk: float = maxf(temp[c] + LAPhysical.KELVIN_OFFSET, 1.0)
			var rho_v: float = (maxf(moisture[c], 0.0) if has_moisture else 0.0) \
				* LAPhysical.WATER_DENSITY_KG_M3
			var rho_c: float = (maxf(co2[c], 0.0) if has_co2 else 0.0) \
				* LAPhysical.CO2_UNIT_DENSITY_KG_M3
			t_k.append(tk)
			p_pa.append(maxf(pressure[c], 0.0) if has_pressure else 0.0)
			u_co2.append(rho_c * dz)
			u_h2o.append(rho_v * dz)
			p_co2.append(RadScript.partial_pressure_pa(rho_c, tk, LAPhysical.CO2_GAS_CONST_J_KGK))
			p_h2o.append(RadScript.partial_pressure_pa(rho_v, tk, LAPhysical.VAPOUR_GAS_CONST_J_KGK))
			c = LAFieldGeometry.above(_f, c)

		var wet: float = clampf(water[sc], 0.0, 1.0) if water.size() == cc else 0.0
		var icy: float = clampf((snow[sc] if snow.size() == cc else 0.0) * K_ICE_ALBEDO_GAIN, 0.0, 1.0)
		var veg: float = 0.0
		if biomass.size() == cc:
			var leaf: float = maxf(biomass[sc], 0.0) * LAPhysical.DRY_WOOD_DENSITY_KG_M3 \
				* dz * LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
			veg = 1.0 - exp(-LAPhysical.CANOPY_EXTINCTION_COEFF * (leaf / LAPhysical.LEAF_MASS_PER_AREA_KG_M2))
		var land: float = lerpf(LAPhysical.ALBEDO_BARE_GROUND, LAPhysical.ALBEDO_VEGETATION, veg)
		var albedo: float = lerpf(lerpf(land, LAPhysical.ALBEDO_OCEAN, wet), LAPhysical.ALBEDO_SNOW_ICE, icy)
		var emis: float = lerpf(lerpf(LAPhysical.BASALT_EMISSIVITY, LAPhysical.EMISSIVITY_WATER, wet),
			LAPhysical.EMISSIVITY_SNOW, icy)
		var coz: float = LAFieldGeometry.up(_f, sc).dot(sun.normalized()) if sun.length() > 1.0e-6 else 0.0
		var s_toa: float = LAPhysical.SOLAR_CONSTANT_W_M2 * sun.length() * maxf(coz, 0.0)
		var mu: float = maxf(coz, 1.0 / LAPhysical.AIR_MASS_HORIZON)
		var t_s: float = maxf(temp[sc] + LAPhysical.KELVIN_OFFSET, 1.0)
		var res: Dictionary = RadScript.solve(t_k, p_pa, u_co2, u_h2o, p_co2, p_h2o,
			t_s, emis, albedo, s_toa, mu)

		var col_abs: float = float(res["sw_atm"]) + float(res["sw_surface"])
		var col_emit: float = float(res["olr"])
		absorbed_total += col_abs
		emitted_total += col_emit
		face_m2_total += face_m2
		abs_w += col_abs * face_m2
		emit_w += col_emit * face_m2
		sw_atm += float(res["sw_atm"])
		sw_surface += float(res["sw_surface"])
		albedo_sum += albedo
		emis_sum += emis
		t_sum += temp[sc]
		# net_surface is W/m^2 into a layer dz thick, so the enthalpy density it moves is J/m^3.
		var d_h: float = float(res["net_surface"]) * dt_real / dz
		dh_sum += d_h
		dh_abs_max = maxf(dh_abs_max, absf(d_h))
		if s_toa > 0.0:
			lit_cells += 1
		if temp[sc] < LAPhysical.BASALT_SOLIDUS_C:
			cells_cool += 1
			abs_cool += col_abs
			emit_cool += col_emit
			t_cool_sum += temp[sc]
		else:
			emit_magma += col_emit
		sampled += 1
		s += stride

	if sampled <= 0:
		return out
	# Scale the sample up to the whole grid.
	var scale: float = float(columns) / float(sampled)
	absorbed_total *= scale
	emitted_total *= scale
	sw_atm *= scale
	sw_surface *= scale
	abs_cool *= scale
	emit_cool *= scale
	emit_magma *= scale
	abs_w *= scale
	emit_w *= scale
	face_m2_total *= scale
	var fn: float = float(sampled)
	var net: float = absorbed_total - emitted_total

	var sim_s: float = LASimReport.gauge_cur("field_sim_s", 0.0)
	if _last_sim_s >= 0.0 and sim_s > _last_sim_s:
		var d_s: float = sim_s - _last_sim_s
		_cum_absorbed += absorbed_total * d_s
		_cum_emitted += emitted_total * d_s
	_last_sim_s = sim_s
	_samples += 1

	out["energy_absorbed"] = absorbed_total
	out["energy_emitted"] = emitted_total
	out["energy_net"] = net
	# WATTS. LAMaterialFieldLedger3D's energy books read these three and no others; a W/m^2 sum cannot be
	# differenced against a joule stock.
	out["energy_absorbed_w"] = abs_w
	out["energy_emitted_w"] = emit_w
	out["energy_net_w"] = abs_w - emit_w
	out["energy_face_area_m2"] = face_m2_total
	# The dimensionless read of "how far from balance". At equilibrium this is near zero; the SIGN says which
	# way the planet is going, which no temperature reading gives you.
	out["energy_imbalance"] = net / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	out["energy_absorbed_mean"] = absorbed_total / float(columns)
	out["energy_emitted_mean"] = emitted_total / float(columns)
	out["energy_cells"] = columns
	out["energy_sample_columns"] = sampled
	out["energy_lit_cells"] = lit_cells
	out["energy_lit_frac"] = float(lit_cells) / fn
	out["energy_albedo_mean"] = albedo_sum / fn
	out["energy_emissivity_mean"] = emis_sum / fn
	out["energy_surf_temp_mean"] = t_sum / fn
	out["energy_dh_mean_j_m3"] = dh_sum / fn
	out["energy_dh_absmax_j_m3"] = dh_abs_max
	# THE CLIMATE HALF — the same books over the sub-solidus surface only. Read these for anything about
	# whether the planet is warming, cooling or in balance; the totals above are dominated by open lava.
	var fc: float = float(maxi(cells_cool, 1))
	out["energy_abs_cool"] = abs_cool
	out["energy_emit_cool"] = emit_cool
	out["energy_net_cool"] = abs_cool - emit_cool
	out["energy_imbalance_cool"] = (abs_cool - emit_cool) / abs_cool if abs_cool > 1.0e-9 else 0.0
	out["energy_temp_cool_mean"] = t_cool_sum / fc
	out["energy_cells_cool"] = cells_cool
	out["energy_emit_magma"] = emit_magma
	out["energy_magma_share"] = emit_magma / emitted_total if emitted_total > 1.0e-9 else 0.0
	# THE COLUMN SHORTWAVE SPLIT. `energy_sw_atm + energy_sw_surface` IS `energy_absorbed`.
	out["energy_sw_atm"] = sw_atm
	out["energy_sw_surface"] = sw_surface
	out["energy_sw_frac_atm"] = sw_atm / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	out["energy_cum_absorbed"] = _cum_absorbed
	out["energy_cum_emitted"] = _cum_emitted
	out["energy_cum_net"] = _cum_absorbed - _cum_emitted
	out["energy_samples"] = _samples
	out["energy_scan_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return out


func _blank() -> Dictionary:
	return {
		"energy_absorbed": 0.0, "energy_emitted": 0.0, "energy_net": 0.0, "energy_imbalance": 0.0,
		"energy_absorbed_w": 0.0, "energy_emitted_w": 0.0, "energy_net_w": 0.0, "energy_face_area_m2": 0.0,
		"energy_absorbed_mean": 0.0, "energy_emitted_mean": 0.0,
		"energy_cells": 0, "energy_sample_columns": 0,
		"energy_lit_cells": 0, "energy_lit_frac": 0.0,
		"energy_albedo_mean": 0.0, "energy_emissivity_mean": 0.0,
		"energy_surf_temp_mean": 0.0, "energy_dh_mean_j_m3": 0.0, "energy_dh_absmax_j_m3": 0.0,
		"energy_abs_cool": 0.0, "energy_emit_cool": 0.0, "energy_net_cool": 0.0,
		"energy_imbalance_cool": 0.0, "energy_temp_cool_mean": 0.0, "energy_cells_cool": 0,
		"energy_emit_magma": 0.0, "energy_magma_share": 0.0,
		"energy_sw_atm": 0.0, "energy_sw_surface": 0.0, "energy_sw_frac_atm": 0.0,
		"energy_cum_absorbed": _cum_absorbed, "energy_cum_emitted": _cum_emitted,
		"energy_cum_net": _cum_absorbed - _cum_emitted, "energy_samples": _samples,
		"energy_scan_ms": 0.0,
	}
