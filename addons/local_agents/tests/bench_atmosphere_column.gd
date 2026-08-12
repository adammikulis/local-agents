extends SceneTree


const PRESSURE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl"
const WIND_PATH: String = "res://addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl"

# Planet geometry — mirrors VoxelWorld.gd (PLANET_RADIUS 500 => PLANET_SCALE 2) and VoxelSettingsApplier
# (GRID_DEPTH 20), and SimWorld/VoxelWorld's grid.build(res, depth, 170*scale, 8*scale).
const CORE_RADIUS: float = 340.0
const CELL_SIZE: float = 16.0
const DEPTH: int = 20
const SEA_RADIUS: float = 500.0
const DT: float = 0.1
const SPIN_AXIS: Vector3 = Vector3(0.0, 1.0, 0.0)

# Analytic temperature field: an equator-to-pole gradient plus a lapse rate aloft. Both are the shapes the
# real field carries; using an analytic one makes the bench exactly repeatable so any spread reported here is
# the kernel's, not the weather's.
const T_EQUATOR_C: float = 30.0
const T_POLE_DROP_C: float = 55.0     # equator 30 C -> pole -25 C
const LAPSE_C_PER_UNIT: float = 0.25  # 40 C across the 160-unit atmosphere

# Latitude bins for the jet table, in degrees (absolute latitude; both hemispheres folded together after the
# zonal sign is taken, so a westerly in each hemisphere adds rather than cancels).
const LAT_EDGES: PackedFloat32Array = [0.0, 15.0, 30.0, 45.0, 60.0, 75.0, 90.0]

var _rd: RenderingDevice = null
var _grid: LASphereGrid = null
var _cc: int = 0
var _columns: int = 0
var _bufs: Dictionary = {}


func _initialize() -> void:
	var res: int = int(OS.get_environment("LA_BENCH_RES")) if OS.has_environment("LA_BENCH_RES") else 24
	var steps: int = int(OS.get_environment("LA_BENCH_STEPS")) if OS.has_environment("LA_BENCH_STEPS") else 400
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		print("BENCH_ERROR=no local RenderingDevice (headless has no compute device — use run_sim_offscreen.sh)")
		_done(1)
		return

	_grid = LASphereGrid.new()
	_grid.build(res, DEPTH, CORE_RADIUS, CELL_SIZE, Vector3.ZERO)
	_cc = _grid.cell_count
	_columns = _grid.surf_count
	print("BENCH_GRID={\"res\":%d,\"depth\":%d,\"cells\":%d,\"columns\":%d,\"sea_radius\":%.1f,\"cell_size\":%.1f}"
			% [res, DEPTH, _cc, _columns, SEA_RADIUS, CELL_SIZE])

	_alloc()
	_probe_readback_legality()

	# Run A: the kernels as committed (no prescribed base flow anywhere).
	_reset_state()
	_run(steps, 0.0)
	var prof: Array = _shell_pressure()
	_print_pressure(prof)
	_print_jet("JET_NOBASE", _zonal_table())
	var wind_off: Dictionary = _wind_stats()
	print("WIND_NOBASE=%s" % JSON.stringify(wind_off))

	# Run B: the SAME kernels with the deleted latitude-band cosine re-imposed from the CPU, as a relax toward
	# u(lat) = -BASE_WIND*cos(3*lat) applied after each step. This is the band-aid, restored only here, so the
	# "with and without" comparison is controlled — same seed, same temperature field, same everything else.
	_reset_state()
	_run(steps, 6.0)
	_print_jet("JET_BASEWIND", _zonal_table())
	var wind_on: Dictionary = _wind_stats()
	print("WIND_BASEWIND=%s" % JSON.stringify(wind_on))

	_done(0)


func _done(code: int) -> void:
	print("LA_RUN_COMPLETE={\"code\":%d}" % code)
	quit(code)


func _new_f(n: int) -> RID:
	var z: PackedFloat32Array = PackedFloat32Array()
	z.resize(n)
	return _rd.storage_buffer_create(n * 4, z.to_byte_array())


func _alloc() -> void:
	_bufs["air"] = [_new_f(_cc), _new_f(_cc)]
	for k: String in ["temp", "solid", "pressure", "vel_x", "vel_y", "vel_z"]:
		_bufs[k] = _new_f(_cc)
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	var rad: PackedFloat32Array = PackedFloat32Array()
	rad.resize(_cc * 3)
	for c in _cc:
		var d: Vector3 = _grid.cell_radial(c)
		rad[c * 3 + 0] = d.x
		rad[c * 3 + 1] = d.y
		rad[c * 3 + 2] = d.z
	_bufs["radial"] = _rd.storage_buffer_create(rad.size() * 4, rad.to_byte_array())
	# Per-column tangent-frame table (LASphereGrid.link_tan): the direction of each lateral link in the cell's
	# own (tan_a, tan_b) axes. Both wind kernels read it — the frame momentum is stored in is a table of its
	# own, not the neighbour slot order.
	var ltan: PackedByteArray = _grid.link_tan.to_byte_array()
	_bufs["link_tan"] = _rd.storage_buffer_create(ltan.size(), ltan)


## Seed temperature + solid (an all-ocean planet: rock below the sea shell, open air above) and zero the
## dynamic state. An unbroken ocean surface is deliberate — it isolates the thermal wind from terrain noise.
func _reset_state() -> void:
	var temp: PackedFloat32Array = PackedFloat32Array()
	temp.resize(_cc)
	var solid: PackedFloat32Array = PackedFloat32Array()
	solid.resize(_cc)
	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(_cc)
	for c in _cc:
		var r: int = c % DEPTH
		var radius: float = CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE
		var sinlat: float = _grid.cell_radial(c).dot(SPIN_AXIS)
		var t: float = T_EQUATOR_C - T_POLE_DROP_C * sinlat * sinlat
		if radius > SEA_RADIUS:
			t -= LAPSE_C_PER_UNIT * (radius - SEA_RADIUS)
		temp[c] = t
		solid[c] = 1.0 if radius < SEA_RADIUS else 0.0
	_rd.buffer_update(_bufs["temp"], 0, temp.size() * 4, temp.to_byte_array())
	_rd.buffer_update(_bufs["solid"], 0, solid.size() * 4, solid.to_byte_array())
	for k: String in ["pressure", "vel_x", "vel_y", "vel_z"]:
		_rd.buffer_update(_bufs[k], 0, zero.size() * 4, zero.to_byte_array())
	for i in 2:
		_rd.buffer_update(_bufs["air"][i], 0, zero.size() * 4, zero.to_byte_array())


func _compile(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	if sf == null:
		print("BENCH_ERROR=shader load failed: ", path)
		return RID()
	return _rd.shader_create_from_spirv(sf.get_spirv())


func _uset(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _run(steps: int, base_wind: float) -> void:
	var wp_shader: RID = _compile(PRESSURE_PATH)
	var ws_shader: RID = _compile(WIND_PATH)
	if not wp_shader.is_valid() or not ws_shader.is_valid():
		return
	var wp_pipe: RID = _rd.compute_pipeline_create(wp_shader)
	var ws_pipe: RID = _rd.compute_pipeline_create(ws_shader)
	var air: Array = _bufs["air"]
	var wp_set: Array = [RID(), RID()]
	var ws_set: Array = [RID(), RID()]
	for p in 2:
		wp_set[p] = _uset(wp_shader, [[0, air[p]], [1, air[1 - p]], [2, _bufs["temp"]], [3, _bufs["solid"]],
				[4, _bufs["pressure"]], [5, _bufs["vel_x"]], [6, _bufs["vel_z"]], [15, _bufs["nbr"]],
				[16, _bufs["link_tan"]]])
		# AirIn for pass B is the BACK half — the one pass A just wrote at this parity.
		ws_set[p] = _uset(ws_shader, [[0, _bufs["pressure"]], [1, _bufs["temp"]], [2, _bufs["solid"]],
				[3, _bufs["vel_x"]], [4, _bufs["vel_y"]], [5, _bufs["vel_z"]], [6, air[1 - p]],
				[14, _bufs["radial"]], [15, _bufs["nbr"]], [16, _bufs["link_tan"]]])

	var col_groups: int = int(ceil(float(_columns) / 64.0))
	var cell_groups: int = int(ceil(float(_cc) / 64.0))
	var pc_ws: PackedByteArray = PackedByteArray()
	pc_ws.resize(48)
	pc_ws.encode_u32(0, _cc)
	pc_ws.encode_float(4, 0.0)      # pvx — prevailing wind, zero here
	pc_ws.encode_float(8, 0.0)      # pvz
	pc_ws.encode_float(12, DT)
	pc_ws.encode_u32(16, 1)         # buoyancy on
	pc_ws.encode_float(20, SPIN_AXIS.x)
	pc_ws.encode_float(24, SPIN_AXIS.y)
	pc_ws.encode_float(28, SPIN_AXIS.z)
	pc_ws.encode_u32(32, DEPTH)
	pc_ws.encode_float(36, CORE_RADIUS)
	pc_ws.encode_float(40, CELL_SIZE)
	pc_ws.encode_float(44, SEA_RADIUS)

	var phase: int = 0
	for i in steps:
		var pc_wp: PackedByteArray = PackedByteArray()
		pc_wp.resize(32)
		pc_wp.encode_u32(0, _columns)
		pc_wp.encode_u32(4, DEPTH)
		pc_wp.encode_float(8, CORE_RADIUS)
		pc_wp.encode_float(12, CELL_SIZE)
		pc_wp.encode_float(16, SEA_RADIUS)
		pc_wp.encode_float(20, DT)
		pc_wp.encode_u32(24, i)
		pc_wp.encode_u32(28, 0)
		var cl: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, wp_pipe)
		_rd.compute_list_bind_uniform_set(cl, wp_set[phase], 0)
		_rd.compute_list_set_push_constant(cl, pc_wp, pc_wp.size())
		_rd.compute_list_dispatch(cl, col_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_bind_compute_pipeline(cl, ws_pipe)
		_rd.compute_list_bind_uniform_set(cl, ws_set[phase], 0)
		_rd.compute_list_set_push_constant(cl, pc_ws, pc_ws.size())
		_rd.compute_list_dispatch(cl, cell_groups, 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		phase = 1 - phase
		if base_wind > 0.0:
			_apply_base_wind(base_wind)
		# Growth trace: a mass-pressure-wind loop integrated with forward Euler either settles or runs away, and
		# the two look identical in a single end-state snapshot. Sampling it decides which.
		if i % 50 == 0 or i == steps - 1:
			var st: Dictionary = _wind_stats()
			print("TRACE={\"base\":%.1f,\"step\":%d,\"mean_horiz\":%.4f,\"max_horiz\":%.3f,\"air_total\":%.2f}"
					% [base_wind, i, st["mean_horiz"], st["max_horiz"], _air_total()])

	for r: RID in [wp_set[0], wp_set[1], ws_set[0], ws_set[1], wp_pipe, ws_pipe, wp_shader, ws_shader]:
		if r.is_valid():
			_rd.free_rid(r)


## Run B only: relax each cell's tangent velocity toward the prescribed zonal band
## u(lat) = -base*cos(3*lat) at BODY_FORCE rate, on the CPU.
func _apply_base_wind(base: float) -> void:
	const BODY_FORCE: float = 0.02
	var vx: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_x"]).to_float32_array()
	var vz: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_z"]).to_float32_array()
	for c in _cc:
		var radial: Vector3 = _grid.cell_radial(c)
		var east: Vector3 = SPIN_AXIS.cross(radial)
		if east.length() < 1.0e-4:
			continue
		var lat: float = asin(clampf(radial.dot(SPIN_AXIS), -1.0, 1.0))
		var target: Vector3 = east.normalized() * (-base * cos(3.0 * lat))
		vx[c] += (target.dot(_grid.tangent_a(c)) - vx[c]) * BODY_FORCE
		vz[c] += (target.dot(_grid.tangent_b(c)) - vz[c]) * BODY_FORCE
	_rd.buffer_update(_bufs["vel_x"], 0, vx.size() * 4, vx.to_byte_array())
	_rd.buffer_update(_bufs["vel_z"], 0, vz.size() * 4, vz.to_byte_array())


## Mean pressure over the ATMOSPHERIC cells of each radial shell (shells below the sea shell hold no air and
## carry their column's surface pressure, so they are reported separately as the "surface" row).
func _shell_pressure() -> Array:
	var p: PackedFloat32Array = _rd.buffer_get_data(_bufs["pressure"]).to_float32_array()
	var air: PackedFloat32Array = _rd.buffer_get_data(_bufs["air"][0]).to_float32_array()
	var air_b: PackedFloat32Array = _rd.buffer_get_data(_bufs["air"][1]).to_float32_array()
	var out: Array = []
	for r in DEPTH:
		var sum_p: float = 0.0
		var sum_a: float = 0.0
		var n: int = 0
		for s in _columns:
			var c: int = s * DEPTH + r
			sum_p += p[c]
			sum_a += maxf(air[c], air_b[c])
			n += 1
		var radius: float = CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE
		out.append({"shell": r, "radius": radius, "height": radius - SEA_RADIUS,
				"p_mean": sum_p / float(maxi(n, 1)), "air_mean": sum_a / float(maxi(n, 1))})
	return out


func _print_pressure(prof: Array) -> void:
	var mono: bool = true
	for i in range(1, prof.size()):
		if float(prof[i]["p_mean"]) > float(prof[i - 1]["p_mean"]) + 1.0e-6:
			mono = false
	# Scale height H = -dz / ln(p2/p1). Fitted over the INTERIOR of the atmosphere, not end to end: the top
	# shell has nothing above it, so its pressure is only half its own weight and the domain truncation there
	# would masquerade as a much smaller scale height. Both fits are printed so the difference is visible.
	var lo: Dictionary = prof[SURF_SHELL]
	var mid: Dictionary = prof[DEPTH - 4]
	var hi: Dictionary = prof[DEPTH - 1]
	print("PRESSURE_PROFILE=%s" % JSON.stringify(prof))
	print("PRESSURE_SUMMARY={\"monotone_decreasing_outward\":%s,\"H_interior\":%.2f,\"H_interior_cells\":%.2f,\"H_endtoend\":%.2f,\"p_surface\":%.3f,\"p_top\":%.4f}"
			% [str(mono).to_lower(), _fit_h(lo, mid), _fit_h(lo, mid) / CELL_SIZE, _fit_h(lo, hi),
			float(lo["p_mean"]), float(hi["p_mean"])])


func _fit_h(a: Dictionary, b: Dictionary) -> float:
	if float(a["p_mean"]) <= 0.0 or float(b["p_mean"]) <= 0.0:
		return 0.0
	return -(float(b["height"]) - float(a["height"])) / log(float(b["p_mean"]) / float(a["p_mean"]))


func _wind_world(c: int, vx: PackedFloat32Array, vy: PackedFloat32Array,
		vz: PackedFloat32Array) -> Vector3:
	return (_grid.cell_radial(c) * vy[c]
			+ _grid.tangent_a(c) * vx[c]
			+ _grid.tangent_b(c) * vz[c])


## Mean ZONAL (eastward) wind per latitude band x radial shell. Positive = westerly (eastward), the sign a
## real jet stream carries. Both hemispheres are folded onto absolute latitude AFTER projecting onto each
## cell's own eastward direction, so a symmetric pair of westerly jets reinforces instead of cancelling.
func _zonal_table() -> Array:
	var vx: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_x"]).to_float32_array()
	var vy: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_y"]).to_float32_array()
	var vz: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_z"]).to_float32_array()
	var press: PackedFloat32Array = _rd.buffer_get_data(_bufs["pressure"]).to_float32_array()
	var bands: int = LAT_EDGES.size() - 1
	var sum_u: Array = []
	var sum_v: Array = []
	var sum_w: Array = []
	var sum_p: Array = []
	var sum_sp: Array = []
	var cnt: Array = []
	for b in bands:
		sum_u.append(PackedFloat32Array()); sum_u[b].resize(DEPTH)
		sum_v.append(PackedFloat32Array()); sum_v[b].resize(DEPTH)
		sum_w.append(PackedFloat32Array()); sum_w[b].resize(DEPTH)
		sum_p.append(PackedFloat32Array()); sum_p[b].resize(DEPTH)
		sum_sp.append(PackedFloat32Array()); sum_sp[b].resize(DEPTH)
		cnt.append(PackedInt32Array()); cnt[b].resize(DEPTH)
	for c in _cc:
		var r: int = c % DEPTH
		var radius: float = CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE
		if radius < SEA_RADIUS:
			continue
		var radial: Vector3 = _grid.cell_radial(c)
		var sinlat: float = clampf(radial.dot(SPIN_AXIS), -1.0, 1.0)
		var lat_deg: float = absf(rad_to_deg(asin(sinlat)))
		var east: Vector3 = SPIN_AXIS.cross(radial)
		if east.length() < 1.0e-4:
			continue
		east = east.normalized()
		# Fold the southern hemisphere onto the north: its eastward unit already points the right way, so a
		# westerly there projects positive too. No sign flip needed.
		var w: Vector3 = _wind_world(c, vx, vy, vz)
		var b: int = bands - 1
		for i in range(bands):
			if lat_deg >= LAT_EDGES[i] and lat_deg < LAT_EDGES[i + 1]:
				b = i
				break
		sum_p[b][r] += press[c]
		# Split the wind into its three meaningful directions. Lumping them hides the physics: a uniform lapse
		# rate makes every cell buoyant, so the RADIAL component alone can dominate a speed average while the
		# horizontal circulation this pass is about sits near zero.
		var north: Vector3 = radial.cross(east).normalized()
		if sinlat < 0.0:
			north = -north          # fold the southern hemisphere: "poleward" is one direction in both
		sum_u[b][r] += w.dot(east)
		sum_v[b][r] += w.dot(north)
		sum_w[b][r] += w.dot(radial)
		sum_sp[b][r] += w.length()
		cnt[b][r] += 1
	var out: Array = []
	for b in bands:
		var rows: Array = []
		for r in DEPTH:
			var radius: float = CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE
			if radius < SEA_RADIUS or cnt[b][r] == 0:
				continue
			var n: float = float(cnt[b][r])
			rows.append({"shell": r, "height": radius - SEA_RADIUS,
					"u_east": sum_u[b][r] / n, "v_pole": sum_v[b][r] / n, "w_up": sum_w[b][r] / n,
					"p": sum_p[b][r] / n, "speed": sum_sp[b][r] / n})
		out.append({"lat_lo": LAT_EDGES[b], "lat_hi": LAT_EDGES[b + 1], "rows": rows})
	return out


const SURF_SHELL: int = 10        # int((SEA_RADIUS - CORE_RADIUS) / CELL_SIZE) — the sea shell


func _print_jet(tag: String, table: Array) -> void:
	print("%s=%s" % [tag, JSON.stringify(table)])
	# Locate the strongest eastward mean and say where it sits, plus the surface value beneath it.
	var best_u: float = -1.0e20
	var best: Dictionary = {}
	for band: Dictionary in table:
		for row: Dictionary in band["rows"]:
			if float(row["u_east"]) > best_u:
				best_u = float(row["u_east"])
				best = {"lat_lo": band["lat_lo"], "lat_hi": band["lat_hi"], "shell": row["shell"],
						"height": row["height"], "u_east": row["u_east"], "v_pole": row["v_pole"],
						"w_up": row["w_up"], "speed": row["speed"]}
	if best.is_empty():
		return
	var surf_u: float = 0.0
	for band: Dictionary in table:
		if band["lat_lo"] == best["lat_lo"]:
			for row: Dictionary in band["rows"]:
				if int(row["shell"]) == SURF_SHELL:
					surf_u = float(row["u_east"])
	best["u_east_surface_below"] = surf_u
	best["aloft_over_surface"] = best["u_east"] / surf_u if absf(surf_u) > 1.0e-6 else INF
	print("%s_PEAK=%s" % [tag, JSON.stringify(best)])
	# THE THERMAL-WIND DRIVER, measured rather than assumed: the equator-to-pole pressure difference at each
	# height. If this does not grow with height there is nothing for a jet to come from and no amount of
	# tuning downstream will make one; if it does, the question moves to the momentum balance.
	var eq: Dictionary = {}
	var pole: Dictionary = {}
	for band: Dictionary in table:
		if float(band["lat_lo"]) == 0.0:
			for row: Dictionary in band["rows"]:
				eq[int(row["shell"])] = float(row["p"])
		if float(band["lat_hi"]) == 90.0:
			for row: Dictionary in band["rows"]:
				pole[int(row["shell"])] = float(row["p"])
	var dp: Array = []
	for r in range(SURF_SHELL, DEPTH):
		if eq.has(r) and pole.has(r):
			dp.append({"shell": r, "height": CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE - SEA_RADIUS,
					"p_equator": eq[r], "p_pole": pole[r], "dp_eq_minus_pole": eq[r] - pole[r]})
	print("%s_THERMAL_GRADIENT=%s" % [tag, JSON.stringify(dp)])


## Total air mass over both ping-pong halves' live buffer — the conservation check. Horizontal transport is
## face-symmetric and the vertical settle renormalises to the column total, so this should hold flat.
func _air_total() -> float:
	var a: PackedFloat32Array = _rd.buffer_get_data(_bufs["air"][0]).to_float32_array()
	var b: PackedFloat32Array = _rd.buffer_get_data(_bufs["air"][1]).to_float32_array()
	var sa: float = 0.0
	var sb: float = 0.0
	for i in a.size():
		sa += a[i]
		sb += b[i]
	return maxf(sa, sb)


## Aggregate wind magnitude over the atmosphere — the "does circulation survive" number.
func _wind_stats() -> Dictionary:
	var vx: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_x"]).to_float32_array()
	var vy: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_y"]).to_float32_array()
	var vz: PackedFloat32Array = _rd.buffer_get_data(_bufs["vel_z"]).to_float32_array()
	var sum: float = 0.0
	var mx: float = 0.0
	var sum_h: float = 0.0
	var mx_h: float = 0.0
	var n: int = 0
	for c in _cc:
		var r: int = c % DEPTH
		if CORE_RADIUS + (float(r) + 0.5) * CELL_SIZE < SEA_RADIUS:
			continue
		var w: Vector3 = _wind_world(c, vx, vy, vz)
		var sp: float = w.length()
		# Horizontal magnitude separately: the radial component is buoyancy, not circulation, and letting it
		# into the average hides what the pressure field is actually doing sideways.
		var radial: Vector3 = _grid.cell_radial(c)
		var sp_h: float = (w - radial * w.dot(radial)).length()
		sum += sp
		mx = maxf(mx, sp)
		sum_h += sp_h
		mx_h = maxf(mx_h, sp_h)
		n += 1
	var inv: float = 1.0 / float(maxi(n, 1))
	return {"mean_speed": sum * inv, "max_speed": mx,
			"mean_horiz": sum_h * inv, "max_horiz": mx_h, "cells": n}


## One-off: is buffer_get_data legal while a compute list is open? Decides whether an in-sim probe can read
## the field's GPU buffers from inside a pass's dispatch(), or whether measurement has to stay in this bench.
func _probe_readback_legality() -> void:
	var cl: int = _rd.compute_list_begin()
	var data: PackedByteArray = _rd.buffer_get_data(_bufs["pressure"], 0, 16)
	_rd.compute_list_end()
	print("READBACK_DURING_COMPUTE_LIST={\"bytes\":%d}" % data.size())
	if cl < 0:
		print("READBACK_PROBE_NOTE=compute_list_begin returned %d" % cl)
