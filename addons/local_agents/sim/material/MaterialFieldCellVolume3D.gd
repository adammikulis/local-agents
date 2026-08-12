class_name LAMaterialFieldCellVolume3D
extends RefCounted

## Volume of every cell, m^3. A channel value is a FILL FRACTION of the cell that holds it, so the matter in
## a channel is channel*volume and a bare sum over cells is not proportional to matter. On the cubed sphere
static var _cache: Dictionary = {}

static func of(field) -> PackedFloat32Array:
	if field == null:
		return PackedFloat32Array()
	var cc: int = int(field._cell_count)
	if cc <= 0:
		return PackedFloat32Array()
	var grid: RefCounted = field.sphere_grid()
	# Keyed on the GRID too: a rebuild at the same cell count is a different table.
	var key: String = "%d:%d" % [field.get_instance_id(), grid.get_instance_id() if grid != null else 0]
	var hit = _cache.get(key)
	if hit is PackedFloat32Array and hit.size() == cc:
		return hit
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cc)
	if grid != null:
		var model: PackedFloat32Array = grid.cell_volumes()
		if model.size() != cc:
			return PackedFloat32Array()
		for i in cc:
			out[i] = model[i]
	else:
		var side: float = float(field.cell_size())
		out.fill(side * side * side)
	_cache[key] = out
	return out


## Sum of `arr` weighted by each cell's own volume — the matter the channel holds. `mask_open` restricts it
## to cells where `solid` is 0.
static func weighted(arr: PackedFloat32Array, vol: PackedFloat32Array, solid: PackedByteArray,
		mask_open: bool) -> float:
	var n: int = arr.size()
	if vol.size() != n:
		return 0.0
	var t: float = 0.0
	if mask_open:
		if solid.size() != n:
			return 0.0
		for c in n:
			if solid[c] == 0:
				t += arr[c] * vol[c]
	else:
		for c in n:
			t += arr[c] * vol[c]
	return t
