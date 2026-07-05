class_name LAMaterialGravity
extends RefCounted

## Granular gravity for the MaterialField, split out as its own concern. When ground is DISTURBED
## (a meteor blast, an earthquake, a saturated slope), any column that overhangs a lower neighbour by
## more than the angle of repose sheds material downhill under gravity until the local slope is
## stable, editing the terrain SDF (carve high, fill low). This is the ONLY landslide mechanism —
## pure material physics, no scripted event. Operates on the shared grid via a back reference (_f).
## (Explicit types only — project rule: no ':=' inferred typing.)

const REPOSE_TAN: float = 0.7             # max stable rise/run for loose soil (~35°)
const REPOSE_PASSES: int = 6              # relaxation iterations over the disturbed patch
const REPOSE_MIN_MOVE: float = 0.4        # height change below this makes no SDF edit
const REPOSE_MAX_EDITS: int = 140         # cap SDF edits per disturbance (keeps the hitch bounded)

var _f = null                              # LAMaterialField (shared grid back-reference)
var _slumps: int = 0                       # diagnostic: SDF columns moved by slumping


func setup(field) -> void:
	_f = field


func slump_count() -> int:
	return _slumps


## Shake the ground over a region: any column that overhangs a lower neighbour beyond the angle of
## repose sheds material downhill under gravity until the local slope is stable, editing the terrain
## SDF (carve high, fill low). Flat ground does nothing. `strength` (~0..3, e.g. meteor size) scales
## how much of each overhang gives way.
func disturb_terrain(world_pos: Vector3, radius: float, strength: float) -> void:
	var terrain = _f._terrain
	if terrain == null or not terrain.has_method("surface_height"):
		return
	if not terrain.has_method("carve_sphere") or not terrain.has_method("fill_sphere"):
		return
	var s: float = clampf(strength, 0.1, 3.0)
	var cells: int = int(ceil(radius / _f._cell_size))
	var ci: int = int(round((world_pos.x + _f._half_extent) / _f._cell_size))
	var cj: int = int(round((world_pos.z + _f._half_extent) / _f._cell_size))
	var r2: float = radius * radius

	# Collect the disturbed columns and their CURRENT surface heights (sampled fresh from the SDF).
	var region: Array = []                       # idx list
	var h0: Dictionary = {}                       # idx -> original height
	var h: Dictionary = {}                        # idx -> working height
	for dj in range(-cells, cells + 1):
		var j: int = cj + dj
		if j < 0 or j >= _f._dim:
			continue
		for di in range(-cells, cells + 1):
			var i: int = ci + di
			if i < 0 or i >= _f._dim:
				continue
			var cx: float = _f._cell_x(i)
			var cz: float = _f._cell_z(j)
			var dx: float = cx - world_pos.x
			var dz: float = cz - world_pos.z
			if dx * dx + dz * dz > r2:
				continue
			var gy = terrain.surface_height(cx, cz)
			if typeof(gy) != TYPE_FLOAT and typeof(gy) != TYPE_INT:
				continue
			var gyf: float = float(gy)
			if is_nan(gyf) or is_inf(gyf):
				continue
			var idx: int = j * _f._dim + i
			region.append(idx)
			h0[idx] = gyf
			h[idx] = gyf

	if region.size() < 2:
		return

	# Relax toward the angle of repose: repeatedly push a column's overhang down to its lowest
	# in-region neighbour. Order-tolerant enough over several passes (gravity settles a pile).
	var max_step: float = REPOSE_TAN * _f._cell_size
	var move_frac: float = clampf(0.5 * s, 0.25, 0.9)
	for pass_i in range(REPOSE_PASSES):
		for idx in region:
			var hi: float = h[idx]
			var i2: int = idx % _f._dim
			var j2: int = idx / _f._dim
			var low_idx: int = -1
			var low_h: float = hi
			var neighbours: Array = [idx - 1 if i2 > 0 else -1, idx + 1 if i2 < _f._dim - 1 else -1,
				idx - _f._dim if j2 > 0 else -1, idx + _f._dim if j2 < _f._dim - 1 else -1]
			for nb in neighbours:
				if nb >= 0 and h.has(nb) and float(h[nb]) < low_h:
					low_h = float(h[nb])
					low_idx = nb
			if low_idx < 0:
				continue
			var excess: float = (hi - low_h) - max_step
			if excess > 0.0:
				var m: float = excess * 0.5 * move_frac
				h[idx] = hi - m
				h[low_idx] = float(h[low_idx]) + m

	# Apply the net height change to the terrain SDF (carve where it dropped, fill where it rose).
	var edits: int = 0
	for idx in region:
		if edits >= REPOSE_MAX_EDITS:
			break
		var dh: float = float(h[idx]) - float(h0[idx])
		if absf(dh) < REPOSE_MIN_MOVE:
			continue
		var i3: int = idx % _f._dim
		var j3: int = idx / _f._dim
		var cx2: float = _f._cell_x(i3)
		var cz2: float = _f._cell_z(j3)
		var sphere_r: float = clampf(absf(dh) * 0.9, 0.6, _f._cell_size)
		if dh < 0.0:
			terrain.carve_sphere(Vector3(cx2, float(h0[idx]), cz2), sphere_r)
		else:
			terrain.fill_sphere(Vector3(cx2, float(h[idx]), cz2), sphere_r)
		if _f._sampled[idx] != 0:
			_f._terrain_h[idx] = float(h[idx])          # keep cached altitude consistent (lapse/temp)
		edits += 1
		_slumps += 1
