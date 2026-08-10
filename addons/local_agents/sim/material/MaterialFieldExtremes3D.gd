class_name LAMaterialFieldExtremes3D
extends RefCounted


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
