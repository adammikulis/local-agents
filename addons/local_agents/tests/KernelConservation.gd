class_name LAKernelConservation
extends Node


const GRAVITY_FLOW: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"
const TRACER: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"
const EROSION: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

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
## Per-arm volume-weighted drift, in percent. REPORTED, never asserted — see `_note_volume`.
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
	_check_live_grid()
	_check_graded_grid()

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


func _sum(a: PackedFloat32Array, solid: PackedFloat32Array) -> float:
	var t: float = 0.0
	for i in a.size():
		t += a[i]
	return t


## The kernels conserve the raw fill-fraction sum by construction. Weighted by each cell's own volume the
## same transfer moves a different amount of matter than it delivers, because a radial neighbour is a
## different size. That is a physics decision, not a kernel bug, so it is recorded rather than failed.
func _note_volume(label: String, before_arr: PackedFloat32Array, after_arr: PackedFloat32Array) -> void:
	var b: float = _volume_weighted(before_arr)
	var a: float = _volume_weighted(after_arr)
	_volume_notes[label] = snappedf(100.0 * (a - b) / maxf(absf(b), 1e-9), 0.0001)


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
	var before: float = _sum(mass, solid)

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
	var after: float = _sum(out_arr, solid)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, label + ".mass_conserved", before, after)
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
	var before: float = _sum(mass, solid)

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
		[39, _shell_buf()]])
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
	var after: float = _sum(out_arr, solid)
	var rel: float = absf(after - before) / maxf(before, 1e-9)
	_expect(rel <= TOLERANCE, "tracer_transport.mass_conserved." + tag, before, after)
	_note_volume(tag, mass, out_arr)


## erosion_transport carries a suspended LOAD on flowing water, so its bindings differ from gravity_flow's.
func _binds(label: String, b_in: RID, b_out: RID, b_send: RID, b_solid: RID, b_temp: RID,
		b_nbr: RID, b_larc: RID, b_part: RID) -> Array:
	if label == "erosion_transport":
		# 0=susp_in 1=susp_out 2=water 3=solid 5=send 15=nbr
		return [[0, b_in], [1, b_out], [2, b_temp], [3, b_solid], [5, b_send], [15, b_nbr],
			[17, b_part]]
	return [[0, b_in], [1, b_out], [2, b_send], [3, b_solid], [5, b_temp], [15, b_nbr], [16, b_larc],
		[17, b_part], [39, _shell_buf()]]


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
	var before: float = _sum(mass, solid)

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
			[4, b_vx], [5, b_vy], [6, b_vz], [15, b_nbr], [16, b_ltan], [17, b_part], [39, b_shell]])
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, pipe)
		_rd.compute_list_bind_uniform_set(cl, uset, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		var now: float = _sum(_read(half[back]), solid)
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


## GRADED SHELLS. A gather that conserves at constant spacing can still leak when the radial runs differ, so
## every transport arm is re-run on a profile whose thickest shell is 4x its thinnest. It also reports the
## VOLUME-WEIGHTED total: the channels are fill fractions, so a conserved fraction is not conserved matter.
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


## Sum of the channel weighted by each cell's own volume. The kernels conserve the UNWEIGHTED sum; this is
## what a conserved substance would have to hold, and the gap between them is reported, never asserted.
func _volume_weighted(a: PackedFloat32Array) -> float:
	var t: float = 0.0
	var vol: PackedFloat32Array = _grid.shell_vol
	for i in a.size():
		t += a[i] * vol[i % _depth]
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
	pc.resize(32)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, _depth)
	pc.encode_float(12, 0.25)       # max_flow
	pc.encode_float(16, 1e-5)       # min_flow
	pc.encode_float(20, 1e-4)       # min_mass
	pc.encode_float(24, 0.25)       # lateral_frac
	pc.encode_float(28, 0.0)        # repose_tan: level out freely
	return pc


func _pc_erosion() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, _cc)
	pc.encode_u32(4, 0)
	pc.encode_u32(8, 1)             # enabled
	pc.encode_u32(12, 0)
	return pc
