class_name LAMaterialFieldMomentumLedger3D
extends RefCounted

## Momentum stock and its books, in the FIELD frame (planet-fixed, the frame the velocity channels and the
## tangent tables are written in). The GPU stores velocity FRAME-LOCAL: vel_x along tangent_a, vel_z along
## tangent_b, vel_y outward-radial, all m/s.
##   momentum = Σ over open cells of  air * AIR_DENSITY_KG_M3 * cell_volume_m3 * (ta*vel_x + tb*vel_z + r*vel_y)
## in kg·m/s. `air` is a dimensionless multiplier on AIR_DENSITY_KG_M3 (wind_pressure_sphere3d.glsl).

const LEGS: PackedStringArray = ["air", "pressure"]

## Momentum terms wind_step_sphere3d.glsl applies that no CPU-side sum can reach — their rates are per-step
## fractions declared only inside that kernel (drag), or the transfer leaves no per-cell trace (the rest).
## They land in `momentum_residual`.
const UNBOOKED: Array = ["drag", "terrain_block", "orographic_lift", "solid_zeroing", "air_advection"]

var _f = null                                # back-reference to the owning LAMaterialField3D

var _prev_stock: Vector3 = Vector3.ZERO
var _prev_step: int = -1

var _first_stock: Vector3 = Vector3.ZERO
var _first_step: int = -1
var _samples: int = 0
var _cum_pgf: Vector3 = Vector3.ZERO         # ∫ pressure-gradient force dt, kg·m/s
var _cum_cor: Vector3 = Vector3.ZERO         # ∫ Coriolis force dt, kg·m/s
var _cum_buo: Vector3 = Vector3.ZERO         # ∫ buoyancy force dt, kg·m/s


func setup(field) -> void:
	_f = field


func report(step_index: int) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0 or _f._sphere == null:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var grid = _f._sphere
	if grid.cell_count != cc or grid.depth <= 0:
		return out

	# READ-ONLY, AT THE DRAIN. `air` has no CPU mirror and `pressure` is demand-gated; both arrive through the
	# probe, which never changes channel residency.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var air: PackedFloat32Array = legs.get("air", PackedFloat32Array())
	var pres: PackedFloat32Array = legs.get("pressure", PackedFloat32Array())
	var has_air: bool = air.size() == cc
	var has_pres: bool = pres.size() == cc
	out["momentum_live"] = {"air": has_air, "pressure": has_pres}

	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z
	if not has_air or solid.size() != cc or temp.size() != cc \
			or vx.size() != cc or vy.size() != cc or vz.size() != cc:
		out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var nbr: PackedInt32Array = grid.neighbours
	var ltan: PackedFloat32Array = grid.link_tan
	var depth: int = grid.depth
	var columns: int = cc / depth
	var cell_m: float = float(_f._cell_size) * LAPhysical.METRES_PER_MODEL_UNIT
	var spin: Vector3 = _spin_axis()
	var rho0: float = LAPhysical.AIR_DENSITY_KG_M3
	var g_acc: float = LAPhysical.STANDARD_GRAVITY_M_S2
	var two_omega: float = LAPhysical.CORIOLIS_TWO_OMEGA_RAD_S

	var stock: Vector3 = Vector3.ZERO
	var carried: float = 0.0                 # Σ m|v|, kg·m/s — never cancels
	var mass_kg: float = 0.0
	var moving_cells: int = 0
	var f_pgf: Vector3 = Vector3.ZERO
	var f_cor: Vector3 = Vector3.ZERO
	var f_buo: Vector3 = Vector3.ZERO

	for s in columns:
		var base_c: int = s * depth
		var ta: Vector3 = grid.tangent_a(base_c)
		var tb: Vector3 = grid.tangent_b(base_c)
		var rad: Vector3 = grid.cell_radial(base_c)
		# f = 2Ω sin(lat), and sin(lat) is the outward radial against the spin axis — the kernel's own form.
		var fcor: float = two_omega * clampf(rad.dot(spin), -1.0, 1.0)
		var lb: int = s * 8
		for r in depth:
			var c: int = base_c + r
			if solid[c] != 0:
				continue
			var v_m3: float = LAFieldTotals.cell_volume_m3(grid, c)
			var m: float = air[c] * rho0 * v_m3
			if m <= 0.0:
				continue
			mass_kg += m
			var va: float = vx[c]
			var vb: float = vz[c]
			var vr: float = vy[c]
			var v: Vector3 = ta * va + tb * vb + rad * vr
			stock += v * m
			var speed: float = v.length()
			carried += m * speed
			if speed > 0.0:
				moving_cells += 1
			# CORIOLIS: the kernel rotates the tangential pair by a_a = f*vel_z, a_b = -f*vel_x.
			f_cor += (ta * (fcor * vb) - tb * (fcor * va)) * m
			# PRESSURE GRADIENT: the same 4-link tangential gradient wind_step builds, in Pa per model unit;
			# over cell_m it is Pa/m, and F = -V ∇p in newtons. A solid or missing neighbour reflects.
			if has_pres:
				var p0: float = pres[c]
				var ga: float = 0.0
				var gb: float = 0.0
				for l in 4:
					var mi: int = nbr[c * 6 + 2 + l]
					var pn: float = pres[mi] if (mi >= 0 and solid[mi] == 0) else p0
					var d: float = 0.5 * (pn - p0)
					ga += d * ltan[lb + l * 2]
					gb += d * ltan[lb + l * 2 + 1]
				f_pgf += (ta * ga + tb * gb) * (-v_m3 / cell_m)
			# BUOYANCY: Boussinesq a = g·ΔT/T against the open cell outward, as wind_step applies it.
			var mo: int = nbr[c * 6 + 1]
			if mo >= 0 and solid[mo] == 0:
				var d_t: float = temp[c] - temp[mo]
				if d_t > 0.0:
					f_buo += rad * (m * g_acc * d_t / maxf(temp[c] + LAPhysical.KELVIN_OFFSET, 1.0))

	out["momentum_vec"] = _vec(stock)
	out["momentum_total"] = stock.length()
	out["momentum_carried"] = carried
	out["momentum_mass_kg"] = mass_kg
	out["momentum_cells"] = moving_cells
	out["momentum_force_n"] = _vec(f_pgf + f_cor + f_buo)

	var steps: int = step_index - _prev_step
	var dt_real: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	if steps > 0 and _prev_step >= 0:
		out["momentum_drift"] = (stock - _prev_stock).length()
		out["momentum_drift_steps"] = steps
	if steps > 0 or _prev_step < 0:
		_prev_stock = stock
		_prev_step = step_index

	_samples += 1
	var latched: bool = false
	if _first_step < 0 and _sealed():
		_first_stock = stock
		_first_step = step_index
		_cum_pgf = Vector3.ZERO
		_cum_cor = Vector3.ZERO
		_cum_buo = Vector3.ZERO
		_note_seed("momentum_kg_m_s", stock.length())
		latched = true
	if _first_step >= 0 and not latched and steps > 0:
		# Rectangle rule over the window at the force sampled at its right-hand end, the same approximation
		# LAMaterialFieldEnergyLedger3D integrates its fluxes with.
		var window_s: float = dt_real * float(steps)
		_cum_pgf += f_pgf * window_s
		_cum_cor += f_cor * window_s
		_cum_buo += f_buo * window_s

	var run_steps: int = (step_index - _first_step) if _first_step >= 0 else 0
	out["momentum_samples"] = _samples
	out["momentum_first_step"] = _first_step
	out["momentum_run_steps"] = run_steps
	if run_steps <= 0:
		out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var run_drift: Vector3 = stock - _first_stock
	var booked: Vector3 = _cum_pgf + _cum_cor + _cum_buo
	var residual: Vector3 = run_drift - booked
	out["momentum_run_drift_vec"] = _vec(run_drift)
	out["momentum_run_drift"] = run_drift.length()
	out["momentum_booked_vec"] = _vec(booked)
	out["momentum_booked"] = booked.length()
	out["momentum_residual_vec"] = _vec(residual)
	# The impulse nothing names, as a magnitude — scored against `momentum_booked` by scripts/physics_score.sh.
	out["momentum_residual"] = residual.length()
	out["momentum_book_pgf"] = _vec(_cum_pgf)
	out["momentum_book_coriolis"] = _vec(_cum_cor)
	out["momentum_book_buoyancy"] = _vec(_cum_buo)
	out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


## Planet spin axis in the FIELD frame — the same vector GasWindPass hands the kernel as `spin_*`.
func _spin_axis() -> Vector3:
	if _f._body != null and _f._body.has_method("spin_axis") and _f.has_method("dir_to_field"):
		var v: Vector3 = _f.dir_to_field(_f._body.spin_axis())
		if v.length() > 0.001:
			return v.normalized()
	return Vector3.UP


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _blank() -> Dictionary:
	return {
		# Net vector momentum of the air: which way the whole atmosphere is going, and how hard.
		"momentum_total": 0.0, "momentum_vec": [0.0, 0.0, 0.0],
		# Σ m|v| — how much motion exists at all. Cancellation cannot hide inside it.
		"momentum_carried": 0.0, "momentum_mass_kg": 0.0, "momentum_cells": 0,
		"momentum_drift": 0.0, "momentum_drift_steps": 0,
		"momentum_run_drift": 0.0, "momentum_run_drift_vec": [0.0, 0.0, 0.0],
		"momentum_booked": 0.0, "momentum_booked_vec": [0.0, 0.0, 0.0],
		"momentum_residual": 0.0, "momentum_residual_vec": [0.0, 0.0, 0.0],
		"momentum_book_pgf": [0.0, 0.0, 0.0], "momentum_book_coriolis": [0.0, 0.0, 0.0],
		"momentum_book_buoyancy": [0.0, 0.0, 0.0],
		"momentum_force_n": [0.0, 0.0, 0.0],
		"momentum_unbooked": UNBOOKED,
		"momentum_samples": 0, "momentum_first_step": -1, "momentum_run_steps": 0,
		"momentum_live": {}, "momentum_scan_ms": 0.0,
	}


func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
