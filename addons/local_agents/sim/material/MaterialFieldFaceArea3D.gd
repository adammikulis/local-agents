class_name LAMaterialFieldFaceArea3D
extends RefCounted

## Area of every cell face, m^2, flat `cell*6 + slot`. The amount of anything that crosses a wall between two
## cells is proportional to that wall's area, and on a cubed sphere it is not one number: a cell's outward
## radial face exceeds its inward one by (r_out/r_in)^2, and a lateral face near a face corner is several
## times smaller than one near the centre.
## `LASphereGrid` is geometry and answers in model units; this is the physics accessor and answers in metres,
## because every consumer multiplies it by a per-m^2 quantity (W/m^2, kg/m^2/s), exactly as
## `LAMaterialFieldCellVolume3D` does for volume.
## Never scale LASphereGrid's own table in place — it is a live member the GPU reads.
static var _cache: Dictionary = {}

static func of(field) -> PackedFloat32Array:
	if field == null:
		return PackedFloat32Array()
	var cc: int = int(field._cell_count)
	if cc <= 0:
		return PackedFloat32Array()
	var grid: RefCounted = field.sphere_grid()
	var key: String = "%d:%d" % [field.get_instance_id(), grid.get_instance_id() if grid != null else 0]
	var hit = _cache.get(key)
	if hit is PackedFloat32Array and hit.size() == cc * 6:
		return hit
	var m2: float = LAPhysical.METRES_PER_MODEL_UNIT * LAPhysical.METRES_PER_MODEL_UNIT
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cc * 6)
	if grid != null:
		var model: PackedFloat32Array = grid.face_areas()
		if model.size() != cc * 6:
			return PackedFloat32Array()
		for i in cc * 6:
			out[i] = model[i] * m2
	else:
		var side: float = float(field.cell_size())
		out.fill(side * side * m2)
	_cache[key] = out
	return out


## Area of the face in neighbour slot `d` of cell `c`, m^2.
static func at(areas: PackedFloat32Array, c: int, d: int) -> float:
	var i: int = c * 6 + d
	return areas[i] if i >= 0 and i < areas.size() else 0.0
