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
## Every `rel` is a residual over the absolute book: drift net of what was booked, as a fraction of what
## is held. `reads` is the stock reads it differences, whose round-off adds in quadrature; 1 when absent.
const GATED: Dictionary = {
	"element_C_total": {"rel": "element_C_total_rel_drift"},
	"element_O_total": {"rel": "element_O_total_rel_drift"},
	"h2o_total": {"rel": "h2o_rel_drift"},
	"nitrogen_all": {"rel": "nitrogen_rel_drift"},
	"mineral_total": {"rel": "mineral_rel_drift"},
	"lith_Fe_total": {"rel": "lith_Fe_rel_drift"},
	"lith_Mg_total": {"rel": "lith_Mg_rel_drift"},
	"lith_Al_total": {"rel": "lith_Al_rel_drift"},
	"lith_Na_total": {"rel": "lith_Na_rel_drift"},
	"lith_Cl_total": {"rel": "lith_Cl_rel_drift"},
	"lith_P_total": {"rel": "lith_P_rel_drift"},
	"lith_Ca_total": {"rel": "lith_Ca_rel_drift"},
	"lith_Ni_total": {"rel": "lith_Ni_rel_drift"},
	"lith_F_total": {"rel": "lith_F_rel_drift"},
	"energy_held": {"rel": "energy_residual_stock_rel", "reads": 2},
	"charge_stock": {"rel": "charge_rel_drift", "reads": 2, "needs": "charge_separate"},
}

var _f = null
var _worst: Dictionary = {}          # substance -> peak relative excursion since the seal
var _violations: PackedStringArray = PackedStringArray()
## Latched only when every gated quantity produced a number at or past the horizon.
var _audited: bool = false
## CONSERVATION_UNMEASURED printed once, the first sample past the horizon that could not answer.
var _unmeasured_announced: bool = false
## The last audit's published block.
var _block: Dictionary = {}


func setup(field) -> void:
	_f = field


## The last audit. A world whose books never folded is audited on nothing, so every row reads unmeasured.
func block() -> Dictionary:
	return _block if not _block.is_empty() else check({}, -1)


## Check every gated quantity against its sealed baseline, on the books a drain reduced at `books_step`
## folded this step. Prints CONSERVATION_VIOLATION on a breach and CONSERVATION_UNMEASURED when one past
## the horizon had no number.
func check(d: Dictionary, books_step: int) -> Dictionary:
	var out: Dictionary = {}
	_block = out
	if _f == null or _f._seal == null or not _f._seal.sealed():
		out["conservation"] = "seeding"
		return out
	var elapsed: int = _span(d, books_step)
	# A world that never folded books is due its audit on the loop's clock: the absence is the finding.
	var due: bool = elapsed >= REFERENCE_STEPS or (books_step < 0 and _clock_since_seal() >= REFERENCE_STEPS)
	# The round-off of a single float32 sum over this grid, already a FRACTION.
	var floor_rel: float = noise_floor(_f._cell_count if _f != null else 0)
	var rows: Dictionary = {}
	var allowed_by: Dictionary = {}
	var unmeasured: PackedStringArray = PackedStringArray()
	for key in GATED:
		var spec: Dictionary = GATED[key]
		# A quantity no process in THIS world produces is absent, not a stock that went unmeasured.
		if spec.has("needs") and not LAProcessSet.has_record("transport", String(spec["needs"])):
			continue
		var rel = d.get(String(spec["rel"]))
		var allowed: float = floor_rel * sqrt(float(spec.get("reads", 1)))
		if not (rel is float or rel is int):
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		allowed_by[key] = allowed
		# Seeded UNCONDITIONALLY. A row reading exactly 0.0 never cleared a `>` test, so the peak read below
		# threw and took the whole conservation block with it — every row after a conserved one went silent.
		var mag: float = absf(float(rel))
		_worst[key] = maxf(mag, float(_worst.get(key, 0.0)))
		rows[key] = snappedf(float(rel), 1e-12)
		if not due:
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
	if due and unmeasured.is_empty():
		_audited = true
	if due and not unmeasured.is_empty() and not _unmeasured_announced:
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
	out["conservation_starved"] = due and not unmeasured.is_empty()
	out["conservation_failed"] = bool(out["conservation_violated"]) or bool(out["conservation_starved"])
	return out


## Steps the books span: from the drain every baseline latched on to the one audited. 0 with either absent.
func _span(d: Dictionary, books_step: int) -> int:
	var base: int = int(d.get("world_baseline_step", -1))
	if books_step < 0 or base < 0:
		return 0
	return books_step - base


## Loop steps since the seal.
func _clock_since_seal() -> int:
	var loop: LASimLoop = LASimLoop.active()
	if loop == null or _f._seal == null:
		return 0
	return loop.step_index() - _f._seal.seal_step()
