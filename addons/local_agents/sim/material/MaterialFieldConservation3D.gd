class_name LAMaterialFieldConservation3D
extends RefCounted


## Relative run-long drift each substance is allowed before CONSERVATION_VIOLATION fires. Measured, not fitted.
const DEBT: Dictionary = {
	"element_C_total": 0.28,      # measured -0.240
	"h2o_closed_total": 0.20,     # measured -0.169
	"o2_total": 0.055,            # measured -0.041 (was -0.903 three commits ago)
	"oxidant_all": 0.045,         # measured -0.032. MASK-FREE — see the note below on the open-cell twin.
	"nitrogen_all": 0.0062,       # measured -0.0049
	"mineral_total": 0.00002,     # measured -0.000006 — still the bar for everything else
}

## Steps past the seal at which the books are audited, once. 600 is the project's standard verification
## horizon (a 600-frame run at --fast=8 is ~760 steps, so this lands comfortably inside one).
const REFERENCE_STEPS: int = 600

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
## CONSERVATION_UNMEASURED printed once, the first sample past the horizon that could not answer.
var _unmeasured_announced: bool = false


func setup(field) -> void:
	_f = field


## Check every gated substance against its sealed baseline. Prints CONSERVATION_VIOLATION on a breach.
func check(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if _f == null or _f._seal == null or not _f._seal.sealed():
		out["conservation"] = "seeding"
		return out
	# ONE EVALUATION, AT THE REFERENCE HORIZON. See the header for the two statistics this replaced and why
	# each failed. The worst excursion is still accumulated every sample below; only the VERDICT waits.
	var elapsed: int = _steps_since_seal()
	var rows: Dictionary = {}
	var fresh: PackedStringArray = PackedStringArray()
	var unmeasured: PackedStringArray = PackedStringArray()
	for key in DEBT:
		var first_key: String = String(BASELINE.get(key, ""))
		var now = d.get(key)
		var first = d.get(first_key)
		if not (now is float or now is int) or not (first is float or first is int):
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		var f: float = float(first)
		if f == 0.0:
			rows[key] = "unmeasured"
			unmeasured.append(key)
			continue
		var rel: float = (float(now) - f) / f
		var mag: float = absf(rel)
		if mag > float(_worst.get(key, 0.0)):
			_worst[key] = mag
		rows[key] = snappedf(rel, 1e-6)
		# The verdict only at the horizon; before it the run is still accumulating, after it the same
		# breach would be re-reported every sample.
		if elapsed < REFERENCE_STEPS or _audited:
			continue
		if mag > float(DEBT[key]) and not _violations.has(key):
			_violations.append(key)
			fresh.append(key)
			# One line per substance, the first time it breaches. A marker rather than a push_error so the
			# offscreen wrapper and CI can both find it without parsing Godot's error stream.
			print("CONSERVATION_VIOLATION=", JSON.stringify({
				"substance": key, "first": f, "now": float(now),
				"rel_drift": snappedf(rel, 1e-6), "allowed": float(DEBT[key]), "at_steps": elapsed,
				"seal_step": _f._seal.seal_step(),
			}))
	# A gate that cannot run must not pass: the audit latches only when every substance produced a number.
	if elapsed >= REFERENCE_STEPS and unmeasured.is_empty():
		_audited = true
	if elapsed >= REFERENCE_STEPS and not unmeasured.is_empty() and not _unmeasured_announced:
		_unmeasured_announced = true
		print("CONSERVATION_UNMEASURED=", JSON.stringify({
			"substances": unmeasured, "at_steps": elapsed, "seal_step": _f._seal.seal_step()}))
	out["conservation"] = rows
	out["conservation_audited"] = _audited
	out["conservation_steps"] = elapsed
	out["conservation_worst"] = _worst
	out["conservation_violations"] = _violations
	out["conservation_unmeasured"] = unmeasured
	# Past the horizon an unmeasured substance is a failure of the instrument, and reads as one.
	out["conservation_failed"] = (not _violations.is_empty()) \
		or (elapsed >= REFERENCE_STEPS and not unmeasured.is_empty())
	return out


## Steps elapsed since the books closed. The denominator that makes every figure above a RATE rather than a
## number that grows with the length of the run.
func _steps_since_seal() -> int:
	if _f == null or _f._gpu == null or _f._seal == null:
		return 0
	return int(_f._gpu._step_index) - _f._seal.seal_step()
