extends RefCounted

## CUBED-SPHERE SOLID-DERIVE pass (rock unification Stage B). Runs FIRST in the per-step pass list, before any
## kernel reads `solid`. It recomputes the binary `solid` cache from the authoritative fractional mineral channel
## `rock_fill` (solid iff rock_fill >= 0.5) via one cheap per-cell kernel (solid_derive_sphere3d.glsl). This makes
## `solid` a DERIVED VIEW of rock_fill instead of an independent buffer seeded once from the SDF and never updated
## (the old seed→never-readback divergence). Every downstream `solid == 0.0` reader is unchanged.
##
## It also LITHIFIES the loose mineral phases of any cell that is now rock — sediment, suspension and dust
## fold into `rock_fill` rather than being sealed beside it where no kernel will ever touch them again (see the
## kernel header). Those three are PAIR channels and this pass runs before anything has written the back half,
## so it reads and edits the LIVE half in place, which is what every later pass takes as its input.
##
## The WATER phases fold the same way — into `soil` as pore water, with the cell marked regolith so the
## aquifer kernel picks it up from the next step. See the kernel header for why that is what really happens.
##
## Kernel binding -> bufs-key: 0 RockFill=rock_fill (single, rw) · 1 Solid=solid (single) ·
## 2 Sediment=sediment[live] · 3 Susp=susp[live] · 4 Dust=dust[live] · 5 Water=water[live] ·
## 6 Moisture=moisture[live] · 7 Snow=snow (single) · 8 Soil=soil[live] · 9 Regolith (single, rw) ·
## 10 Grain (single, rw).
## Push { uint cell_count; float fresh_grain_m; 2x pad }, 16 bytes.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/solid_derive_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]     # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("SolidDerivePass: null RenderingDevice")
		return
	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("SolidDerivePass: solid_derive_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("SolidDerivePass: solid_derive_sphere3d.glsl failed to compile")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var rock_fill: RID = bufs.get("rock_fill", RID())
	var solid: RID = bufs.get("solid", RID())
	var sediment: Array = bufs.get("sediment", [RID(), RID()])
	var susp: Array = bufs.get("susp", [RID(), RID()])
	var dust: Array = bufs.get("dust", [RID(), RID()])
	var water: Array = bufs.get("water", [RID(), RID()])
	var moisture: Array = bufs.get("moisture", [RID(), RID()])
	var soil: Array = bufs.get("soil", [RID(), RID()])
	var snow: RID = bufs.get("snow", RID())
	var regolith: RID = bufs.get("regolith", RID())
	var grain: RID = bufs.get("grain", RID())
	for p in 2:
		_set[p] = _mkset([[0, rock_fill], [1, solid], [2, sediment[p]], [3, susp[p]], [4, dust[p]],
			[5, water[p]], [6, moisture[p]], [7, snow], [8, soil[p]], [9, regolith], [10, grain]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, LAPhysical.GRAIN_D_LOWLAND_M)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for r in _set:
		if r is RID and r.is_valid():
			rd.free_rid(r)
	_set = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


func _mkset(entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, _shader, 0)
