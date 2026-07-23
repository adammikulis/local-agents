extends RefCounted

## Cubed-sphere RELEVANCE pass (Keystone C / "Lane B3" — see activity_sphere3d.glsl for the full design).
## Runs the wake-bubble + camera-proximity kernel: reads the PAIR `activity` channel's live half + every
## gated kernel's own self-seed inputs, writes the new 0..1 relevance to `activity` back. Positioned in
## PASS_SCRIPTS right before FireDustPass so FireDustPass (and any other post-Activity pass) can read this
## step's freshly-computed `activity[back]` the same step; passes earlier in PASS_SCRIPTS read last step's
## settled relevance via `activity[live]` — a one-step lag, the same accepted coupling-fidelity convention
## already used elsewhere in this driver.
##
## bufs contract (from the driver): PAIR key -> [rid_a, rid_b]; SINGLE key -> rid. `nbr` is the SINGLE int32
## neighbour index table (cell*6 + slot), bound at binding 15 on every kernel, matching every other pass.

const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/activity_sphere3d.glsl"

# Dev A/B knob (LA_NO_ACTIVITY_LOD=1): force relevance=1.0 everywhere, so every gated kernel resolves its
# stride to 1 (full rate) — one bypass point disables all relevance-gating at once. Mirrors LA_NO_ANIM_LOD.
static var _no_activity_lod: bool = OS.has_environment("LA_NO_ACTIVITY_LOD")
# Distance at which camera-relevance has fallen to 0.5 (LALodStride.relevance_from_distance's GLSL mirror) —
# the field's own "how far until this stops mattering" number, same shape as the creature LOD constants.
const CAMERA_CHARACTERISTIC_DISTANCE: float = 60.0

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
	var static_ch: RID = bufs["static"]
	var water: Array = bufs["water"]
	var rock_fill: RID = bufs["rock_fill"]
	var soil: Array = bufs["soil"]
	var regolith: RID = bufs["regolith"]
	var lava: Array = bufs["lava"]
	var vel_y: RID = bufs["vel_y"]
	var moisture: Array = bufs["moisture"]
	var dust: Array = bufs["dust"]
	var pos: RID = bufs["pos"]

	for p in 2:
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[0, activity[p]], [1, activity[back]], [2, fire[p]], [3, fuel], [4, temp[p]],
			[5, static_ch], [6, water[back]], [7, rock_fill], [8, soil[back]], [9, regolith],
			[10, lava[back]], [11, vel_y], [12, moisture[back]], [13, dust[p]], [14, pos], [15, nbr]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _pipe.is_valid():
		return
	var step_index: int = int(ctx.get("step_index", 0))
	var cam: Vector3 = ctx.get("camera_pos", Vector3(INF, INF, INF))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, step_index)
	pc.encode_u32(8, 1 if _no_activity_lod else 0)
	pc.encode_u32(12, 0)
	pc.encode_float(16, cam.x)
	pc.encode_float(20, cam.y)
	pc.encode_float(24, cam.z)
	pc.encode_float(28, CAMERA_CHARACTERISTIC_DISTANCE)
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
