extends SceneTree

## Phase B GPU spike — prove RADIAL GRAVITY: the water CA (water_sphere3d.glsl) run on the real GPU must make
## water flow toward the INWARD-radial (down) neighbour and pile up at the inner layers, i.e. "down = inward"
## works on-device. Seed water in the OUTERMOST radial layer everywhere; after N steps the water's mean radius
## must DROP sharply (it settled inward) with mass conserved. Run:
##   godot --rendering-driver metal -s addons/local_agents/scenes/simulation/voxel/sphere/spike_gpu_water.gd

const SphereGrid = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")
const KERNEL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water_sphere3d.glsl"


func _initialize() -> void:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		print("GPU_WATER_REPORT=", JSON.stringify({"ok": false, "error": "no RenderingDevice"}))
		quit(1)
		return

	var grid: RefCounted = SphereGrid.new()
	grid.build(10, 10, 30.0, 4.0)                 # res=10/face, 10 radial layers (room to settle)
	var cc: int = grid.cell_count
	var depth: int = grid.depth

	var sf: RDShaderFile = load(KERNEL_PATH)
	var shader: RID = rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = rd.compute_pipeline_create(shader)

	# Water seeded in the OUTERMOST layer (r == depth-1) of every surface cell; empty elsewhere.
	var water: PackedFloat32Array = PackedFloat32Array()
	water.resize(cc)
	water.fill(0.0)
	for s in grid.surf_count:
		water[s * depth + (depth - 1)] = 1.0
	var start_mass: float = 0.0
	var start_wr: float = 0.0
	for c in cc:
		start_mass += water[c]
		start_wr += water[c] * float(c % depth)
	var start_mean_r: float = start_wr / start_mass

	var wb: PackedByteArray = water.to_byte_array()
	var buf_a: RID = rd.storage_buffer_create(wb.size(), wb)
	var buf_b: RID = rd.storage_buffer_create(wb.size(), PackedFloat32Array(water).to_byte_array())
	var zc: PackedByteArray = PackedFloat32Array([]).to_byte_array()
	var solid_bytes: PackedByteArray = _zeros(cc)
	var buf_solid: RID = rd.storage_buffer_create(solid_bytes.size(), solid_bytes)   # all void
	var buf_static: RID = rd.storage_buffer_create(solid_bytes.size(), solid_bytes)  # no infinite sinks
	var send_bytes: PackedByteArray = _zeros(cc * 6)
	var buf_send: RID = rd.storage_buffer_create(send_bytes.size(), send_bytes)
	var nbr_bytes: PackedByteArray = grid.neighbours_kernel_order().to_byte_array()
	var buf_n: RID = rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)

	var set_ab: RID = _make_set(rd, shader, buf_a, buf_solid, buf_static, buf_send, buf_b, buf_n)
	var set_ba: RID = _make_set(rd, shader, buf_b, buf_solid, buf_static, buf_send, buf_a, buf_n)
	var groups: int = int(ceil(float(cc) / 64.0))

	var steps: int = 300
	for step in steps:
		var uset: RID = set_ab if (step % 2 == 0) else set_ba
		rd.buffer_clear(buf_send, 0, send_bytes.size())          # fresh scratch each step
		# pass 0 = outflow (write send), pass 1 = inflow/apply (write water_out)
		for pass_id in 2:
			var pc: PackedByteArray = PackedInt32Array([cc, pass_id, 0, 0]).to_byte_array()
			var cl: int = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, pipe)
			rd.compute_list_bind_uniform_set(cl, uset, 0)
			rd.compute_list_set_push_constant(cl, pc, pc.size())
			rd.compute_list_dispatch(cl, groups, 1, 1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()

	var live: RID = buf_a if ((steps - 1) % 2 == 1) else buf_b
	var out: PackedFloat32Array = rd.buffer_get_data(live).to_float32_array()

	var end_mass: float = 0.0
	var end_wr: float = 0.0
	var nan_count: int = 0
	var inner_mass: float = 0.0                                   # water in the inner half of layers
	for c in cc:
		var v: float = out[c]
		if is_nan(v):
			nan_count += 1
			continue
		end_mass += v
		var r: int = c % depth
		end_wr += v * float(r)
		if r < depth / 2:
			inner_mass += v
	var end_mean_r: float = end_wr / maxf(0.0001, end_mass)
	var mass_err: float = absf(end_mass - start_mass) / start_mass

	# Radial gravity works iff water settled inward (mean radius dropped a lot) + mass conserved + no NaN.
	var settled: bool = end_mean_r < start_mean_r - 2.0
	var ok: bool = nan_count == 0 and settled and mass_err < 0.05
	print("GPU_WATER_REPORT=", JSON.stringify({
		"ok": ok, "cell_count": cc, "depth": depth,
		"start_mean_r": snappedf(start_mean_r, 0.01), "end_mean_r": snappedf(end_mean_r, 0.01),
		"settled_inward": settled, "inner_half_frac": snappedf(inner_mass / maxf(0.0001, end_mass), 0.001),
		"mass_err": snappedf(mass_err, 0.0001), "nan": nan_count,
	}))
	quit(0 if ok else 1)


func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(0.0)
	return a.to_byte_array()


func _make_set(rd: RenderingDevice, shader: RID, b_in: RID, b_solid: RID, b_static: RID, b_send: RID, b_out: RID, b_nbr: RID) -> RID:
	var ids: Array = [b_in, b_solid, b_static, b_send, b_out]
	var bindings: Array = [0, 1, 2, 3, 4]
	var us: Array[RDUniform] = []
	for k in ids.size():
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = bindings[k]
		u.add_id(ids[k])
		us.append(u)
	var un: RDUniform = RDUniform.new()
	un.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	un.binding = 15
	un.add_id(b_nbr)
	us.append(un)
	return rd.uniform_set_create(us, shader, 0)
