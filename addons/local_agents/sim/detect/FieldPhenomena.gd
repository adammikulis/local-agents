class_name LAFieldPhenomena
extends RefCounted

## Reads the field's own mirrors and names what is already in them.

## Lava mass per cell the readback can resolve above zero. One declaration, shared with the molten gauge.
const MELT_PRESENT: float = LAMaterialFieldQueries3D.MOLTEN_MIN

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
	var melt_ok: bool = _live("lava")
	var low_ok: bool = _live("pressure") and vel_ok and _f._temp.size() == _f._cell_count
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


## Melt standing in an open cell is melt that reached the surface.
func _eruptions() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or _f._lava.size() != _f._cell_count or _f._solid.size() != _f._cell_count:
		return out
	for c in _f._cell_count:
		if _f._solid[c] != 0 or _f._lava[c] < MELT_PRESENT:
			continue
		var peak: bool = true
		var base: int = c * LAVoxelGrid.SLOTS
		for d in LAVoxelGrid.SLOTS:
			var n: int = grid.neighbours[base + d]
			if n >= 0 and _f._lava[n] > _f._lava[c]:
				peak = false
				break
		if peak:
			out.append({"pos": grid.cell_world_pos(c), "melt": _f._lava[c], "temp_c": _f._temp[c] if _f._temp.size() == _f._cell_count else 0.0})
	return out


## A cyclone is a closed low with a warm core and rotating air.
func _cyclones() -> Array:
	var out: Array = []
	var grid: LAVoxelGrid = _f._grid
	if grid == null or _f._pressure.size() != _f._cell_count:
		return out
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		var lo: int = LAFieldGeometry.below(_f, c)
		if lo < 0 or _f._solid[lo] == 0:
			continue                                   # not the ground layer of an air column
		var ring: PackedInt32Array = _horizontal(c)
		if ring.size() < 4:
			continue
		var p_sum: float = 0.0
		var t_sum: float = 0.0
		var z_sum: float = 0.0
		var closed: bool = true
		for n in ring:
			if _f._pressure[n] <= _f._pressure[c]:
				closed = false
				break
			p_sum += _f._pressure[n]
			t_sum += _f._temp[n]
			z_sum += absf(_spin(n))
		if not closed:
			continue
		var w: float = float(ring.size())
		if _f._temp[c] <= t_sum / w:
			continue                                   # no warm core
		var spin: float = absf(_spin(c))
		if spin <= z_sum / w:
			continue                                   # the core does not out-spin its surroundings
		out.append({
			"pos": grid.cell_world_pos(c),
			"pressure_pa": _f._pressure[c],
			"depth_pa": p_sum / w - _f._pressure[c],
			"core_temp_c": _f._temp[c],
			"warm_core_k": _f._temp[c] - t_sum / w,
			"vorticity_s": spin,
		})
	return out


## Spin about the local vertical at `c`, 1/s.
func _spin(c: int) -> float:
	return LAFieldGeometry.curl(_f, c).dot(LAFieldGeometry.up(_f, c))


## Four cells one cell out in the TANGENT PLANE at `c`.
func _horizontal(c: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var up: Vector3 = LAFieldGeometry.up(_f, c)
	if up == Vector3.ZERO:
		return out
	var t1: Vector3 = up.cross(Vector3.RIGHT)
	if t1.length_squared() < 1.0e-6:
		t1 = up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	var here: Vector3 = _f._grid.cell_world_pos(c)
	var step: float = _f._grid.cell_size
	for k in 4:
		var a: float = TAU * float(k) / 4.0
		var n: int = _f.world_to_cell(here + (t1 * cos(a) + t2 * sin(a)) * step)
		if n < 0 or n == c or _f._solid[n] != 0:
			return PackedInt32Array()                  # an incomplete ring cannot say a low is closed
		out.append(n)
	return out
