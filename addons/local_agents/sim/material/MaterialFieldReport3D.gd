class_name LAMaterialFieldReport3D
extends RefCounted

## LAMaterialFieldReport3D: the central-telemetry snapshot of LAMaterialField3D, factored out of the

const PhotoStatsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd")
const EnergyBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd")
const ExtremesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldExtremes3D.gd")
const ClimateSwingScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd")
const ElementInventoryScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementInventory3D.gd")
const MineralBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralBudget3D.gd")
const EnergyLedgerScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldEnergyLedger3D.gd")
const SealScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSeal3D.gd")
const ConservationScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldConservation3D.gd")

## Process frames between recomputes of the O(cells) instrument block.
##
## These gauges are GDScript walks over every cell — measured on frame 1: energy_stock 87.9 ms, energy 38.5,
## mass 13.7, mineral 11.0, clim 7.1, against a field step of 6.5 ms. At every 8 frames they were ~20x the
## cost of the simulation they measure and dominated every verification run. `LA_GAUGE_EVERY` overrides.
const HEAVY_EVERY_FRAMES: int = 64

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _photo = null                                        # LAMaterialFieldPhotoStats3D — primary-production spatial stats
var _energy = null                                       # LAMaterialFieldEnergyBudget3D — absorbed/emitted/net radiation
var _extremes = null                                     # LAMaterialFieldExtremes3D — min/max-ever register
var _swing = null                                        # LAMaterialFieldClimateSwing3D — diurnal + seasonal range
var _mass = null                                         # LAMaterialFieldElementInventory3D — carbon/oxygen/fertility ledgers
var _mineral = null                                      # LAMaterialFieldMineralBudget3D — the five-phase rock ledger
var _energy_stock = null                         # LAMaterialFieldEnergyLedger3D — rho*c*V*T stock + its drift
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
	_mass = ElementInventoryScript.new()
	_mass.setup(field)
	_mineral = MineralBudgetScript.new()
	_mineral.setup(field)
	_energy_stock = EnergyLedgerScript.new()
	_energy_stock.setup(field)
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
const PLANET_SPIN_AXIS: Vector3 = Vector3(0.40, 0.92, 0.0)

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
	if solid.size() != _f._cell_count or temp.size() != _f._cell_count or _f._sphere == null:
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
	var depth: int = _f._dim_y
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
	var grid = _f._sphere
	var core_r: float = float(grid.core_radius)
	var cell_sz: float = float(grid.cell_size)
	var limit: int = mini(_f._cell_count, CLIMATE_MAX_CELLS)
	var columns: int = limit / depth
	# Per-r radius and altitude band, computed once for the whole grid.
	var r_alt: PackedFloat32Array = PackedFloat32Array()
	var r_ab: PackedInt32Array = PackedInt32Array()
	r_alt.resize(depth)
	r_ab.resize(depth)
	for r in depth:
		var radius: float = core_r + (float(r) + 0.5) * cell_sz
		var alt_r: float = radius - sea_r
		r_alt[r] = alt_r
		r_ab[r] = clampi(int(maxf(alt_r, 0.0) / ALT_BAND_SPAN), 0, ALT_BANDS - 1)
	for s in columns:
		var base: int = s * depth
		var wdir: Vector3 = _f._body_basis * _f.cell_radial(base)
		var lat: float = absf(rad_to_deg(asin(clampf(wdir.dot(axis), -1.0, 1.0))))
		var band: int = clampi(int(lat / (90.0 / float(CLIMATE_BANDS))), 0, CLIMATE_BANDS - 1)
		for r in depth:
			var c: int = base + r
			if solid[c] != 0:
				continue
			var t: float = temp[c]
			var alt: float = r_alt[r]
			if t < coldest:
				coldest = t
				if t < _coldest_ever:
					_coldest_ever = t
					_coldest_ever_alt = snappedf(alt, 0.1)
					_coldest_ever_lat = snappedf(lat, 0.1)
			# ALTITUDE profile over every open cell — this is where an equatorial summit and the cold upper air
			# both show up, and neither is visible in a latitude-only or ground-only scan.
			var ab: int = r_ab[r]
			alt_n[ab] += 1
			if t < alt_min[ab]:
				alt_min[ab] = t
			if has_water and water[c] > LAMaterialField3D.MIN_MASS:
				water_cells += 1
				if t < LAPhysical.WATER_FREEZE_C:
					water_frozen += 1
				if t < water_coldest:
					water_coldest = t
			# GROUND-HUGGING (inward neighbour is rock) vs ALOFT — the two distinct freezing populations.
			var is_ground: bool = r > 0 and solid[c - 1] != 0
			if is_ground:
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
	# The seal is polled on the FIELD STEP (LAMaterialFieldSphereStep3D), never here: this runs on the gauge
	# cadence, so polling here made the seal step depend on the report rate and on renderer-driven channel
	# residency. Announce the transition once, from the phase the step has already reached.
	if _seal != null and _seal.sealed() and not _seal_announced:
		_seal_announced = true
		print("WORLD_SEALED=", JSON.stringify(_seal.report()))
	var q: LAMaterialFieldQueries3D = _f._queries
	var r: Dictionary = {
		"wet_cells": _f.wet_cell_count(), "heat_peak": _f.peak_heat(), "heat_cells": _f.hot_cell_count(),
		"lava_cells": _f.lava_peak(), "cloud_cells": _f.cloud_cell_count(), "cloud_cover": _f.avg_cloud_cover(),
		"fog_cover": _f.avg_fog_cover(), "moisture_total": _f.moisture_total(),
		"wind": _f.wind().length(), "scent_cells": _f.scent_cell_count(),
		"fertility_peak": _f.fertility_peak(), "magma_cells": _f.magma_cell_count(),
		# Molten rock standing in OPEN cells — an eruption, by what the word means. `magma_erupting()` already
		# reads the same cached walk `magma_cells` and `lava_cells` above have already paid for.
		"magma_erupting": _f.magma_erupting(),
		"erosion_cells": _f.erosion_cell_count(), "snow_cells": _f.snow_cell_count(), "ice_cells": _f.ice_cell_count(),
		"sea_ice_cells": q.sea_ice_cell_count(), "sea_ice_temp": q.sea_ice_temp_avg(), "open_sea_temp": q.open_sea_temp_avg(),
		# (`dust_cells` moved into the mineral budget's single pass — it already walks the dust channel, so
		# counting there is free, where a call here would have added an O(cells) walk to the per-frame path.)
		"charge_peak": _f.charge_peak(), "bolts": _f.bolts_fired(),
		"shock_cells": _f.shock_cell_count(), "o2_min": _f.o2_min_open(), "o2_avg": _f.o2_avg(),
		"co2_peak": _f.co2_peak(), "co2_avg": _f.co2_avg(),
		"biomass_total": _f.biomass_total(),
		"fuel_total": q.fuel_total(), "fire_peak": q.fire_peak(), "fire_cells": q.fire_cells(),
		"h2o_total": _f.h2o_total(), "water_total": _f.water_total(), "snow_total": _f.snow_total(), "soil_total": _f.soil_total(),
		"snow_line_temp": _f.snow_line_temp(),
		# and cost ELEVEN O(cells) walks per report call — `mineral_total()` re-walks the grid five times and
		# the five individual getters walked it five more. LAMaterialFieldMineralBudget3D produces all of them,
		# both masks, and the drift they never had, in ONE pass behind `_heavy_block()`'s cadence gate.
		"enclosed_void": q.enclosed_void_cells(),
		"enclosed_void5": q.enclosed_void_cells(5),
		"rock_grows": (_f._stamp.grows if _f._stamp != null else 0), "rock_shrinks": (_f._stamp.shrinks if _f._stamp != null else 0),
	}
	r.merge(_f._ledger.conservation_report(_f._gpu._step_index if _f._gpu != null else 0))
	if _f._inject != null:
		r.merge(_f._inject.queue.report())
	var temps: Dictionary = _open_temp_stats()
	r.merge(temps)
	r.merge(_photo.report())
	# DECOMPOSER extent + intensity (fungus_peak/_cells, detritus_peak/_cells). One grid pass for all four.
	# half of the carbon loop published nothing but zeros while fungus_total beside it read real values.
	r.merge(_f.decomposer_stats())
	r.merge(q.rock_radial_profile())
	# The geothermal RESERVOIR, which rock_radial_profile above cannot show: rock_core_c is the innermost
	# simulated shell, and the reservoir is the unsimulated interior underneath it. core_res_c is the state
	# variable that falls; core_flux_w_m2 is what it delivers, to be read against LAPhysical's 0.087.
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
	_extremes.track("h2o_total", float(r.get("h2o_total", 0.0)))
	_extremes.track("energy_net", float(heavy.get("energy_net", 0.0)))
	_extremes.track("subsolar_lat", float(r.get("swing_subsolar_lat", 0.0)))
	r.merge(_extremes.report())
	if _seal != null:
		r.merge(_seal.report())
	# THE LAW, CHECKED LAST — here rather than inside _heavy_block() because the H2O ledger's `h2o_first` is
	# merged into `r` after that block runs, and checking early reported the planet's water as "unmeasured".
	# It reads what every ledger has published, so it must run after all of them.
	if _conservation != null:
		r.merge(_conservation.check(r))

	return r


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
	# BY NOTHING: a grep for `clim_lat_mean` found the literal that builds it and no consumer anywhere, so the
	# one gauge that can answer "can it freeze HERE" never reached a single SIM_REPORT. Per the standing rule
	# that unwired code is a previous session's unfinished job, it is connected rather than left.
	var d: Dictionary = surface_climate()
	#   energy — the radiative books. There was NO energy accounting anywhere before this; a radiative sink was
	#            added on this line of work and nothing could verify it.
	var flux: Dictionary = _energy.report()
	d.merge(flux)
	d.merge(_energy_stock.report(_f._gpu._step_index if _f._gpu != null else 0, flux))
	#   mass   — conservation ledgers for carbon, oxygen, fertility and biomass, on the H₂O ledger's pattern.
	#            Every substance here that had a ledger conserved; every substance without one minted.
	d.merge(_mass.report(_f._gpu._step_index if _f._gpu != null else 0))
	#   mineral — the five-phase rock ledger. Publishes the same six absolutes this block replaced (so nothing
	#            downstream lost a key) PLUS the drift, the source-corrected net rate, and both masks. It is a
	#            NET REDUCTION in work here: one pass instead of the eleven the ungated block above ran.
	d.merge(_mineral.report(_f._gpu._step_index if _f._gpu != null else 0))
	if d.has("element_C") and d.has("lith_element_C"):
		var c_total: float = float(d["element_C"]) + float(d["lith_element_C"])
		d["element_C_total"] = snappedf(c_total, 0.01)
		if _seal != null and _seal.sealed():
			var step_now: int = int(_f._gpu._step_index) if _f._gpu != null else 0
			if is_nan(_first_element_c):
				_first_element_c = c_total
				_first_element_c_step = step_now
				_seal.note_seed({"element_C_mol": c_total})
			d["element_C_total_first"] = snappedf(_first_element_c, 0.01)
			d["element_C_total_drift"] = snappedf(c_total - _first_element_c, 0.01)
			var c_steps: int = step_now - _first_element_c_step
			if c_steps > 0:
				d["element_C_total_drift_per_step"] = snappedf((c_total - _first_element_c) / float(c_steps), 0.0001)
			if _first_element_c != 0.0:
				d["element_C_total_rel_drift"] = snappedf((c_total - _first_element_c) / _first_element_c, 1e-9)
	_heavy_cache = d
	return d
