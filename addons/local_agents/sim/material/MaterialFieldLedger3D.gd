class_name LAMaterialFieldLedger3D
extends RefCounted

## THE conservation ledger. LAFieldLedger keeps the books in double; this drains the device into it and
## hands it the minted rock and the injected joules, which the field owns and the ledger does not.

var _f = null
var _n: LAFieldLedger = null


func setup(field) -> void:
	_f = field
	_n = LAFieldLedger.new()
	_n.configure(LAFieldLedgerRecords.tables())


## ONE drain, folded on the field step. take_pass_results CONSUMES, so a drain nobody folds is a step's
## crossings thrown away — and a crossing is a flux, which only integrates if every step is counted.
## Returns the step the folded drain's reduction ran at, -1 when no drain waited or it carried no step.
func sample() -> int:
	if _f == null or _f._cell_count <= 0 or _f._gpu == null:
		return -1
	if not _f._gpu.has_method("take_pass_results"):
		return -1
	var drained: Dictionary = _f._gpu.take_pass_results()
	if drained.is_empty():
		return -1
	_n.set_seal(_f._seal)
	_n.fold(drained, _minted(), _injected_j())
	return int(drained.get("reduce_step", -1))


## Every conserved substance, published together from the last fold. A stock may be read on any cadence;
## `step_index` is the field's own step counter, never a frame.
func report(step_index: int) -> Dictionary:
	if _f == null or _f._cell_count <= 0:
		return {}
	_n.set_seal(_f._seal)
	return _n.report(step_index, _minted(), _injected_j())


## One published total, for a consumer outside the report path.
func total(key: String) -> float:
	return _n.total(key)


## The silicate injection created, as the device's own tally reads it.
func _minted() -> float:
	if _f._gpu == null or not _f._gpu.has_method("inject_created"):
		return 0.0
	return float(_f._gpu.inject_created("silicate"))


func _injected_j() -> float:
	if _f._inject == null or _f._inject.queue == null:
		return 0.0
	return float(_f._inject.queue.heat_landed_j)
