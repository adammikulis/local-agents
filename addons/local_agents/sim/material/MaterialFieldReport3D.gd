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

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Open-cell (void) temperature spread — the direct read of whether the solar terminator + heat diffusion
## actually move the temp field (a flat min==max means solar is not depositing). Snapshot-time only.
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
	r.merge(_open_temp_stats())
	r.merge(q.rock_radial_profile())
	r.merge(q.hot_spring_stats())
	r.merge(q.lava_shell_diag())
	return r
