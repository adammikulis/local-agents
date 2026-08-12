class_name LAMaterialFieldCellVolume3D
extends RefCounted

## Volume of every cell, model units^3. A channel value is a FILL FRACTION of the cell that holds it, so the
## matter in a channel is channel*volume and a bare sum over cells is not proportional to matter. On the
## cubed sphere cells differ radially (volume goes as r^2 dr) and laterally (a gnomonic cell shrinks toward a
## face corner by up to 4.7x at res 24). The box field is uniform, so every entry is side^3 there.
static func of(field) -> PackedFloat32Array:
	if field == null:
		return PackedFloat32Array()
	var cc: int = int(field._cell_count)
	if cc <= 0:
		return PackedFloat32Array()
	var grid: RefCounted = field.sphere_grid()
	if grid != null:
		return grid.cell_volumes()
	var side: float = float(field.cell_size())
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(cc)
	out.fill(side * side * side)
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
