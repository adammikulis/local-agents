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


## Gated quantity -> the PUBLISHED DIMENSIONLESS key it is asserted on; the ledger owns every ratio.
## `rel` is drift NET of what crossed the edge over the baseline PLUS what crossed, both zero on a shut
## wall; `+ turnover` is a residual of the EXCHANGE, denominated in what crossed rather than what is held.
const GATED: Dictionary = {
	"element_C_total": {"rel": "element_C_total_rel_drift"},
	"h2o_closed_total": {"rel": "h2o_rel_drift"},
	"o2_total": {"rel": "o2_rel_drift"},
	"oxidant_all": {"rel": "oxidant_rel_drift"},
	"nitrogen_all": {"rel": "nitrogen_rel_drift"},
	"mineral_total": {"rel": "mineral_rel_drift"},
	"energy_stock": {"rel": "energy_residual_rel", "turnover": "energy_turnover_j", "stock": "energy_stock"},
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
	# The round-off of a single float32 sum over this grid, already a FRACTION.
	var floor_rel: float = noise_floor(_f._cell_count if _f != null else 0)
	var rows: Dictionary = {}
	var allowed_by: Dictionary = {}
	var unmeasured: PackedStringArray = PackedStringArray()
	for key in GATED:
		var spec: Dictionary = GATED[key]
		var rel = d.get(String(spec["rel"]))
		var allowed: float = _allowed_rel(d, spec, floor_rel)
		# A tolerance at or past 1.0 cannot tell a wholly unaccounted window from round-off, so the row reads
		# UNMEASURED. A gate that cannot fail must never report a pass.
		if not (rel is float or rel is int) or not is_finite(allowed) or allowed >= 1.0:
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		allowed_by[key] = allowed
		# Seeded UNCONDITIONALLY. A row reading exactly 0.0 never cleared a `>` test, so the peak read below
		# threw and took the whole conservation block with it — every row after a conserved one went silent.
		var mag: float = absf(float(rel))
		_worst[key] = maxf(mag, float(_worst.get(key, 0.0)))
		rows[key] = snappedf(float(rel), 1e-12)
		if elapsed < REFERENCE_STEPS:
			continue
		# The PEAK, not the reading of the moment: a quantity that swings out and returns has still broken
		# conservation, and the peak is never smaller than the current drift.
		var peak: float = float(_worst[key])
		if peak > allowed and not _violations.has(key):
			_violations.append(key)
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "rel_key": String(spec["rel"]),
				"rel_drift": snappedf(float(rel), 1e-12), "worst_rel_drift": snappedf(peak, 1e-12),
				"allowed_rel": allowed, "at_steps": elapsed,
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
	out["conservation_allowed_rel"] = allowed_by
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


## The fraction below which a row cannot tell a breach from float32 round-off. A closed total's floor IS its
## sum's relative round-off; a residual's is that round-off re-expressed in units of the boundary exchange,
## two stock reads differenced in quadrature. INF when the row carries no denominator to answer on.
func _allowed_rel(d: Dictionary, spec: Dictionary, floor_rel: float) -> float:
	if not spec.has("turnover"):
		return floor_rel
	var turnover = d.get(String(spec["turnover"]))
	var stock = d.get(String(spec["stock"]))
	if not (turnover is float or turnover is int) or not (stock is float or stock is int):
		return INF
	if float(turnover) <= 0.0:
		return INF
	return sqrt(2.0) * floor_rel * absf(float(stock)) / float(turnover)


## Steps elapsed since the books closed.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
