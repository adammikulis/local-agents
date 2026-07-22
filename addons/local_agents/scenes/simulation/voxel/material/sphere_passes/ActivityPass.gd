extends RefCounted

## Cubed-sphere ACTIVITY-BUBBLE LOD pass (Keystone C / "Lane B3", first slice — see activity_sphere3d.glsl for
## the propagation design). Runs the wake-bubble kernel: reads the PAIR `activity` channel's live half + fire/
## fuel/temp live, writes the new wake state to `activity` back. Positioned in PASS_SCRIPTS right before
## FireDustPass so FireDustPass can read this step's freshly-computed `activity[back]` the same step (matches
## the driver's "later pass reads back for an earlier pass's output" data-flow convention).
##
## bufs contract (from the driver): PAIR key -> [rid_a, rid_b]; SINGLE key -> rid. `nbr` is the SINGLE int32
## neighbour index table (cell*6 + slot), bound at binding 15 on every kernel, matching every other pass.

const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/activity_sphere3d.glsl"

var _shader: RID = RID()
var _pipe: RID = RID()
var _sets: Array = [RID(), RID()]   # per parity p


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_warning("ActivityPass: activity_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_warning("ActivityPass: activity_sphere3d.glsl failed to compile")
		return
	_pipe = rd.compute_pipeline_create(_shader)

	var nbr: RID = bufs["nbr"]
	var fire: Array = bufs["fire"]
	var fuel: RID = bufs["fuel"]
	var temp: Array = bufs["temp"]
	var activity: Array = bufs["activity"]

	for p in 2:
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[0, activity[p]], [1, activity[back]], [2, fire[p]], [3, fuel], [4, temp[p]], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _pipe.is_valid():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for r: RID in _sets:
		if r is RID and r.is_valid():
			rd.free_rid(r)
	_sets = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


func _build_set(rd: RenderingDevice, shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)
