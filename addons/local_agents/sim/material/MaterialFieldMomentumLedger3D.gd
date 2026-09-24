class_name LAMaterialFieldMomentumLedger3D
extends RefCounted

## Momentum stock and its books in the FIELD frame, folded on the device: stock, mass and Σm|v| are
## MomentumRows reduce rows, body impulse is state_derive's bodyf deposit, bnd_mom_* the outside exchange.
## LAFieldLedger integrates them; this reads the rows.

var _f = null
var _n: LAFieldLedger = null


func setup(field) -> void:
	_f = field
	_n = LAFieldLedger.new()


func _row3(prefix: String) -> Vector3:
	var q: LAMaterialFieldQueries3D = _f._queries
	return Vector3(q.row_f(prefix + "x"), q.row_f(prefix + "y"), q.row_f(prefix + "z"))


## Fold the drained step's books, keyed on the step its reduction ran at, so one drain folds once.
func sample() -> void:
	if _f == null or _f._queries == null:
		return
	_n.set_seal(_f._seal)
	_n.momentum_sample(_f._queries.row_n("reduce_step"), _row3("open_mom_"), _row3("bodyf_"), _row3("bnd_mom_"))


func report(step_index: int) -> Dictionary:
	if _f == null or _f._queries == null:
		return {}
	var q: LAMaterialFieldQueries3D = _f._queries
	return _n.momentum_report(step_index, _row3("open_mom_"), _row3("bodyf_"), _row3("bnd_mom_"),
		q.row_f("momentum_carried"), q.row_f("momentum_mass_kg"), q.row_n("momentum_cells"))
