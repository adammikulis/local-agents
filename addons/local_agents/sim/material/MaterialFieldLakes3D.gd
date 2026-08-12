class_name LAMaterialFieldLakes3D
extends RefCounted

## PRIORITY-FLOOD depression fill (Barnes et al.) over the open cells, in true 3D: a basin holds water up to
## the lowest height any escape route to the ocean has to climb over.
func seed(field) -> void:
	var grid: LAVoxelGrid = field._grid
	if grid == null or field._solid.size() != field._cell_count:
		return
	if field._terrain == null or not field._terrain.has_method("sea_radius"):
		return
	var sea_r: float = field._terrain.sea_radius()
	if sea_r <= 0.0:
		return
	var cc: int = field._cell_count
	var solid: PackedByteArray = field._solid
	var nbr: PackedInt32Array = grid.neighbours
	var cell: float = grid.cell_size

	# Height above the body centre, bucketed at cell resolution — the flood's priority key.
	var height: PackedFloat32Array = PackedFloat32Array()
	height.resize(cc)
	var bins: int = grid.max_span() + 2
	for c in cc:
		height[c] = LAFieldGeometry.radius_of(field, c)
	var buckets: Array = []
	for _b in bins:
		buckets.append(PackedInt32Array())

	var level: PackedFloat32Array = PackedFloat32Array()
	level.resize(cc)
	level.fill(INF)
	var done: PackedByteArray = PackedByteArray()
	done.resize(cc)

	# OUTLETS: an open cell at or below the sea surface drains to the ocean, and one on the box face drains
	# out of the world. Both start the flood at their own height.
	for c in cc:
		if solid[c] != 0:
			continue
		var edge: bool = false
		for d in LAVoxelGrid.SLOTS:
			if nbr[c * LAVoxelGrid.SLOTS + d] < 0:
				edge = true
				break
		if not edge and height[c] > sea_r:
			continue
		level[c] = maxf(height[c], sea_r)
		buckets[_bin_of(level[c], sea_r, cell, bins)].push_back(c)

	# Process low -> high: a cell finalises at the level it spills over, and raises its neighbours to at least
	# that. The first time a cell is popped it holds the lowest spill level any route out of it has.
	for b in bins:
		var qi: int = 0
		while qi < buckets[b].size():
			var c: int = buckets[b][qi]
			qi += 1
			if done[c] != 0:
				continue
			done[c] = 1
			var here: float = level[c]
			for d in LAVoxelGrid.SLOTS:
				var n: int = nbr[c * LAVoxelGrid.SLOTS + d]
				if n < 0 or done[n] != 0 or solid[n] != 0:
					continue
				var lv: float = maxf(height[n], here)
				if lv < level[n]:
					level[n] = lv
					buckets[_bin_of(lv, sea_r, cell, bins)].push_back(n)

	# Fill: a cell whose basin's spill level stands above the cell itself is under water.
	var lake_cells: int = 0
	for c in cc:
		if solid[c] != 0 or done[c] == 0 or height[c] <= sea_r:
			continue                                       # rock, unreached, or already static sea
		if level[c] <= height[c] or field._h2o[c] > 0.0:
			continue
		field._h2o[c] = 1.0
		lake_cells += 1
	if OS.has_environment("LA_WATER_DEBUG"):
		print("LAKES_SEEDED={cells:%d}" % lake_cells)


## Bucket index of a level, quantised at one cell. Levels below the sea land in bucket 0.
func _bin_of(lv: float, sea_r: float, cell: float, bins: int) -> int:
	return clampi(int((lv - sea_r) / maxf(cell, 1.0e-6)), 0, bins - 1)
