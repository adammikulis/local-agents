class_name LAMaterialFieldMomentumLedger3D
extends RefCounted

## Momentum stock and its books in the FIELD frame, folded on the device: stock, mass and Σm|v| are
## MomentumRows reduce rows, body impulse is state_derive's bodyf deposit, bnd_mom_* the outside exchange.

var _f = null

var _prev_step: int = -1
var _first_stock: Vector3 = Vector3.ZERO
var _first_step: int = -1
var _samples: int = 0
var _cum_body: Vector3 = Vector3.ZERO        # Σ bodyf rows: (weight + rotating frame) impulse, kg·m/s
var _cum_bnd: Vector3 = Vector3.ZERO         # Σ bnd_mom_* rows, inflow-positive, walls included
## Σ |bodyf| + |bnd|, the impulse that ACTED: a denominator that never passes through zero.
var _cum_impulse: float = 0.0


func setup(field) -> void:
	_f = field


func _row3(prefix: String) -> Vector3:
	var q: LAMaterialFieldQueries3D = _f._queries
	return Vector3(q.row_f(prefix + "x"), q.row_f(prefix + "y"), q.row_f(prefix + "z"))


func report(step_index: int) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._queries == null:
		return out
	var stock: Vector3 = _row3("open_mom_")
	var body_now: Vector3 = _row3("bodyf_")
	var bnd_now: Vector3 = _row3("bnd_mom_")
	out["momentum_live"] = {"stock": stock.is_finite(), "bodyf": body_now.is_finite(),
		"bnd_mom": bnd_now.is_finite()}
	if not stock.is_finite():
		return out
	var carried: float = _f._queries.row_f("momentum_carried")
	out["momentum_vec"] = _vec(stock)
	out["momentum_total"] = stock.length()
	out["momentum_carried"] = carried
	out["momentum_mass_kg"] = _f._queries.row_f("momentum_mass_kg")
	out["momentum_cells"] = _f._queries.row_n("momentum_cells")

	var steps: int = step_index - _prev_step
	if steps > 0 or _prev_step < 0:
		_prev_step = step_index

	_samples += 1
	var latched: bool = false
	if _first_step < 0 and _sealed():
		_first_stock = stock
		_first_step = step_index
		_cum_body = Vector3.ZERO
		_cum_bnd = Vector3.ZERO
		_cum_impulse = 0.0
		_note_seed("momentum_kg_m_s", stock.length())
		latched = true
	if _first_step >= 0 and not latched and steps > 0 and body_now.is_finite() and bnd_now.is_finite():
		# Both books are impulses PER STEP; the rectangle rule over the window samples the last step.
		_cum_body += body_now * float(steps)
		_cum_bnd += bnd_now * float(steps)
		_cum_impulse += (body_now.length() + bnd_now.length()) * float(steps)

	var run_steps: int = (step_index - _first_step) if _first_step >= 0 else 0
	out["momentum_samples"] = _samples
	out["momentum_first_step"] = _first_step
	out["momentum_run_steps"] = run_steps
	if run_steps <= 0:
		return out

	var run_drift: Vector3 = stock - _first_stock
	var booked: Vector3 = _cum_body + _cum_bnd
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
	out["momentum_residual_rel"] = _rel(residual.length(), _cum_impulse)
	out["momentum_book_body"] = _vec(_cum_body)
	out["momentum_book_bnd"] = _vec(_cum_bnd)
	return out


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


## A residual over the quantity it is a residual OF, dimensionless. Null when there is no scale to divide by.
static func _rel(numerator: float, denominator: float):
	if not is_finite(numerator) or not is_finite(denominator) or denominator == 0.0:
		return null
	return snappedf(numerator / absf(denominator), 1.0e-12)


func _sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func _note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})
