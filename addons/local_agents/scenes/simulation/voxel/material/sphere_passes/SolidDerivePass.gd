extends RefCounted

## CUBED-SPHERE SOLID-DERIVE pass (rock unification Stage B). Runs FIRST in the per-step pass list, before any
## kernel reads `solid`. It recomputes the binary `solid` cache from the authoritative fractional mineral channel
## `rock_fill` (solid iff rock_fill >= 0.5) via one cheap per-cell kernel (solid_derive_sphere3d.glsl). This makes
## `solid` a DERIVED VIEW of rock_fill instead of an independent buffer seeded once from the SDF and never updated
## (the old seed→never-readback divergence). Every downstream `solid == 0.0` reader is unchanged.
##
## `solid` and `rock_fill` are both SINGLE (non-ping-pong) buffers, so there is one uniform set (no parity).
## Kernel binding -> bufs-key: 0 RockFill=rock_fill · 1 Solid=solid. Push { uint cell_count; 3x pad } — 16 bytes.

const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/solid_derive_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: RID = RID()


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
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(rock_fill)
	var u1: RDUniform = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(solid)
	_set = _rd.uniform_set_create([u0, u1], _shader, 0)


func dispatch(rd: RenderingDevice, cl: int, _parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	if _set.is_valid():
		rd.free_rid(_set)
		_set = RID()
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
