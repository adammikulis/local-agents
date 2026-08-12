extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Gravity-driven mass movement for every flowing material, through one kernel.
## Two passes per material (outflow, then gather) sharing the driver's `send` scratch.

const FLOW_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"

## One row per flowing material. `repose` is LAPhysical.REPOSE_TAN_DRY_GRANULAR for granular material and 0
## for a fluid, which levels out freely. The flow caps are model parameters of this grid and step.
## `group` names the LAHeatCapacity group the material joins in `rc_of`, which sets how much heat a unit of
## it carries.
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

## Argument index of each LAHeatCapacity.mix group.
const MIX_SLOT: Dictionary = {"silicate": 0, "carbonate": 1, "silica": 2, "water": 3, "snow": 4,
	"vapour": 5, "organic": 6}

var _flow_pipe: RID = RID()
## _sets[material_index][parity]
var _sets: Array = []
## Enthalpy scratch, one slot per cell face: pass 0 writes it, pass 1 gathers it. A receiver cannot read its
## donor's temperature instead — pass 1 writes temp, so that read races the write.
var _send_h: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_flow_pipe = _kernel(FLOW_PATH)
	_send_h = _scratch(cc * 6)

	var send_rid: RID = _single(bufs, "send")
	var solid_rid: RID = _single(bufs, "solid")
	var nbr_rid: RID = _single(bufs, "nbr")
	var larc_rid: RID = _single(bufs, "link_arc")
	var partner_rid: RID = _single(bufs, "link_partner")
	var shell_rid: RID = _single(bufs, "shell")
	var cvol_rid: RID = _single(bufs, "cell_vol")
	var temp_pair: Array = _pair(bufs, "temp")

	_sets = []
	for _m in MATERIALS.size():
		_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		# The composition rc_of() reads is the one this pass is about to move: the LIVE half of every pair.
		var carriers: Array = []
		for name: String in RC_PAIR_BINDS:
			carriers.append([int(RC_PAIR_BINDS[name]), _half(bufs, name, p, false)])
		for name: String in RC_SINGLE_BINDS:
			carriers.append([int(RC_SINGLE_BINDS[name]), _single(bufs, name)])
		for mi in MATERIALS.size():
			var pair: Array = _pair(bufs, String(MATERIALS[mi]["channel"]))
			var entries: Array = [
				[0, pair[p]],            # MassIn  = live half
				[1, pair[back]],         # MassOut = back half
				[2, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
				[3, solid_rid],          # Solid
				[4, _send_h],            # SendH — paired slot-for-slot with Send
				[5, temp_pair[p]],       # Temp, in place
				[15, nbr_rid],           # Neigh table
				[16, larc_rid],          # lateral arc per column, radians
				[17, partner_rid],       # the slot that answers each link
				[39, shell_rid],         # radial shell table, model units
				[40, cvol_rid],          # per-cell volume, model units^3
			]
			entries.append_array(carriers)
			_sets[mi][p] = _uset(_flow_pipe, entries)


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var depth: int = _ctx_depth(ctx)
	for mi in MATERIALS.size():
		_two_pass(rd, cl, _sets[mi][parity], cc, groups, MATERIALS[mi], depth)


# --- helpers ------------------------------------------------------------------

func _two_pass(rd: RenderingDevice, cl: int, uset: RID, cc: int, groups: int, mat: Dictionary,
		depth: int) -> void:
	if not uset.is_valid():
		return
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _flow_pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(cc, pass_id, mat, depth)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## std430: 3x uint (cell_count, pass_id, depth) then 6x float (max_flow, min_flow, min_mass, lateral,
## repose_tan, rc_gain) — 36 bytes.
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


## Heat capacity a cell gains per unit fill of this material, J/m3K: the material's own capacity less the
## air it displaces, because rc_of() fills the unoccupied fraction of a cell with air.
static func rc_gain(group: String) -> float:
	var f: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	f[int(MIX_SLOT.get(group, 0))] = 1.0
	return LAHeatCapacity.mix(f[0], f[1], f[2], f[3], f[4], f[5], f[6]) \
		- LAHeatCapacity.mix(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
