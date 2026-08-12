extends RefCounted

## Gravity-driven mass movement for every flowing material, through one kernel.
## Two passes per material (outflow, then gather) sharing the driver's `send` scratch.

const FLOW_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"

## One row per flowing material. `repose` is LAPhysical.REPOSE_TAN_DRY_GRANULAR for granular material and 0
## for a fluid, which levels out freely. The flow caps are model parameters of this grid and step.
## `group` names the LAHeatCapacity group the material joins in `rc_of`, which is what sets how much heat a
## unit of it carries.
const MATERIALS: Array = [
	{"channel": "water", "max_flow": 1.0, "lateral": 0.5, "repose": 0.0, "group": "water"},
	{"channel": "sediment", "max_flow": 0.5, "lateral": 0.25,
		"repose": LAPhysical.REPOSE_TAN_DRY_GRANULAR, "group": "silicate"},
	{"channel": "lava", "max_flow": 0.25, "lateral": 0.25, "repose": 0.0, "group": "silicate"},
]
const MIN_FLOW: float = 0.01
const MIN_MASS: float = 0.0001

## Every channel rc_shared.glsli reads, paired with the kernel binding it arrives on.
const RC_PAIR_BINDS: Dictionary = {
	"water": 7, "lava": 20, "sediment": 30, "susp": 31, "dust": 32, "soil": 35, "moisture": 36,
	"fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {
	"rock_fill": 18, "snow": 19, "fuel": 21, "biomass": 22, "detritus": 23, "carbonate": 33,
	"silica": 34, "porosity": 38}

var _rd: RenderingDevice = null
var _flow_shader: RID = RID()
var _flow_pipe: RID = RID()
## _sets[material_index][parity]
var _sets: Array = []
var _send: RID = RID()
## Enthalpy scratch, one slot per cell face, written by pass 0 and gathered by pass 1. A receiver cannot read
## its donor's temperature instead: pass 1 writes temp, so that read races the write.
var _send_h: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("WaterSlumpLavaPass: null RenderingDevice")
		return

	_send = bufs.get("send", RID())
	var zeros: PackedByteArray = _zeros(cc * 6).to_byte_array()
	_send_h = _rd.storage_buffer_create(zeros.size(), zeros)

	var sf: RDShaderFile = load(FLOW_PATH)
	_flow_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	_flow_pipe = _rd.compute_pipeline_create(_flow_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var larc_rid: RID = bufs.get("link_arc", RID())
	var partner_rid: RID = bufs.get("link_partner", RID())
	var shell_rid: RID = bufs.get("shell", RID())
	var cvol_rid: RID = bufs.get("cell_vol", RID())
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])

	_sets = []
	for _m in MATERIALS.size():
		_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		# The composition rc_of() reads is the one this pass is about to move: the LIVE half of every pair.
		var carriers: Array = []
		for name: String in RC_PAIR_BINDS:
			var cp: Array = bufs.get(name, [RID(), RID()])
			carriers.append([int(RC_PAIR_BINDS[name]), cp[p]])
		for name: String in RC_SINGLE_BINDS:
			carriers.append([int(RC_SINGLE_BINDS[name]), bufs.get(name, RID())])
		for mi in MATERIALS.size():
			var pair: Array = bufs.get(String(MATERIALS[mi]["channel"]), [RID(), RID()])
			var entries: Array = [
				[0, pair[p]], [1, pair[back]], [2, _send], [3, solid_rid], [4, _send_h],
				[5, temp_pair[p]], [15, nbr_rid], [16, larc_rid], [17, partner_rid],
				[39, shell_rid], [40, cvol_rid],
			]
			entries.append_array(carriers)
			_sets[mi][p] = _build_set(_flow_shader, entries)


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
	for r: RID in [_flow_pipe, _flow_shader, _send_h]:
		if r.is_valid():
			rd.free_rid(r)
	_flow_pipe = RID()
	_flow_shader = RID()
	_send_h = RID()


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


## { cell_count, pass_id, depth, max_flow, min_flow, min_mass, lateral, repose, rc_gain }
func _pc(cc: int, pass_id: int, mat: Dictionary, depth: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, depth)
	pc.encode_float(12, float(mat["max_flow"]))
	pc.encode_float(16, MIN_FLOW)
	pc.encode_float(20, MIN_MASS)
	pc.encode_float(24, float(mat["lateral"]))
	pc.encode_float(28, float(mat["repose"]))
	pc.encode_float(32, rc_gain(String(mat["group"])))
	return pc


## Argument index of each LAHeatCapacity.mix group.
const MIX_SLOT: Dictionary = {"silicate": 0, "carbonate": 1, "silica": 2, "water": 3, "snow": 4,
	"vapour": 5, "organic": 6}


## Heat capacity a cell gains per unit fill of this material, J/m3K: the material's own capacity less the
## air it displaces, because rc_of() fills the unoccupied fraction of a cell with air.
static func rc_gain(group: String) -> float:
	var f: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	f[int(MIX_SLOT.get(group, 0))] = 1.0
	return LAHeatCapacity.mix(f[0], f[1], f[2], f[3], f[4], f[5], f[6]) \
		- LAHeatCapacity.mix(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


static func _zeros(n: int) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a


func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)
