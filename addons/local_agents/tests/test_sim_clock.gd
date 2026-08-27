@tool
extends RefCounted


const ClockScript: GDScript = preload("res://addons/local_agents/sim/SimClock.gd")

## The one thing LASimClock reads off a planet: how fast it turns. Earth's sidereal rotation period is
## 86164.0905 s (IERS Conventions 2010).
class SpinningBody extends RefCounted:
	func angular_velocity_rad_s() -> float:
		return TAU / 86164.0905


func run_test(tree: SceneTree) -> bool:
	var clock: LASimClock = ClockScript.new()
	clock.set_body(SpinningBody.new())
	tree.get_root().add_child(clock)

	var ok: bool = _round_trip_keeps_the_time(clock)
	ok = _refuses_a_time_nobody_has(clock) and ok

	clock.queue_free()
	if ok:
		print("SimClock tests passed")
	return ok


## A save that loses time is a world that runs backwards over a reload, and the loss lands on a day
## boundary sooner or later. Step 15 is the first count whose serialized seconds divide back to less
## than itself in double precision; the rest are a day, five days and eight days in.
func _round_trip_keeps_the_time(clock: LASimClock) -> bool:
	var ok: bool = true
	for target_v in [1, 15, 30, 55, 1994, 9973, 15956]:
		var target: int = int(target_v)
		while clock.steps() < target:
			clock.advance()
		var steps_before: int = clock.steps()
		var day_before: int = clock.day()
		clock.restore(clock.serialize())
		ok = _assert(clock.steps() == steps_before,
			"a save and reload moved the clock from step %d to step %d" % [steps_before, clock.steps()]) and ok
		ok = _assert(clock.day() == day_before,
			"a save and reload moved the calendar from day %d to day %d" % [day_before, clock.day()]) and ok
	return ok


## A restore is not a place to invent a time. An elapsed nobody can read leaves the clock where it was.
func _refuses_a_time_nobody_has(clock: LASimClock) -> bool:
	var steps_before: int = clock.steps()
	clock.restore({"elapsed": NAN})
	return _assert(clock.steps() == steps_before,
		"a NAN elapsed moved the clock from step %d to step %d" % [steps_before, clock.steps()])


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
