class_name LAMaterialFieldEnergyBudget3D
extends RefCounted

## constant are now the measured ones, so a per-cell flux really is in W/m^2. The TOTALS are still sums
## an Earth-like planet sits near 240 W/m^2 absorbed on the global mean.

# --- CONSTANTS FROM LAPhysical -----------------------------------------------------------------------------

# --- CONSTANTS MIRRORED FROM THE KERNEL --------------------------------------------------------------------
const K_SOLAR_CONSTANT: float = LAPhysical.SOLAR_CONSTANT_W_M2   # glsl:119
const K_ICE_ALBEDO_GAIN: float = 40.0      # glsl:137 — snow mass -> reflectivity; a dusting already whitens
# ROCK 604800 / WATER 3888000 / SNOW 1080000 J/m^2/K, and against rho*c*cell_size for the very cell the
const K_P_REF: float = LAPhysical.STANDARD_PRESSURE_PA   # mirrors heat3d_solar P_REF; pressure is PASCALS now
const K_MAX_DT_PER_STEP: float = 5.0       # glsl:132 MAX_DT_PER_STEP — the guard whose binding this file counts
const K_WATER_SURFACE_MIN: float = 0.5     # glsl:279 WATER_SURFACE_MIN — water fraction that makes a cell a sea surface

var _f = null                                # back-reference to the owning LAMaterialField3D
var _samples: int = 0                        # recomputes so far

# Running integrals. Integrated against `field_sim_s` — the FIELD's own simulated clock — because the kernel
# applies its flux over STEP_DT per field step. Integrating against wall time or render frames would make the
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


func _compute() -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._sphere == null or _f._cell_count <= 0:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var depth: int = int(_f._sphere.depth)
	if depth <= 0:
		return out
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var water: PackedFloat32Array = _f._water
	var snow: PackedFloat32Array = _f._snow
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		var want: PackedStringArray = PackedStringArray(["pressure"])
		want.append_array(LAHeatCapacity.channels())
		_f._gpu.request_probe(want)
	var pressure: PackedFloat32Array = legs.get("pressure", PackedFloat32Array())
	var rock_fill: PackedFloat32Array = legs.get("rock_fill", PackedFloat32Array())
	# ONE capacity model, shared with the stock this module's output is differenced against. See the note at
	# the `rc` assignment below for what the two-copy version cost.
	var _rc_channels: Dictionary = {
		"rock_fill": rock_fill, "lava": legs.get("lava", PackedFloat32Array()),
		"sediment": _f._sediment, "susp": _f._susp, "dust": legs.get("dust", PackedFloat32Array()),
		"carbonate": legs.get("carbonate", PackedFloat32Array()),
		"silica": legs.get("silica", PackedFloat32Array()),
		"water": _f._water, "soil": _f._soil, "snow": _f._snow, "moisture": _f._moisture,
		"porosity": _f._porosity,
		"fuel": legs.get("fuel", PackedFloat32Array()), "biomass": legs.get("biomass", PackedFloat32Array()),
		"detritus": legs.get("detritus", PackedFloat32Array()),
		"fungus": legs.get("fungus", PackedFloat32Array()),
	}
	if solid.size() != cc or temp.size() != cc:
		return out
	var has_water: bool = water.size() == cc
	var has_snow: bool = snow.size() == cc
	var has_rock: bool = rock_fill.size() == cc
	var has_pressure: bool = pressure.size() == cc
	# The canopy leg of the albedo (glsl:396-401). Read from the CPU mirror the same way `snow` and `water`
	# above are, and NEVER by calling request_channel — a gauge that changes which channels are resident
	# changes the simulation, which is the rule this file's own header lane exists to keep.
	var biomass: PackedFloat32Array = _f._biomass
	var has_biomass: bool = biomass.size() == cc
	var pressure_live: int = 0
	var sun: Vector3 = sun_field_dir()

	var abs_w: float = 0.0            # TRUE watts: per-cell flux times that cell's own face area
	var emit_w: float = 0.0
	var face_m2_total: float = 0.0    # the real radiating area of the cells counted above, m^2
	var abs_toa: float = 0.0
	var abs_ground: float = 0.0
	var emit_toa: float = 0.0
	var emit_ground: float = 0.0
	var surf_toa: int = 0
	var surf_ground: int = 0
	var lit_cells: int = 0
	var emis_sum: float = 0.0
	var cap_sum: float = 0.0
	var dt_sum: float = 0.0
	var dt_abs_max: float = 0.0
	var clamped: int = 0
	var t_sum: float = 0.0
	# The sub-solidus (non-magmatic) surface, tracked in parallel — the climate half of the books. See the
	# header: T⁴ makes a few lava cells dominate every global total, so a total that mixes them answers a
	# question nobody asked.
	var abs_cool: float = 0.0
	var emit_cool: float = 0.0
	var cells_cool: int = 0
	var t_cool_sum: float = 0.0
	var emit_magma: float = 0.0
	# they were not halves at all: both cells absorbed the full undiminished beam.
	var sw_atm: float = 0.0
	var sw_surface: float = 0.0
	var cells_bedrock: int = 0
	var albedo_sum_surface: float = 0.0
	var cell_size: float = float(_f._cell_size)
	if cell_size <= 0.0:
		return out

	var columns: int = cc / depth
	for surf in columns:
		var base: int = surf * depth
		# Per-COLUMN insolation: `SphereGrid.cell_radial(c)` is `_dir[c / depth]`, one vector per column, so the
		# only Vector3 work in this scan is O(columns). Same expression as glsl:370-373.
		var insolation: float = maxf(0.0, _f.cell_radial(base).dot(sun))
		# glsl:307-326 find_column_surface(), hoisted: the column is scanned top-down ONCE for the cell the beam
		var surf_c: int = -1
		for r in range(depth - 1, -1, -1):
			var c0: int = base + r
			if solid[c0] != 0:
				break                                       # rock: nothing below is lit through it
			if has_water and clampf(water[c0], 0.0, 1.0) >= K_WATER_SURFACE_MIN:
				surf_c = c0                                 # topmost water cell: the sea/lake surface
				break
			if r > 0 and solid[c0 - 1] != 0:
				surf_c = c0                                 # rests on rock: the ground
				break
		# The overlying air mass at the cell the beam lands on — ONE number for the whole column, so the
		# shortwave shares are complementary and the longwave exchange is symmetric by construction, not by
		# coincidence (glsl:427-443).
		var p_beam: float = 0.0
		if surf_c >= 0:
			p_beam = pressure[surf_c] if has_pressure else 0.0
			if p_beam <= 0.0:
				p_beam = K_P_REF
		var mu: float = maxf(insolation, 1.0 / LAPhysical.AIR_MASS_HORIZON)
		var trans: float = exp(-LAPhysical.ATMOS_SW_OPTICAL_DEPTH * (p_beam / K_P_REF) / mu)
		# The air column's LONGWAVE absorptivity — what it intercepts of the surface's infrared and re-emits
		# from both faces (glsl:485). The top-of-atmosphere cell of this column, needed for the exchange.
		var eps_a: float = 1.0 - 1.0 / (1.0 + LAPhysical.TWO_STREAM_COEFF * LAPhysical.ATMOS_OPTICAL_DEPTH * (p_beam / K_P_REF))
		var top_c: int = -1
		if solid[base + depth - 1] == 0:
			top_c = base + depth - 1
		var t_top_4: float = 0.0
		if top_c >= 0:
			var tt: float = maxf(temp[top_c] + LAPhysical.KELVIN_OFFSET, 1.0)
			t_top_4 = tt * tt * tt * tt
		var t_surf_4: float = 0.0
		if surf_c >= 0:
			var tsr: float = maxf(temp[surf_c] + LAPhysical.KELVIN_OFFSET, 1.0)
			t_surf_4 = tsr * tsr * tsr * tsr

		for r in depth:
			var c: int = base + r
			# glsl:333-367. Column layout is c = surf * depth + r (LAMaterialField3D._compute_regolith), so the
			# outward neighbour (nbr slot 5) is c+1 and the inward one (slot 0) is c-1; -1 means space/core.
			var up: int = c + 1 if r < depth - 1 else -1
			var down: int = c - 1 if r > 0 else -1
			var solid_here: bool = solid[c] != 0
			var faces_space: bool = up < 0
			var top_of_atm: bool = faces_space and not solid_here
			var bedrock_top: bool = faces_space and solid_here
			var mat_surface: bool = (not solid_here) and (c == surf_c)
			if not (top_of_atm or bedrock_top or mat_surface):
				continue      # roofed pockets, interior air and buried rock: conduction + buoyancy only

			var wet: float = clampf(water[c], 0.0, 1.0) if has_water else 0.0
			var snow_m: float = snow[c] if has_snow else 0.0
			var icy: float = clampf(snow_m * K_ICE_ALBEDO_GAIN, 0.0, 1.0)
			# glsl:396-401 — canopy cover by Beer-Lambert through the leaf area the cell's standing biomass
			# carries. Vegetation darkens the LAND inside the water mix, so plankton cannot brighten a sea.
			var veg: float = 0.0
			if has_biomass:
				var leaf_kg_m2: float = maxf(biomass[c], 0.0) * LAPhysical.DRY_WOOD_DENSITY_KG_M3 \
					* cell_size * LAPhysical.FOLIAGE_FRACTION_OF_PLANT_MASS
				veg = 1.0 - exp(-LAPhysical.CANOPY_EXTINCTION_COEFF * (leaf_kg_m2 / LAPhysical.LEAF_MASS_PER_AREA_KG_M2))
			# glsl:412-413 — ice/snow reflect, open water absorbs nearly everything, bare ground between, and a
			# canopy is darker than the ground it stands on.
			var land: float = lerpf(LAPhysical.ALBEDO_BARE_GROUND, LAPhysical.ALBEDO_VEGETATION, veg)
			var albedo: float = lerpf(lerpf(land, LAPhysical.ALBEDO_OCEAN, wet), LAPhysical.ALBEDO_SNOW_ICE, icy)
			# hold 3.41e6 J/m3K while split 0.5/0.5 held 4.87e6, a 43% jump for no change of mass — and it
			var rc: float = LAHeatCapacity.cell(_rc_channels, c)
			var cap: float = maxf(rc * cell_size, 1.0)
			# Provenance only — this reports whether the greenhouse came from a live pressure readback. The
			# radiative terms below use `p_beam`, the COLUMN's value, because both cells must share it.
			var p_col: float = pressure[c] if has_pressure else 0.0
			if p_col > 0.0:
				pressure_live += 1
			var eps_cell: float = eps_a if (top_of_atm or mat_surface) else 0.0
			# glsl:445-453 — the column's beam, spent once. The top-of-atmosphere cell takes what the air
			# intercepts; the material surface takes what got through, less what it reflects. Exposed bedrock
			# faces space with no air over it at all, so nothing is intercepted above it.
			var t_k: float = maxf(temp[c] + LAPhysical.KELVIN_OFFSET, 1.0)
			var absorbed: float = 0.0
			if top_of_atm:
				var a_atm: float = K_SOLAR_CONSTANT * insolation * (1.0 - trans)
				absorbed += a_atm
				sw_atm += a_atm
			if mat_surface or bedrock_top:
				var beam: float = trans if mat_surface else 1.0
				var a_surf: float = K_SOLAR_CONSTANT * insolation * beam * (1.0 - albedo)
				absorbed += a_surf
				sw_surface += a_surf
				albedo_sum_surface += albedo
				if bedrock_top:
					cells_bedrock += 1
			# glsl:485-503 — the two-layer grey exchange. The air layer radiates eps_a from BOTH faces and
			var lw_self: float = 0.0
			var lw_in: float = 0.0
			if top_of_atm:
				lw_self += 2.0 * eps_cell
				if surf_c >= 0:
					lw_in += eps_cell * LAPhysical.STEFAN_BOLTZMANN * t_surf_4
			if mat_surface or bedrock_top:
				lw_self += 1.0
				if mat_surface and top_c >= 0:
					lw_in += eps_cell * LAPhysical.STEFAN_BOLTZMANN * t_top_4
			var emitted: float = lw_self * LAPhysical.STEFAN_BOLTZMANN * t_k * t_k * t_k * t_k - lw_in
			# The step the kernel would apply, and whether its numerical guard binds. The dt is the field's ONE
			# mirroring a kernel constant that disagreed with the conduction kernel dispatched beside it.
			var d_t: float = (absorbed - emitted) * LAMaterialFieldSphereStep3D.real_seconds_per_step() / cap
			if absf(d_t) > K_MAX_DT_PER_STEP:
				clamped += 1
			dt_sum += d_t
			dt_abs_max = maxf(dt_abs_max, absf(d_t))
			emis_sum += eps_cell
			cap_sum += cap
			t_sum += temp[c]
			if temp[c] < LAPhysical.BASALT_SOLIDUS_C:
				cells_cool += 1
				abs_cool += absorbed
				emit_cool += emitted
				t_cool_sum += temp[c]
			else:
				emit_magma += emitted
			if insolation > 0.0:
				lit_cells += 1
			# W/m^2 sums feed the per-cell MEANS below and stay as they are. The WATTS are a different
			# question and need each cell's own face area: a radial flux crosses the outward face, whose area
			# is solid_angle * r^2 and varies across the grid by the same ~8.8x the volumes do.
			var face_m2: float = LAFieldTotals.face_area_outward_m2(_f._sphere, c)
			face_m2_total += face_m2
			abs_w += absorbed * face_m2
			emit_w += emitted * face_m2
			if top_of_atm:
				surf_toa += 1
				abs_toa += absorbed
				emit_toa += emitted
			else:
				surf_ground += 1
				abs_ground += absorbed
				emit_ground += emitted

	var n: int = surf_toa + surf_ground
	if n <= 0:
		return out
	var absorbed_total: float = abs_toa + abs_ground
	var emitted_total: float = emit_toa + emit_ground
	out["energy_absorbed_w"] = abs_w
	out["energy_emitted_w"] = emit_w
	out["energy_net_w"] = abs_w - emit_w
	out["energy_face_area_m2"] = face_m2_total
	var net: float = absorbed_total - emitted_total
	var fn: float = float(n)

	# RUNNING TOTALS. Rectangle rule over the field's own simulated seconds. The global sums are smooth in time
	# (half the sphere is lit at every instant, so the planet-wide absorbed total barely breathes over a day),
	# which is what makes a coarse sample rate adequate here — unlike a single cell, which swings.
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
	# The dimensionless read of "how far from balance". At equilibrium this is near zero; the SIGN says which
	# way the planet is going, which no temperature reading gives you.
	out["energy_imbalance"] = net / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	out["energy_absorbed_mean"] = absorbed_total / fn
	out["energy_emitted_mean"] = emitted_total / fn
	out["energy_abs_toa"] = abs_toa
	out["energy_abs_ground"] = abs_ground
	out["energy_emit_toa"] = emit_toa
	out["energy_emit_ground"] = emit_ground
	out["energy_cells_toa"] = surf_toa
	out["energy_cells_ground"] = surf_ground
	out["energy_cells"] = n
	out["energy_lit_cells"] = lit_cells
	out["energy_lit_frac"] = float(lit_cells) / fn
	out["energy_albedo_mean"] = albedo_sum_surface / float(maxi(surf_ground + cells_bedrock, 1))
	out["energy_emissivity_mean"] = emis_sum / fn
	out["energy_cap_mean"] = cap_sum / fn
	out["energy_surf_temp_mean"] = t_sum / fn
	out["energy_dt_mean"] = dt_sum / fn
	out["energy_dt_absmax"] = dt_abs_max
	# NON-ZERO MEANS THE BOOKS BELOW ARE FICTION for that many cells — the kernel threw the excess away.
	out["energy_clamped_cells"] = clamped
	# THE CLIMATE HALF — the same books over the sub-solidus surface only. Read these for anything about
	# whether the planet is warming, cooling or in balance; the totals above are dominated by open lava.
	var fc: float = float(maxi(cells_cool, 1))
	out["energy_abs_cool"] = abs_cool
	out["energy_emit_cool"] = emit_cool
	out["energy_net_cool"] = abs_cool - emit_cool
	out["energy_imbalance_cool"] = (abs_cool - emit_cool) / abs_cool if abs_cool > 1.0e-9 else 0.0
	out["energy_absorbed_cool_mean"] = abs_cool / fc
	out["energy_emitted_cool_mean"] = emit_cool / fc
	out["energy_temp_cool_mean"] = t_cool_sum / fc
	out["energy_cells_cool"] = cells_cool
	out["energy_cells_magma"] = n - cells_cool
	out["energy_emit_magma"] = emit_magma
	# How much of the whole planet's longwave leaves through molten rock. Near 1.0 means the global totals
	# above describe volcanism and nothing else.
	out["energy_magma_share"] = emit_magma / emitted_total if emitted_total > 1.0e-9 else 0.0
	# THE COLUMN SHORTWAVE SPLIT. `energy_sw_atm + energy_sw_surface` IS `energy_absorbed` — the two are the
	# `energy_sw_frac_atm` is the fraction the atmosphere intercepts, which should sit near Earth's measured
	# 0.23 wherever the column is close to sea-level pressure and the sun is high.
	out["energy_sw_atm"] = sw_atm
	out["energy_sw_surface"] = sw_surface
	out["energy_sw_frac_atm"] = sw_atm / absorbed_total if absorbed_total > 1.0e-9 else 0.0
	# capped by stone traded no radiation with the sky in either direction.
	out["energy_cells_bedrock"] = cells_bedrock
	out["energy_cum_absorbed"] = _cum_absorbed
	out["energy_cum_emitted"] = _cum_emitted
	out["energy_cum_net"] = _cum_absorbed - _cum_emitted
	out["energy_samples"] = _samples
	# Provenance, so a flat emissivity profile is never mistaken for a physical result: the share of surface
	# cells whose greenhouse came from a LIVE pressure readback rather than the kernel's sea-level fallback.
	out["energy_pressure_live"] = float(pressure_live) / fn
	out["energy_scan_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return out


func _blank() -> Dictionary:
	return {
		"energy_absorbed": 0.0, "energy_emitted": 0.0, "energy_net": 0.0, "energy_imbalance": 0.0,
		"energy_absorbed_mean": 0.0, "energy_emitted_mean": 0.0,
		"energy_abs_toa": 0.0, "energy_abs_ground": 0.0, "energy_emit_toa": 0.0, "energy_emit_ground": 0.0,
		"energy_cells_toa": 0, "energy_cells_ground": 0, "energy_cells": 0,
		"energy_lit_cells": 0, "energy_lit_frac": 0.0,
		"energy_albedo_mean": 0.0, "energy_emissivity_mean": 0.0, "energy_cap_mean": 0.0,
		"energy_surf_temp_mean": 0.0, "energy_dt_mean": 0.0, "energy_dt_absmax": 0.0,
		"energy_clamped_cells": 0,
		"energy_abs_cool": 0.0, "energy_emit_cool": 0.0, "energy_net_cool": 0.0, "energy_imbalance_cool": 0.0,
		"energy_absorbed_cool_mean": 0.0, "energy_emitted_cool_mean": 0.0, "energy_temp_cool_mean": 0.0,
		"energy_cells_cool": 0, "energy_cells_magma": 0, "energy_emit_magma": 0.0, "energy_magma_share": 0.0,
		"energy_sw_atm": 0.0, "energy_sw_surface": 0.0, "energy_sw_frac_atm": 0.0,
		"energy_cells_bedrock": 0,
		"energy_cum_absorbed": _cum_absorbed, "energy_cum_emitted": _cum_emitted,
		"energy_cum_net": _cum_absorbed - _cum_emitted, "energy_samples": _samples,
		"energy_pressure_live": 0.0, "energy_scan_ms": 0.0,
	}
