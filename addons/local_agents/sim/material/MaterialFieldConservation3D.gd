class_name LAMaterialFieldConservation3D
extends RefCounted

## Steps past the seal at which the books are audited, and the first sample at which any verdict is given.
const REFERENCE_STEPS: int = 600

## Machine epsilon for the IEEE-754 binary32 the GPU buffers carry: 2^-24, the gap between 1.0 and the next
## representable float32. A property of the format.
const FLOAT32_EPSILON: float = 1.0 / 16777216.0

## Relative round-off of ONE sum of N float32 values, order sqrt(N)*eps. A single-sample magnitude with no
## time dimension: it is compared against a relative drift, never against a per-step rate.
static func noise_floor(cell_count: int) -> float:
	return sqrt(float(maxi(cell_count, 1))) * FLOAT32_EPSILON


## Gated quantity -> the report keys it is read from, and the only declaration of what is gated.
## `now`/`first`: a CLOSED total, nothing crosses the world boundary, so `now - first` must be zero.
## `unbooked`/`first`: an OPEN one, and the ledger has already subtracted every booked exchange with space.
const GATED: Dictionary = {
	"element_C_total": {"now": "element_C_total", "first": "element_C_total_first"},
	"h2o_closed_total": {"now": "h2o_closed_total", "first": "h2o_first"},
	"o2_total": {"now": "o2_total", "first": "o2_first"},
	"oxidant_all": {"now": "oxidant_all", "first": "oxidant_first"},
	"nitrogen_all": {"now": "nitrogen_all", "first": "nitrogen_first"},
	"mineral_total": {"now": "mineral_total", "first": "mineral_first"},
	"energy_stock": {"unbooked": "energy_residual", "first": "energy_stock_first"},
}

var _f = null
var _worst: Dictionary = {}          # substance -> peak relative excursion since the seal
var _violations: PackedStringArray = PackedStringArray()
## Latched only when every gated quantity produced a number at or past the horizon.
var _audited: bool = false
## CONSERVATION_UNMEASURED printed once, the first sample past the horizon that could not answer.
var _unmeasured_announced: bool = false


func setup(field) -> void:
	_f = field


## Check every gated quantity against its sealed baseline. Prints CONSERVATION_VIOLATION on a breach and
## CONSERVATION_UNMEASURED when one past the horizon could not produce a number.
func check(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._seal == null or not _f._seal.sealed():
		out["conservation"] = "seeding"
		return out
	var elapsed: int = _steps_since_seal()
	# One threshold for every row: the round-off of a single float32 sum over this grid.
	var ceiling: float = noise_floor(_f._cell_count if _f != null else 0)
	var rows: Dictionary = {}
	var unmeasured: PackedStringArray = PackedStringArray()
	for key in GATED:
		var spec: Dictionary = GATED[key]
		var first = d.get(String(spec["first"]))
		if not (first is float or first is int) or float(first) == 0.0:
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		var drift = _unbooked(d, spec, float(first))
		if drift == null:
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		var rel: float = float(drift) / absf(float(first))
		var mag: float = absf(rel)
		if mag > float(_worst.get(key, 0.0)):
			_worst[key] = mag
		rows[key] = snappedf(rel, 1e-9)
		if elapsed < REFERENCE_STEPS:
			continue
		# The PEAK, not the reading of the moment: a quantity that swings out and returns has still broken
		# conservation, and the peak is never smaller than the current drift.
		var peak: float = float(_worst[key])
		if peak > ceiling and not _violations.has(key):
			_violations.append(key)
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "first": float(first),
				"rel_drift": snappedf(rel, 1e-9), "worst_rel_drift": snappedf(peak, 1e-9),
				"allowed_rel": ceiling, "at_steps": elapsed,
				"seal_step": _f._seal.seal_step(),
			}))
	# A gate that cannot run must not pass: the audit latches only when every row produced a number.
	if elapsed >= REFERENCE_STEPS and unmeasured.is_empty():
		_audited = true
	if elapsed >= REFERENCE_STEPS and not unmeasured.is_empty() and not _unmeasured_announced:
		_unmeasured_announced = true
		print("CONSERVATION_UNMEASURED=", JSON.stringify({
			"substances": unmeasured, "at_steps": elapsed, "seal_step": _f._seal.seal_step()}))
	out["conservation"] = rows
	out["conservation_allowed_rel"] = ceiling
	out["conservation_audited"] = _audited
	out["conservation_steps"] = elapsed
	out["conservation_worst"] = _worst
	out["conservation_violations"] = _violations
	out["conservation_unmeasured"] = unmeasured
	# TWO CAUSES, TWO KEYS. A breach and a gate that could not run are different findings, so neither hides
	# inside the other. `conservation_failed` is their union.
	out["conservation_violated"] = not _violations.is_empty()
	out["conservation_starved"] = elapsed >= REFERENCE_STEPS and not unmeasured.is_empty()
	out["conservation_failed"] = bool(out["conservation_violated"]) or bool(out["conservation_starved"])
	return out


## The change since the seal that no booked exchange accounts for, or null when the row cannot answer.
func _unbooked(d: Dictionary, spec: Dictionary, first: float):
	if spec.has("unbooked"):
		var residual = d.get(String(spec["unbooked"]))
		return float(residual) if (residual is float or residual is int) else null
	var now = d.get(String(spec["now"]))
	return (float(now) - first) if (now is float or now is int) else null


## Steps elapsed since the books closed.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
