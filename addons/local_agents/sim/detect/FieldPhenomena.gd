class_name LAFieldPhenomena
extends RefCounted

## Reads the field's own mirrors and names what is already in them.

var _f = null
var _step: int = -1
var _obs: Dictionary = {}


func setup(field) -> void:
	_f = field


## `eruptions` / `cyclones` are world positions with the readings that named them.
func observe() -> Dictionary:
	var step: int = _f._gpu._step_index if _f != null and _f._gpu != null else -1
	if step >= 0 and step == _step and not _obs.is_empty():
		return _obs
	_step = step
	var vel_ok: bool = _f != null and _f._vel_x.size() == _f._cell_count
	var melt_ok: bool = _live("silicate") and LAProcessSet.has_record("pass", "FluxPass.gd")
	var low_ok: bool = _live("pressure") and vel_ok and _f._temp.size() == _f._cell_count \
		and LAProcessSet.has_record("transport", "mom_flux")
	_obs = {
		"eruptions": _eruptions() if melt_ok else [],
		"eruptions_live": melt_ok,
		"cyclones": _cyclones() if low_ok else [],
		"cyclones_live": low_ok,
	}
	return _obs


## True when `name`'s readback landed on the most recent drain, so its mirror is current.
func _live(name: String) -> bool:
	if _f == null or _f._gpu == null or _f._cell_count <= 0:
		return false
	var got = _f._gpu._cached.get(name, null)
	return got is PackedFloat32Array and got.size() == _f._cell_count


## Melt standing in an open cell is melt that reached the surface. state_derive.glsl's detect phase
## flags the cells; the list gives back WHERE, and the mirrors are read at those indices only.
func _eruptions() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or _f._temp.size() != _f._cell_count:
		return out
	for c in _f._gpu.list_indices("erupt"):
		out.append({"pos": grid.cell_world_pos(c), "melt": _f._queries.melt_at(c),
			"temp_c": _f._temp[c]})
	return out


## A cyclone is a closed low with a warm core and rotating air. Same shape: the device named the cells,
## and the readings that describe one are taken at those cells.
func _cyclones() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or _f._pressure.size() != _f._cell_count:
		return out
	for c in _f._gpu.list_indices("cyclone"):
		var ring: PackedInt32Array = _ring(c)
		if ring.is_empty():
			continue
		var p_sum: float = 0.0
		var t_sum: float = 0.0
		for n in ring:
			p_sum += _f._pressure[n]
			t_sum += _f._temp[n]
		var w: float = float(ring.size())
		out.append({
			"pos": grid.cell_world_pos(c),
			"pressure_pa": _f._pressure[c],
			"depth_pa": p_sum / w - _f._pressure[c],
			"core_temp_c": _f._temp[c],
			"warm_core_k": _f._temp[c] - t_sum / w,
			"vorticity_s": absf(LAFieldGeometry.curl(_f, c).dot(LAFieldGeometry.up(_f, c))),
		})
	return out


## The cell's own neighbours ACROSS the local vertical — the ring the derive closed the low on.
func _ring(c: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var up: Vector3 = LAFieldGeometry.up(_f, c)
	if up == Vector3.ZERO:
		return out
	var grid: LAVoxelGrid = _f._grid
	var here: Vector3 = grid.cell_world_pos(c)
	for f in range(grid.slot_begin(c, 0), grid.slot_begin(c, LAVoxelGrid.SLOTS)):
		var n: int = grid.neighbours[f]
		if n < 0:
			continue
		var d: Vector3 = grid.cell_world_pos(n) - here
		if d.length_squared() <= 0.0 or absf(d.normalized().dot(up)) >= 0.5:
			continue
		out.append(n)
	return out
