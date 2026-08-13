class_name LAMaterialFieldCellVolume3D
extends RefCounted

## Volume of every cell, m^3. A channel value is a FILL FRACTION of the cell that holds it, so the matter in
## a channel is channel*volume and a bare sum over cells is not proportional to matter.
static var _cache: Dictionary = {}

## The grid is the ONE owner of cell volume; this caches its table so a per-frame gauge does not rebuild it.
static func of(field) -> PackedFloat32Array:
	if field == null or field._grid == null:
		return PackedFloat32Array()
	var cc: int = int(field._cell_count)
	if cc <= 0:
		return PackedFloat32Array()
	# Keyed on the GRID too: a rebuild at the same cell count is a different table.
	var key: String = "%d:%d" % [field.get_instance_id(), field._grid.get_instance_id()]
	var hit = _cache.get(key)
	if hit is PackedFloat32Array and hit.size() == cc:
		return hit
	var out: PackedFloat32Array = field._grid.cell_volumes()
	if out.size() != cc:
		return PackedFloat32Array()
	_cache[key] = out
	return out


## Volume of cell `c`, m^3. NEGATIVE when the grid published no table: a volume is never negative, so the
## caller must read that as "unmeasured" and refuse whatever it was sizing.
static func m3(field, c: int) -> float:
	var vol: PackedFloat32Array = of(field)
	if c < 0 or c >= vol.size():
		return -1.0
	return vol[c]


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
