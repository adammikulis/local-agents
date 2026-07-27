class_name LAThresholdDetector
extends LAEventDetector

## The GENERIC, CONFIG-DRIVEN detector — one class covers every "a scalar field aggregate crossed a
## threshold" phenomenon (eruption, wildfire, flood, storm, lightning, impact). This is "config over
## `if type == X`" applied to detection: the registry is a LIST of these configured with (key, mode,
## threshold, intensity), NOT a monolith with a branch per phenomenon. A new threshold phenomenon = one
## more configured record.
##
## Three modes, each with its own debounce so an ongoing phenomenon is not re-emitted every sample:
##   • "cross_up" — fire when `cur[key]` rises above `threshold` from below `rearm` (HYSTERESIS: must
##                  drop back under `rearm` to re-arm). While held high, an escalation fires if the value
##                  grows past the last-fired value by `escalate_factor`. Used for lava_total / wind /
##                  heat that ramp up and stay up.
##   • "increment" — fire when the value (a cumulative counter like `bolts`) increases, gated by
##                   `cooldown_s`. Each strike/increment is its own event.
##   • "rate"      — fire when the per-second RISE `(cur-prev)/dt` exceeds `threshold`, gated by
##                   `cooldown_s`. Used for a FAST rise off a large baseline (a flood surge on
##                   water_total, an impact heat spike).
##
## Intensity scales with magnitude: `intensity_base + intensity_scale * <how far past the bar>`.
## (Explicit types only — project rule: no ':=' inferred typing.)

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

# --- debounce state ---
var _armed: bool = true               # cross_up: ready to fire (below rearm)
var _last_fired_value: float = 0.0    # cross_up escalation reference
var _time_since_emit: float = 1.0e9   # increment/rate cooldown accumulator


func phenomenon() -> String:
	return type_name


## bolts/charge/shock/magma are stubbed to 0 on the sphere path — treat a flatly-zero cumulative signal
## as dormant so the tracker can LOG "not producing yet" instead of silently watching a dead channel.
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
