extends SceneTree

func _init() -> void:
	var fail: int = 0
	var g = LAVoxelGrid.new()
	g.build_centred(Vector3.ZERO, 660.0, 16.0)
	var v: Dictionary = g.validate()
	if not bool(v["ok"]): fail += 1
	if int(v["non_reciprocal"]) != 0: fail += 1
	if absf(float(v["volume_ratio"]) - 1.0) > 1.0e-9: fail += 1
	# d ^ 1 is an involution on every slot, and never maps a slot to itself.
	for d in 6:
		if LAVoxelGrid.opposite_slot(LAVoxelGrid.opposite_slot(d)) != d: fail += 1
		if LAVoxelGrid.opposite_slot(d) == d: fail += 1
	# A neighbour step and its reverse return to the start, on an interior cell.
	var c: int = g.index(3, 4, 5)
	for d in 6:
		var m: int = g.neighbours[c * 6 + d]
		if m < 0: fail += 1
		elif g.neighbours[m * 6 + LAVoxelGrid.opposite_slot(d)] != c: fail += 1
	# A small asymmetric grid: index/coords round-trip over every cell.
	var h = LAVoxelGrid.new()
	h.build(5, 7, 3, 2.0, Vector3(-4.0, 6.0, 0.0))
	if h.cell_count != 105: fail += 1
	for i in h.cell_count:
		var p: Vector3i = h.coords(i)
		if h.index(p.x, p.y, p.z) != i: fail += 1
		if h.cell_at(h.cell_world_pos(i)) != i: fail += 1
	# Boundary faces are -1, never a wrapped neighbour.
	if h.neighbours[h.index(0, 0, 0) * 6 + LAVoxelGrid.S_NEG_X] != -1: fail += 1
	if h.neighbours[h.index(4, 6, 2) * 6 + LAVoxelGrid.S_POS_Z] != -1: fail += 1
	print('VOXEL_GRID={"cells":%d,"non_reciprocal":%d,"volume_ratio":%.6f,"failures":%d}'
		% [int(v["cells"]), int(v["non_reciprocal"]), float(v["volume_ratio"]), fail])
	quit(1 if fail > 0 else 0)
