extends RefCounted

## Gravity-driven mass movement for every flowing material, through one kernel.
## Two passes per material (outflow, then gather) sharing the driver's `send` scratch.

const FLOW_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"

## One row per flowing material. `repose` is LAPhysical.REPOSE_TAN_DRY_GRANULAR for granular material and 0
## for a fluid, which levels out freely. The flow caps are model parameters of this grid and step.
const MATERIALS: Array = [
	{"channel": "water", "max_flow": 1.0, "lateral": 0.5, "repose": 0.0},
	{"channel": "sediment", "max_flow": 0.5, "lateral": 0.25,
		"repose": LAPhysical.REPOSE_TAN_DRY_GRANULAR},
	{"channel": "lava", "max_flow": 0.25, "lateral": 0.25, "repose": 0.0},
]
const MIN_FLOW: float = 0.01
const MIN_MASS: float = 0.0001

var _rd: RenderingDevice = null
var _flow_shader: RID = RID()
var _flow_pipe: RID = RID()
## _sets[material_index][parity]
var _sets: Array = []
var _send: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("WaterSlumpLavaPass: null RenderingDevice")
		return

	_send = bufs.get("send", RID())

	var sf: RDShaderFile = load(FLOW_PATH)
	_flow_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	_flow_pipe = _rd.compute_pipeline_create(_flow_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var larc_rid: RID = bufs.get("link_arc", RID())
	var partner_rid: RID = bufs.get("link_partner", RID())
	var shell_rid: RID = bufs.get("shell", RID())
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])

	_sets = []
	for _m in MATERIALS.size():
		_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		for mi in MATERIALS.size():
			var pair: Array = bufs.get(String(MATERIALS[mi]["channel"]), [RID(), RID()])
			_sets[mi][p] = _build_set(_flow_shader, [
				[0, pair[p]], [1, pair[back]], [2, _send], [3, solid_rid],
				[5, temp_pair[p]], [15, nbr_rid], [16, larc_rid], [17, partner_rid],
				[39, shell_rid],
			])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	for mi in MATERIALS.size():
		_two_pass(rd, cl, _sets[mi][parity], cc, groups, MATERIALS[mi], depth)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in _sets:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_sets = []
	for r: RID in [_flow_pipe, _flow_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_flow_pipe = RID()
	_flow_shader = RID()


# --- helpers ------------------------------------------------------------------

func _two_pass(rd: RenderingDevice, cl: int, uset: RID, cc: int, groups: int, mat: Dictionary,
		depth: int) -> void:
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _flow_pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(cc, pass_id, mat, depth)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## { cell_count, pass_id, depth, max_flow, min_flow, min_mass, lateral, repose }
func _pc(cc: int, pass_id: int, mat: Dictionary, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, depth)
	pc.encode_float(12, float(mat["max_flow"]))
	pc.encode_float(16, MIN_FLOW)
	pc.encode_float(20, MIN_MASS)
	pc.encode_float(24, float(mat["lateral"]))
	pc.encode_float(28, float(mat["repose"]))
	return pc


func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)
