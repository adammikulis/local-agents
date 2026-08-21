class_name LAMaterialFieldMomentumLedger3D
extends RefCounted

## Momentum stock and its books in the FIELD frame, folded on the device: stock, mass and Σm|v| are
## MomentumRows reduce rows, body impulse is state_derive's bodyf deposit, bnd_mom_* the outside exchange.

var _f = null

var _prev_step: int = -1
var _first_stock: Vector3 = Vector3.ZERO
var _first_step: int = -1
var _cum_body: Vector3 = Vector3.ZERO        # Σ bodyf rows: (weight + rotating frame) impulse, kg·m/s
var _cum_bnd: Vector3 = Vector3.ZERO         # Σ bnd_mom_* rows, inflow-positive, walls included
## Σ |bodyf| + |bnd|, the impulse that ACTED: a denominator that never passes through zero.
var _cum_impulse: float = 0.0


func setup(field) -> void:
	_f = field


func _row3(prefix: String) -> Vector3:
	var q: LAMaterialFieldQueries3D = _f._queries
	return Vector3(q.row_f(prefix + "x"), q.row_f(prefix + "y"), q.row_f(prefix + "z"))


## Fold the drained step's books. Runs on the FIELD step, so the fold does not depend on report cadence.
func sample(step_index: int) -> void:
	if _f == null or _f._queries == null:
		return
	var steps: int = step_index - _prev_step
	if steps > 0 or _prev_step < 0:
		_prev_step = step_index
	if _first_step < 0:
		var stock: Vector3 = _row3("open_mom_")
		if _f._seal != null and _f._seal.sealed() and stock.is_finite():
			_first_stock = stock
			_first_step = step_index
			_f._seal.note_seed({"momentum_kg_m_s": stock.length()})
		return
	# Both books are impulses PER STEP; a non-finite step's book is absent, never folded.
	var body_now: Vector3 = _row3("bodyf_")
	var bnd_now: Vector3 = _row3("bnd_mom_")
	if steps > 0 and body_now.is_finite() and bnd_now.is_finite():
		_cum_body += body_now * float(steps)
		_cum_bnd += bnd_now * float(steps)
		_cum_impulse += (body_now.length() + bnd_now.length()) * float(steps)


func report(step_index: int) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._queries == null:
		return out
	var stock: Vector3 = _row3("open_mom_")
	out["momentum_live"] = {"stock": stock.is_finite(), "bodyf": _row3("bodyf_").is_finite(),
		"bnd_mom": _row3("bnd_mom_").is_finite()}
	var run_steps: int = (step_index - _first_step) if _first_step >= 0 else 0
	out["momentum_first_step"] = _first_step
	out["momentum_run_steps"] = run_steps
	if run_steps > 0:
		# The books are sums of finite per-step folds, so they stand even when the instant stock does not.
		out["momentum_book_body"] = _vec(_cum_body)
		out["momentum_book_bnd"] = _vec(_cum_bnd)
		out["momentum_impulse"] = _cum_impulse
	if not stock.is_finite():
		return out
	var carried: float = _f._queries.row_f("momentum_carried")
	out["momentum_vec"] = _vec(stock)
	out["momentum_total"] = stock.length()
	out["momentum_carried"] = carried
	out["momentum_mass_kg"] = _f._queries.row_f("momentum_mass_kg")
	out["momentum_cells"] = _f._queries.row_n("momentum_cells")
	if run_steps <= 0:
		return out
	var run_drift: Vector3 = stock - _first_stock
	var residual: Vector3 = run_drift - (_cum_body + _cum_bnd)
	out["momentum_run_drift_vec"] = _vec(run_drift)
	out["momentum_run_drift"] = run_drift.length()
	# Σ m|v| is the motion that exists; a net stock change is a fraction OF it.
	out["momentum_run_drift_rel"] = _rel(run_drift.length(), carried)
	out["momentum_residual_vec"] = _vec(residual)
	out["momentum_residual"] = residual.length()
	out["momentum_residual_rel"] = _rel(residual.length(), _cum_impulse)
	return out


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


## A residual over the quantity it is a residual OF, dimensionless. Null when there is no scale to divide by.
static func _rel(numerator: float, denominator: float):
	if not is_finite(numerator) or not is_finite(denominator) or denominator == 0.0:
		return null
	return snappedf(numerator / absf(denominator), 1.0e-12)
