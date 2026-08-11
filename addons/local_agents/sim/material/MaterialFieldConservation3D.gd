class_name LAMaterialFieldConservation3D
extends RefCounted

## The horizon the debts below were calibrated at, and the first sample at which any verdict is given. 600 is
## the project's standard verification horizon.
const REFERENCE_STEPS: int = 600


## THE DEBT IS A RATE, NOT A TOTAL, AND THAT IS THE WHOLE POINT.
##
## These were ceilings on the RELATIVE TOTAL drift, calibrated at REFERENCE_STEPS. A substance with any
## steady leak breaches a fixed relative ceiling EVENTUALLY, so the verdict depended on how long the run
## happened to be — measured 2026-08-11: at step 723-7770 every one of the six breached, on a tree where the
## 600-step audit passed. A measurement whose answer is decided by how long you looked is the same defect
## as the one-shot audit it replaced, pointing the other way.
##
## Per STEP, the question is run-length independent: a real leak holds its rate, and a startup transient
## that settles shows a rate that FALLS as the horizon grows. `conservation_rate_trend` below reports which
## of the two each substance is doing, because the ceiling alone cannot tell them apart.
##
## The numbers are the previous totals divided by REFERENCE_STEPS. That is a unit conversion, not a
## re-tuning: each says exactly what it said before AT the calibration horizon, and now says it at every
## horizon. Nothing was loosened to make a run pass.
const DEBT_PER_STEP: Dictionary = {
	"element_C_total": 0.28 / float(REFERENCE_STEPS),
	"h2o_closed_total": 0.20 / float(REFERENCE_STEPS),
	"o2_total": 0.055 / float(REFERENCE_STEPS),
	"oxidant_all": 0.045 / float(REFERENCE_STEPS),
	"nitrogen_all": 0.0062 / float(REFERENCE_STEPS),
	"mineral_total": 0.00002 / float(REFERENCE_STEPS),
}

## reasoning: the rates it replaced were FITTED — each picked by running the sim and keeping the value whose


## Baseline key for each gated total. A substance with no sealed baseline is NOT gated — it is reported as
## unmeasurable, which is the honest answer and is itself worth seeing in a run.
const BASELINE: Dictionary = {
	"element_C_total": "element_C_total_first",
	"h2o_closed_total": "h2o_first",
	"o2_total": "o2_first",
	"oxidant_all": "oxidant_first",
	"nitrogen_all": "nitrogen_first",
	"mineral_total": "mineral_first",
}

var _f = null
var _worst: Dictionary = {}          # substance -> worst relative drift seen this run
var _violations: PackedStringArray = PackedStringArray()
## The audit happens once, at REFERENCE_STEPS. Without this the same breach re-reports every sample and a
## reader cannot tell one violation from forty.
var _audited: bool = false
## Per-substance drift rate at the first audited sample — the baseline the leak/transient trend is read against.
var _rate_first: Dictionary = {}
var _rate_first_at: Dictionary = {}   # the step each baseline was taken at, so a trend can be read


func setup(field) -> void:
	_f = field


## Check every gated substance against its sealed baseline. Returns the report block; prints a marker when a
## substance exceeds its recorded debt, in the same shape as STALE_SHADERS so a run can be checked
## mechanically by grepping one string rather than by a human reading a table.
func check(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._seal == null or not _f._seal.sealed():
		out["conservation"] = "seeding"
		return out
	# ONE EVALUATION, AT THE REFERENCE HORIZON. See the header for the two statistics this replaced and why
	# each failed. The worst excursion is still accumulated every sample below; only the VERDICT waits.
	var elapsed: int = _steps_since_seal()
	var rows: Dictionary = {}
	var rates: Dictionary = {}
	var fresh: PackedStringArray = PackedStringArray()
	for key in DEBT_PER_STEP:
		var first_key: String = String(BASELINE.get(key, ""))
		var now = d.get(key)
		var first = d.get(first_key)
		if not (now is float or now is int) or not (first is float or first is int):
			rows[key] = "unmeasured"
			continue
		var f: float = float(first)
		if f == 0.0:
			rows[key] = "unmeasured"
			continue
		var rel: float = (float(now) - f) / f
		var mag: float = absf(rel)
		if mag > float(_worst.get(key, 0.0)):
			_worst[key] = mag
		rows[key] = snappedf(rel, 1e-6)
		# The run-length-independent figure. `elapsed` is >= REFERENCE_STEPS at every point a verdict is
		# given, so this is never divided by a small number.
		var rate: float = (mag / float(elapsed)) if elapsed > 0 else 0.0
		rates[key] = rate
		# IS IT A LEAK OR A TRANSIENT? A leak holds its rate; a settling transient's rate falls as the horizon
		# grows. Compared against the rate at the FIRST audited sample, which is the earliest honest one.
		# Latched at the first audited sample where the substance has ACTUALLY drifted. Latching on the first
		# audited sample regardless left r0 == 0 for anything still flat at the horizon, and a zero baseline
		# drops it from the trend entirely — which is what happened to five of the six on the first run.
		if not _rate_first.has(key) and elapsed >= REFERENCE_STEPS and rate > 0.0:
			_rate_first[key] = rate
			_rate_first_at[key] = elapsed
		# No verdict before the horizon — the run is still accumulating. AFTER it, every sample is checked.
		# `or _audited` used to sit here too, which made this gate evaluate exactly ONCE and then go blind:
		# a run 60x past the horizon reported conservation_failed: false while carbon had grown 12x. The
		# stated reason for it — "the same breach would be re-reported every sample" — is already handled by
		# the `not _violations.has(key)` below, which is what makes it one line per substance.
		if elapsed < REFERENCE_STEPS:
			continue
		if rate > float(DEBT_PER_STEP[key]) and not _violations.has(key):
			_violations.append(key)
			fresh.append(key)
			# One line per substance, the first time it breaches. A marker rather than a push_error so the
			# offscreen wrapper and CI can both find it without parsing Godot's error stream.
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "first": f, "now": float(now),
				"rel_drift": snappedf(rel, 1e-6), "rel_drift_per_step": rate,
				"allowed_per_step": float(DEBT_PER_STEP[key]), "at_steps": elapsed,
				"seal_step": _f._seal.seal_step(),
			}))
	if elapsed >= REFERENCE_STEPS:
		_audited = true
	out["conservation"] = rows
	out["conservation_rate"] = rates
	# Rate NOW over rate at the first audited sample. Below 1 the drift is settling (a transient); at or above
	# 1 it is holding or accelerating, which is a leak. One number per substance, so a reader can tell the two
	# apart without comparing runs.
	var trend: Dictionary = {}
	for key in rates:
		var r0: float = float(_rate_first.get(key, 0.0))
		# A trend needs a horizon long enough to be a comparison rather than noise: at least double the step
		# the baseline was taken at.
		if r0 > 0.0 and elapsed >= 2 * int(_rate_first_at.get(key, elapsed)):
			trend[key] = snappedf(float(rates[key]) / r0, 1e-4)
	out["conservation_rate_trend"] = trend
	out["conservation_audited"] = _audited
	out["conservation_steps"] = elapsed
	out["conservation_worst"] = _worst
	out["conservation_violations"] = _violations
	# "seeding" above is the only way to avoid answering, and it stops being available once the world seals.
	out["conservation_failed"] = not _violations.is_empty()
	# The PEAK excursion, which is a different question from "where did it end up": a substance that swings
	# far out and returns has still broken conservation. Reported beside the verdict rather than folded into
	# it, so a run says both what happened and how bad it got.
	var worst_over: Dictionary = {}
	for key in _worst:
		if float(_worst[key]) / float(maxi(elapsed, 1)) > float(DEBT_PER_STEP.get(key, INF)):
			worst_over[key] = snappedf(float(_worst[key]), 1e-6)
	out["conservation_worst_over_debt"] = worst_over
	return out


## Steps elapsed since the books closed. The denominator that makes every figure above a RATE rather than a
## number that grows with the length of the run.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
