extends RefCounted
class_name LocalAgentsCadencePolicy

static func cadence_for_activity(activity: float, idle_cadence: int) -> int:
	var max_cadence = maxi(1, idle_cadence)
	var a = clampf(activity, 0.0, 1.0)
	return clampi(int(round(lerpf(float(max_cadence), 1.0, a))), 1, max_cadence)

static func should_step_with_key(step_key: String, tick: int, cadence: int, seed: int) -> bool:
	if cadence <= 1:
		return true
	var phase = abs(int(hash("%s|%d" % [step_key, seed]))) % cadence
	return (tick + phase) % cadence == 0

