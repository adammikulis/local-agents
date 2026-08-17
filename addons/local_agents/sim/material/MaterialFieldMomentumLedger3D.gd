class_name LAMaterialFieldMomentumLedger3D
extends RefCounted

## Momentum stock and its books, in the FIELD frame (planet-fixed). The velocity channels are the grid's own
## axes, so there is no basis to rotate through.

## rho_bulk is the density state_derive.glsl divides momentum by.
const LEGS: PackedStringArray = ["rho_bulk", "pressure"]

var _f = null                                # back-reference to the owning LAMaterialField3D

var _prev_step: int = -1

var _first_stock: Vector3 = Vector3.ZERO
var _first_step: int = -1
var _samples: int = 0
var _cum_pgf: Vector3 = Vector3.ZERO         # ∫ pressure-gradient force dt, kg·m/s
var _cum_frame: Vector3 = Vector3.ZERO       # ∫ (Coriolis + centrifugal) dt, kg·m/s
## ∫ (|pgf| + |rotating frame|) dt, kg·m/s. The impulse that ACTED — no direction to cancel through,
## so it is the one denominator the residual can be a fraction of that does not pass through zero.
var _cum_impulse: float = 0.0


func setup(field) -> void:
	_f = field


func report(step_index: int) -> Dictionary:
	var out: Dictionary = _blank()
	if _f == null or _f._cell_count <= 0 or _f._grid == null:
		return out
	var t0: int = Time.get_ticks_usec()
	var cc: int = _f._cell_count
	var grid: LAVoxelGrid = _f._grid
	if grid.cell_count != cc:
		return out

	# READ-ONLY, AT THE DRAIN, through the probe, which never changes channel residency.
	var legs: Dictionary = {}
	if _f._gpu != null and _f._gpu.has_method("take_probe"):
		legs = _f._gpu.take_probe()
		_f._gpu.request_probe(LEGS)
	var rho: PackedFloat32Array = legs.get("rho_bulk", PackedFloat32Array())
	var pres: PackedFloat32Array = legs.get("pressure", PackedFloat32Array())
	var has_rho: bool = rho.size() == cc
	var has_pres: bool = pres.size() == cc
	out["momentum_live"] = {"rho_bulk": has_rho, "pressure": has_pres}

	var solid: PackedByteArray = _f._solid
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z
	if not has_rho or solid.size() != cc \
			or vx.size() != cc or vy.size() != cc or vz.size() != cc:
		out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var nbr: PackedInt32Array = grid.neighbours
	var cell_m: float = float(_f._cell_size)
	var v_m3: float = grid.cell_volume()
	var spin: Vector3 = LAFieldGeometry.spin_axis(_f)
	var omega: Vector3 = spin * LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S
	var two_omega: float = LAPhysical.CORIOLIS_TWO_OMEGA_RAD_S
	var centre: Vector3 = LAFieldGeometry.centre(_f)

	var stock: Vector3 = Vector3.ZERO
	var carried: float = 0.0                 # Σ m|v|, kg·m/s — never cancels
	var mass_kg: float = 0.0
	var moving_cells: int = 0
	var f_pgf: Vector3 = Vector3.ZERO
	var f_frame: Vector3 = Vector3.ZERO

	for c in cc:
		if solid[c] != 0:
			continue
		var m: float = rho[c] * v_m3
		if m <= 0.0:
			continue
		mass_kg += m
		var v: Vector3 = Vector3(vx[c], vy[c], vz[c])
		stock += v * m
		var speed: float = v.length()
		carried += m * speed
		if speed > 0.0:
			moving_cells += 1
		# THE ROTATING FRAME, both terms state_derive.glsl applies: Coriolis -2Ω x v and centrifugal
		# -Ω x (Ω x r). Booking one and not the other made the residual carry the difference.
		var r_vec: Vector3 = grid.cell_world_pos(c) - centre
		f_frame += (spin.cross(v) * -two_omega - omega.cross(omega.cross(r_vec))) * m
		# PRESSURE GRADIENT: F = -V grad(p), central differences over the six faces. A solid or missing
		# neighbour reflects, which is what a wall does.
		if has_pres:
			var p0: float = pres[c]
			var gp: Vector3 = Vector3.ZERO
			for d in LAVoxelGrid.SLOTS:
				var mi: int = nbr[c * LAVoxelGrid.SLOTS + d]
				var pn: float = pres[mi] if (mi >= 0 and solid[mi] == 0) else p0
				gp += Vector3(LAVoxelGrid.SLOT_STEP[d]) * (0.5 * (pn - p0))
			f_pgf += gp * (-v_m3 / cell_m)

	out["momentum_vec"] = _vec(stock)
	out["momentum_total"] = stock.length()
	out["momentum_carried"] = carried
	out["momentum_mass_kg"] = mass_kg
	out["momentum_cells"] = moving_cells
	out["momentum_force_n"] = _vec(f_pgf + f_frame)

	var steps: int = step_index - _prev_step
	var dt_real: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	if steps > 0 or _prev_step < 0:
		_prev_step = step_index

	_samples += 1
	var latched: bool = false
	if _first_step < 0 and _sealed():
		_first_stock = stock
		_first_step = step_index
		_cum_pgf = Vector3.ZERO
		_cum_frame = Vector3.ZERO
		_cum_impulse = 0.0
		_note_seed("momentum_kg_m_s", stock.length())
		latched = true
	if _first_step >= 0 and not latched and steps > 0:
		# Rectangle rule over the window at the force sampled at its right-hand end, the same approximation
		# LAMaterialFieldLedger3D integrates its fluxes with.
		var window_s: float = dt_real * float(steps)
		_cum_pgf += f_pgf * window_s
		_cum_frame += f_frame * window_s
		_cum_impulse += (f_pgf.length() + f_frame.length()) * window_s

	var run_steps: int = (step_index - _first_step) if _first_step >= 0 else 0
	out["momentum_samples"] = _samples
	out["momentum_first_step"] = _first_step
	out["momentum_run_steps"] = run_steps
	if run_steps <= 0:
		out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
		return out

	var run_drift: Vector3 = stock - _first_stock
	var booked: Vector3 = _cum_pgf + _cum_frame
	var residual: Vector3 = run_drift - booked
	out["momentum_run_drift_vec"] = _vec(run_drift)
	out["momentum_run_drift"] = run_drift.length()
	# Σ m|v| is the motion that exists; a net stock change is a fraction OF it.
	out["momentum_run_drift_rel"] = _rel(run_drift.length(), carried)
	out["momentum_booked_vec"] = _vec(booked)
	out["momentum_booked"] = booked.length()
	out["momentum_residual_vec"] = _vec(residual)
	out["momentum_residual"] = residual.length()
	out["momentum_impulse"] = _cum_impulse
	# The impulse nothing names, as a fraction of the impulse that acted. NOT of |booked|: that is a vector sum
	# whose magnitude cancels toward zero, so the same residual read anywhere from fine to infinite.
	out["momentum_residual_rel"] = _rel(residual.length(), _cum_impulse)
	out["momentum_book_pgf"] = _vec(_cum_pgf)
	out["momentum_book_frame"] = _vec(_cum_frame)
	out["momentum_scan_ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.01)
	return out


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


## A residual over the quantity it is a residual OF, dimensionless. Null when there is no scale to divide by.
static func _rel(numerator: float, denominator: float):
	if not is_finite(numerator) or not is_finite(denominator) or denominator == 0.0:
		return null
	return snappedf(numerator / absf(denominator), 1.0e-12)


func _blank() -> Dictionary:
	return {
		# Net vector momentum of the air: which way the whole atmosphere is going, and how hard.
		"momentum_total": 0.0, "momentum_vec": [0.0, 0.0, 0.0],
		# Σ m|v| — how much motion exists at all. Cancellation cannot hide inside it.
		"momentum_carried": 0.0, "momentum_mass_kg": 0.0, "momentum_cells": 0,
		"momentum_run_drift": 0.0, "momentum_run_drift_vec": [0.0, 0.0, 0.0],
		"momentum_run_drift_rel": null,
		"momentum_booked": 0.0, "momentum_booked_vec": [0.0, 0.0, 0.0],
		"momentum_residual": 0.0, "momentum_residual_vec": [0.0, 0.0, 0.0],
		"momentum_impulse": 0.0, "momentum_residual_rel": null,
		"momentum_book_pgf": [0.0, 0.0, 0.0], "momentum_book_frame": [0.0, 0.0, 0.0],
		"momentum_force_n": [0.0, 0.0, 0.0],
		"momentum_samples": 0, "momentum_first_step": -1, "momentum_run_steps": 0,
		"momentum_live": {}, "momentum_scan_ms": 0.0,
	}


func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
