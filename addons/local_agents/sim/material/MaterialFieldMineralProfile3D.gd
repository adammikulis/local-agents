class_name LAMaterialFieldMineralProfile3D
extends RefCounted

## LAMaterialFieldMineralProfile3D: WHERE the planet's loose mineral is, by elevation — not how much of it

## Field steps between printed profiles. A sample walks every cell once, so this is not free.
const SAMPLE_EVERY: int = 100

## A cell counts as actively eroding when it is carrying a real suspended load. Well above fp noise and well
## below a single scour event (erosion_pickup_sphere3d.MAX_SCOUR is 0.08), so it counts cells with a load in
## transit rather than cells with a rounding error.
const SUSP_ACTIVE: float = 0.001


var _f = null                    # back-reference to the owning LAMaterialField3D
var _gate: int = 0
var _cut_lo: float = 0.0         # radius below which ground counts as the low tercile
var _cut_hi: float = 0.0         # ...and at or above which it counts as the high one
var _bin_ready: bool = false


func setup(field) -> void:
	_f = field


## Called once per field step by LAMaterialFieldSphereStep3D. Samples on the SAMPLE_EVERY cadence.
func post_step() -> void:
	_gate += 1
	if _gate < SAMPLE_EVERY:
		return
	_gate = 0
	var p: Dictionary = sample()
	if p.is_empty():
		return
	print("MINERAL_PROFILE=", JSON.stringify(p))


## One elevation profile of the mobile mineral phases, against distance from the body centre. Empty before
## the grid exists.
func sample() -> Dictionary:
	if _f == null or _f._grid == null:
		return {}
	var cc: int = _f._cell_count
	if _f._solid.size() != cc or _f._silicate.size() != cc:
		return {}
	if _f._silicate_bed.size() != cc or _f._silicate_susp_water.size() != cc:
		return {}
	var cell: float = _f._grid.cell_size

	# Three pools that behave completely differently: mineral inside rock, mineral in an enclosed void under
	# an overhang, and mineral in the open where wind and water can still move it.
	var beds: PackedFloat32Array = PackedFloat32Array()        # radius of every surface rock cell
	var surf_r: PackedFloat32Array = PackedFloat32Array()      # radius of every open cell holding loose mineral
	var surf_m: PackedFloat32Array = PackedFloat32Array()      # ...and how much it holds
	var buried: float = 0.0
	var enclosed: float = 0.0
	var sed_mass: float = 0.0
	var sed_r: float = 0.0
	var susp_mass: float = 0.0
	var susp_r: float = 0.0
	for c in cc:
		var sil: float = _f._silicate[c]
		var sd: float = sil * _f._silicate_bed[c]
		var sp: float = sil * _f._silicate_susp_water[c]
		var m: float = sd + sp
		var hi: int = LAFieldGeometry.above(_f, c)
		if _f._solid[c] != 0:
			buried += m
			if hi >= 0 and _f._solid[hi] == 0:
				beds.append(LAFieldGeometry.radius_of(_f, c))
			continue
		if hi >= 0 and _f._solid[hi] != 0:
			enclosed += m                                      # roofed over: a cave, not a surface deposit
			continue
		var r: float = LAFieldGeometry.radius_of(_f, c)
		sed_mass += sd
		sed_r += sd * r
		susp_mass += sp
		susp_r += sp * r
		if m > 0.0:
			surf_r.append(r)
			surf_m.append(m)
	if beds.size() < 3:
		return {}

	# Terciles cut from the TERRAIN on the first sample and then frozen, so a later profile is comparable.
	beds.sort()
	if not _bin_ready:
		_cut_lo = beds[int(beds.size() / 3)]
		_cut_hi = beds[int(2 * beds.size() / 3)]
		_bin_ready = true
	var bed_sum: float = 0.0
	var bed_lo_sum: float = 0.0
	var bed_hi_sum: float = 0.0
	var n_lo: int = 0
	var n_hi: int = 0
	for r in beds:
		bed_sum += r
		if r < _cut_lo:
			bed_lo_sum += r
			n_lo += 1
		elif r >= _cut_hi:
			bed_hi_sum += r
			n_hi += 1
	var loose_lo: float = 0.0
	var loose_mid: float = 0.0
	var loose_hi: float = 0.0
	var loose_total: float = 0.0
	var loose_elev: float = 0.0
	for i in surf_m.size():
		var m: float = surf_m[i]
		var r: float = surf_r[i]
		loose_total += m
		loose_elev += m * r
		if r < _cut_lo:
			loose_lo += m
		elif r < _cut_hi:
			loose_mid += m
		else:
			loose_hi += m

	var n_land: int = beds.size()
	var bed_mean: float = bed_sum / float(n_land)
	var bed_lo_mean: float = bed_lo_sum / maxf(float(n_lo), 1.0)
	var bed_hi_mean: float = bed_hi_sum / maxf(float(n_hi), 1.0)
	var mobile: float = sed_mass + susp_mass
	return {
		"field_step": (_f._gpu._step_index if _f._gpu != null else 0),
		"land_cells": n_land,
		"bed_mean": snappedf(bed_mean, 0.001),
		"bed_cut_lo": snappedf(_cut_lo, 0.001),
		"bed_cut_hi": snappedf(_cut_hi, 0.001),
		# THE LANDSCAPE ITSELF, over the frozen tercile bins. If mineral genuinely moves downhill, the high
		# third loses ground and the low third gains it, so `relief` shrinks.
		"bed_lo_mean": snappedf(bed_lo_mean, 0.001),
		"bed_hi_mean": snappedf(bed_hi_mean, 0.001),
		"relief": snappedf(bed_hi_mean - bed_lo_mean, 0.001),
		# The two immobile pools, reported so they are never silently averaged into the mobile one.
		"buried_loose": snappedf(buried, 0.001),
		"enclosed_loose": snappedf(enclosed, 0.001),
		# --- everything below is the SURFACE pool only, in model units of radius ---
		"surf_loose": snappedf(loose_total, 0.001),
		"surf_susp": snappedf(susp_mass, 0.001),
		"surf_mean_r": snappedf((sed_r + susp_r) / maxf(mobile, 1.0e-9), 0.001),
		"sed_mean_r": snappedf(sed_r / maxf(sed_mass, 1.0e-9), 0.001),
		"susp_mean_r": snappedf(susp_r / maxf(susp_mass, 1.0e-9), 0.001),
		# Mass-weighted BED elevation: which ground the loose mineral lies on. Below `bed_mean` means it has
		# moved downhill from where it was made.
		"surf_mean_bed": snappedf(loose_elev / maxf(loose_total, 1.0e-9), 0.001),
		"surf_bed_offset": snappedf(loose_elev / maxf(loose_total, 1.0e-9) - bed_mean, 0.001),
		"surf_lo": snappedf(loose_lo, 0.001),
		"surf_mid": snappedf(loose_mid, 0.001),
		"surf_hi": snappedf(loose_hi, 0.001),
		"lo_over_hi": snappedf(loose_lo / maxf(loose_hi, 1.0e-9), 0.0001),
		"cell_size": snappedf(cell, 0.001),
	}
