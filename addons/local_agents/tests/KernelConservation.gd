class_name LAKernelConservation
extends Node


const GRAVITY_FLOW: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"
const TRACER: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"
const EROSION: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"
const EROSION_PICKUP: String = "res://addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl"
const PLATE_ADVECT: String = "res://addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl"
const SOIL: String = "res://addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl"
const WIND_PRESSURE: String = "res://addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl"

const RES_PER_FACE: int = 4
const DEPTH: int = 6
# The shipped planet: VoxelSettingsApplier.grid_res_per_face() at the default budget, GRID_DEPTH.
const LIVE_RES: int = 24
const LIVE_DEPTH: int = 20
const TOLERANCE: float = 1e-4      # relative; float32 over a few thousand cells

var _rd: RenderingDevice = null
var _grid: RefCounted = null
var _cc: int = 0
var _depth: int = DEPTH
var _failures: Array = []
var _checks: int = 0
## Per-arm volume-weighted drift, in percent — the same quantity the assertions gate on, published so the
## magnitude is visible rather than only pass/fail.
var _volume_notes: Dictionary = {}


func _ready() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		print("KERNEL_CONSERVATION={\"ok\":false,\"reason\":\"no compute device\"}")
		LAAppExit.request(self, 2)
		return
	_grid = LASphereGrid.new()
	_grid.build(RES_PER_FACE, DEPTH, 100.0, 8.0, Vector3.ZERO)
	_cc = _grid.neighbours.size() / 6

	var v: Dictionary = _grid.validate()
	_expect(bool(v.get("ok", false)), "grid.validate", 1.0, 1.0 if bool(v.get("ok", false)) else 0.0)
	_expect(bool(v.get("shells_uniform", false)), "grid.uniform_by_default", 1.0,
		1.0 if bool(v.get("shells_uniform", false)) else 0.0)
	_check_cell_volume()

	_check_uniform_identity()
	_check_two_pass(GRAVITY_FLOW, "gravity_flow", _pc_gravity())
	_check_two_pass(EROSION, "erosion_transport", _pc_erosion())
	_check_tracer(0.0, false, "still")
	_check_tracer(3.0, false, "wind")
	# The real field is about a quarter solid. Solid cells are where the gathers skip and where the deposit
	# branch lives, so an all-open grid never exercises the paths a planet actually runs.
	_check_tracer(0.0, true, "still_solid")
	_check_tracer(3.0, true, "wind_solid")
	# The live field runs at 160 m/s, which is what the operator actually sees.
	_check_tracer(160.0, true, "gale_solid")
	# The live field carries a huge VERTICAL velocity, and the vertical terms are the asymmetric ones — the
	# up flux is gated on an open cell above, the down flux is not. Every case above left vel_y at zero.
	_check_tracer(0.0, true, "updraft_solid", 300.0)
	_check_tracer(0.0, false, "updraft_open", 300.0)
	_check_tracer(0.0, true, "downdraft_solid", -300.0)
	# The sim runs the operator MANY times, ping-ponging the two halves. One dispatch cannot show a defect
	# that compounds, and the live runaway takes 12 steps to become visible.
	_check_tracer_steps(20, 160.0, 300.0, true, "pingpong_20")
	# MASS WITHOUT ITS HEAT. Both gathers move matter between cells at different temperatures, so the enthalpy
	# they carry has to leave one cell and arrive in the other, in full.
	_check_flow_energy("gravity_flow")
	_check_soil_energy("soil")
	_check_erosion_transport_energy("erosion_transport")
	_check_erosion_pickup_energy("erosion_pickup")
	_check_plate_advect_energy("plate_advect")
	_check_live_grid()
	_check_graded_grid()
	# AIR. The wind pass moves a whole COLUMN of it and then re-settles that column hydrostatically, which is
	# a shape no other arm here covers.
	_check_wind_air_all()
	_check_wind_momentum()
	_check_wind_eos()

	print("KERNEL_CONSERVATION=", JSON.stringify({
		"ok": _failures.is_empty(), "checks": _checks, "failures": _failures,
		"volume_weighted_drift_pct": _volume_notes}))
	_rd.free()
	LAAppExit.request(self, 0 if _failures.is_empty() else 1)


## A cell's mass, seeded so there is something to move: a spike in one column, flat elsewhere.
func _seed_mass() -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(_cc)
	a.fill(0.25)
	for i in range(0, _cc, 37):
		a[i] = 0.9
	return a


func _zeros(n: int) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a


func _buf(arr: PackedFloat32Array) -> RID:
	var b: PackedByteArray = arr.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)


func _read(rid: RID) -> PackedFloat32Array:
	return _rd.buffer_get_data(rid).to_float32_array()


## The channels are fill fractions, so MATTER is the sum of channel*volume. That is the only total worth
## asserting: the bare sum is conserved by an operator that moves the wrong amount of matter.
func _sum(a: PackedFloat32Array) -> float:
	return _volume_weighted(a)


func _note_volume(label: String, before_arr: PackedFloat32Array, after_arr: PackedFloat32Array) -> void:
	var b: float = _volume_weighted(before_arr)
	var a: float = _volume_weighted(after_arr)
	_volume_notes[label] = snappedf(100.0 * (a - b) / maxf(absf(b), 1e-9), 0.0001)


## The solid angles must close the sphere, or every volume derived from them is wrong by the same factor.
func _check_cell_volume() -> void:
	var v: Dictionary = _grid.validate()
	var omega: float = float(v.get("omega_total", 0.0))
	_expect(absf(omega - TAU * 2.0) < 1e-4, "grid.omega_closes_sphere", TAU * 2.0, omega)
	var vol: PackedFloat32Array = _grid.cell_volumes()
	_expect(vol.size() == _cc, "grid.cell_volumes_sized", float(_cc), float(vol.size()))
	var lo: float = INF
	for i in vol.size():
		lo = minf(lo, vol[i])
	_expect(lo > 0.0, "grid.cell_volumes_positive", 1.0, 1.0 if lo > 0.0 else 0.0)

func _expect(ok: bool, what: String, want: float, got: float) -> void:
	_checks += 1
	if not ok:
		_failures.append({"check": what, "want": want, "got": got})


## The two-pass send/gather shape: pass 0 writes outflow, pass 1 gathers. Total mass over ALL cells must be
## unchanged — that is the whole contract, and it is the one that broke in four kernels.
func _check_two_pass(path: String, label: String, pc_base: PackedByteArray) -> void:
	var sf = load(path)
	if sf == null:
		_failures.append({"check": label, "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var mass: PackedFloat32Array = _seed_mass()
	var solid: PackedFloat32Array = _zeros(_cc)
	var before: float = _sum(mass)

	var b_in: RID = _buf(mass)
	var b_out: RID = _buf(_zeros(_cc))
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_solid: RID = _buf(solid)
	# For erosion this slot is WATER: without flow there is nothing for the load to ride.
	var b_temp: RID = _buf(_seed_mass() if label == "erosion_transport" else _zeros(_cc))
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_larc: RID = _buf(_grid.link_arc)
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())

	var groups: int = int(ceil(float(_cc) / 64.0))
	for pass_id in 2:
		var uset: RID = _uset(shader, _binds(label, b_in, b_out, b_send, b_solid, b_temp, b_nbr, b_larc, b_part))
		var pc: PackedByteArray = pc_base.duplicate()
		pc.encode_u32(4, pass_id)
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()

	var out_arr: PackedFloat32Array = _read(b_out)
	var after: float = _sum(out_arr)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, label + ".matter_conserved", before, after)
	_note_volume(label, mass, out_arr)


## The tracer operator is a SINGLE pass: out = in - own_out + gain. Same contract, one dispatch.
func _check_tracer(wind_m_s: float, with_solid: bool, tag: String, vy_m_s: float = 0.0) -> void:
	var sf = load(TRACER)
	if sf == null:
		_failures.append({"check": "tracer_transport", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var mass: PackedFloat32Array = _seed_mass()
	var solid: PackedFloat32Array = _zeros(_cc)
	if with_solid:
		# Rock at the bottom of every column, like a crust: the inward shells of each column.
		for c in _cc:
			if (c % _depth) < 2:
				solid[c] = 1.0
	var before: float = _sum(mass)

	var b_in: RID = _buf(mass)
	var b_out: RID = _buf(_zeros(_cc))
	var b_dep: RID = _buf(_zeros(_cc))
	var b_solid: RID = _buf(solid)
	var wind: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		wind[i] = wind_m_s * (1.0 if (i % 3) == 0 else 0.4)
	var b_vx: RID = _buf(wind)
	var vyf: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		vyf[i] = vy_m_s * (1.0 if (i % 2) == 0 else 0.55)
	var b_vy: RID = _buf(vyf)
	var b_vz: RID = _buf(wind)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_ltan: RID = _buf(_grid.link_tan)

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, _depth)
	pc.encode_float(8, 0.05)        # k_lat, the lateral Courant factor
	pc.encode_float(12, 0.0)        # settle_v: still, so the only motion is diffusion
	pc.encode_float(16, 0.05)       # diffuse
	pc.encode_u32(20, 0)            # deposit off — a gas
	pc.encode_u32(24, 0)            # offset
	pc.encode_float(28, 0.0)        # decay 0: a conserved tracer
	pc.encode_float(32, 8.0)        # lat_ref: the spacing k_lat was divided by

	var b_part2: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())
	var uset: RID = _uset(shader, [[0, b_in], [1, b_out], [2, b_dep], [3, b_solid],
		[4, b_vx], [5, b_vy], [6, b_vz], [15, b_nbr], [16, b_ltan], [17, b_part2],
		[39, _shell_buf()], [40, _cvol_buf()]])
	var groups: int = int(ceil(float(_cc) / 64.0))
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var out_arr: PackedFloat32Array = _read(b_out)
	var after: float = _sum(out_arr)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, "tracer_transport.matter_conserved." + tag, before, after)
	_note_volume(tag, mass, out_arr)


## erosion_transport carries a suspended LOAD on flowing water, so its bindings differ from gravity_flow's.
func _binds(label: String, b_in: RID, b_out: RID, b_send: RID, b_solid: RID, b_temp: RID,
		b_nbr: RID, b_larc: RID, b_part: RID) -> Array:
	if label == "erosion_transport":
		# 0=susp_in 1=susp_out 2=flow head 3=solid 4=send_h 5=send 6=temp 15=nbr
		var ero: Array = [[0, b_in], [1, b_out], [2, b_temp], [3, b_solid], [4, _buf(_zeros(_cc * 6))],
			[5, b_send], [6, _buf(_zeros(_cc))], [15, b_nbr], [17, b_part], [40, _cvol_buf()]]
		ero.append_array(_rc_binds(EROSION_RC, {"water": b_temp, "susp": b_in}))
		return ero
	var out: Array = [[0, b_in], [1, b_out], [2, b_send], [3, b_solid], [4, _buf(_zeros(_cc * 6))],
		[5, b_temp], [15, b_nbr], [16, b_larc], [17, b_part], [39, _shell_buf()], [40, _cvol_buf()]]
	out.append_array(_rc_binds(GRAVITY_FLOW_RC, {"water": b_in}))
	return out


## Every carrier rc_shared.glsli reads, per kernel, with the binding it arrives on. `override` supplies the
## live buffer for a channel the arm is actually exercising; the rest are an all-zero cell.
const GRAVITY_FLOW_RC: Dictionary = {"water": 7, "rock_fill": 18, "snow": 19, "lava": 20, "fuel": 21,
	"biomass": 22, "detritus": 23, "sediment": 30, "susp": 31, "dust": 32, "carbonate": 33,
	"silica": 34, "soil": 35, "moisture": 36, "fungus": 37, "porosity": 38}
const SOIL_RC: Dictionary = {"rock_fill": 18, "snow": 19, "lava": 20, "fuel": 21, "biomass": 22,
	"detritus": 23, "sediment": 30, "susp": 31, "dust": 32, "carbonate": 33, "silica": 34,
	"moisture": 36, "fungus": 37}
const EROSION_RC: Dictionary = {"water": 7, "rock_fill": 18, "snow": 19, "lava": 20, "fuel": 21,
	"biomass": 22, "detritus": 23, "sediment": 30, "susp": 31, "dust": 32, "carbonate": 33,
	"silica": 34, "soil": 35, "moisture": 36, "fungus": 37, "porosity": 38}
const PICKUP_RC: Dictionary = {"snow": 19, "lava": 20, "fuel": 21, "biomass": 22, "detritus": 23,
	"sediment": 30, "dust": 32, "carbonate": 33, "silica": 34, "soil": 35, "moisture": 36,
	"fungus": 37, "porosity": 38}
const PLATE_RC: Dictionary = {"snow": 19, "lava": 20, "fuel": 21, "biomass": 22, "detritus": 23,
	"sediment": 30, "susp": 31, "dust": 32, "carbonate": 33, "silica": 34, "soil": 35,
	"moisture": 36, "fungus": 37, "porosity": 38}


func _rc_binds(table: Dictionary, override: Dictionary) -> Array:
	var empty: RID = _buf(_zeros(_cc))
	var out: Array = []
	for name: String in table:
		out.append([int(table[name]), override.get(name, empty)])
	return out


## Run the operator N times, alternating in/out the way the driver's ping-pong does, and check the total
## after each. Reports the FIRST step that diverges, because a compounding defect is invisible in one.
func _check_tracer_steps(n: int, wind_m_s: float, vy_m_s: float, with_solid: bool, tag: String) -> void:
	var sf = load(TRACER)
	if sf == null:
		_failures.append({"check": tag, "reason": "kernel did not load"}); return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var mass: PackedFloat32Array = _seed_mass()
	var solid: PackedFloat32Array = _zeros(_cc)
	if with_solid:
		for c in _cc:
			if (c % _depth) < 2:
				solid[c] = 1.0
	var before: float = _sum(mass)

	var half: Array = [_buf(mass), _buf(_zeros(_cc))]
	var b_dep: RID = _buf(_zeros(_cc))
	var b_solid: RID = _buf(solid)
	var wind: PackedFloat32Array = _zeros(_cc)
	var vyf: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		wind[i] = wind_m_s * (1.0 if (i % 3) == 0 else 0.4)
		vyf[i] = vy_m_s * (1.0 if (i % 2) == 0 else 0.55)
	var b_vx: RID = _buf(wind)
	var b_vy: RID = _buf(vyf)
	var b_vz: RID = _buf(wind)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_ltan: RID = _buf(_grid.link_tan)
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())
	var b_shell: RID = _shell_buf()
	var b_cvol: RID = _cvol_buf()

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, _depth)
	pc.encode_float(8, 0.032)       # the live Courant factor
	pc.encode_float(12, 0.0052)     # o2's settling velocity
	pc.encode_float(16, 0.02)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_float(28, 0.0)
	pc.encode_float(32, 8.0)

	var groups: int = int(ceil(float(_cc) / 64.0))
	var live: int = 0
	for step in n:
		var back: int = 1 - live
		var uset: RID = _uset(shader, [[0, half[live]], [1, half[back]], [2, b_dep], [3, b_solid],
			[4, b_vx], [5, b_vy], [6, b_vz], [15, b_nbr], [16, b_ltan], [17, b_part], [39, b_shell],
			[40, b_cvol]])
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		var now: float = _sum(_read(half[back]))
		var rel: float = absf(now - before) / maxf(before, 1e-9)
		if rel > TOLERANCE:
			_checks += 1
			_failures.append({"check": tag, "first_bad_step": step, "want": before, "got": now})
			return
		live = back
	_expect(true, tag, before, before)


## The same ping-pong at the SHIPPED planet's dimensions. The 4x4x6 grid has 8 bent seam links; the live one
## has 48, and a defect that only shows at the live seam count is invisible on the small grid.
func _check_live_grid() -> void:
	var small_grid: RefCounted = _grid
	var small_cc: int = _cc
	_grid = LASphereGrid.new()
	_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO)
	_cc = _grid.cell_count
	_depth = LIVE_DEPTH
	var v: Dictionary = _grid.validate()
	_expect(bool(v.get("ok", false)), "live_grid.validate", 1.0, 1.0 if bool(v.get("ok", false)) else 0.0)
	_check_tracer_steps(20, 160.0, 300.0, true, "pingpong_20_live_grid")
	_grid = small_grid
	_cc = small_cc
	_depth = DEPTH


## A uniform build must reproduce the scalar grid EXACTLY, or every number recorded before the shell table
## existed is incomparable with every number after it. Checked in float32, which is what the GPU reads.
func _check_uniform_identity() -> void:
	var core_r: float = float(_grid.core_radius)
	var cs: float = float(_grid.cell_size)
	var bad_mid: int = 0
	var bad_dr: int = 0
	for r in int(_grid.depth):
		var want_mid: PackedFloat32Array = PackedFloat32Array([core_r + (float(r) + 0.5) * cs])
		if _grid.shell_mid[r] != want_mid[0]:
			bad_mid += 1
		if _grid.shell_dr[r] != cs or _grid.shell_d_in[r] != cs or _grid.shell_d_out[r] != cs:
			bad_dr += 1
	_expect(bad_mid == 0, "uniform.shell_mid_identical", 0.0, float(bad_mid))
	_expect(bad_dr == 0, "uniform.shell_dr_identical", 0.0, float(bad_dr))
	var span: float = float(_grid.shell_span())
	_expect(span == float(_grid.depth) * cs, "uniform.span_identical", float(_grid.depth) * cs, span)


## The shell table as the kernels see it. Rebuilt per grid, because `_grid` is swapped by the live/graded arms.
func _shell_buf() -> RID:
	return _buf(_grid.shell_table())


## Per-cell volume as the kernels see it. Rebuilt per grid, for the same reason as the shell table.
func _cvol_buf() -> RID:
	return _buf(_grid.cell_volumes())


## GRADED SHELLS. A gather that conserves at constant spacing can still leak when the radial runs differ, so
## every transport arm is re-run on a profile whose thickest shell is 4x its thinnest.
func _check_graded_grid() -> void:
	var small_grid: RefCounted = _grid
	var small_cc: int = _cc
	var small_depth: int = _depth
	var profile: PackedFloat32Array = LASphereGridProfiles.surface_focus(LIVE_DEPTH, 8.0, LIVE_DEPTH / 2)
	_expect(profile.size() == LIVE_DEPTH, "graded_grid.profile_built", float(LIVE_DEPTH),
		float(profile.size()))
	if profile.size() != LIVE_DEPTH:
		_grid = small_grid
		return
	_grid = LASphereGrid.new()
	_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO, profile)
	_cc = _grid.cell_count
	_depth = LIVE_DEPTH
	var v: Dictionary = _grid.validate()
	_expect(bool(v.get("ok", false)), "graded_grid.validate", 1.0,
		1.0 if bool(v.get("ok", false)) else 0.0)
	_expect(not bool(v.get("shells_uniform", true)), "graded_grid.is_graded", 1.0,
		0.0 if bool(v.get("shells_uniform", true)) else 1.0)
	_expect(absf(float(v.get("shell_span", 0.0)) - float(LIVE_DEPTH) * 8.0) < 1e-3,
		"graded_grid.span_preserved", float(LIVE_DEPTH) * 8.0, float(v.get("shell_span", 0.0)))
	_check_two_pass(GRAVITY_FLOW, "gravity_flow_graded", _pc_gravity())
	_check_tracer(0.0, true, "graded_still_solid")
	_check_tracer(160.0, true, "graded_gale_solid")
	_check_tracer(0.0, true, "graded_updraft_solid", 300.0)
	_check_tracer_steps(20, 160.0, 300.0, true, "graded_pingpong_20")
	_grid = small_grid
	_cc = small_cc
	_depth = small_depth


## Sum of the channel weighted by each cell's own volume — the amount of matter present.
func _volume_weighted(a: PackedFloat32Array) -> float:
	var t: float = 0.0
	var vol: PackedFloat32Array = _grid.cell_volumes()
	for i in a.size():
		t += a[i] * vol[i]
	return t


func _uset(shader: RID, binds: Array) -> RID:
	var us: Array = []
	for b in binds:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(b[0])
		u.add_id(b[1])
		us.append(u)
	return _rd.uniform_set_create(us, shader, 0)


func _pc_gravity() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, _depth)
	pc.encode_float(12, 0.25)       # max_flow
	pc.encode_float(16, 1e-5)       # min_flow
	pc.encode_float(20, 1e-4)       # min_mass
	pc.encode_float(24, 0.25)       # lateral_frac
	pc.encode_float(28, 0.0)        # repose_tan: level out freely
	pc.encode_float(32, _rc_gain_water())
	return pc


## Heat capacity a cell gains per unit fill of liquid water, J/m3K: the water's own capacity less the air it
## displaces. Same quantity WaterSlumpLavaPass.rc_gain hands the kernel in the live sim.
func _rc_gain_water() -> float:
	return LAHeatCapacity.mix(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0) \
		- LAHeatCapacity.mix(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


## Absolute enthalpy of the whole grid, J: each cell's volumetric heat capacity from its own composition,
## times its temperature in KELVIN, times its own volume. Kelvin rather than Celsius on purpose — a Celsius
## total is blind to a transfer that also loses or invents heat CAPACITY.
func _energy(ch: Dictionary, temp: PackedFloat32Array) -> float:
	var rc: PackedFloat64Array = LAHeatCapacity.field(ch, _cc)
	var vol: PackedFloat32Array = _grid.cell_volumes()
	var e: float = 0.0
	for i in _cc:
		e += rc[i] * (float(temp[i]) + LAPhysical.KELVIN_OFFSET) * vol[i]
	return e


## How many cells the operator actually changed the temperature of. A conservation check that passes because
## nothing moved is not a check, so every energy arm asserts this is nonzero.
func _moved(a: PackedFloat32Array, b: PackedFloat32Array) -> int:
	var n: int = 0
	for i in a.size():
		if absf(a[i] - b[i]) > 1e-4:
			n += 1
	return n


## GRAVITY FLOW moves water, sediment and lava, and every one of those carries its heat. The cells differ in
## composition AND in temperature, so a mix weighted by the moving mass alone (which is what this did) hands
## the receiving cell the donor's temperature and throws the rest of the cell's heat away.
func _check_flow_energy(label: String) -> void:
	var sf = load(GRAVITY_FLOW)
	if sf == null:
		_failures.append({"check": label + ".energy", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)

	# Water fills that leave room for air at every cell, so the arriving water displaces air rather than
	# saturating rc_of()'s clamp — the regime the substrate is meant to run in.
	var mass: PackedFloat32Array = _zeros(_cc)
	var temp: PackedFloat32Array = _zeros(_cc)
	var rock: PackedFloat32Array = _zeros(_cc)
	# Cold aloft, hot at depth, and the flow is downward — so a mix that gets the receiver's heat capacity
	# wrong is wrong in ONE direction everywhere and cannot cancel itself across the grid.
	for i in _cc:
		mass[i] = 0.35 if (i % 37) == 0 else 0.10
		temp[i] = 90.0 - 15.0 * float(i % _depth) + 4.0 * float((i * 7) % 5)
		rock[i] = 0.50
	var phi: PackedFloat32Array = _zeros(_cc)
	var ch: Dictionary = {"water": mass, "rock_fill": rock, "porosity": phi}
	var before_e: float = _energy(ch, temp)

	var b_in: RID = _buf(mass)
	var b_out: RID = _buf(_zeros(_cc))
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_send_h: RID = _buf(_zeros(_cc * 6))
	var b_solid: RID = _buf(_zeros(_cc))
	var b_temp: RID = _buf(temp)
	var b_rock: RID = _buf(rock)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_larc: RID = _buf(_grid.link_arc)
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())

	var binds: Array = [[0, b_in], [1, b_out], [2, b_send], [3, b_solid], [4, b_send_h], [5, b_temp],
		[15, b_nbr], [16, b_larc], [17, b_part], [39, _shell_buf()], [40, _cvol_buf()]]
	binds.append_array(_rc_binds(GRAVITY_FLOW_RC, {"water": b_in, "rock_fill": b_rock}))

	var groups: int = int(ceil(float(_cc) / 64.0))
	for pass_id in 2:
		var uset: RID = _uset(shader, binds)
		var pc: PackedByteArray = _pc_gravity()
		pc.encode_u32(4, pass_id)
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()

	var mass2: PackedFloat32Array = _read(b_out)
	var temp2: PackedFloat32Array = _read(b_temp)
	var after_e: float = _energy({"water": mass2, "rock_fill": rock, "porosity": phi}, temp2)
	var rel: float = absf(after_e - before_e) / maxf(absf(before_e), 1e-9)
	_expect(rel <= TOLERANCE, label + ".energy_conserved", before_e, after_e)
	var moved: int = _moved(temp, temp2)
	_expect(moved > 0, label + ".heat_actually_moved", 1.0, float(moved))
	_volume_notes[label + "_energy"] = snappedf(100.0 * (after_e - before_e) / maxf(absf(before_e), 1e-9),
		0.000001)
	var mass_before: float = _volume_weighted(mass)
	var relm: float = absf(_volume_weighted(mass2) - mass_before) / maxf(mass_before, 1e-9)
	_expect(relm <= TOLERANCE, label + ".energy_arm_matter_conserved", mass_before,
		_volume_weighted(mass2))


## THE AQUIFER. Regolith at the two inner shells with a lateral head gradient, so the Darcy leg runs between
## rock cells at different temperatures, and open cells above it so the spring and infiltration legs run too.
func _check_soil_energy(label: String) -> void:
	var sf = load(SOIL)
	if sf == null:
		_failures.append({"check": label + ".energy", "reason": "kernel did not load"})
		return
	var spirv: RDShaderSPIRV = sf.get_spirv()
	var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err.is_empty():
		_failures.append({"check": label + ".energy", "reason": "compile: " + err})
		return
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	var pipe: RID = _rd.compute_pipeline_create(shader)

	var regolith: PackedFloat32Array = _zeros(_cc)
	var solid: PackedFloat32Array = _zeros(_cc)
	var soil: PackedFloat32Array = _zeros(_cc)
	var water: PackedFloat32Array = _zeros(_cc)
	var rock: PackedFloat32Array = _zeros(_cc)
	var grain: PackedFloat32Array = _zeros(_cc)
	var temp: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		var r: int = i % _depth
		temp[i] = 4.0 + 50.0 * float((i * 13) % 17) / 16.0
		if r < 2:
			regolith[i] = 1.0
			solid[i] = 1.0
			rock[i] = 1.0
			grain[i] = 2.0e-3                          # gravel: enough conductivity to move real water
			soil[i] = 0.05 + 0.30 * float((i * 5) % 7) / 6.0
		elif r == 2:
			water[i] = 0.6 if (i % 3) == 0 else 0.05   # surface water to infiltrate, and springs to land in

	var b_water: RID = _buf(water)
	var b_solid: RID = _buf(solid)
	var b_send_h: RID = _buf(_zeros(_cc * 6))
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_soil_in: RID = _buf(soil)
	var b_soil_out: RID = _buf(_zeros(_cc))
	var b_reg: RID = _buf(regolith)
	var b_temp: RID = _buf(temp)
	var b_grain: RID = _buf(grain)
	var b_dbg: RID = _buf(_zeros(_cc * 21))
	var b_phi: RID = _buf(_zeros(_cc))
	var b_rock: RID = _buf(rock)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())

	var binds: Array = [[0, b_water], [1, b_solid], [2, b_send_h], [3, b_send], [4, b_soil_in],
		[5, b_soil_out], [6, b_reg], [7, b_temp], [8, b_grain], [9, b_dbg], [11, b_phi],
		[15, b_nbr], [17, b_part], [39, _shell_buf()], [40, _cvol_buf()]]
	binds.append_array(_rc_binds(SOIL_RC, {"rock_fill": b_rock}))

	var groups: int = int(ceil(float(_cc) / 64.0))
	var uset: RID = _uset(shader, binds)
	var phi_out: PackedFloat32Array = _zeros(_cc)
	for pass_id in 2:
		var pc: PackedByteArray = _pc_soil(pass_id)
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		if pass_id == 0:
			# The kernel publishes phi in pass 0, and rc_of() reads it. Both totals must be taken against
			# the SAME porosity, so the baseline waits for it.
			phi_out = _read(b_phi)

	var soil2: PackedFloat32Array = _read(b_soil_out)
	var water2: PackedFloat32Array = _read(b_water)
	var temp2: PackedFloat32Array = _read(b_temp)
	var before_e: float = _energy({"soil": soil, "water": water, "rock_fill": rock,
		"porosity": phi_out}, temp)
	var after_e: float = _energy({"soil": soil2, "water": water2, "rock_fill": rock,
		"porosity": phi_out}, temp2)
	var rel: float = absf(after_e - before_e) / maxf(absf(before_e), 1e-9)
	_expect(rel <= TOLERANCE, label + ".energy_conserved", before_e, after_e)

	# H2O is soil + surface water: a spring moves the same molecules from one channel to the other.
	var h2o_before: float = _volume_weighted(soil) + _volume_weighted(water)
	var h2o_after: float = _volume_weighted(soil2) + _volume_weighted(water2)
	var relm: float = absf(h2o_after - h2o_before) / maxf(h2o_before, 1e-9)
	_expect(relm <= TOLERANCE, label + ".matter_conserved", h2o_before, h2o_after)
	var moved: int = _moved(temp, temp2)
	_expect(moved > 0, label + ".heat_actually_moved", 1.0, float(moved))
	_volume_notes[label + "_energy"] = snappedf(100.0 * (after_e - before_e) / maxf(absf(before_e), 1e-9),
		0.000001)


## std430: 4x uint (cell_count, pass_id, depth, pad) then 3x float (lat_size, shell_m, step_s).
func _pc_soil(pass_id: int) -> PackedByteArray:
	var out: PackedByteArray = PackedInt32Array([_cc, pass_id, _depth, 0]).to_byte_array()
	out.append_array(PackedFloat32Array([8.0, 50.0, 3600.0]).to_byte_array())
	return out


func _pc_erosion() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 1)             # enabled
	pc.encode_u32(12, 0)
	return pc


## AIR, over every grid the other arms use. The wind pass is the only writer of that channel.
func _check_wind_air_all() -> void:
	var small_grid: RefCounted = _grid
	var small_cc: int = _cc
	var small_depth: int = _depth
	_check_wind_air(8, 160.0, "wind_air", false)
	_grid = LASphereGrid.new()
	_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO)
	_cc = _grid.cell_count
	_depth = LIVE_DEPTH
	_check_wind_air(8, 160.0, "wind_air_live_grid", true)
	var profile: PackedFloat32Array = LASphereGridProfiles.surface_focus(LIVE_DEPTH, 8.0, LIVE_DEPTH / 2)
	if profile.size() == LIVE_DEPTH:
		_grid = LASphereGrid.new()
		_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO, profile)
		_cc = _grid.cell_count
		_depth = LIVE_DEPTH
		_check_wind_air(8, 160.0, "wind_air_graded", false)
	_grid = small_grid
	_cc = small_cc
	_depth = small_depth


## Step 0 seeds the standard atmosphere; every step after it only moves air between columns and re-settles
## each column, so the volume-weighted total may not move. Run with a gale, because the lateral exchange is
## the half that carries a direction and the diffusive half is symmetric with no wind at all.
func _check_wind_air(steps: int, wind_m_s: float, tag: String, check_scale: bool) -> void:
	var sf = load(WIND_PRESSURE)
	if sf == null:
		_failures.append({"check": tag, "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)
	var columns: int = _cc / _depth
	var sea_shell: int = _depth / 2
	var sea_radius: float = float(_grid.shell_face[sea_shell])
	var temp: PackedFloat32Array = PackedFloat32Array()
	temp.resize(_cc)
	temp.fill(15.0)
	var vx: PackedFloat32Array = _zeros(_cc)
	var vz: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		vx[i] = wind_m_s * (1.0 if (i % 3) == 0 else -0.4)
		vz[i] = wind_m_s * (0.3 if (i % 5) == 0 else 0.8)

	var half: Array = [_buf(_zeros(_cc)), _buf(_zeros(_cc))]
	var b_temp: RID = _buf(temp)
	var b_solid: RID = _buf(_wind_terrain(sea_shell))
	var b_press: RID = _buf(_zeros(_cc))
	var b_vx: RID = _buf(vx)
	var b_vz: RID = _buf(vz)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())
	var b_ltan: RID = _buf(_grid.link_tan)
	var b_larc: RID = _buf(_grid.link_arc)
	var b_shell: RID = _shell_buf()
	var b_cvol: RID = _cvol_buf()

	var groups: int = int(ceil(float(columns) / 64.0))
	var live: int = 0
	var seeded: float = 0.0
	var last: float = 0.0
	for step in steps + 1:
		var back: int = 1 - live
		var uset: RID = _uset(shader, [[0, half[live]], [1, half[back]], [2, b_temp], [3, b_solid],
			[4, b_press], [5, b_vx], [6, b_vz], [15, b_nbr], [16, b_ltan], [17, b_part], [41, b_larc],
			[39, b_shell], [40, b_cvol]])
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, _pc_wind(columns, sea_radius, step),
			_pc_wind(columns, sea_radius, step).size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		last = _sum(_read(half[back]))
		if step == 0:
			seeded = last
			_expect(seeded > 0.0, tag + ".seeded", 1.0, seeded)
			if check_scale:
				_check_wind_pressure_scale(_read(b_press), tag)
		else:
			var rel: float = absf(last - seeded) / maxf(seeded, 1e-9)
			if rel > TOLERANCE:
				_checks += 1
				_failures.append({"check": tag, "first_bad_step": step, "want": seeded, "got": last})
				return
		live = back
	_expect(true, tag, seeded, last)
	_volume_notes[tag] = snappedf(100.0 * (last - seeded) / maxf(seeded, 1e-9), 0.0001)


## A crust with relief: the rock top varies by column, some columns stand above the sea shell and some below
## it, and one in seven carries a rock lid with open air beneath. Neighbouring columns then start their
## atmospheres at different shells, which is the case a column-walking kernel gets wrong.
func _wind_terrain(sea_shell: int) -> PackedFloat32Array:
	var solid: PackedFloat32Array = _zeros(_cc)
	var columns: int = _cc / _depth
	for s in columns:
		var top: int = sea_shell + (s % 3) - 1
		for r in _depth:
			if r <= top:
				solid[s * _depth + r] = 1.0
		if (s % 7) == 0 and top + 3 < _depth:
			solid[s * _depth + top + 3] = 1.0
	return solid


## The seeded column weighs about one atmosphere at its floor. A bound, not a statement about the
## discretisation: it is what catches a model-unit length meeting a per-metre constant (168.6x) or a
## density floor standing in for the air (50x).
func _check_wind_pressure_scale(press: PackedFloat32Array, tag: String) -> void:
	var hi: float = 0.0
	for i in press.size():
		hi = maxf(hi, press[i])
	var lo_bound: float = 0.5 * LAPhysical.STANDARD_PRESSURE_PA
	var hi_bound: float = 1.5 * LAPhysical.STANDARD_PRESSURE_PA
	_expect(hi > lo_bound and hi < hi_bound, tag + ".surface_pressure_one_atm",
		LAPhysical.STANDARD_PRESSURE_PA, hi)


## std430: {uint surf_count, uint depth, float sea_radius, float dt, uint step_index, 3x pad}.
func _pc_wind(columns: int, sea_radius: float, step_index: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, columns)
	pc.encode_u32(4, _depth)
	pc.encode_float(8, sea_radius)
	pc.encode_float(12, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	pc.encode_u32(16, step_index)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc


## Sum of a MINERAL total, volume weighted: `rock_fill` is a saturation of the cell's rock matrix, so the
## mineral in it is the pore-free share, exactly as rc_of() and LAHeatCapacity read it.
func _mineral_total(rock: PackedFloat32Array, phi: PackedFloat32Array,
		loose: PackedFloat32Array) -> float:
	var vol: PackedFloat32Array = _grid.cell_volumes()
	var t: float = 0.0
	for i in _cc:
		t += (rock[i] * (1.0 - clampf(phi[i], 0.0, 1.0)) + loose[i]) * vol[i]
	return t


## Per-cell world vectors as the kernels read them: flat c*3 + {0,1,2}.
func _vec3_buf(fn: Callable) -> RID:
	var a: PackedFloat32Array = _zeros(_cc * 3)
	for c in _cc:
		var v: Vector3 = fn.call(c)
		a[c * 3 + 0] = v.x
		a[c * 3 + 1] = v.y
		a[c * 3 + 2] = v.z
	return _buf(a)


func _dispatch(pipe: RID, uset: RID, pc: PackedByteArray, groups: int) -> void:
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, pipe)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()


## Both halves of an energy arm's verdict: the drift, and proof the operator moved heat at all. A
## conservation check that passes because nothing happened is not a check.
func _expect_energy(label: String, before_e: float, after_e: float, temp: PackedFloat32Array,
		temp2: PackedFloat32Array) -> void:
	var rel: float = absf(after_e - before_e) / maxf(absf(before_e), 1e-9)
	_expect(rel <= TOLERANCE, label + ".energy_conserved", before_e, after_e)
	var moved: int = _moved(temp, temp2)
	_expect(moved > 0, label + ".heat_actually_moved", 1.0, float(moved))
	_volume_notes[label + "_energy"] = snappedf(100.0 * (after_e - before_e) / maxf(absf(before_e), 1e-9),
		0.000001)


## THE SUSPENDED LOAD. Mineral riding the water between cells at different temperatures. The temperature ramp
## runs across the COLUMNS while the head drives the load radially inward, so a wrong receiver weight is
## wrong in one direction everywhere and cannot cancel across the grid.
func _check_erosion_transport_energy(label: String) -> void:
	var sf = load(EROSION)
	if sf == null:
		_failures.append({"check": label + ".energy", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)

	var susp: PackedFloat32Array = _zeros(_cc)
	var water: PackedFloat32Array = _zeros(_cc)
	var rock: PackedFloat32Array = _zeros(_cc)
	var phi: PackedFloat32Array = _zeros(_cc)
	var temp: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		susp[i] = 0.02 + 0.06 * float((i * 11) % 5) / 4.0
		water[i] = 0.15 + 0.35 * float((i * 3) % 4) / 3.0
		rock[i] = 0.20
		temp[i] = 5.0 + 3.0 * float((i / _depth) % 11) + 0.5 * float(i % _depth)
	var ch: Dictionary = {"susp": susp, "water": water, "rock_fill": rock, "porosity": phi}
	var before_e: float = _energy(ch, temp)

	var b_in: RID = _buf(susp)
	var b_out: RID = _buf(_zeros(_cc))
	var b_water: RID = _buf(water)
	var b_solid: RID = _buf(_zeros(_cc))
	var b_send_h: RID = _buf(_zeros(_cc * 6))
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_temp: RID = _buf(temp)
	var b_rock: RID = _buf(rock)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())

	var binds: Array = [[0, b_in], [1, b_out], [2, b_water], [3, b_solid], [4, b_send_h], [5, b_send],
		[6, b_temp], [15, b_nbr], [17, b_part], [40, _cvol_buf()]]
	binds.append_array(_rc_binds(EROSION_RC, {"water": b_water, "susp": b_in, "rock_fill": b_rock}))
	var uset: RID = _uset(shader, binds)

	var groups: int = int(ceil(float(_cc) / 64.0))
	for pass_id in 2:
		var pc: PackedByteArray = _pc_erosion()
		pc.encode_u32(4, pass_id)
		_dispatch(pipe, uset, pc, groups)

	var susp2: PackedFloat32Array = _read(b_out)
	var temp2: PackedFloat32Array = _read(b_temp)
	var after_e: float = _energy({"susp": susp2, "water": water, "rock_fill": rock, "porosity": phi},
		temp2)
	_expect_energy(label, before_e, after_e, temp, temp2)
	var m_before: float = _volume_weighted(susp)
	var m_after: float = _volume_weighted(susp2)
	_expect(absf(m_after - m_before) / maxf(m_before, 1e-9) <= TOLERANCE,
		label + ".energy_arm_matter_conserved", m_before, m_after)


## THE SCOUR. Bedrock lifted out of the bed cell below and put into suspension in the cell above: mineral
## crosses a cell boundary, so its enthalpy has to cross with it. The bed is porous, which is the case that
## separates the rock MATRIX saturation from the mineral actually in it.
func _check_erosion_pickup_energy(label: String) -> void:
	var sf = load(EROSION_PICKUP)
	if sf == null:
		_failures.append({"check": label + ".energy", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)

	var solid: PackedFloat32Array = _zeros(_cc)
	var rock: PackedFloat32Array = _zeros(_cc)
	var phi: PackedFloat32Array = _zeros(_cc)
	var water: PackedFloat32Array = _zeros(_cc)
	var susp: PackedFloat32Array = _zeros(_cc)
	var temp: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		var r: int = i % _depth
		# The scour is purely radial, so the contrast that has to be carried is the bed's: hot rock under
		# cool surface water. The lateral ramp on top of it keeps the error from cancelling across columns.
		temp[i] = 5.0 + 3.0 * float((i / _depth) % 11) + (60.0 if r < 2 else 0.5 * float(r))
		if r < 2:
			solid[i] = 1.0
			rock[i] = 1.0
			phi[i] = 0.40
		else:
			water[i] = 0.10 + 0.50 * float((i * 3) % 4) / 3.0
			susp[i] = 0.01
	var before_e: float = _energy({"rock_fill": rock, "susp": susp, "water": water, "porosity": phi},
		temp)
	var m_before: float = _mineral_total(rock, phi, susp)

	var b_water: RID = _buf(water)
	var b_solid: RID = _buf(solid)
	var b_temp: RID = _buf(temp)
	var b_rock: RID = _buf(rock)
	var b_susp: RID = _buf(susp)
	var b_phi: RID = _buf(phi)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())

	var binds: Array = [[0, b_water], [1, b_solid], [2, b_temp], [3, b_rock], [4, b_susp],
		[15, b_nbr], [40, _cvol_buf()]]
	binds.append_array(_rc_binds(PICKUP_RC, {"porosity": b_phi}))
	var uset: RID = _uset(shader, binds)

	_dispatch(pipe, uset, PackedInt32Array([_cc, 0, 0, 0]).to_byte_array(),
		int(ceil(float(_cc) / 64.0)))

	var rock2: PackedFloat32Array = _read(b_rock)
	var susp2: PackedFloat32Array = _read(b_susp)
	var temp2: PackedFloat32Array = _read(b_temp)
	var after_e: float = _energy({"rock_fill": rock2, "susp": susp2, "water": water, "porosity": phi},
		temp2)
	_expect_energy(label, before_e, after_e, temp, temp2)
	var m_after: float = _mineral_total(rock2, phi, susp2)
	_expect(absf(m_after - m_before) / maxf(m_before, 1e-9) <= TOLERANCE,
		label + ".mineral_conserved", m_before, m_after)


## THE CRUST. Plate motion carries the slab laterally and uplifts the surplus a shell outward, then the rock
## evicts the water it closed over. Every one of those moves matter between cells, so all of them carry heat.
## Porosity steps between shells, so the mineral a unit of `rock_fill` stands for differs across the up-flux.
func _check_plate_advect_energy(label: String) -> void:
	var sf = load(PLATE_ADVECT)
	if sf == null:
		_failures.append({"check": label + ".energy", "reason": "kernel did not load"})
		return
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var pipe: RID = _rd.compute_pipeline_create(shader)

	var rock: PackedFloat32Array = _zeros(_cc)
	var phi: PackedFloat32Array = _zeros(_cc)
	var water: PackedFloat32Array = _zeros(_cc)
	var temp: PackedFloat32Array = _zeros(_cc)
	for i in _cc:
		var r: int = i % _depth
		rock[i] = 0.55 + 0.25 * float((i * 5) % 3) / 2.0
		phi[i] = 0.40 if r < 3 else 0.10
		water[i] = 0.05
		temp[i] = 5.0 + 3.0 * float((i / _depth) % 11) + 0.5 * float(r)
	var before_e: float = _energy({"rock_fill": rock, "water": water, "porosity": phi}, temp)
	var m_before: float = _mineral_total(rock, phi, _zeros(_cc))
	var w_before: float = _volume_weighted(water)

	# ONE plate: a Voronoi seed the whole sphere resolves to, and an Euler pole it turns about.
	var plates: PackedFloat32Array = _zeros(8)
	plates[2] = 1.0
	plates[3] = 1.0e-2
	plates[5] = 1.0

	var b_rock: RID = _buf(rock)
	var b_send: RID = _buf(_zeros(_cc * 6))
	var b_send_h: RID = _buf(_zeros(_cc * 6))
	var b_temp: RID = _buf(temp)
	var b_water: RID = _buf(water)
	var b_phi: RID = _buf(phi)
	var b_plates: RID = _buf(plates)
	var b_nbr: RID = _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
		_grid.neighbours.to_byte_array())
	var b_part: RID = _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
		_grid.link_partner.to_byte_array())

	var binds: Array = [[0, b_rock], [1, b_send], [2, _vec3_buf(_grid.cell_radial)],
		[3, _vec3_buf(_grid.cell_world_pos)], [4, b_nbr], [5, b_plates], [6, b_water], [7, b_rock],
		[8, b_send_h], [9, b_temp], [17, b_part], [39, _shell_buf()], [40, _cvol_buf()]]
	binds.append_array(_rc_binds(PLATE_RC, {"porosity": b_phi}))
	var uset: RID = _uset(shader, binds)

	var groups: int = int(ceil(float(_cc) / 64.0))
	for pass_id in [0, 1]:
		_dispatch(pipe, uset, _pc_plate(pass_id, 1.0), groups)
	for pass_id in [2, 3]:
		_dispatch(pipe, uset, _pc_plate(pass_id, 0.0), groups)

	var rock2: PackedFloat32Array = _read(b_rock)
	var water2: PackedFloat32Array = _read(b_water)
	var temp2: PackedFloat32Array = _read(b_temp)
	var after_e: float = _energy({"rock_fill": rock2, "water": water2, "porosity": phi}, temp2)
	_expect_energy(label, before_e, after_e, temp, temp2)
	var m_after: float = _mineral_total(rock2, phi, _zeros(_cc))
	_expect(absf(m_after - m_before) / maxf(m_before, 1e-9) <= TOLERANCE,
		label + ".mineral_conserved", m_before, m_after)
	var w_after: float = _volume_weighted(water2)
	_expect(absf(w_after - w_before) / maxf(w_before, 1e-9) <= TOLERANCE,
		label + ".displaced_water_conserved", w_before, w_after)


## std430: 4x uint (cell_count, pass_id, n_plates, depth) then 4x float (dt, lat_size, max_mass, pore_scale).
func _pc_plate(pass_id: int, pore_scale: float) -> PackedByteArray:
	var out: PackedByteArray = PackedInt32Array([_cc, pass_id, 1, _depth]).to_byte_array()
	out.append_array(PackedFloat32Array([1.0, 8.0, 0.70, pore_scale]).to_byte_array())
	return out


## THE MOMENTUM OPERATOR. Three properties, each falsifiable in one dispatch: it cannot amplify what it is
## given, its surface drag is the closed form the log law predicts, and a vector crossing a seam is rotated.
func _check_wind_momentum() -> void:
	var small_grid: RefCounted = _grid
	var small_cc: int = _cc
	var small_depth: int = _depth
	_grid = LASphereGrid.new()
	_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO)
	_cc = _grid.cell_count
	_depth = LIVE_DEPTH
	_check_link_rot_direction()
	_check_wind_bounded(12, 300.0)
	_check_wind_surface_drag(200.0)
	_check_wind_smagorinsky(120.0)
	_grid = small_grid
	_cc = small_cc
	_depth = small_depth


## link_rot carries MY tangent axes into the neighbour's, so reading the neighbour's velocity in MY axes is
## the INVERSE rotation. Checked against the world-space projection, which needs no table at all: the two
## agree to the curvature over one link, and a rotation applied the wrong way round is off by twice the arc.
func _check_link_rot_direction() -> void:
	var grid: LASphereGrid = _grid
	var worst: float = 0.0
	var arc_max: float = 0.0
	var checked: int = 0
	for s in range(0, grid.surf_count, 7):
		for l in 4:
			var m_surf: int = -1
			for g in 4:
				if grid.lateral_slot[s * 4 + g] == l:
					m_surf = grid.surf_nbr[s * 4 + g]
			if m_surf < 0:
				continue
			# A velocity expressed in the NEIGHBOUR's axes, read back in mine two ways.
			var v: Vector2 = Vector2(3.0, -2.0)
			var world: Vector3 = grid.tan_a[m_surf] * v.x + grid.tan_b[m_surf] * v.y
			var want: Vector2 = Vector2(world.dot(grid.tan_a[s]), world.dot(grid.tan_b[s]))
			var cs: float = grid.link_rot[(s * 4 + l) * 2 + 0]
			var sn: float = grid.link_rot[(s * 4 + l) * 2 + 1]
			var got: Vector2 = Vector2(v.x * cs + v.y * sn, -v.x * sn + v.y * cs)
			worst = maxf(worst, (got - want).length() / v.length())
			arc_max = maxf(arc_max, float(grid.link_arc[s * 4 + l]))
			checked += 1
	_expect(checked > 0, "wind_link_rot.checked", 1.0, float(checked))
	# The residual is the sphere's curvature over one link. Applying the rotation the wrong way round leaves
	# twice the arc, which this bound is well inside.
	_expect(worst < arc_max, "wind_link_rot.inverse_is_the_transport", arc_max, worst)


## No forces, a violent alternating velocity field, and a Courant number an explicit scheme could not
## survive. The transport is a convex combination of a cell and its neighbours, so the field's largest speed
## can only shrink. An explicit gather amplifies it instead, which is what this arm is here to catch.
func _check_wind_bounded(steps: int, speed_m_s: float) -> void:
	var d: Dictionary = _wind_step_world(speed_m_s, false)
	if d.is_empty():
		return
	var start: float = _max_speed(d)
	for step in steps:
		_wind_step_dispatch(d, 0)
		var now: float = _max_speed(d)
		if now > start * 1.0001:
			_checks += 1
			_failures.append({"check": "wind_bounded", "first_bad_step": step, "want": start, "got": now})
			return
	_expect(true, "wind_bounded", start, _max_speed(d))
	_volume_notes["wind_bounded_end_over_start"] = snappedf(_max_speed(d) / maxf(start, 1e-9), 0.0001)


## Bulk aerodynamic drag against the closed form built here from LAPhysical alone: one implicit step of
## dv/dt = -C_d |v| v / h leaves v / (1 + C_d |v| dt / h). Read as the RATIO down a column, whose shells
## share one frame and one seeded speed, so the only difference left between them is the drag.
func _check_wind_surface_drag(speed_m_s: float) -> void:
	var d: Dictionary = _wind_step_world(speed_m_s, true)
	if d.is_empty():
		return
	var ground_shell: int = int(d["ground"])
	var col: int = int(d["probe_col"])
	var v0: float = float(d["probe_speed"])
	var ground: int = col * _depth + ground_shell
	var above: int = ground + 1
	_wind_step_dispatch(d, 0)
	var vx: PackedFloat32Array = _read(d["vx"])
	var vz: PackedFloat32Array = _read(d["vz"])
	var h_m: float = float(_grid.shell_dr[ground_shell])
	var ln_r: float = log(0.5 * h_m / LAPhysical.ROUGHNESS_LENGTH_LAND_M)
	var cd: float = pow(LAPhysical.VON_KARMAN_CONSTANT / ln_r, 2.0)
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var want: float = 1.0 / (1.0 + cd * v0 / h_m * dt)
	var free: float = Vector2(vx[above], vz[above]).length()
	var got: float = Vector2(vx[ground], vz[ground]).length() / maxf(free, 1e-9)
	_expect(absf(got - want) / want < 1e-3, "wind_surface_drag.bulk_formula", want, got)
	# A world-uniform wind is the field the transport is supposed to leave alone; what it does not cancel is
	# the sphere's curvature over one link.
	_expect(absf(free - v0) / v0 < 0.01, "wind_surface_drag.free_air_holds", v0, free)
	_volume_notes["wind_drag_cd"] = snappedf(cd, 0.0000001)


## A world for wind_step alone: rock below the sea shell, air above, flat pressure and temperature so the
## only thing acting is the operator under test. `uniform` projects ONE world vector onto every column, the
## field a correct transport leaves alone; otherwise the sign alternates per cell, the hardest case to bound.
func _wind_step_world(speed_m_s: float, uniform: bool) -> Dictionary:
	var sf = load(WIND_PRESSURE.replace("wind_pressure", "wind_step"))
	if sf == null:
		_failures.append({"check": "wind_step", "reason": "kernel did not load"})
		return {}
	var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
	var ground_shell: int = _depth / 2
	var solid: PackedFloat32Array = _zeros(_cc)
	var air: PackedFloat32Array = _zeros(_cc)
	var vx: PackedFloat32Array = _zeros(_cc)
	var vz: PackedFloat32Array = _zeros(_cc)
	var world: Vector3 = Vector3(1, 0, 0) * speed_m_s
	var probe_col: int = 0
	var probe_speed: float = 0.0
	for c in _cc:
		var r: int = c % _depth
		if r < ground_shell:
			solid[c] = 1.0
			continue
		air[c] = 1.0
		if uniform:
			vx[c] = world.dot(_grid.tangent_a(c))
			vz[c] = world.dot(_grid.tangent_b(c))
			var sp: float = Vector2(vx[c], vz[c]).length()
			if sp > probe_speed:
				probe_speed = sp
				probe_col = c / _depth
		else:
			vx[c] = speed_m_s if (c % 2) == 0 else -speed_m_s
			vz[c] = speed_m_s if (c % 3) == 0 else -speed_m_s
	var flat: PackedFloat32Array = _zeros(_cc)
	flat.fill(LAPhysical.STANDARD_PRESSURE_PA)
	var radial: PackedFloat32Array = PackedFloat32Array()
	radial.resize(_cc * 3)
	for c in _cc:
		var n: Vector3 = _grid.cell_radial(c)
		radial[c * 3 + 0] = n.x
		radial[c * 3 + 1] = n.y
		radial[c * 3 + 2] = n.z
	var out: Dictionary = {
		"shader": shader, "pipe": _rd.compute_pipeline_create(shader),
		"vx": _buf(vx), "vy": _buf(_zeros(_cc)), "vz": _buf(vz),
		"press": _buf(flat), "temp": _buf(_zeros(_cc)), "solid": _buf(solid), "air": _buf(air),
		"water": _buf(_zeros(_cc)), "radial": _buf(radial),
		"nbr": _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
			_grid.neighbours.to_byte_array()),
		"ltan": _buf(_grid.link_tan), "larc": _buf(_grid.link_arc), "lrot": _buf(_grid.link_rot),
		"shell": _shell_buf(), "ground": ground_shell,
		"probe_col": probe_col, "probe_speed": probe_speed}
	return out


func _wind_step_dispatch(d: Dictionary, buoy: int) -> void:
	var uset: RID = _uset(d["shader"], [[0, d["press"]], [1, d["temp"]], [2, d["solid"]], [3, d["vx"]],
		[4, d["vy"]], [5, d["vz"]], [6, d["air"]], [7, d["water"]], [14, d["radial"]], [15, d["nbr"]],
		[16, d["ltan"]], [41, d["larc"]], [43, d["lrot"]], [39, d["shell"]]])
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, _cc)
	pc.encode_float(4, LAMaterialFieldSphereStep3D.real_seconds_per_step())
	pc.encode_u32(8, buoy)
	pc.encode_float(12, 0.0)
	pc.encode_float(16, 1.0)
	pc.encode_float(20, 0.0)
	pc.encode_u32(24, _depth)
	pc.encode_u32(28, 0)
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, d["pipe"])
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, int(ceil(float(_cc) / 64.0)), 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()


func _max_speed(d: Dictionary) -> float:
	var vx: PackedFloat32Array = _read(d["vx"])
	var vy: PackedFloat32Array = _read(d["vy"])
	var vz: PackedFloat32Array = _read(d["vz"])
	var hi: float = 0.0
	for i in vx.size():
		hi = maxf(hi, Vector3(vx[i], vy[i], vz[i]).length())
	return hi


## THE SUBGRID VISCOSITY ITSELF: a quadratically sheared column has a second derivative for the mixing to
## act on, so one step must leave (v + w*(v_up + v_dn)) / (1 + 2w), w = nu*dt/dz^2, nu = (C_s*filter)^2*|dv/dy|.
## Every factor comes from LAPhysical and the grid, so a drifted coefficient or a wrong filter width shows.
func _check_wind_smagorinsky(scale_m_s: float) -> void:
	var d: Dictionary = _wind_step_shear(scale_m_s)
	if d.is_empty():
		return
	var col: int = int(d["probe_col"])
	var shell: int = int(d["probe_shell"])
	var cell: int = col * _depth + shell
	var before: PackedFloat32Array = d["seed_speed"]
	var v0: float = before[cell]
	var v_up: float = before[cell + 1]
	var v_dn: float = before[cell - 1]
	var dz: float = float(_grid.shell_dr[shell])
	var lat_mean: float = 0.0
	for l in 4:
		lat_mean += float(_grid.link_arc[col * 4 + l]) * float(_grid.shell_mid[shell])
	lat_mean *= 0.25
	var filter_m: float = pow(lat_mean * lat_mean * dz, 1.0 / 3.0)
	var dv_dy: float = absf(v_up - v_dn) / (2.0 * dz)
	var nu: float = pow(LAPhysical.SMAGORINSKY_COEFF * filter_m, 2.0) * dv_dy
	var w: float = nu * LAMaterialFieldSphereStep3D.real_seconds_per_step() / (dz * dz)
	var want: float = (v0 + w * (v_up + v_dn)) / (1.0 + 2.0 * w)
	_wind_step_dispatch(d, 0)
	var vx: PackedFloat32Array = _read(d["vx"])
	var vz: PackedFloat32Array = _read(d["vz"])
	var got: float = Vector2(vx[cell], vz[cell]).length()
	_expect(absf(got - want) / maxf(want, 1e-9) < 2.0e-3, "wind_smagorinsky.mixing_law", want, got)
	_volume_notes["wind_smagorinsky_nu_m2_s"] = snappedf(nu, 0.001)


## The same world as the drag arm, but the world-projected wind is scaled quadratically with the shell so the
## column carries both a shear and a curvature. Lateral neighbours still hold the same profile, so the only
## thing the operator can act on is the vertical.
func _wind_step_shear(scale_m_s: float) -> Dictionary:
	var d: Dictionary = _wind_step_world(scale_m_s, true)
	if d.is_empty():
		return d
	var ground_shell: int = int(d["ground"])
	var col: int = int(d["probe_col"])
	var span: float = maxf(float(_depth - 1 - ground_shell), 1.0)
	var vx: PackedFloat32Array = _zeros(_cc)
	var vz: PackedFloat32Array = _zeros(_cc)
	var speed: PackedFloat32Array = _zeros(_cc)
	for c in _cc:
		var r: int = c % _depth
		if r < ground_shell:
			continue
		var k: float = pow((float(r) - float(ground_shell)) / span, 2.0)
		vx[c] = _grid.tangent_a(c).dot(Vector3(1, 0, 0)) * scale_m_s * k
		vz[c] = _grid.tangent_b(c).dot(Vector3(1, 0, 0)) * scale_m_s * k
		speed[c] = Vector2(vx[c], vz[c]).length()
	_rd.buffer_update(d["vx"], 0, vx.to_byte_array().size(), vx.to_byte_array())
	_rd.buffer_update(d["vz"], 0, vz.to_byte_array().size(), vz.to_byte_array())
	d["seed_speed"] = speed
	# One shell above the parabola's vertex: both radial neighbours exist, the curvature there is twice the
	# local speed, and the surface layer's drag is one cell below and acting on nothing.
	d["probe_shell"] = ground_shell + 1
	d["probe_col"] = col
	return d


## THE EQUATION OF STATE. Two columns whose floors stand at the same altitude carry the same pressure there,
## so their densities must be in the INVERSE ratio of their temperatures — a form no discretisation or model
## top enters, and one a floor pinned to a fixed density reads as 1.0 whatever the temperatures are.
func _check_wind_eos() -> void:
	var small_grid: RefCounted = _grid
	var small_cc: int = _cc
	var small_depth: int = _depth
	_grid = LASphereGrid.new()
	_grid.build(LIVE_RES, LIVE_DEPTH, 170.0, 8.0, Vector3.ZERO)
	_cc = _grid.cell_count
	_depth = LIVE_DEPTH
	var sf = load(WIND_PRESSURE)
	if sf != null:
		var shader: RID = _rd.shader_create_from_spirv(sf.get_spirv())
		var pipe: RID = _rd.compute_pipeline_create(shader)
		var ground_shell: int = _depth / 2
		var cold_c: float = 0.0
		var warm_c: float = 40.0
		var solid: PackedFloat32Array = _zeros(_cc)
		var temp: PackedFloat32Array = _zeros(_cc)
		var columns: int = _cc / _depth
		for c in _cc:
			if (c % _depth) < ground_shell:
				solid[c] = 1.0
			temp[c] = cold_c if ((c / _depth) % 2) == 0 else warm_c
		var air_buf: RID = _buf(_zeros(_cc))
		var press: RID = _buf(_zeros(_cc))
		var uset: RID = _uset(shader, [[0, _buf(_zeros(_cc))], [1, air_buf], [2, _buf(temp)],
			[3, _buf(solid)], [4, press], [5, _buf(_zeros(_cc))], [6, _buf(_zeros(_cc))],
			[15, _rd.storage_buffer_create(_grid.neighbours.to_byte_array().size(),
				_grid.neighbours.to_byte_array())],
			[16, _buf(_grid.link_tan)],
			[17, _rd.storage_buffer_create(_grid.link_partner.to_byte_array().size(),
				_grid.link_partner.to_byte_array())],
			[41, _buf(_grid.link_arc)], [39, _shell_buf()], [40, _cvol_buf()]])
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, _pc_wind(columns, float(_grid.shell_face[ground_shell]), 0),
			32)
		_rd.compute_list_dispatch(cl, int(ceil(float(columns) / 64.0)), 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		var air: PackedFloat32Array = _read(air_buf)
		var cold: float = air[0 * _depth + ground_shell]
		var warm: float = air[1 * _depth + ground_shell]
		var want: float = (warm_c + LAPhysical.KELVIN_OFFSET) / (cold_c + LAPhysical.KELVIN_OFFSET)
		var got: float = cold / maxf(warm, 1e-9)
		_expect(absf(got - want) / want < 1e-3, "wind_eos.density_inverse_in_temperature", want, got)
		_volume_notes["wind_eos_density_ratio"] = snappedf(got, 0.00001)
	_grid = small_grid
	_cc = small_cc
	_depth = small_depth
