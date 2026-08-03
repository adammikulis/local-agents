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

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _photo = null                                        # LAMaterialFieldPhotoStats3D — primary-production spatial stats


func setup(field) -> void:
	_f = field
	_photo = PhotoStatsScript.new()
	_photo.setup(field)


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
const CLIMATE_MAX_CELLS: int = 60000            # scan bound; snapshot-time only, never per frame
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
	for c in mini(_f._cell_count, CLIMATE_MAX_CELLS):
		if solid[c] != 0:
			continue
		var p: Vector3 = _f.cell_world_pos_linear(c) - _f._origin
		var radius: float = p.length()
		if radius < 0.001:
			continue
		var t: float = temp[c]
		var lat: float = absf(rad_to_deg(asin(clampf(p.dot(axis) / radius, -1.0, 1.0))))
		var alt: float = radius - sea_r
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
		# GROUND-HUGGING (inward neighbour is rock) vs ALOFT — the two distinct freezing populations.
		var r: int = c % depth
		var is_ground: bool = r > 0 and solid[c - 1] != 0
		if is_ground:
			var band: int = clampi(int(lat / (90.0 / float(CLIMATE_BANDS))), 0, CLIMATE_BANDS - 1)
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


## Polled only at snapshot time, so these (cheap forwarder) reads don't run per frame.
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
		"dust_cells": _f.dust_cell_count(), "charge_peak": _f.charge_peak(), "bolts": _f.bolts_fired(),
		"shock_cells": _f.shock_cell_count(), "o2_min": _f.o2_min_open(), "o2_avg": _f.o2_avg(),
		"co2_peak": _f.co2_peak(), "co2_avg": _f.co2_avg(), "fungus_cells": _f.fungus_cells(),
		"fungus_peak": _f.fungus_peak(), "detritus_peak": _f.detritus_peak(),
		"biomass_total": _f.biomass_total(),
		"fuel_total": q.fuel_total(), "fire_peak": q.fire_peak(), "fire_cells": q.fire_cells(),
		"active_cells": q.active_cells(), "mean_relevance": q.mean_relevance(),
		"h2o_total": _f.h2o_total(), "water_total": _f.water_total(), "snow_total": _f.snow_total(), "soil_total": _f.soil_total(),
		"snow_line_temp": _f.snow_line_temp(),
		"mineral_total": q.mineral_total(), "rock_cells": q.rock_cells(),
		"rock_fill_total": q.rock_fill_total(), "lava_total": q.lava_total(),
		"sediment_total": q.sediment_total(), "dust_total": q.dust_total(),
		"susp_total": q.susp_total(),
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
	r.merge(_open_temp_stats())
	r.merge(_photo.report())
	r.merge(q.rock_radial_profile())
	r.merge(q.hot_spring_stats())
	r.merge(q.lava_shell_diag())
	return r
