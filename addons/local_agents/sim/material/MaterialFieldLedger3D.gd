class_name LAMaterialFieldLedger3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldLedger3D: the conserved H₂O ledger of LAMaterialField3D, plus the snow/ice extent
## diagnostics. Reaches into the owning field `_f` for the shared channels.

var _f = null                                            # back-reference to the owning LAMaterialField3D

var _stranded_cells: int = 0    # set by stranded_soil_total(); reported beside it
var _prev_h2o: float = NAN
var _prev_step: int = -1
# Run-level anchor: the total at the seal step, so drift is measured over the whole horizon.
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


## Open cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			n += 1
	return n


## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] >= LAMaterialField3D.ICE_DEPTH:
			n += 1
	return n


# Every leg of h2o_total is mask-free: water that infiltrates a cell the derived solid flag then covers has
# moved, not vanished, and an open-only sum books that move as destruction.

## Frozen H₂O over every cell — one leg of the conserved h2o_total.
func snow_total() -> float:
	return CellVolScript.weighted(_f._snow, CellVolScript.of(_f), _f._solid, false)


## Liquid H₂O over every cell — one leg of the conserved h2o_total.
func water_total() -> float:
	return CellVolScript.weighted(_f._water, CellVolScript.of(_f), _f._solid, false)


## Groundwater over every cell — one leg of the conserved h2o_total.
func soil_total() -> float:
	return CellVolScript.weighted(_f._soil, CellVolScript.of(_f), _f._solid, false)


## Liquid + airborne + frozen + groundwater. Every leg mask-free, so burial reads as burial.
func h2o_total() -> float:
	return water_total() + _f.moisture_total() + snow_total() + soil_total()


func stranded_soil_total() -> float:
	if _f._soil.size() != _f._cell_count or _f._regolith.size() != _f._cell_count:
		return 0.0
	var regolith: PackedByteArray = _f._regolith
	var solid: PackedByteArray = _f._solid
	var soil: PackedFloat32Array = _f._soil
	var vol: PackedFloat32Array = CellVolScript.of(_f)
	if vol.size() != _f._cell_count:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if regolith[c] != 0 and solid[c] == 0:
			sum += soil[c] * vol[c]
			n += 1
	_stranded_cells = n
	return sum


func conservation_report(step_index: int) -> Dictionary:
	var h2o: float = h2o_total()
	var drift: float = 0.0
	var per_step: float = 0.0
	if not is_nan(_prev_h2o) and step_index > _prev_step:
		drift = h2o - _prev_h2o
		per_step = drift / float(step_index - _prev_step)
	_prev_h2o = h2o
	_prev_step = step_index
	if _first_step < 0 and _at_seal(step_index):
		_first_h2o = h2o
		_note_seed("h2o", h2o)
		_first_step = step_index
	var run_steps: int = step_index - _first_step
	var out: Dictionary = {
		# The key LAMaterialFieldConservation3D gates on.
		"h2o_closed_total": snappedf(h2o, 0.01),
		"h2o_drift": snappedf(drift, 0.01),
		"h2o_drift_per_step": snappedf(per_step, 0.001),
		"h2o_first": snappedf(_first_h2o, 0.01),
		"h2o_run_steps": run_steps,
		"soil_stranded": snappedf(stranded_soil_total(), 0.01),
		"soil_stranded_cells": _stranded_cells,
	}
	if run_steps > 0:
		out["h2o_run_drift"] = snappedf(h2o - _first_h2o, 0.01)
		out["h2o_run_drift_per_step"] = snappedf((h2o - _first_h2o) / float(run_steps), 0.0001)
	return out


## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var temp: PackedFloat32Array = _f._temp
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			sum += temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0


## True only on the step LAMaterialFieldSeal3D latched the books. The seal drives one sample there; a sample
## on any other step cannot take a baseline, so a late one is impossible rather than merely unlikely.
func _at_seal(step_index: int) -> bool:
	return _f != null and _f._seal != null and step_index == _f._seal.baseline_step()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
