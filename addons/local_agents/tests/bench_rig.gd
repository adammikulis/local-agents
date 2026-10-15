extends RefCounted

## The device rig every analytic benchmark stands on: a box of cells, every buffer the real passes read,
## and one dispatch of a real pass over it. The benchmark itself owns the state it uploads and the
## closed-form answer it is judged against; this file owns nothing physical.

const TEMPORAL_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TemporalLevels.gd"

var rd: RenderingDevice = null
## The device's one driver: every pass the rig attaches submits through it.
var driver: LAFieldDriver = null
var grid: LAVoxelGrid = null
var bufs: Dictionary = {}
var cell_count: int = 0
var ghost_count: int = 0
var error: String = ""

var _owned: Array[RID] = []
var _passes: Array = []
var _bnd: LAFieldBoundary3D = null


## flux.glsl reads the redirect table and the ghost tail off the driver, so a boundary provider is
## handed an object shaped like one.
class StubGpu:
	extends RefCounted
	var _rd: RenderingDevice = null
	var _bufs: Dictionary = {}


func open() -> bool:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		error = "no RenderingDevice: this build has no compute device"
		return false
	driver = LAFieldDriver.on(rd)
	return true


func filled(n: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(maxi(n, 1))
	a.fill(v)
	return a


func _f32(vals: PackedFloat32Array) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _i32(vals: PackedInt32Array) -> RID:
	return _bytes(vals.to_byte_array())


func _bytes(b: PackedByteArray) -> RID:
	var r: RID = rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


## The box, plus whichever faces the benchmark declares. `modes` and `states` are LAFieldBoundary3D's,
## six entries each; an empty `modes` shuts every wall.
func build(nx: int, ny: int, nz: int, cell_m: float, modes: PackedInt32Array = PackedInt32Array(),
		states: Array = []) -> bool:
	grid = LAVoxelGrid.new()
	var origin: Vector3 = Vector3(-0.5 * float(nx), -0.5 * float(ny), -0.5 * float(nz)) * cell_m
	grid.build(nx, ny, nz, cell_m, origin)
	cell_count = grid.cell_count
	if not modes.is_empty():
		_bnd = LAFieldBoundary3D.new()
		if not _bnd.configure(grid, modes, states):
			error = "boundary configure failed: " + _bnd.error
			return false
		ghost_count = _bnd.ghost_count()
	_allocate()
	return true


## Every channel, every derived buffer and the geometry each kernel indexes, over interior plus ghost
## tail. The values are zero: a benchmark uploads the state it is testing and nothing is assumed.
func _allocate() -> void:
	var tc: int = cell_count + ghost_count
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(filled(tc, 0.0))
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(filled(tc, 0.0))
	bufs["gravity"] = _f32(filled(tc * 3, 0.0))
	bufs["pos"] = _bytes(grid.centres.to_byte_array())
	bufs["nbr"] = _i32(grid.neighbours)
	bufs["slot_off"] = _i32(grid.slot_off)
	bufs["face_partner"] = _i32(grid.partners)
	bufs["cell_edge"] = _f32(grid.cell_edges())
	bufs["ground_d"] = _f32(filled(tc, 0.0))
	var redirect: PackedInt32Array = PackedInt32Array()
	redirect.resize(grid.neighbours.size())
	redirect.fill(-1)
	bufs["ghost"] = _i32(redirect)


## One buffer declaration, allocated the way the driver allocates it.
func _allocate_spec(name: String, spec: Variant) -> void:
	if bufs.has(name):
		return
	var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
	if spec is Dictionary and bool(spec.get("ghosts", false)):
		n = (n + ghost_count) * int(spec.get("stride", 1))
	if spec is Dictionary and bool(spec.get("faces", false)):
		n = grid.neighbours.size()
	var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
	var zeros: PackedByteArray = filled(maxi(n, 1), 0.0).to_byte_array()
	var r: RID = rd.storage_buffer_create(zeros.size(), zeros,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
	_owned.append(r)
	bufs[name] = r


## A pass's declared buffers, without running it. A rig that dispatches only one pass still binds the
## buffers another pass owns, so the declarations come first and the setups after.
func declare(script_path: String) -> bool:
	var scr: GDScript = load(script_path)
	if scr == null:
		error = script_path + " did not load"
		return false
	var p: RefCounted = scr.new()
	p.ghost_count = ghost_count
	var want: Dictionary = p._buffers(cell_count)
	for key in want:
		_allocate_spec(String(key), want[key])
	return true


## One pass, set up against the buffers already declared plus its own.
func attach(script_path: String) -> RefCounted:
	var scr: GDScript = load(script_path)
	if scr == null:
		error = script_path + " did not load"
		return null
	var p: RefCounted = scr.new()
	p.ghost_count = ghost_count
	p.face_count = grid.neighbours.size()
	p.grid_dims = Vector3i(grid.nx, grid.ny, grid.nz)
	p.grid_origin = grid.origin
	p.grid_cell_size = grid.cell_size
	var want: Dictionary = p._buffers(cell_count)
	for key in want:
		_allocate_spec(String(key), want[key])
	p.setup(rd, driver, bufs, cell_count)
	_passes.append(p)
	return p


## The temporal-level buffers a transport rig gets from the derive when the derive is not in the world.
func add_levels(group_count: int) -> void:
	var levels: GDScript = load(TEMPORAL_PATH)
	var want: Dictionary = levels.buffers(cell_count + ghost_count, group_count)
	for key in want:
		_allocate_spec(String(key), want[key])


## The redirect table and the ghost tail the boundary provider fills, once the passes have bound.
func attach_boundary() -> bool:
	if _bnd == null:
		return true
	var stub: StubGpu = StubGpu.new()
	stub._rd = rd
	stub._bufs = bufs
	_bnd.attach(stub)
	if _bnd.error != "":
		error = "boundary attach failed: " + _bnd.error
		return false
	return true


func upload(name: String, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	rd.buffer_update(bufs[name], 0, b.size(), b)


func fill(name: String, v: float, n: int = -1) -> void:
	upload(name, filled(n if n > 0 else cell_count + ghost_count, v))


func read(name: String) -> PackedFloat32Array:
	return rd.buffer_get_data(bufs[name]).to_float32_array()


func clear_prefix(prefix: String) -> void:
	for key in bufs:
		if String(key).begins_with(prefix):
			rd.buffer_clear(bufs[key], 0, (cell_count + ghost_count) * 4)


## One dispatch of every attached pass, in the order they were attached, submitted and synced.
func step(ctx: Dictionary) -> void:
	var groups: int = int(ceil(float(cell_count) / 64.0))
	driver.open()
	for p in _passes:
		p.dispatch(rd, ctx, cell_count, groups)
	driver.close()


## One dispatch of a single pass, when the rig holds more than one and only this one is asked for.
func step_only(p: RefCounted, ctx: Dictionary) -> void:
	driver.open()
	p.dispatch(rd, ctx, cell_count, int(ceil(float(cell_count) / 64.0)))
	driver.close()


## Transport reads the peak temporal level per group in a submit of its own before the step records.
func pre_step(p: RefCounted, ctx: Dictionary) -> void:
	p.pre_step(rd, ctx, cell_count, int(ceil(float(cell_count) / 64.0)))


func close() -> void:
	for p in _passes:
		p.dispose(rd)
	_passes.clear()
	for r in _owned:
		if r.is_valid():
			rd.free_rid(r)
	_owned.clear()
	driver = null
	rd.free()
	rd = null
