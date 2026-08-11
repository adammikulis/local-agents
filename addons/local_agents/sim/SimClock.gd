class_name LASimClock
extends Node

## LASimClock — the world's ELAPSED TIME, and the one module that owns it.
##
## The sim had none. LAVoxelSkyCycle integrated a `_time_of_day` float that WRAPS at 1.0 and never
## accumulates (`fposmod(_time_of_day + delta / DAY_LENGTH, 1.0)`), so nothing could answer "what day is
## it"; LAWorldSaveState persisted no day count; and every dated write into the backstory store
## (add_relationship, update_quest_state and record_relationship_interaction all hard-require
## world_day >= 0) had nowhere to read a day from — LAAgentBackstory sidestepped it by hardcoding
## world_day = -1, which is legal for memories and for nothing else.
##
## Deliberately NOT bolted into the sky cycle. A sky cycle is a RENDERING node: it draws the sun arc, the
## moon phase and the horizon colour. It is now a CONSUMER of this clock (see
## LAVoxelSkyCycle._update_day_night) instead of the source of time, so the day count does not depend on
## whether the sky happens to be in planet mode, and a world with no sky still has a history.
##
## It is a Node, not a RefCounted, for one reason worth stating: `_process(delta)` already arrives scaled
## by Engine.time_scale, so pausing pauses history and `--fast=N` fast-forwards it, with no extra wiring
## and no second notion of time to keep in sync.
##
## Readers reach it through the static `active()` locator (the LAWorldSaveController idiom) rather than
## being threaded a reference: LAVoxelSkyCycle for the sun/moon phase, LABandChronicle for the day it
## stamps dated MEMBER_OF records with and for set_world_time(), LAWorldSaveState to persist and resume.
## (Explicit types only, no ':=' inferred typing.)

## Seconds of simulated time in one day. This is the SINGLE source: LAVoxelSkyCycle.DAY_LENGTH now reads
## it, so the sun arc and the day count can never disagree about how long a day is.
const DAY_LENGTH: float = 200.0

## Days in one season, and the season names in order. This is a NAMING of elapsed time and nothing more —
## the physical seasons (axial tilt vs the orbit plane, insolation) are LASystemOrbits' business and are
## unaffected by what this calls the current stretch of days. It exists because the store's world-time
## record is `set_world_time(day, season, calendar)` and a season derived from the clock is real data a
## day-windowed query can read back, where an empty string is not.
const DAYS_PER_SEASON: int = 4
const SEASONS: Array[String] = ["spring", "summer", "autumn", "winter"]
const CALENDAR: String = "sim"

## Emitted the frame the integer day rolls over, carrying the new day. The chronicle listens so the store's
## world-time record is written once per day rather than polled per frame.
signal day_advanced(day: int)

static var _active: LASimClock = null

var _elapsed: float = 0.0     # total simulated seconds since the world started (never wraps)
var _day: int = 0             # cached int(_elapsed / DAY_LENGTH), so the rollover is one compare per frame


## The live clock, or null when no world has one (a bare demo scene, a unit test). Callers null-guard;
## see world_day() below for the one-line read that does it for you.
static func active() -> LASimClock:
	return _active


## The current world day, or 0 when there is no clock. Safe to call from anywhere, including code that
## runs before the world is built.
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


## Fraction through the current day: 0 = the day's start, 0.5 = halfway. The sky adds its own seeded phase
## offset on top, because "what time the world starts at" is a presentation choice, not a property of time.
func day_fraction() -> float:
	return fposmod(_elapsed / DAY_LENGTH, 1.0)


func season() -> String:
	return SEASONS[(_day / DAYS_PER_SEASON) % SEASONS.size()]


## SAVE: the whole clock is one float. Everything else (day, fraction, season) derives from it, so there is
## no second field that can be restored out of step with the first.
func serialize() -> Dictionary:
	return {"elapsed": _elapsed}


## RESTORE: resume the saved elapsed time. Does NOT emit day_advanced — a reload is not the world living
## through those days, and re-emitting would make the chronicle re-stamp a day that already happened.
func restore(data: Dictionary) -> void:
	_elapsed = maxf(0.0, float(data.get("elapsed", 0.0)))
	_day = int(_elapsed / DAY_LENGTH)
