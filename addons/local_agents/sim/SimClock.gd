class_name LASimClock
extends Node


const CALENDAR: String = "sim"

signal day_advanced(day: int)

static var _active: LASimClock = null

var _day: int = 0             # cached int(elapsed() / day_length()), so a rollover is one compare per step
var _body = null              # LAPlanetBody: a day is ITS rotation period, measured


## The body whose spin this clock is counting. Until one is set the day length is unmeasured, and the
## calendar refuses to advance rather than counting days of a length nobody established.
func set_body(body) -> void:
	_body = body


## The planet's rotation period, simulated seconds: a turn over the spin rate its own inertia produced.
## NAN while unmeasured — a day is the body's spin, never a pacing knob.
func day_length() -> float:
	if _body == null or not is_instance_valid(_body) or not _body.has_method("angular_velocity_rad_s"):
		return NAN
	var w: float = float(_body.angular_velocity_rad_s())
	return NAN if not is_finite(w) or w <= 0.0 else TAU / w


## The live clock, or null when no world has one (a bare demo scene, a unit test). Callers null-guard;
## see world_day() below for the one-line read that does it for you.
static func active() -> LASimClock:
	return _active


static func world_day() -> int:
	return _active._day if _active != null else 0


## Total elapsed days as a FLOAT (2.5 = midday of day two). The sky reads this for the sun and moon phase,
## which is why it is unwrapped: the lunar cycle is longer than a day and would lose its place otherwise.
static func days_elapsed_now() -> float:
	return _active.days_elapsed() if _active != null else 0.0


func _ready() -> void:
	_active = self


func _exit_tree() -> void:
	if _active == self:
		_active = null


## One simulated step. Driven by LASimLoop and by nothing else.
func advance() -> void:
	var len_s: float = day_length()
	if not is_finite(len_s):
		return
	var d: int = int(elapsed() / len_s)
	if d != _day:
		_day = d
		day_advanced.emit(d)


## Simulated seconds since the world was sealed. LASimLoop counts them; nothing here restates one.
func elapsed() -> float:
	var loop: LASimLoop = LASimLoop.active()
	return loop.elapsed_s() if loop != null else 0.0


func steps() -> int:
	var loop: LASimLoop = LASimLoop.active()
	return loop.step_index() if loop != null else 0


func day() -> int:
	return _day


func days_elapsed() -> float:
	return elapsed() / day_length()


## SAVE: the whole clock is one step count, written out in simulated seconds. Everything else derives
## from it, so there is no second field that can be restored out of step.
func serialize() -> Dictionary:
	return {"elapsed": elapsed()}


func restore(data: Dictionary) -> void:
	var seconds: float = float(data.get("elapsed", 0.0))
	if not is_finite(seconds):
		push_error("LASimClock.restore: elapsed is %s. A clock is not restored to a time nobody has." % seconds)
		return
	var loop: LASimLoop = LASimLoop.active()
	if loop != null:
		loop.restore_elapsed_s(seconds)
	var len_s: float = day_length()
	_day = 0 if not is_finite(len_s) else int(elapsed() / len_s)
