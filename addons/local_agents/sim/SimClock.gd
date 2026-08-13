class_name LASimClock
extends Node


# The planet's rotation period, simulated seconds. A day is the body's spin, not a pacing knob.
const DAY_LENGTH: float = TAU / LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S

const DAYS_PER_SEASON: int = 4
const SEASONS: Array[String] = ["spring", "summer", "autumn", "winter"]
const CALENDAR: String = "sim"

signal day_advanced(day: int)

static var _active: LASimClock = null

var _step: int = 0            # THE counter. Every time reading below derives from it.
var _day: int = 0             # cached int(elapsed() / DAY_LENGTH), so the rollover is one compare per step


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
	_step += 1
	var d: int = int(elapsed() / DAY_LENGTH)
	if d != _day:
		_day = d
		day_advanced.emit(d)


## Simulated seconds since the world was sealed.
func elapsed() -> float:
	return float(_step) * LAMaterialFieldSphereStep3D.SIM_SECONDS_PER_STEP


func steps() -> int:
	return _step


func day() -> int:
	return _day


func days_elapsed() -> float:
	return elapsed() / DAY_LENGTH


func day_fraction() -> float:
	return fposmod(elapsed() / DAY_LENGTH, 1.0)


func season() -> String:
	return SEASONS[(_day / DAYS_PER_SEASON) % SEASONS.size()]


## SAVE: the whole clock is one step count, written out in simulated seconds. Everything else (day,
## fraction, season) derives from it, so there is no second field that can be restored out of step.
func serialize() -> Dictionary:
	return {"elapsed": elapsed()}


func restore(data: Dictionary) -> void:
	_step = int(maxf(0.0, float(data.get("elapsed", 0.0))) / LAMaterialFieldSphereStep3D.SIM_SECONDS_PER_STEP)
	_day = int(elapsed() / DAY_LENGTH)
	var loop: LASimLoop = LASimLoop.active()
	if loop != null:
		loop.restore_elapsed_s(elapsed())
