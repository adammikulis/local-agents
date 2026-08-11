class_name LAKernelConservation
extends Node

## Dispatches ONE kernel on a small real cubed-sphere grid and asserts it conserves. The unit of feedback
## for a kernel bug was a 200-frame world, so every one this session was found by bisecting full runs.
##
## Needs a real RenderingDevice, so it runs windowed through scripts/run_sim_offscreen.sh.

const GRAVITY_FLOW: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"
const TRACER: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"
const EROSION: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

const RES_PER_FACE: int = 4
const DEPTH: int = 6
const TOLERANCE: float = 1e-4      # relative; float32 over a few thousand cells

var _rd: RenderingDevice = null
var _grid: RefCounted = null
var _cc: int = 0
var _failures: Array = []
var _checks: int = 0


func _ready() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		print("KERNEL_CONSERVATION={\"ok\":false,\"reason\":\"no compute device\"}")
		LAAppExit.request(self, 2)
		return
	_grid = LASphereGrid.new()
	_grid.build(RES_PER_FACE, DEPTH, 100.0, 8.0, Vector3.ZERO)
	_cc = _grid.neighbours.size() / 6

	var v: Dictionary = _grid.validate()
	_expect(bool(v.get("ok", false)), "grid.validate", 1.0, 1.0 if bool(v.get("ok", false)) else 0.0)

	_check_two_pass(GRAVITY_FLOW, "gravity_flow", _pc_gravity())
	_check_two_pass(EROSION, "erosion_transport", _pc_erosion())
	_check_tracer(0.0, false, "still")
	_check_tracer(3.0, false, "wind")
	# The real field is about a quarter solid. Solid cells are where the gathers skip and where the deposit
	# branch lives, so an all-open grid never exercises the paths a planet actually runs.
	_check_tracer(0.0, true, "still_solid")
	_check_tracer(3.0, true, "wind_solid")
	# The live field runs at 160 m/s, which is what the operator actually sees.
	_check_tracer(160.0, true, "gale_solid")

	print("KERNEL_CONSERVATION=", JSON.stringify({
		"ok": _failures.is_empty(), "checks": _checks, "failures": _failures}))
	_rd.free()
	LAAppExit.request(self, 0 if _failures.is_empty() else 1)


## A cell's mass, seeded so there is something to move: a spike in one column, flat elsewhere.
func _seed_mass() -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(_cc)
	a.fill(0.25)
	for i in range(0, _cc, 37):
		a[i] = 0.9
	return a


func _zeros(n: int) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a


func _buf(arr: PackedFloat32Array) -> RID:
	var b: PackedByteArray = arr.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)


func _read(rid: RID) -> PackedFloat32Array:
	return _rd.buffer_get_data(rid).to_float32_array()


func _sum(a: PackedFloat32Array, solid: PackedFloat32Array) -> float:
	var t: float = 0.0
	for i in a.size():
		t += a[i]
	return t


func _expect(ok: bool, what: String, want: float, got: float) -> void:
	_checks += 1
	if not ok:
		_failures.append({"check": what, "want": want, "got": got})


## The two-pass send/gather shape: pass 0 writes outflow, pass 1 gathers. Total mass over ALL cells must be
## unchanged — that is the whole contract, and it is the one that broke in four kernels.
func _check_two_pass(path: String, label: String, pc_base: PackedByteArray) -> void:
	var sf = load(path)
	if sf == null:
		_failures.append({"check": label, "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var mass: PackedFloat32Array = _seed_mass()
	var solid: PackedFloat32Array = _zeros(_cc)
	var before: float = _sum(mass, solid)

	var b_in: RID = _buf(mass)
	var b_out: RID = _buf(_zeros(_cc))
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_solid: RID = _buf(solid)
	# For erosion this slot is WATER: without flow there is nothing for the load to ride.
	var b_temp: RID = _buf(_seed_mass() if label == "erosion_transport" else _zeros(_cc))
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_larc: RID = _buf(_grid.link_arc)

	var groups: int = int(ceil(float(_cc) / 64.0))
	for pass_id in 2:
		var uset: RID = _uset(shader, _binds(label, b_in, b_out, b_send, b_solid, b_temp, b_nbr, b_larc))
		var pc: PackedByteArray = pc_base.duplicate()
		pc.encode_u32(4, pass_id)
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()

	var after: float = _sum(_read(b_out), solid)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, label + ".mass_conserved", before, after)


## The tracer operator is a SINGLE pass: out = in - own_out + gain. Same contract, one dispatch.
func _check_tracer(wind_m_s: float, with_solid: bool, tag: String) -> void:
	var sf = load(TRACER)
	if sf == null:
		_failures.append({"check": "tracer_transport", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var mass: PackedFloat32Array = _seed_mass()
	var solid: PackedFloat32Array = _zeros(_cc)
	if with_solid:
		# Rock at the bottom of every column, like a crust: the inward shells of each column.
		for c in _cc:
			if (c % DEPTH) < 2:
				solid[c] = 1.0
	var before: float = _sum(mass, solid)

	var b_in: RID = _buf(mass)
	var b_out: RID = _buf(_zeros(_cc))
	var b_dep: RID = _buf(_zeros(_cc))
	var b_solid: RID = _buf(solid)
	var wind: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		wind[i] = wind_m_s * (1.0 if (i % 3) == 0 else 0.4)
	var b_vx: RID = _buf(wind)
	var b_vy: RID = _buf(_zeros(_cc))
	var b_vz: RID = _buf(wind)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_ltan: RID = _buf(_grid.link_tan)

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, DEPTH)
	pc.encode_float(8, 0.05)        # k, the Courant factor
	pc.encode_float(12, 0.0)        # settle_v: still, so the only motion is diffusion
	pc.encode_float(16, 0.05)       # diffuse
	pc.encode_u32(20, 0)            # deposit off — a gas
	pc.encode_u32(24, 0)            # offset
	pc.encode_float(28, 0.0)        # decay 0: a conserved tracer

	var uset: RID = _uset(shader, [[0, b_in], [1, b_out], [2, b_dep], [3, b_solid],
		[4, b_vx], [5, b_vy], [6, b_vz], [15, b_nbr], [16, b_ltan]])
	var groups: int = int(ceil(float(_cc) / 64.0))
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var after: float = _sum(_read(b_out), solid)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, "tracer_transport.mass_conserved." + tag, before, after)


## erosion_transport carries a suspended LOAD on flowing water, so its bindings differ from gravity_flow's.
func _binds(label: String, b_in: RID, b_out: RID, b_send: RID, b_solid: RID, b_temp: RID,
		b_nbr: RID, b_larc: RID) -> Array:
	if label == "erosion_transport":
		# 0=susp_in 1=susp_out 2=water 3=solid 5=send 15=nbr
		return [[0, b_in], [1, b_out], [2, b_temp], [3, b_solid], [5, b_send], [15, b_nbr]]
	return [[0, b_in], [1, b_out], [2, b_send], [3, b_solid], [5, b_temp], [15, b_nbr], [16, b_larc]]


func _uset(shader: RID, binds: Array) -> RID:
	var us: Array = []
	for b in binds:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(b[0])
		u.add_id(b[1])
		us.append(u)
	return _rd.uniform_set_create(us, shader, 0)


func _pc_gravity() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(40)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, DEPTH)
	pc.encode_float(12, 100.0)      # core_radius
	pc.encode_float(16, 8.0)        # cell_size
	pc.encode_float(20, 0.25)       # max_flow
	pc.encode_float(24, 1e-5)       # min_flow
	pc.encode_float(28, 1e-4)       # min_mass
	pc.encode_float(32, 0.25)       # lateral_frac
	pc.encode_float(36, 0.0)        # repose_tan: level out freely
	return pc


func _pc_erosion() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 1)             # enabled
	pc.encode_u32(12, 0)
	return pc
