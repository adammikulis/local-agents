class_name LAMaterialFieldConservation3D
extends RefCounted

## The horizon the debts below were calibrated at, and the first sample at which any verdict is given. 600 is
## the project's standard verification horizon.
const REFERENCE_STEPS: int = 600

## Machine epsilon for the IEEE-754 binary32 the GPU buffers carry, written as the computation rather than
## its value: 2^-24, the gap between 1.0 and the next representable float32. A property of the format.
const FLOAT32_EPSILON: float = 1.0 / 16777216.0

## The only tolerance a conservation ledger is entitled to, and it is DERIVED rather than picked. Summing N
## float32 values accumulates relative round-off of order sqrt(N)·eps, so the floor depends on how many cells
## there are — 1.6e-5 at 69120 cells. Writing a single constant here would have been a number I chose, and
## the model-parameters gate said so the moment I tried.
static func noise_floor(cell_count: int) -> float:
	return sqrt(float(maxi(cell_count, 1))) * FLOAT32_EPSILON


## A CONSERVED SUBSTANCE DRIFTS AT ZERO. THE ONLY HONEST CEILING IS FLOAT NOISE.
##
## These were six per-substance allowances, each carried forward from a measured run — and every one of
## those runs is now known to be unreadable. They were taken with flat-summed totals over cells that differ
## in volume by up to 8.8x, before `element_C_mol` was in moles, on a substrate whose `energy_stock` moves
## 87% depending on whether anyone is watching and whose two runs at ONE SEED differ by 0.41%.
##
## When the debts were reshaped from totals to rates on 2026-08-11 the values were preserved deliberately,
## described as "a unit conversion, not a re-tuning — nothing was loosened". That was the wrong instinct
## dressed as rigour: it protected six numbers whose provenance had already been invalidated. A ceiling
## measured through a broken instrument is not a bar, it is a licence to leak up to it.
##
## So there is one number, and it is float noise. Conservation means the total does not change. Everything
## breaches this today; that is the correct reading, not a reason to raise it. RAISING ANY OF THESE
## REQUIRES THE MAINTAINER, and a measurement taken after the floor holds — determinism, observer
## independence and a physics-clock horizon — because until then no run can justify a number.
const DEBT_PER_STEP: Dictionary = {
	"element_C_total": 0.0, "h2o_closed_total": 0.0, "o2_total": 0.0,
	"oxidant_all": 0.0, "nitrogen_all": 0.0, "mineral_total": 0.0,
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
		# A zero entry means "no allowance beyond arithmetic": use the derived float floor for THIS grid.
		var ceiling: float = float(DEBT_PER_STEP[key])
		if ceiling <= 0.0:
			ceiling = noise_floor(_f._cell_count if _f != null else 0)
		if rate > ceiling and not _violations.has(key):
			_violations.append(key)
			fresh.append(key)
			# One line per substance, the first time it breaches. A marker rather than a push_error so the
			# offscreen wrapper and CI can both find it without parsing Godot's error stream.
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "first": f, "now": float(now),
				"rel_drift": snappedf(rel, 1e-6), "rel_drift_per_step": rate,
				"allowed_per_step": ceiling, "at_steps": elapsed,
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
		var w_ceil: float = float(DEBT_PER_STEP.get(key, 0.0))
		if w_ceil <= 0.0:
			w_ceil = noise_floor(_f._cell_count if _f != null else 0)
		if float(_worst[key]) / float(maxi(elapsed, 1)) > w_ceil:
			worst_over[key] = snappedf(float(_worst[key]), 1e-6)
	out["conservation_worst_over_debt"] = worst_over
	return out


## Steps elapsed since the books closed. The denominator that makes every figure above a RATE rather than a
## number that grows with the length of the run.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
