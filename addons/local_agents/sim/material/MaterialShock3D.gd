class_name LAMaterialShock3D
extends RefCounted

## The shock / seismic-sound channel of LAMaterialField3D.

# Amplitude above which a cell reads as actively shaking.
const SHOCK_ACTIVE: float = 0.05
# Fraction of a seed's magnitude given to each of the 6 neighbours.
const SEED_NEIGHBOUR_FRACTION: float = 0.5

var _f = null


func setup(field) -> void:
	_f = field


## Queue a sparse shock ADD of `magnitude` on the cell at `world_pos` and its neighbour ring.
func emit_shock(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0 or _f._shock.size() != _f._cell_count:
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	var cells: PackedInt32Array = PackedInt32Array([c])
	var deltas: PackedFloat32Array = PackedFloat32Array([magnitude])
	_f._shock[c] = _f._shock[c] + magnitude
	if _f._grid != null:
		var nbr: PackedInt32Array = _f._grid.neighbours
		var spill: float = magnitude * SEED_NEIGHBOUR_FRACTION
		for d in range(6):
			var nb: int = nbr[c * 6 + d]
			if nb >= 0 and _f._solid[nb] == 0:
				_f._shock[nb] = _f._shock[nb] + spill
				cells.append(nb)
				deltas.append(spill)
	if _f._inject != null:
		_f._inject.queue.add("shock", cells, deltas)


## Shock amplitude at a world point (0 outside the shell / where the wave has not reached).
func shock_at(world_pos: Vector3) -> float:
	if _f._shock.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	return _f._shock[c] if c >= 0 else 0.0


## Normalised world direction of increasing shock, from the 6-neighbour differences; zero where quiet.
func shock_gradient(world_pos: Vector3) -> Vector3:
	if _f._shock.size() != _f._cell_count:
		return Vector3.ZERO
	return LAFieldGeometry.gradient_at(_f, _f.world_to_cell(world_pos),
		func(i: int) -> float: return _f._shock[i])


## Open cells over SHOCK_ACTIVE, reduced on the device. null when the row was never reduced.
func shock_cell_count():
	return _f._queries.row_v("shock_cells", true) if _f != null and _f._queries != null else null
