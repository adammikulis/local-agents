extends SceneTree

const Cap: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundaryCapture3D.gd")
const BODY_R: float = 2.4397e6
const DOMAIN_R: float = BODY_R + 1.0e5

var _fails: int = 0


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_slice_exterior: " + msg)
		_fails += 1


func _why(faces: Array, d: int) -> String:
	return String((faces[d] as Dictionary).get("unresolved", ""))


## Every global cell face `d` draws on, as grid coordinates.
func _coords(grid: LAVoxelGrid, faces: Array, d: int) -> Array:
	var out: Array = []
	for c in (faces[d] as Dictionary)["cells"] as PackedInt32Array:
		out.append(grid.coords(c))
	return out


func _box(spec: String) -> LAFieldSlice3D:
	var b: LAFieldSlice3D = LAFieldSlice3D.parse(spec)
	if b == null or b.error != "":
		printerr("check_slice_exterior: box spec \"%s\" did not parse" % spec)
		quit(2)
	return b


## A global grid whose cells dwarf the slice box: the vertical faces must still draw on different cells.
func _coarse() -> void:
	var box: LAFieldSlice3D = _box("0,%f,0,24,32,24,4000" % BODY_R)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	var gd: Vector3i = LAVoxelGrid.dims_for(DOMAIN_R, 2.0 * DOMAIN_R / 24.0)
	grid.build(gd.x, gd.y, gd.z, 2.0 * DOMAIN_R / 24.0, -0.5 * float(gd.x) * (2.0 * DOMAIN_R / 24.0) * Vector3.ONE)
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	for d in LAVoxelGrid.SLOTS:
		_expect(_why(faces, d) == "",
			"the default box's face %d resolves to no exterior on the default global grid (%s)."
			% [d, _why(faces, d)])
	if _fails > 0:
		return
	var lo_y: float = box.offset.y - 0.5 * float(box.dims.y) * box.cell_size
	var below: int = 0
	for v: Vector3i in _coords(grid, faces, LAVoxelGrid.S_NEG_Y):
		if grid.origin.y + float(v.y + 1) * grid.cell_size <= lo_y:
			below += 1
	_expect(below > 0, "the bottom face draws on no global cell that lies wholly under the box: "
		+ "its exterior is the box's own cell, which is also the top face's.")
	for d in LAVoxelGrid.SLOTS:
		for e in range(d + 1, LAVoxelGrid.SLOTS):
			_expect(String(faces[d]["sig"]) != String(faces[e]["sig"]),
				"faces %d and %d resolve to the same weighted cells and neither was named." % [d, e])


## A global grid finer than the slice box: every face's exterior lies wholly beyond that face.
func _fine() -> void:
	var box: LAFieldSlice3D = _box("0,10000,0,8,8,8,100")
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(40, 40, 40, 100.0, Vector3(-2000.0, 8000.0, -2000.0))
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	var half: Vector3 = 0.5 * Vector3(box.dims) * box.cell_size
	var lo: Vector3 = box.offset - half
	var hi: Vector3 = box.offset + half
	for d in LAVoxelGrid.SLOTS:
		if _why(faces, d) != "":
			_expect(false, "face %d of a box inside a finer global grid resolved nothing (%s)."
				% [d, _why(faces, d)])
			continue
		var a: int = d >> 1
		for v: Vector3i in _coords(grid, faces, d):
			var c_lo: float = grid.origin[a] + float(v[a]) * grid.cell_size
			var inside: bool = c_lo + grid.cell_size > lo[a] if (d & 1) == 0 else c_lo < hi[a]
			_expect(not inside, "face %d draws on a global cell that is not outside it." % d)


## A global grid of one cell: it cannot tell the faces apart, so every face is NAMED, not copied.
func _unresolvable() -> void:
	var box: LAFieldSlice3D = _box("0,%f,0,24,32,24,4000" % BODY_R)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(1, 1, 1, 4.0 * DOMAIN_R, Vector3(-2.0 * DOMAIN_R, -2.0 * DOMAIN_R, -2.0 * DOMAIN_R))
	var faces: Array = Cap.exterior_faces(grid, box.offset, box)
	for d in LAVoxelGrid.SLOTS:
		_expect(_why(faces, d) != "",
			"face %d silently took the one global cell the whole box sits in as its exterior." % d)
		_expect(not (faces[d] as Dictionary).has("cells"),
			"face %d carries cells as well as a name; an unresolved face supplies nothing." % d)


func _init() -> void:
	_coarse()
	_fine()
	_unresolvable()
	print('SLICE_EXTERIOR_GEOM={"failures":%d}' % _fails)
	quit(1 if _fails > 0 else 0)
