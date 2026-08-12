class_name LAMaterialFieldReport3D
extends RefCounted

## The central-telemetry snapshot of LAMaterialField3D.

const PhotoStatsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd")
const EnergyBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd")
const ExtremesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldExtremes3D.gd")
const ClimateSwingScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd")
const MomentumLedgerScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMomentumLedger3D.gd")
const SealScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSeal3D.gd")
const ConservationScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldConservation3D.gd")

## Process frames between recomputes of the O(cells) instrument block. These gauges are GDScript walks over
## every cell and cost far more than the field step they measure. `LA_GAUGE_EVERY` overrides.
const HEAVY_EVERY_FRAMES: int = 64

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _photo = null                                        # LAMaterialFieldPhotoStats3D — primary-production spatial stats
var _energy = null                                       # LAMaterialFieldEnergyBudget3D — absorbed/emitted/net radiation
var _extremes = null                                     # LAMaterialFieldExtremes3D — min/max-ever register
var _swing = null                                        # LAMaterialFieldClimateSwing3D — diurnal + seasonal range
var _momentum = null                             # LAMaterialFieldMomentumLedger3D — Σ m*v stock + its books
# The cross-book carbon baseline, latched at the seal. Lives here rather than in either ledger because it is
# the SUM of the two, and neither of them can see the other.
var _first_element_c: float = NAN
var _first_element_c_step: int = -1
var _conservation = null                         # LAMaterialFieldConservation3D — the law, enforced
var _seal = null                                 # LAMaterialFieldSeal3D — SEEDING -> SEALED, the line the books start at
var _seal_announced: bool = false                # WORLD_SEALED printed once, from the step-driven phase
var _heavy_cache: Dictionary = {}                        # last computed instrument block
var _heavy_frame: int = -1_000_000                       # process frame it was computed on


func setup(field) -> void:
	_f = field
	_photo = PhotoStatsScript.new()
	_photo.setup(field)
	_energy = EnergyBudgetScript.new()
	_energy.setup(field)
	_extremes = ExtremesScript.new()
	_swing = ClimateSwingScript.new()
	_swing.setup(field)
	_momentum = MomentumLedgerScript.new()
	_momentum.setup(field)
	_seal = SealScript.new()
	_seal.setup(field)
	_conservation = ConservationScript.new()
	_conservation.setup(field)
	# The field holds the seal so anything outside this report path can ask it — the injection queue has to
	# know whether a mint is seeding or a violation, and it does not go through the report.
	field._seal = _seal


const CLIMATE_BANDS: int = 6                    # 15° per band from equator to pole
const ALT_BANDS: int = 4                        # ground / low / mid / high, by altitude above the sea shell
const ALT_BAND_SPAN: float = 8.0                # world units per altitude band
const CLIMATE_MAX_CELLS: int = 200000
const PLANET_SPIN_AXIS: Vector3 = LAPlanetBody.SPIN_AXIS

# Running extremes across the whole run — never reset by a snapshot, so the coldest instant is not lost
# between samples. `_coldest_ever` is the answer to "how low does ANY cell ever get", which is the question
# that should have been asked before anyone moved water's freezing point.
var _coldest_ever: float = 1.0e20
var _coldest_ever_alt: float = 0.0
var _coldest_ever_lat: float = 0.0
var _ground_coldest_ever: float = 1.0e20


func surface_climate() -> Dictionary:
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	if solid.size() != _f._cell_count or temp.size() != _f._cell_count or _f._grid == null:
		return {}
	var t_scan: int = Time.get_ticks_usec()
	var axis: Vector3 = (_f.spin_axis() if _f.has_method("spin_axis") else PLANET_SPIN_AXIS).normalized()
	var sea_r: float = float(_f.sea_radius()) if _f.has_method("sea_radius") else 0.0
	var lat_sum: PackedFloat64Array = PackedFloat64Array(); lat_sum.resize(CLIMATE_BANDS)
	var lat_min: PackedFloat64Array = PackedFloat64Array(); lat_min.resize(CLIMATE_BANDS)
	var lat_n: PackedInt32Array = PackedInt32Array(); lat_n.resize(CLIMATE_BANDS)
	var alt_min: PackedFloat64Array = PackedFloat64Array(); alt_min.resize(ALT_BANDS)
	var alt_n: PackedInt32Array = PackedInt32Array(); alt_n.resize(ALT_BANDS)
	for b in CLIMATE_BANDS:
		lat_min[b] = 1.0e20
	for b in ALT_BANDS:
		alt_min[b] = 1.0e20
	var ground_frozen: int = 0
	var ground_n: int = 0
	var air_frozen: int = 0
	var air_n: int = 0
	var coldest: float = 1.0e20        # coldest OPEN cell anywhere this snapshot (ground or aloft)
	var ground_coldest: float = 1.0e20
	var water: PackedFloat32Array = _f._water
	var has_water: bool = water.size() == _f._cell_count
	var water_frozen: int = 0
	var water_cells: int = 0
	var water_coldest: float = 1.0e20
	# Strided so the scan stays bounded on a big grid; the stride is over CELLS, not columns, because the
	# Cartesian box has none.
	var stride: int = maxi(1, _f._cell_count / CLIMATE_MAX_CELLS)
	var c: int = 0
	while c < _f._cell_count:
		var cell: int = c
		c += stride
		if solid[cell] != 0:
			continue
		var up: Vector3 = LAFieldGeometry.up(_f, cell)
		if up == Vector3.ZERO:
			continue
		# Latitude from the LOCAL VERTICAL against the spin axis; altitude from the body centre.
		var wdir: Vector3 = _f._body_basis * up
		var lat: float = absf(rad_to_deg(asin(clampf(wdir.dot(axis), -1.0, 1.0))))
		var band: int = clampi(int(lat / (90.0 / float(CLIMATE_BANDS))), 0, CLIMATE_BANDS - 1)
		var alt: float = LAFieldGeometry.radius_of(_f, cell) - sea_r
		var t: float = temp[cell]
		if t < coldest:
			coldest = t
			if t < _coldest_ever:
				_coldest_ever = t
				_coldest_ever_alt = snappedf(alt, 0.1)
				_coldest_ever_lat = snappedf(lat, 0.1)
		# ALTITUDE profile over every open cell — this is where an equatorial summit and the cold upper air
		# both show up, and neither is visible in a latitude-only or ground-only scan.
		var ab: int = clampi(int(maxf(alt, 0.0) / ALT_BAND_SPAN), 0, ALT_BANDS - 1)
		alt_n[ab] += 1
		if t < alt_min[ab]:
			alt_min[ab] = t
		if has_water and water[cell] > LAMaterialField3D.MIN_MASS:
			water_cells += 1
			if t < LAPhysical.WATER_FREEZE_C:
				water_frozen += 1
			if t < water_coldest:
				water_coldest = t
		# GROUND-HUGGING (the cell one step DOWN is rock) vs ALOFT — two distinct freezing populations.
		var lo: int = LAFieldGeometry.below(_f, cell)
		if lo >= 0 and solid[lo] != 0:
			lat_sum[band] += t
			lat_n[band] += 1
			if t < lat_min[band]:
				lat_min[band] = t
			ground_n += 1
			if t < LAPhysical.WATER_FREEZE_C:
				ground_frozen += 1
			if t < ground_coldest:
				ground_coldest = t
				_ground_coldest_ever = minf(_ground_coldest_ever, t)
		else:
			air_n += 1
			if t < LAPhysical.WATER_FREEZE_C:
				air_frozen += 1
	var means: Array = []
	var lmins: Array = []
	for b in CLIMATE_BANDS:
		means.append(snappedf(lat_sum[b] / float(maxi(lat_n[b], 1)), 0.1) if lat_n[b] > 0 else 0.0)
		lmins.append(snappedf(lat_min[b], 0.1) if lat_n[b] > 0 else 0.0)
	var amins: Array = []
	for b in ALT_BANDS:
		amins.append(snappedf(alt_min[b], 0.1) if alt_n[b] > 0 else 0.0)
	return {
		# Equator-first: [0] is 0-15°, [5] is 75-90°. A working planet DESCENDS across this.
		"clim_lat_mean": means,
		"clim_lat_min": lmins,
		# Ground-up: [0] is sea level, [3] is high. A working planet DESCENDS across this too (the lapse).
		"clim_alt_min": amins,
		# Coldest anything gets, this snapshot and EVER — the number that decides whether 0 °C can fire.
		"clim_coldest_now": snappedf(coldest if coldest < 1.0e19 else 0.0, 0.1),
		"clim_coldest_ever": snappedf(_coldest_ever if _coldest_ever < 1.0e19 else 0.0, 0.1),
		"clim_coldest_ever_at": {"alt": _coldest_ever_alt, "lat": _coldest_ever_lat},
		"clim_ground_coldest_ever": snappedf(_ground_coldest_ever if _ground_coldest_ever < 1.0e19 else 0.0, 0.1),
		# Sub-zero populations, split: snow forms from the AIR one, so a zero there means no snow can fall
		# however cold the ground is.
		"clim_ground_frozen": ground_frozen,
		"clim_ground_cells": ground_n,
		"clim_air_frozen": air_frozen,
		"clim_air_cells": air_n,
		# Cells that actually HOLD liquid water, and how many of those are below freezing. A large
		# `clim_ground_frozen` with a zero here means the cold ground is dry and no ice can form on it.
		"clim_water_cells": water_cells,
		"clim_water_frozen": water_frozen,
		"clim_water_coldest": snappedf(water_coldest if water_coldest < 1.0e19 else 0.0, 0.1),
		"clim_scan_ms": snappedf(float(Time.get_ticks_usec() - t_scan) / 1000.0, 0.01),
	}


func _open_temp_stats() -> Dictionary:
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var mn: float = 1.0e20
	var mx: float = -1.0e20
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0:
			continue
		var t: float = temp[c]
		if t < mn:
			mn = t
		if t > mx:
			mx = t
		sum += t
		n += 1
	# All-cell max (incl. solid) exposes the pinned geothermal core + the conduction gradient, which the
	# open-cell stats above hide (the hot core cells are rock).
	var all_mx: float = -1.0e20
	for v in temp:
		if v > all_mx:
			all_mx = v
	if n == 0:
		return {"temp_min": 0.0, "temp_mean": 0.0, "temp_max": 0.0, "temp_open": 0, "temp_all_max": all_mx}
	return {"temp_min": mn, "temp_mean": sum / float(n), "temp_max": mx, "temp_open": n, "temp_all_max": all_mx}


func report() -> Dictionary:
	# LAMaterialFieldSphereStep3D polls the seal on the field step; this only announces the transition once.
	if _seal != null and _seal.sealed() and not _seal_announced:
		_seal_announced = true
		print("WORLD_SEALED=", JSON.stringify(_seal.report()))
	var q: LAMaterialFieldQueries3D = _f._queries
	# `lava` and `fire` are demand-gated, so each of these blocks carries a provenance flag: `molten_live` /
	# `fire_live` false means the channel did not arrive and the zeros beside it measure nothing.
	var molten: Dictionary = q.molten_counts()
	var fire: Dictionary = q.fire_stats()
	var r: Dictionary = {
		"wet_cells": _f.wet_cell_count(), "heat_peak": _f.peak_heat(), "heat_cells": _f.hot_cell_count(),
		"cloud_cells": _f.cloud_cell_count(), "cloud_cover": _f.avg_cloud_cover(),
		"fog_cover": _f.avg_fog_cover(), "moisture_total": _f.moisture_total(),
		"wind": _f.wind().length(),
		"fertility_peak": _f.fertility_peak(),
		# Molten rock standing in open cells is an eruption. All three come from one cached walk.
		"lava_cells": molten.get("lava_cells", 0), "magma_cells": molten.get("magma_cells", 0),
		"magma_erupting": q.magma_erupting(),
		"molten_live": molten.get("molten_live", false),
		"erosion_cells": _f.erosion_cell_count(),
		"charge_peak": _f.charge_peak(), "bolts": _f.bolts_fired(),
		"shock_cells": _f.shock_cell_count(), "o2_min": _f.o2_min_open(), "o2_avg": _f.o2_avg(),
		"co2_peak": _f.co2_peak(), "co2_avg": _f.co2_avg(),
		"biomass_total": _f.biomass_total(),
		"fire_peak": fire.get("fire_peak", 0.0), "fire_cells": fire.get("fire_cells", 0),
		"fire_live": fire.get("fire_live", false),
		# Conserved totals are NOT listed here. LAMaterialFieldLedger3D publishes them in `_heavy_block()`, and
		# `Dictionary.merge` does not overwrite — a key here would shadow the ledger with a CPU-mirror value.
		"enclosed_void": q.enclosed_void_cells(),
		"enclosed_void5": q.enclosed_void_cells(5),
		"rock_grows": (_f._stamp.grows if _f._stamp != null else 0), "rock_shrinks": (_f._stamp.shrinks if _f._stamp != null else 0),
	}
	if _f._inject != null:
		r.merge(_f._inject.queue.report())
	var temps: Dictionary = _open_temp_stats()
	r.merge(temps)
	r.merge(_photo.report())
	# DECOMPOSER extent + intensity (fungus_peak/_cells, detritus_peak/_cells). One grid pass for all four.
	r.merge(_f.decomposer_stats())
	# sea_ice_cells / sea_ice_temp / open_sea_cells / open_sea_temp — one walk, medians.
	r.merge(q.sea_surface_stats())
	r.merge(q.rock_radial_profile())
	# The geothermal RESERVOIR, which rock_radial_profile above cannot show: rock_core_c is the innermost
	# simulated shell, and the reservoir is the unsimulated interior underneath it. core_res_c is the state
	# variable that falls; core_flux_w_m2 is what it delivers, against LAPhysical.GEOTHERMAL_FLUX_W_M2.
	r.merge(_f.geotherm_report())
	r.merge(q.hot_spring_stats())
	r.merge(q.lava_shell_diag())
	var heavy: Dictionary = _heavy_block()
	r.merge(heavy)
	# The station network is read EVERY call, unlike the block above: it is 48 array reads, and the diurnal
	# range it measures is precisely the thing a coarse cadence destroys.
	_swing.sample()
	r.merge(_swing.report())
	# Registering a scalar is one line. Keep them here, at the one place that already holds every aggregate,
	# so adding the next one does not need a new plumbing decision.
	_extremes.track("open_cold", float(temps.get("temp_min", 0.0)))
	_extremes.track("open_hot", float(temps.get("temp_max", 0.0)))
	_track_if_measured(r, "h2o_total", "h2o_total")
	_extremes.track("energy_net", float(heavy.get("energy_net", 0.0)))
	_extremes.track("subsolar_lat", float(r.get("swing_subsolar_lat", 0.0)))
	r.merge(_extremes.report())
	if _seal != null:
		r.merge(_seal.report())
	# THE LAW, CHECKED LAST. It reads what the ledger has published, so it must run after it.
	if _conservation != null:
		r.merge(_conservation.check(r))
	return r


## Track an extreme only when the ledger actually measured it. A refused total is null, and folding that in
## as a zero would put a low-water record into the register that no run ever reached.
func _track_if_measured(r: Dictionary, key: String, register: String) -> void:
	var v = r.get(key)
	if v is float or v is int:
		_extremes.track(register, float(v))


## True on the last frame of a --run-frames run, so the closing report is always freshly computed.
func _is_final_frame() -> bool:
	var want: int = int(Engine.get_meta("la_run_frames", 0))
	return want > 0 and Engine.get_frames_drawn() >= want - 1


func _heavy_block() -> Dictionary:
	var frame: int = int(Engine.get_process_frames())
	var every: int = HEAVY_EVERY_FRAMES
	var ov: String = OS.get_environment("LA_GAUGE_EVERY")
	if ov != "":
		every = maxi(int(ov), 1)
	# Always recompute on the final frame so the report a run is judged on is never a stale cache.
	if not _heavy_cache.is_empty() and frame - _heavy_frame < every and not _is_final_frame():
		return _heavy_cache
	_heavy_frame = frame
	var d: Dictionary = surface_climate()
	#   energy — the radiative books.
	var flux: Dictionary = _energy.report()
	d.merge(flux)
	var step: int = _f._gpu._step_index if _f._gpu != null else 0
	#   momentum — Σ m*v over the air, the third conserved quantity of mechanics. Books the pressure gradient,
	#            Coriolis and buoyancy; `momentum_unbooked` names the terms it cannot reach.
	d.merge(_momentum.report(step))
	#   the conservation ledger — H2O, mineral, the element inventory and the thermal stock, all from ONE
	#            probe read and ONE volume-weighted walk.
	if _f._ledger != null:
		d.merge(_f._ledger.report(step, flux))
	# BOTH SIDES MASK-FREE. `element_C` is the open-cell sum; `lith_element_C` is the whole-grid one, so adding
	# that pair read carbon that moved into a solid cell as carbon destroyed.
	if d.has("element_C_all") and d.has("lith_element_C"):
		var c_total: float = float(d["element_C_all"]) + float(d["lith_element_C"])
		d["element_C_total"] = snappedf(c_total, 0.01)
		if _seal != null and _seal.sealed():
			var step_now: int = int(_f._gpu._step_index) if _f._gpu != null else 0
			# The baseline latches only when BOTH sides of the sum are LIVE — measured from the drain probe this
			# sample, not merely present as an array. A baseline taken through a leg that had not arrived reads
			# near zero and every later sample then looks like carbon appearing from nothing.
			var c_live: bool = _all_live(d.get("mass_live", {})) and _all_live(d.get("mineral_live", {}))
			d["element_C_first_live"] = c_live
			if is_nan(_first_element_c) and c_live:
				_first_element_c = c_total
				_first_element_c_step = step_now
				_seal.note_seed({"element_C_mol": c_total})
			# No baseline, no baseline-derived keys. An absent `element_C_total_first` makes the conservation
			# gate report `element_C_total` unmeasured; a NAN one would be checked against and silently pass.
			if not is_nan(_first_element_c):
				d["element_C_total_first"] = snappedf(_first_element_c, 0.01)
				d["element_C_total_drift"] = snappedf(c_total - _first_element_c, 0.01)
				var c_steps: int = step_now - _first_element_c_step
				if c_steps > 0:
					d["element_C_total_drift_per_step"] = snappedf((c_total - _first_element_c) / float(c_steps), 0.0001)
				if _first_element_c != 0.0:
					d["element_C_total_rel_drift"] = snappedf((c_total - _first_element_c) / _first_element_c, 1e-9)
	_heavy_cache = d
	return d


## True when a ledger `live` map is non-empty and every leg in it arrived from the drain probe. `has_x` (the
## array is the right length) and `live_x` (measured this sample) are different questions; this asks the second.
func _all_live(m: Dictionary) -> bool:
	if m.is_empty():
		return false
	for k in m:
		if not bool(m[k]):
			return false
	return true
