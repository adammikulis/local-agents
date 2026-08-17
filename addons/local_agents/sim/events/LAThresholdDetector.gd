class_name LAThresholdDetector
extends LAEventDetector


var type_name: String = ""            # LAEvent.type this detector emits
var key: String = ""                  # snapshot key it reads
var mode: String = "cross_up"         # "cross_up" | "increment" | "rate"
var threshold: float = 0.0            # fire bar (cross_up: level; increment: min step; rate: per-second)
var rearm: float = 0.0                # cross_up hysteresis floor (must fall below this to re-arm)
var escalate_factor: float = 2.0      # cross_up: re-fire once the held value multiplies past this
var cooldown_s: float = 3.0           # increment/rate: min seconds between emits
var intensity_base: float = 6.0
var intensity_scale: float = 0.0      # intensity per unit past the bar (0 = flat intensity_base)
var intensity_max: float = 40.0
var description_text: String = ""     # narratable sentence; consumers read LAEvent.description

var _armed: bool = true               # cross_up: ready to fire (below rearm)
var _last_fired_value: float = 0.0    # cross_up escalation reference
var _time_since_emit: float = 1.0e9   # increment/rate cooldown accumulator


func phenomenon() -> String:
	return type_name


## False when this detector's signal has never moved, so a detector watching a channel nothing writes is
## reported rather than silently watched.
func signal_live(cur: Dictionary) -> bool:
	if mode == "increment":
		return float(cur.get(key, 0.0)) > 0.0 or _last_fired_value > 0.0
	return cur.has(key)


func detect(prev: Dictionary, cur: Dictionary, dt: float) -> Array:
	_time_since_emit += dt
	var v: float = float(cur.get(key, 0.0))
	var out: Array = []
	if mode == "cross_up":
		if _armed and v > threshold:
			out.append(_emit(v, v - threshold))
			_armed = false
			_last_fired_value = v
		elif not _armed:
			if v < rearm:
				_armed = true                                 # dropped back down — re-arm for the next onset
			elif v >= _last_fired_value * escalate_factor:
				out.append(_emit(v, v - threshold))           # still high but markedly bigger — escalation
				_last_fired_value = v
	elif mode == "increment":
		var pv: float = float(prev.get(key, 0.0))
		if v - pv >= threshold and _time_since_emit >= cooldown_s:
			out.append(_emit(v, v - pv))
			_time_since_emit = 0.0
	elif mode == "rate":
		var pv2: float = float(prev.get(key, 0.0))
		var rate: float = (v - pv2) / maxf(0.0001, dt)
		if rate >= threshold and _time_since_emit >= cooldown_s:
			out.append(_emit(v, rate - threshold))
			_time_since_emit = 0.0
	return out


func _emit(_value: float, over: float) -> LAEvent:
	var intensity: float = clampf(intensity_base + intensity_scale * maxf(0.0, over), intensity_base, intensity_max)
	return LAEvent.make(type_name, intensity, description_text)
