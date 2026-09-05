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
	var vel_ok: bool = _f != null and _f._mirrors != null and _f._mirrors.has("vel_x")
	var melt_ok: bool = _live("silicate") and LAProcessSet.has_record("pass", "FluxPass.gd")
	var low_ok: bool = _live("pressure") and vel_ok and _f._mirrors.has("temp") \
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
	return _f != null and _f._mirrors != null and _f._mirrors.live(name)


## Melt standing in an open cell is melt that reached the surface. state_derive.glsl's detect phase
## flags the cells; the list gives back WHERE, and the mirrors are read at those indices only.
func _eruptions() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or not _f._mirrors.has("temp"):
		return out
	for c in _f._gpu.list_indices("erupt"):
		out.append({"pos": grid.cell_world_pos(c), "melt": _f._queries.melt_at(c),
			"temp_c": _f._mirrors.at("temp", c)})
	return out


## A cyclone is a closed low with a warm core and rotating air. Same shape: the device named the cells,
## and the readings that describe one are taken at those cells.
func _cyclones() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or not _f._mirrors.has("pressure"):
		return out
	var m: LAFieldMirrors = _f._mirrors
	for c in _f._gpu.list_indices("cyclone"):
		var ring: PackedInt32Array = _ring(c)
		if ring.is_empty():
			continue
		var p_sum: float = 0.0
		var t_sum: float = 0.0
		for n in ring:
			p_sum += m.at("pressure", n)
			t_sum += m.at("temp", n)
		var w: float = float(ring.size())
		out.append({
			"pos": grid.cell_world_pos(c),
			"pressure_pa": m.at("pressure", c),
			"depth_pa": p_sum / w - m.at("pressure", c),
			"core_temp_c": m.at("temp", c),
			"warm_core_k": m.at("temp", c) - t_sum / w,
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
