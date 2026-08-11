class_name LAMaterialFieldLedger3D
extends RefCounted

## LAMaterialFieldLedger3D: conserved H₂O totals + snow/ice cell counts for LAMaterialField3D.
## ONE inclusion rule for every H₂O leg (water, snow, moisture, soil): every cell, no residency mask.
## The four phases are kept mutually exclusive by solid_derive_sphere3d.glsl (it moves water/moisture/snow
## into soil when a cell closes), so a mask in a gauge can only hide mass, never find it.

var _f = null                                            # back-reference to the owning LAMaterialField3D

var _prev_h2o: float = NAN
var _prev_step: int = -1
# Run-level anchor: the first sample this run, so drift can be amortised over the whole horizon instead of
# only the gap between two consecutive samples. Same shape as LAMaterialFieldElementInventory3D's `_first_*` set.
var _first_h2o: float = NAN
var _first_step: int = -1


func setup(field) -> void:
	_f = field


## Snow depth at a world point (frozen H₂O in the cell). 2.5D-style (x,z) calls have no radial point, so they
## return the safe default 0 (matching temp_at); a full 3D call (x,z,y) reads the real cell — three-d-always.
func snow_depth_at(pos: Vector3) -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._snow[c] if c >= 0 else 0.0


## Cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if snow[c] > LAMaterialField3D.SNOW_PRESENT:
			n += 1
	return n


## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if snow[c] >= LAMaterialField3D.ICE_DEPTH:
			n += 1
	return n


## Frozen H₂O leg of h2o_total. Channel units.
func snow_total() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var snow: PackedFloat32Array = _f._snow
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += snow[c]
	return sum


## Liquid surface-water leg of h2o_total. Channel units.
func water_total() -> float:
	if _f._water.size() != _f._cell_count:
		return 0.0
	var water: PackedFloat32Array = _f._water
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += water[c]
	return sum


## Pore-water leg of h2o_total. Channel units.
func soil_total() -> float:
	if _f._soil.size() != _f._cell_count:
		return 0.0
	var soil: PackedFloat32Array = _f._soil
	var sum: float = 0.0
	for c in _f._cell_count:
		sum += soil[c]
	return sum


func h2o_total() -> float:
	return water_total() + _f.moisture_total() + snow_total() + soil_total()


func conservation_report(step_index: int) -> Dictionary:
	var h2o: float = h2o_total()
	var drift: float = 0.0
	var per_step: float = 0.0
	if not is_nan(_prev_h2o) and step_index > _prev_step:
		drift = h2o - _prev_h2o
		per_step = drift / float(step_index - _prev_step)
	_prev_h2o = h2o
	_prev_step = step_index
	if _first_step < 0 and _sealed():
		_first_h2o = h2o
		_note_seed("h2o", h2o)
		_first_step = step_index
	var run_steps: int = step_index - _first_step
	var out: Dictionary = {
		"h2o_dynamic_total": snappedf(h2o, 0.01),
		"h2o_closed_total": snappedf(h2o, 0.01),
		"h2o_drift": snappedf(drift, 0.01),
		"h2o_drift_per_step": snappedf(per_step, 0.001),
		"h2o_first": snappedf(_first_h2o, 0.01),
		"h2o_run_steps": run_steps,
	}
	if run_steps > 0:
		out["h2o_run_drift"] = snappedf(h2o - _first_h2o, 0.01)
		out["h2o_run_drift_per_step"] = snappedf((h2o - _first_h2o) / float(run_steps), 0.0001)
	return out


## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var snow: PackedFloat32Array = _f._snow
	var temp: PackedFloat32Array = _f._temp
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if snow[c] > LAMaterialField3D.SNOW_PRESENT:
			sum += temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0


## True once LAMaterialFieldSeal3D has closed the books. Before it, this module publishes totals but latches
## no baseline and reports no run-drift — because until the world is sealed the only thing a drift gauge can
## measure is the planet being assembled.
func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
