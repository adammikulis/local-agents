class_name LAMaterialFieldReport3D
extends RefCounted

## LAMaterialFieldReport3D: the central-telemetry snapshot of LAMaterialField3D, factored out of the
## extract-only field hub. Same pattern as the query / atmos / ledger / channel modules: no state of its own,
## it reaches into the owning field `_f` and calls the field's own (cheap forwarder) accessors.
##
## This is the ONE dict the field contributes to SIM_REPORT, so every channel aggregate flows in from its
## owner instead of being hand-threaded into a format string somewhere else. Polled only at snapshot time, so
## the O(cells) scans behind these getters never run per frame.
## (Explicit types only, no ':=' inferred typing.)

const PhotoStatsScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd")
const EnergyBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd")
const ExtremesScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldExtremes3D.gd")
const ClimateSwingScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd")
const ElementInventoryScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldElementInventory3D.gd")
const MineralBudgetScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldMineralBudget3D.gd")

## Process frames between recomputes of the O(cells) instrument block. See `_heavy_block()` for why a gate is
## needed at all — the short version is that this provider is polled every rendered frame, not once a
## snapshot, and the docstrings that said otherwise were wrong.
const HEAVY_EVERY_FRAMES: int = 8

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _photo = null                                        # LAMaterialFieldPhotoStats3D — primary-production spatial stats
var _energy = null                                       # LAMaterialFieldEnergyBudget3D — absorbed/emitted/net radiation
var _extremes = null                                     # LAMaterialFieldExtremes3D — min/max-ever register
var _swing = null                                        # LAMaterialFieldClimateSwing3D — diurnal + seasonal range
var _mass = null                                         # LAMaterialFieldElementInventory3D — carbon/oxygen/fertility ledgers
var _mineral = null                                      # LAMaterialFieldMineralBudget3D — the five-phase rock ledger
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


## SURFACE CLIMATE BY LATITUDE AND ALTITUDE — the gauge that can actually answer "can it freeze HERE".
##
## THIS EXISTS BECAUSE A GLOBAL AGGREGATE ANSWERED THE WRONG QUESTION AND COST THE PROJECT ITS PHYSICS.
## Freezing is LOCAL: a planet does not need to be cold, it needs cold POLES and cold SUMMITS. But the only
## temperature readouts here were global — `temp_min`, `temp_mean`, `temp_max` over every open cell at once.
## Someone read `temp_min` ~11 °C, concluded "a literal 0 °C freeze can never fire here", and moved WATER'S
## FREEZING POINT to 12.5 °C in five files rather than asking why nowhere on the planet was cold. `temp_min`
## was not even wrong — it is a correct bound — but a bound cannot tell you whether the climate has
## STRUCTURE, and structure is the entire question. `temp_mean` is worse for this: it mixes ground-hugging
## air with open lava and core cells, so it can climb 25 °C while every cell a creature stands on is flat.
##
## So: bin the GROUND-HUGGING surface cells (open, with solid rock directly inward — where snow deposits and
## where creatures live) by |latitude| against the spin axis, and report each band's mean and min plus how
## much of the surface is actually below freezing. A warm equator with cold poles is a working climate; a
## flat profile is a broken one, however comfortable its global mean looks.
## WATER FREEZES IN FOUR DIFFERENT PLACES AND THIS MEASURES ALL OF THEM.
##   * by LATITUDE — cold poles, warm equator
##   * by ALTITUDE — a summit freezes at ANY latitude, which is what makes a snow-capped equatorial peak
##   * ALOFT — snowice_sphere3d freezes CONDENSED ATMOSPHERIC moisture, so the air column is the primary
##     snow source and a ground-only scan would miss the mechanism entirely
##   * over TIME — the coldest moment is the deep night side, and a snapshot every 180 frames walks straight
##     past it. `coldest_ever` is a RUNNING minimum updated on every snapshot, so a transient low is kept.
const CLIMATE_BANDS: int = 6                    # 15° per band from equator to pole
const ALT_BANDS: int = 4                        # ground / low / mid / high, by altitude above the sea shell
const ALT_BAND_SPAN: float = 8.0                # world units per altitude band
## Scan bound. Raised from 60000 on 2026-08-03, when this function was first wired into the report: the
## shipped grid is 6 x 24 x 24 x 20 = 69120 cells, so 60000 dropped 13% of the planet — and because cells are
## enumerated column-major by cube face, what it dropped was a contiguous SLAB OF FACE, i.e. an entire
## geographic region, from a gauge whose whole job is geographic structure. A cap that silently deletes one
## sixth of the map is worse than a slower scan. The per-column hoist below made the FULL sweep cheaper than
## the truncated one was, so nothing was traded for it. It stays as a guard against a much larger grid, and
## the scan is column-aligned so it can only ever cut whole columns.
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
	# FREEZING STANDING WATER — lakes and sea icing over. The most ordinary way water freezes on a planet,
	# and the one a latitude/altitude scan alone does NOT answer: a cell can be below zero and simply have no
	# water in it. These count cells that actually HOLD liquid water and are below freezing, which is the
	# population R21 (WATER -> SNOW) converts, and `water_coldest` is how cold the wettest places get.
	var water: PackedFloat32Array = _f._water
	var has_water: bool = water.size() == _f._cell_count
	var water_frozen: int = 0
	var water_cells: int = 0
	var water_coldest: float = 1.0e20
	# COLUMN-MAJOR, AND THE PER-CELL TRIGONOMETRY IS HOISTED OUT (2026-08-03). This loop used to call
	# `cell_world_pos_linear(c)` — a cross-object call, a Basis multiply and a `length()` — plus an `asin` for
	# EVERY cell, and then the report provider turned out to be polled every rendered frame (see the cadence
	# note on `report()`), which cost the run more than the whole rest of the field step. Two facts make all of
	# it unnecessary: `SphereGrid.cell_world_pos` is `center + _dir[s] * (core_radius + (r+0.5)*cell_size)`, so
	# the RADIUS depends only on `r`, and the DIRECTION only on the column; and `_origin` IS `grid.center`
	# (MaterialField3D.setup_sphere:376), so the offset cancels exactly. Latitude is therefore a per-column
	# quantity and altitude a per-r one. Same numbers, ~O(columns + depth) trig instead of O(cells).
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
		# `cell_radial` is the BODY-LOCAL outward unit; the latitude convention here is the WORLD one, so
		# rotate it into the world frame exactly as `cell_world_pos_linear` does. (Both give the same latitude
		# because the body spins about this very axis, but keeping the frames explicit is what stops the next
		# reader from dotting a body-local vector against a world axis and getting a number that is only right
		# when the rotation happens to be identity.)
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
			# STANDING WATER that is below freezing — the population R21 (WATER -> SNOW) actually converts.
			# These three counters were declared here and never once written, so the comment above them
			# described a measurement that did not exist. Filled in rather than deleted: a cell can be well
			# below zero and simply hold no water, and only this pair of numbers separates "the planet cannot
			# get cold" from "the cold places are dry", which are opposite diagnoses.
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


## Open-cell (void) temperature spread — the direct read of whether the solar terminator + heat diffusion
## actually move the temp field (a flat min==max means solar is not depositing). Snapshot-time only.
##
## CAUTION, and the reason `surface_climate()` above exists: these are GLOBAL aggregates over every open
## cell, which includes open lava and core cells. `temp_mean` can therefore rise steeply while the ground
## every creature stands on is unchanged, and `temp_min` can only ever tell you the single coldest cell —
## never whether the climate has a warm-equator/cold-pole STRUCTURE. Do not conclude anything about
## habitability, snow or freezing from these three numbers alone.
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


## CORRECTED 2026-08-03. This said "Polled only at snapshot time, so these (cheap forwarder) reads don't run
## per frame", and both halves are false: the reads behind these forwarders are O(cells) scans, not cheap, and
## the provider is polled EVERY RENDERED FRAME at any high `--fast` (LAGameHud's 0.5 s refresh Timer counts
## down on the scaled clock). The O(cells) instrument block added here is gated in `_heavy_block()` for that
## reason; the pre-existing scans above are not, and that is a live perf question this lane did not touch.
func report() -> Dictionary:
	var q: LAMaterialFieldQueries3D = _f._queries
	var r: Dictionary = {
		"wet_cells": _f.wet_cell_count(), "heat_peak": _f.peak_heat(), "heat_cells": _f.hot_cell_count(),
		"lava_cells": _f.lava_peak(), "cloud_cells": _f.cloud_cell_count(), "cloud_cover": _f.avg_cloud_cover(),
		"fog_cover": _f.avg_fog_cover(), "moisture_total": _f.moisture_total(),
		"wind": _f.wind().length(), "scent_cells": _f.scent_cell_count(),
		"fertility_peak": _f.fertility_peak(), "magma_cells": _f.magma_cell_count(),
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
		# MINERAL is NOT here. Its six absolutes plus `rock_cells` used to be computed on this line, ungated,
		# and cost ELEVEN O(cells) walks per report call — `mineral_total()` re-walks the grid five times and
		# the five individual getters walked it five more. LAMaterialFieldMineralBudget3D produces all of them,
		# both masks, and the drift they never had, in ONE pass behind `_heavy_block()`'s cadence gate.
		"enclosed_void": q.enclosed_void_cells(),
		"enclosed_void5": q.enclosed_void_cells(5),
		"rock_grows": (_f._stamp.grows if _f._stamp != null else 0), "rock_shrinks": (_f._stamp.shrinks if _f._stamp != null else 0),
	}
	# CONSERVATION. The four h2o legs above are absolute levels; a total printed only as an absolute cannot
	# show a slow leak, which is exactly how this one hid. These add the reservoir the ledger does not count
	# (static water), the closed sum of all five, the per-step drift, and the soil the regolith mask sees but
	# the solidity mask has lost. Sampled on the field's own step counter so drift is per SIM step, not per
	# render frame — a frame-based rate would track framerate rather than physics.
	r.merge(_f._ledger.conservation_report(_f._gpu._step_index if _f._gpu != null else 0))
	# INJECTION LEDGER. The gauges above say whether the books balance; these say who moved the money.
	# `h2o_inject_demand` is what storms asked their own footprint for — and, before add_vapor became a
	# transfer, exactly what they created out of nothing. `..._moved` is what the planet actually supplied,
	# `..._short` the difference (a storm on a dry footprint), `..._minted` the genuinely sourceless adds (a
	# scripted flood surge), and `h2o_displaced`/`h2o_buried` what a solidity change did with the water in a
	# cell that stopped being able to hold it.
	if _f._inject != null:
		r.merge(_f._inject.queue.report())
	var temps: Dictionary = _open_temp_stats()
	r.merge(temps)
	r.merge(_photo.report())
	# DECOMPOSER extent + intensity (fungus_peak/_cells, detritus_peak/_cells). One grid pass for all four.
	# These used to be three separate calls into hub stubs that returned a literal zero, so the decomposer
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
	return r


## THE HEAVY BLOCK — the three O(cells) instruments, behind ONE cadence gate, cached in between.
##
## THE GATE IS NOT AN OPTIMISATION, IT IS A CORRECTION OF A FALSE COMMENT. This file's header (and the
## docstring on `report()` above) claimed the provider is "polled only at snapshot time, so the O(cells) scans
## never run per frame". Measured 2026-08-03: that is FALSE at any interesting `--fast`. LAGameHud arms a
## `Timer` at REFRESH_INTERVAL 0.5 s and a Timer counts down on the SCALED clock, so at `--fast=8` — where the
## idle delta is around a second per rendered frame — it fires every single frame and takes a full snapshot,
## which polls every provider. The existing scans in this function have therefore always been per-frame work;
## adding three more without a gate took a 600-frame run from 47.6 s to over 600 s (it did not reach frame
## 180). With the gate the same run costs a few percent, and `clim_scan_ms` / `energy_scan_ms` /
## `mass_scan_ms` report what one sweep of each actually costs so this can be re-argued from numbers.
##
## Every quantity behind the gate is either an aggregate that moves slowly or a per-STEP drift, and the drifts
## divide by the field steps actually elapsed, so a coarser sample changes their resolution and not their
## value. The one thing that genuinely needs every sample — the weather stations' diurnal range — is
## deliberately outside it.
func _heavy_block() -> Dictionary:
	var frame: int = int(Engine.get_process_frames())
	if not _heavy_cache.is_empty() and frame - _heavy_frame < HEAVY_EVERY_FRAMES:
		return _heavy_cache
	_heavy_frame = frame
	# SURFACE CLIMATE — wired in here (2026-08-03). `surface_climate()` was written in this very file and CALLED
	# BY NOTHING: a grep for `clim_lat_mean` found the literal that builds it and no consumer anywhere, so the
	# one gauge that can answer "can it freeze HERE" never reached a single SIM_REPORT. Per the standing rule
	# that unwired code is a previous session's unfinished job, it is connected rather than left.
	var d: Dictionary = surface_climate()
	#   energy — the radiative books. There was NO energy accounting anywhere before this; a radiative sink was
	#            added on this line of work and nothing could verify it.
	d.merge(_energy.report())
	#   mass   — conservation ledgers for carbon, oxygen, fertility and biomass, on the H₂O ledger's pattern.
	#            Every substance here that had a ledger conserved; every substance without one minted.
	d.merge(_mass.report(_f._gpu._step_index if _f._gpu != null else 0))
	#   mineral — the five-phase rock ledger. Publishes the same six absolutes this block replaced (so nothing
	#            downstream lost a key) PLUS the drift, the source-corrected net rate, and both masks. It is a
	#            NET REDUCTION in work here: one pass instead of the eleven the ungated block above ran.
	d.merge(_mineral.report(_f._gpu._step_index if _f._gpu != null else 0))
	_heavy_cache = d
	return d
