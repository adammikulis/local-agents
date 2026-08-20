@tool
extends RefCounted

## LAFieldBoundary3D: WRAP entries are the exact opposite-face partners, CONSTANT faces get ghost rows
## wired back to their interior partner, and a supplied-state face with no state is an error.

const BoundaryScript: GDScript = preload("res://addons/local_agents/sim/material/FieldBoundary3D.gd")
const GridScript: GDScript = preload("res://addons/local_agents/sim/voxel/VoxelGrid.gd")

const NX: int = 4
const NY: int = 3
const NZ: int = 5


func run_test(_tree: SceneTree) -> bool:
	var ok: bool = true
	ok = _torus() and ok
	ok = _mutation_goes_red() and ok
	ok = _constant_ghosts() and ok
	ok = _constant_without_state_fails() and ok
	if ok:
		print("Boundary wrap test passed")
	return ok


func _grid() -> RefCounted:
	var grid: RefCounted = GridScript.new()
	grid.build(NX, NY, NZ, 1.0, Vector3.ZERO)
	return grid


func _all(mode: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(6)
	out.fill(mode)
	return out


func _torus() -> bool:
	var b: RefCounted = BoundaryScript.new()
	if not b.configure(_grid(), _all(BoundaryScript.WRAP), [null, null, null, null, null, null]):
		return _fault("all-WRAP configure failed: " + String(b.error))
	var chk: Dictionary = b.wrap_check()
	var want: int = 2 * (NY * NZ + NX * NZ + NX * NY)
	if not bool(chk["ok"]) or int(chk["checked"]) != want:
		return _fault("wrap_check %s, wanted %d faces checked" % [str(chk), want])
	return true


func _mutation_goes_red() -> bool:
	var b: RefCounted = BoundaryScript.new()
	b.configure(_grid(), _all(BoundaryScript.WRAP), [null, null, null, null, null, null])
	var g: PackedInt32Array = b._ghost
	for i in g.size():
		if g[i] >= 0:
			g[i] = (g[i] + 1) % (NX * NY * NZ)
			break
	b._ghost = g
	if bool(b.wrap_check()["ok"]):
		return _fault("wrap_check stayed green over a corrupted partner entry")
	return true


func _constant_ghosts() -> bool:
	var grid: RefCounted = _grid()
	var cc: int = NX * NY * NZ
	var modes: PackedInt32Array = _all(BoundaryScript.SHUT)
	modes[0] = BoundaryScript.CONSTANT
	var states: Array = [_state(), null, null, null, null, null]
	var b: RefCounted = BoundaryScript.new()
	if not b.configure(grid, modes, states):
		return _fault("CONSTANT configure failed: " + String(b.error))
	if int(grid.ghost_rows) != NY * NZ:
		return _fault("expected %d ghost rows, grid has %d" % [NY * NZ, int(grid.ghost_rows)])
	for c in b._cells_on_face(0):
		var r: int = b.redirect(int(c), 0)
		if r < cc or r >= cc + NY * NZ:
			return _fault("face cell %d redirects to %d, not a ghost tail cell" % [int(c), r])
		if int(grid.neighbours[r * 6 + 1]) != int(c):
			return _fault("ghost %d does not partner cell %d in its opposite slot" % [r, int(c)])
	return true


func _constant_without_state_fails() -> bool:
	var modes: PackedInt32Array = _all(BoundaryScript.SHUT)
	modes[3] = BoundaryScript.CONSTANT
	var b: RefCounted = BoundaryScript.new()
	if b.configure(_grid(), modes, [null, null, null, null, null, null]):
		return _fault("a CONSTANT face with no supplied state configured anyway")
	if String(b.error) == "":
		return _fault("the refusal named no error")
	return true


func _state() -> Dictionary:
	return {"temp_c": 15.0, "pressure_pa": 101325.0, "gravity": Vector3(0, -9.8, 0),
		"velocity": Vector3.ZERO, "amounts": {"n2": 0.78, "o2": 0.21}}


func _fault(msg: String) -> bool:
	push_error("test_boundary_wrap: " + msg)
	return false
