class_name LAFieldLedgerBooks3D
extends RefCounted

## Per-sample drift and the run-long baseline, keyed by name.

var _f = null
var _prev_v: Dictionary = {}
var _prev_s: Dictionary = {}
var _first_v: Dictionary = {}
var _first_s: Dictionary = {}


func setup(field) -> void:
	_f = field


func sealed() -> bool:
	return _f != null and _f._seal != null and _f._seal.sealed()


func note_seed(key: String, value: float) -> void:
	if _f != null and _f._seal != null:
		_f._seal.note_seed({key: value})


## Returns [drift, per_step, steps] against the previous sample, or [] when there is none.
func sample(key: String, value: float, step: int) -> Array:
	var out: Array = []
	if _prev_s.has(key):
		var steps: int = step - int(_prev_s[key])
		if steps > 0:
			var d: float = value - float(_prev_v[key])
			out = [d, d / float(steps), steps]
	if not _prev_s.has(key) or step > int(_prev_s[key]):
		_prev_v[key] = value
		_prev_s[key] = step
	return out


## Returns [first, drift, per_step, run_steps, first_step] against the sealed baseline, or [] until sealed.
func run(key: String, seed_key: String, value: float, step: int) -> Array:
	if not _first_s.has(key):
		if not sealed():
			return []
		_first_v[key] = value
		_first_s[key] = step
		if seed_key != "":
			note_seed(seed_key, value)
	var f: float = float(_first_v[key])
	var first_step: int = int(_first_s[key])
	var steps: int = step - first_step
	var per_step: float = ((value - f) / float(steps)) if steps > 0 else 0.0
	return [f, value - f, per_step, steps, first_step]


## The latched baseline for a key, or NAN when it has not latched.
func first_of(key: String) -> float:
	return float(_first_v[key]) if _first_v.has(key) else NAN


func first_step_of(key: String) -> int:
	return int(_first_s[key]) if _first_s.has(key) else -1
