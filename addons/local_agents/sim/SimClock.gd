class_name LASimClock
extends Node


const REAL_SECONDS_PER_SIM_SECOND: float = 432.0
# Rotation period, sim-clock seconds.
const DAY_LENGTH: float = TAU / (LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S * REAL_SECONDS_PER_SIM_SECOND)
const SPIN_RAD_PER_SIM_S: float = TAU / DAY_LENGTH

const DAYS_PER_SEASON: int = 4
const SEASONS: Array[String] = ["spring", "summer", "autumn", "winter"]
const CALENDAR: String = "sim"

signal day_advanced(day: int)

static var _active: LASimClock = null

var _elapsed: float = 0.0     # total simulated seconds since the world started (never wraps)
var _day: int = 0             # cached int(_elapsed / DAY_LENGTH), so the rollover is one compare per frame


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


func _process(delta: float) -> void:
	_elapsed += delta
	var d: int = int(_elapsed / DAY_LENGTH)
	if d != _day:
		_day = d
		day_advanced.emit(d)


func elapsed() -> float:
	return _elapsed


func day() -> int:
	return _day


func days_elapsed() -> float:
	return _elapsed / DAY_LENGTH


func day_fraction() -> float:
	return fposmod(_elapsed / DAY_LENGTH, 1.0)


func season() -> String:
	return SEASONS[(_day / DAYS_PER_SEASON) % SEASONS.size()]


## SAVE: the whole clock is one float. Everything else (day, fraction, season) derives from it, so there is
## no second field that can be restored out of step with the first.
func serialize() -> Dictionary:
	return {"elapsed": _elapsed}


func restore(data: Dictionary) -> void:
	_elapsed = maxf(0.0, float(data.get("elapsed", 0.0)))
	_day = int(_elapsed / DAY_LENGTH)
