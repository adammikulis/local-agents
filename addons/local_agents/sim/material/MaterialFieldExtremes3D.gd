class_name LAMaterialFieldExtremes3D
extends RefCounted

## LAMaterialFieldExtremes3D — MIN AND MAX EVER, AND WHEN. A general running-extremes register: hand it a
## named scalar each time the report is built and it keeps the lowest and highest value that scalar has ever
## taken, plus the frame and the simulated second it happened.
##
## WHY A SNAPSHOT IS NOT ENOUGH, which is this whole lane's lesson in one sentence: every number in SIM_REPORT
## is an INSTANT, sampled whenever something happens to ask for one. The coldest moment on a planet is the
## deep night side an hour before dawn; the hottest is the sub-solar point at noon. A sampler that fires at
## an unrelated cadence walks straight past both, and reports a planet that is milder than it is. Two entries
## in GODOT_BEST_PRACTICES.md are the same failure: `is_night()` returned false for entire runs and nothing
## caught it because nobody reported the gauge's min and max, and `temp_min` was read once and used to justify
## moving water's freezing point to 12.5 C.
##
## ADDING A SCALAR IS ONE LINE — `track("open_cold", temp_min)` — which is the point. A hardcoded list of six
## quantities would be the same failure one level up: whatever nobody thought to enumerate stays unmeasured.
##
## WHAT THIS ADDS OVER `LASimReport.gauge()`, which does already keep cur/min/max (SimReport.gd:41-47):
##   * The frame and simulated second of each extreme. A minimum with no timestamp cannot be correlated with
##     the event that caused it, so "it got to -14 C" and "it got to -14 C at field_sim_s 118, four seconds
##     after the impact" are different quantities of information.
##   * It works on PROVIDER values. The field publishes its aggregates through LASimReport.register(), and
##     provider dicts are merged into the snapshot verbatim — no min/max is kept for any of them. Every
##     climate number this project has ever argued about arrives by that path.
## Nothing here is reset by a snapshot, and `reset()` is deliberately not called anywhere: the register spans
## the whole run, because the whole complaint is that a run's extremes were being lost between samples.
##
## Costs O(tracked keys) per report and nothing per frame. It never scans the field — it only ever sees
## scalars its caller has already computed.
## (Explicit types only, no ':=' inferred typing.)

## key -> {"min", "max", "min_frame", "max_frame", "min_sim_s", "max_sim_s", "n", "cur"}
var _rec: Dictionary = {}
var _order: PackedStringArray = PackedStringArray()   # insertion order, so the report reads the same way twice


## Record one observation of `key`. Stamps the PHYSICS frame (the simulation's own clock — a render-frame
## count tracks framerate, not behaviour) and the field's simulated seconds, so an extreme can be placed
## against `field_sim_s` in the same report.
func track(key: String, value: float) -> void:
	if not is_finite(value):
		return                              # a NaN would poison min/max forever; drop it and keep the register usable
	var frame: int = int(Engine.get_physics_frames())
	var sim_s: float = LASimReport.gauge_cur("field_sim_s", 0.0)
	var r: Dictionary = _rec.get(key, {})
	if r.is_empty():
		_order.append(key)
		_rec[key] = {
			"min": value, "max": value, "cur": value,
			"min_frame": frame, "max_frame": frame,
			"min_sim_s": sim_s, "max_sim_s": sim_s, "n": 1,
		}
		return
	r["cur"] = value
	r["n"] = int(r["n"]) + 1
	if value < float(r["min"]):
		r["min"] = value
		r["min_frame"] = frame
		r["min_sim_s"] = sim_s
	if value > float(r["max"]):
		r["max"] = value
		r["max_frame"] = frame
		r["max_sim_s"] = sim_s
	_rec[key] = r


## One `ext_<key>` entry per tracked scalar. `span` is max - min: a zero span on a quantity that is supposed
## to vary is the red flag GODOT_BEST_PRACTICES.md names — a frozen scalar is indistinguishable from a
## working one until you report both ends.
func report() -> Dictionary:
	var out: Dictionary = {}
	for key in _order:
		var r: Dictionary = _rec[key]
		out["ext_" + key] = {
			"min": snappedf(float(r["min"]), 0.001),
			"max": snappedf(float(r["max"]), 0.001),
			"cur": snappedf(float(r["cur"]), 0.001),
			"span": snappedf(float(r["max"]) - float(r["min"]), 0.001),
			"min_frame": int(r["min_frame"]), "max_frame": int(r["max_frame"]),
			"min_sim_s": snappedf(float(r["min_sim_s"]), 0.1),
			"max_sim_s": snappedf(float(r["max_sim_s"]), 0.1),
			"n": int(r["n"]),
		}
	return out
