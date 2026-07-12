extends RefCounted

## Cubed-sphere GPU pass plugin: EROSION PICKUP — the scour leg of the mineral cycle (Stage D). Wires the ONE
## kernel erosion_pickup_sphere3d.glsl into the SphereGPU driver via the plugin contract (setup() once,
## dispatch() each step). Flowing water lifts bedrock (rock_fill) off its bed into waterborne suspension (susp);
## the existing M3 SETTLE record (ReactionsPass) drops susp back to loose sediment where flow slackens, and the
## granular slump CA spreads it. rock_fill scoured below 0.5 opens the bed (incision) via SolidDerive + stamps
## the SDF via MineralStamp3D; susp that settles + lithifies re-crosses 0.5 → new land (deltas/beaches).
##
## PLACEMENT (MaterialSphereGPU3D.PASS_SCRIPTS): right BEFORE ReactionsPass, AFTER the water CA + Atmosphere have
## settled water into the BACK half. Reads water[back] (the current water), scours rock_fill (SINGLE, in place),
## and FULLY writes susp[back] = susp[live] (carry) + scour so ReactionsPass's M3 settle reads a consistent susp.
## Single dispatch — the scour targets each solid bed cell's UNIQUE up-cell (radial reciprocity), so the
## cross-cell rock_fill write is race-free with no barrier; susp is written own-cell.
##
## Kernel binding -> bufs-key map (authoritative layout is erosion_pickup_sphere3d.glsl):
##   0 WaterIn=water[back] · 1 Solid=solid · 2 Static=static · 3 RockFill=rock_fill(single) ·
##   4 SuspIn=susp[live] · 5 SuspOut=susp[back] · 15 Neigh=nbr
## Push constant: PackedInt32Array([cell_count, 0, 0, 0]).to_byte_array().

const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/erosion_pickup_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("ErosionPickupPass: null RenderingDevice")
		return

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("ErosionPickupPass: erosion_pickup_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("ErosionPickupPass: shader compile failed (run --import after editing the .glsl)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var static_rid: RID = bufs.get("static", RID())
	var rock_rid: RID = bufs.get("rock_fill", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var susp_pair: Array = bufs.get("susp", [RID(), RID()])

	for p in 2:
		var back: int = 1 - p
		# Read the SETTLED water (back half, matching ReactionsPass) and carry susp live(p) -> back(1-p).
		_set[p] = _build_set(_shader, [
			[0, water_pair[back]],   # WaterIn = settled water (back)
			[1, solid_rid],          # Solid
			[2, static_rid],         # Static (calm sea — no scour)
			[3, rock_rid],           # RockFill (SINGLE, scoured in place)
			[4, susp_pair[p]],       # SuspIn  = live susp (carry source)
			[5, susp_pair[back]],    # SuspOut = back susp (carry + pickup)
			[15, nbr_rid],           # Neigh table
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc: PackedByteArray = PackedInt32Array([cc, 0, 0, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


## Free every RID this pass owns (uniform sets, pipeline, shader). Borrowed `bufs` entries are freed by the driver.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)
