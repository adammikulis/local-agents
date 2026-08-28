extends SceneTree

## Dispatches kernels3d/stack_selftest.glsl: one gas cell, at rest, must get its own weight back from its
## own six faces. Prints STACK_BALANCE per case and exits 1 on the first residual past the bar.

const KERNEL: String = "res://addons/local_agents/sim/material/kernels3d/stack_selftest.glsl"
## Floats per case, and the kernel's local_size_x: the buffer is padded to a whole workgroup.
const CASE: int = 8
const LANES: int = 64
## Relative residual a float32 sum of six faces may carry.
const BAR: float = 1.0e-5

const P_MEAN_PA: float = 101325.0
const G_M_S2: float = 9.81
const M_GAS_KG_M3: float = 1.225


## edge, g, m_cond, m_total, then the gravity direction, for every (a, condensed load, direction).
func _cases() -> Array:
	var out: Array = []
	var dirs: Array = [Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0),
		Vector3(0.141, -0.984, 0.112), Vector3(1.0, 1.0, 1.0)]
	for a: float in [0.1, 1.0, 10.0]:
		for m_cond: float in [0.0, 900.0]:
			for dir: Vector3 in dirs:
				out.append({"a": a, "edge": 2.0 * a * P_MEAN_PA / (M_GAS_KG_M3 * G_M_S2),
					"m_cond": m_cond, "m_total": M_GAS_KG_M3 + m_cond, "dir": dir.normalized()})
	return out


func _pack(cases: Array) -> PackedFloat32Array:
	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(LANES * CASE)
	for i in cases.size():
		var c: Dictionary = cases[i]
		var b: int = i * CASE
		f[b] = float(c["edge"])
		f[b + 1] = G_M_S2
		f[b + 2] = float(c["m_cond"])
		f[b + 3] = float(c["m_total"])
		f[b + 4] = P_MEAN_PA
		f[b + 5] = float(Vector3(c["dir"]).x)
		f[b + 6] = float(Vector3(c["dir"]).y)
		f[b + 7] = float(Vector3(c["dir"]).z)
	return f


func _init() -> void:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("check_stack_balance: no RenderingDevice, so nothing was dispatched.")
		print("LA_RUN_COMPLETE={\"code\":2}")
		quit(2)
		return
	var file = load(KERNEL)
	if file == null:
		push_error("check_stack_balance: %s did not load; the tree is unimported." % KERNEL)
		print("LA_RUN_COMPLETE={\"code\":2}")
		quit(2)
		return
	var spirv: RDShaderSPIRV = file.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("check_stack_balance: %s did not compile: %s"
			% [KERNEL, "" if spirv == null else spirv.compile_error_compute])
		print("LA_RUN_COMPLETE={\"code\":2}")
		quit(2)
		return
	var cases: Array = _cases()
	var bytes: PackedByteArray = _pack(cases).to_byte_array()
	var shader: RID = rd.shader_create_from_spirv(spirv)
	var pipe: RID = rd.compute_pipeline_create(shader)
	var buf: RID = rd.storage_buffer_create(bytes.size(), bytes)
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf)
	var uset: RID = rd.uniform_set_create([u], shader, 0)
	var cl: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var back: PackedFloat32Array = rd.buffer_get_data(buf).to_float32_array()
	var code: int = 0
	for i in cases.size():
		var c: Dictionary = cases[i]
		var res: float = back[i * CASE]
		var dir: Vector3 = c["dir"]
		print("STACK_BALANCE={\"a\":%s,\"m_cond\":%s,\"dir\":[%.3f,%.3f,%.3f],\"residual\":%s}"
			% [c["a"], c["m_cond"], dir.x, dir.y, dir.z, String.num_scientific(res)])
		if not is_finite(res) or res > BAR:
			push_error(("check_stack_balance: a cube of side %.1f m under %.3f m/s^2 gets %s of its own "
				% [float(c["edge"]), G_M_S2, String.num_scientific(res)])
				+ "weight back as a residual from its own faces. At rest it would accelerate.")
			code = 1
	rd.free_rid(uset)
	rd.free_rid(buf)
	rd.free_rid(pipe)
	rd.free_rid(shader)
	rd.free()
	print("LA_RUN_COMPLETE={\"code\":%d}" % code)
	quit(code)
