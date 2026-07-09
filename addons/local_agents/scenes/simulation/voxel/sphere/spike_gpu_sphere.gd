extends SceneTree

## Phase B2 GPU spike — prove the cubed-sphere NEIGHBOUR-SSBO gather runs on the real RenderingDevice: run
## heat_sphere3d.glsl (table-gather conduction) over a SphereGrid, seed one hot cell, and verify heat DIFFUSES
## ACROSS CUBE SEAMS on-device (a cell on a different face than the seed warms up), bounded + no NaN. This is
## the template every field kernel follows for the sphere port. Run:
##   godot --headless --rendering-driver metal -s addons/local_agents/scenes/simulation/voxel/sphere/spike_gpu_sphere.gd

const SphereGrid = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")
const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat_sphere3d.glsl"


func _initialize() -> void:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		print("GPU_SPHERE_REPORT=", JSON.stringify({"ok": false, "error": "no RenderingDevice"}))
		quit(1)
		return

	var grid: RefCounted = SphereGrid.new()
	grid.build(12, 6, 40.0, 4.0)
	var cell_count: int = grid.cell_count
	var res: int = grid.res
	var depth: int = grid.depth

	# Shader + pipeline
	var sf: RDShaderFile = load(KERNEL_PATH)
	var spirv: RDShaderSPIRV = sf.get_spirv()
	var shader: RID = rd.shader_create_from_spirv(spirv)
	var pipe: RID = rd.compute_pipeline_create(shader)

	# Buffers: two temp (ping-pong) + the neighbour table (kernel slot order).
	var temp: PackedFloat32Array = PackedFloat32Array()
	temp.resize(cell_count)
	temp.fill(0.0)
	temp[0] = 1000.0                                   # seed a single hot cell (surf 0 = face 0 corner)
	var tb: PackedByteArray = temp.to_byte_array()
	var buf_a: RID = rd.storage_buffer_create(tb.size(), tb)
	var zeros: PackedByteArray = PackedFloat32Array(temp).to_byte_array()
	var buf_b: RID = rd.storage_buffer_create(zeros.size(), zeros)
	var nbr_bytes: PackedByteArray = grid.neighbours_kernel_order().to_byte_array()
	var buf_n: RID = rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)

	var set_ab: RID = _make_set(rd, shader, buf_a, buf_b, buf_n)   # read a → write b
	var set_ba: RID = _make_set(rd, shader, buf_b, buf_a, buf_n)   # read b → write a

	var pc: PackedByteArray = PackedInt32Array([cell_count, 0, 0, 0]).to_byte_array()
	var groups: int = int(ceil(float(cell_count) / 64.0))

	var steps: int = 400
	for step in steps:
		var uset: RID = set_ab if (step % 2 == 0) else set_ba
		var cl: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()

	# Live buffer after `steps`: writes went a→b→a…; after an even count the last write was into `a` (step
	# steps-1 is odd → set_ba writes a). Read whichever holds the latest: step steps-1 parity.
	var live: RID = buf_a if ((steps - 1) % 2 == 1) else buf_b
	var out: PackedFloat32Array = rd.buffer_get_data(live).to_float32_array()

	# Verify: heat crossed a seam (a cell on a face != 0 warmed), bounded, no NaN, and it smoothed.
	var seed_face: int = 0
	var max_v: float = -1e9
	var min_v: float = 1e9
	var nan_count: int = 0
	var offface_warm: int = 0
	var offface_max: float = 0.0
	for c in cell_count:
		var v: float = out[c]
		if is_nan(v):
			nan_count += 1
			continue
		max_v = maxf(max_v, v)
		min_v = minf(min_v, v)
		var face: int = (c / depth) / (res * res)
		if face != seed_face and v > 1e-4:
			offface_warm += 1
			offface_max = maxf(offface_max, v)

	var ok: bool = nan_count == 0 and offface_warm > 0 and max_v <= 1000.1 and min_v >= -0.1
	print("GPU_SPHERE_REPORT=", JSON.stringify({
		"ok": ok,
		"cell_count": cell_count,
		"crossed_seam": offface_warm > 0, "offface_warm_cells": offface_warm,
		"offface_max": snappedf(offface_max, 0.0001),
		"max": snappedf(max_v, 0.01), "min": snappedf(min_v, 0.0001), "nan": nan_count,
	}))
	quit(0 if ok else 1)


func _make_set(rd: RenderingDevice, shader: RID, b_in: RID, b_out: RID, b_nbr: RID) -> RID:
	var u0: RDUniform = RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(b_in)
	var u1: RDUniform = RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(b_out)
	var u2: RDUniform = RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(b_nbr)
	return rd.uniform_set_create([u0, u1, u2], shader, 0)
