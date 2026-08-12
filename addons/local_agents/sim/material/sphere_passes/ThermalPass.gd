extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Band-resolved two-stream radiative transfer. Conduction, convection, radiative exchange between cells
## and buoyant melt are LATransportRecords rows and run in TransportPass.

const SOLAR_PATH: String = "res://addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl"

const BandsScript: GDScript = preload("res://addons/local_agents/sim/material/AbsorptionBands.gd")

var _solar_pipe: RID = RID()
var _solar_set: Array = [RID(), RID()]   # per ping-pong parity

# Band edges, per-band absorption coefficients and the Planck CDF the kernel reads.
var _rad_table: RID = RID()
var _band_count: int = 0


func _setup(bufs: Dictionary, _cc: int) -> void:
	_solar_pipe = _kernel(SOLAR_PATH)
	_band_count = BandsScript.BAND_COUNT
	_rad_table = _storage_buffer(BandsScript.packed().to_byte_array())

	for p in 2:
		_solar_set[p] = _uset(_solar_pipe, [
			[0, _half(bufs, "temp", p, false)],
			[1, _single(bufs, "solid")],
			[4, _single(bufs, "snow")],
			[5, _half(bufs, "water", p, true)],
			[6, _single(bufs, "rock_fill")],
			[7, _single(bufs, "pressure")],
			[14, _single(bufs, "radial")],
			[20, _half(bufs, "lava", p, true)],
			[21, _single(bufs, "fuel")],
			[23, _single(bufs, "detritus")],
			[27, _single(bufs, "biomass")],
			[30, _half(bufs, "sediment", p, false)],
			[31, _half(bufs, "susp", p, false)],
			[32, _half(bufs, "dust", p, false)],
			[33, _single(bufs, "carbonate")],
			[34, _single(bufs, "silica")],
			[35, _half(bufs, "soil", p, false)],
			[36, _half(bufs, "moisture", p, false)],
			[37, _half(bufs, "fungus", p, false)],
			[38, _single(bufs, "porosity")],
			[43, _half(bufs, "co2", p, false)],
			[47, _rad_table],
			[48, _single(bufs, "gravity")]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, _groups: int) -> void:
	if not _dispatchable():
		return
	var depth: int = _ctx_depth(ctx)
	var columns: int = cc / depth
	var pc: PackedByteArray = _solar_pc(columns, depth, ctx)
	rd.compute_list_bind_compute_pipeline(cl, _solar_pipe)
	rd.compute_list_bind_uniform_set(cl, _solar_set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, int(ceil(float(columns) / 64.0)), 1, 1)
	rd.compute_list_add_barrier(cl)


# --- helpers ---------------------------------------------------------------------------------------------

# Params { uint column_count; float dt_s; uint depth; float cell_m; uint band_count;
#          float sun_x, sun_y, sun_z; float pad0; } — 36 bytes.
func _solar_pc(columns: int, depth: int, ctx: Dictionary) -> PackedByteArray:
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, columns)
	pc.encode_float(4, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	pc.encode_u32(8, depth)
	pc.encode_float(12, _ctx_cell_size(ctx))
	pc.encode_u32(16, _band_count)
	pc.encode_float(20, sun_dir.x)
	pc.encode_float(24, sun_dir.y)
	pc.encode_float(28, sun_dir.z)
	pc.encode_float(32, 0.0)
	return pc
