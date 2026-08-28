extends SceneTree

## A 2:1 pair's volumes differ by eight, four fine faces tile the coarse face they meet, and every
## face names the face that points back.

func _init() -> void:
	var fail: int = 0
	var g = LAVoxelGrid.new()
	g.build_centred(Vector3.ZERO, 660.0, 16.0)
	var uni: Dictionary = g.validate()
	if not bool(uni["ok"]): fail += 1
	if int(uni["non_reciprocal"]) != 0: fail += 1
	if absf(float(uni["volume_ratio"]) - 1.0) > 1.0e-9: fail += 1
	for d in 6:
		if LAVoxelGrid.opposite_slot(LAVoxelGrid.opposite_slot(d)) != d: fail += 1
		if LAVoxelGrid.opposite_slot(d) == d: fail += 1
	var c: int = g.leaf_at(3, 4, 5)
	for d in 6:
		var f: int = g.slot_begin(c, d)
		var m: int = g.neighbours[f]
		if m < 0: fail += 1
		elif g.neighbours[g.partners[f]] != c: fail += 1

	var r = LAVoxelGrid.new()
	r.build(5, 5, 5, 2.0, Vector3.ZERO)
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(125)
	mask[r.index(2, 2, 2)] = 1
	r.refine(mask)
	var v: Dictionary = r.validate()
	if not bool(v["ok"]): fail += 1
	if int(v["non_reciprocal"]) != 0: fail += 1
	if int(v["ratio_violations"]) != 0: fail += 1
	if int(v["area_violations"]) != 0: fail += 1
	if r.cell_count != 132: fail += 1
	if absf(float(v["volume_ratio"]) - 8.0) > 1.0e-6: fail += 1
	var coarse: int = r.leaf_at(1, 2, 2)
	if r.slot_end(coarse, LAVoxelGrid.S_POS_X) - r.slot_begin(coarse, LAVoxelGrid.S_POS_X) != 4:
		fail += 1
	var fine: int = r.neighbours[r.slot_begin(coarse, LAVoxelGrid.S_POS_X)]
	if r.level_of(fine) != 1: fail += 1
	if absf(r.cell_volume(coarse) / r.cell_volume(fine) - 8.0) > 1.0e-6: fail += 1
	if r.slot_end(fine, LAVoxelGrid.S_NEG_X) - r.slot_begin(fine, LAVoxelGrid.S_NEG_X) != 1: fail += 1
	if r.neighbours[r.slot_begin(fine, LAVoxelGrid.S_NEG_X)] != coarse: fail += 1
	for o in 8:
		var child: int = r.leaf_at(2, 2, 2) + o
		if r.cell_at(r.cell_world_pos(child)) != child: fail += 1

	var h = LAVoxelGrid.new()
	h.build(5, 7, 3, 2.0, Vector3(-4.0, 6.0, 0.0))
	if h.cell_count != 105: fail += 1
	for i in h.cell_count:
		var p: Vector3i = h.coords(i)
		if h.leaf_at(p.x, p.y, p.z) != i: fail += 1
		if h.cell_at(h.cell_world_pos(i)) != i: fail += 1
	if h.neighbours[h.slot_begin(h.leaf_at(0, 0, 0), LAVoxelGrid.S_NEG_X)] != -1: fail += 1
	if h.neighbours[h.slot_begin(h.leaf_at(4, 6, 2), LAVoxelGrid.S_POS_Z)] != -1: fail += 1
	print('VOXEL_GRID={"cells":%d,"non_reciprocal":%d,"volume_ratio":%.6f,"ratio_violations":%d,"area_violations":%d,"failures":%d}'
		% [int(v["cells"]), int(v["non_reciprocal"]), float(v["volume_ratio"]),
			int(v["ratio_violations"]), int(v["area_violations"]), fail])
	quit(1 if fail > 0 else 0)
