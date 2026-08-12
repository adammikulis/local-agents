class_name LAAblate
extends RefCounted


static var _set: Dictionary = {}
static var _parsed: bool = false

static func off(system: String) -> bool:
	if not _parsed:
		_parsed = true
		if OS.has_environment("LA_ABLATE"):
			for n in OS.get_environment("LA_ABLATE").split(",", false):
				_set[n.strip_edges()] = true
	return _set.has(system)


const LIFE_FULL: String = "full"
const LIFE_NO_FAUNA: String = "no_fauna"
const LIFE_PLANET_ONLY: String = "planet_only"

static var _life_mode: String = ""


## Resolved life mode for this run — LIFE_FULL / LIFE_NO_FAUNA / LIFE_PLANET_ONLY.
static func life_mode() -> String:
	if _life_mode != "":
		return _life_mode
	_life_mode = LIFE_FULL
	if Engine.has_meta("la_life_mode"):
		_life_mode = String(Engine.get_meta("la_life_mode"))
	elif OS.has_environment("LA_LIFE_MODE"):
		_life_mode = OS.get_environment("LA_LIFE_MODE").strip_edges().to_lower()
	if _life_mode != LIFE_NO_FAUNA and _life_mode != LIFE_PLANET_ONLY:
		_life_mode = LIFE_FULL
	return _life_mode


## True when ANIMALS (creatures, fish, insects) must not be spawned or simulated at all.
static func fauna_off() -> bool:
	return life_mode() != LIFE_FULL


## True when VEGETATION must not be spawned either — pure geophysics. NOTE this changes the planet's
## CHEMISTRY (no photosynthesis → no biomass/O₂ production), so a climate number measured here is NOT
## comparable with one from a vegetated run. Always say which mode a measurement came from.
static func flora_off() -> bool:
	return life_mode() == LIFE_PLANET_ONLY


## One token for SIM_REPORT / logs, so every measurement records which world it was taken in.
static func life_mode_note() -> String:
	return life_mode()


static var _spawn_scale: float = -1.0
static func spawn_scale() -> float:
	if _spawn_scale < 0.0:
		_spawn_scale = 1.0
		if OS.has_environment("LA_SPAWN_SCALE"):
			_spawn_scale = maxf(0.05, float(OS.get_environment("LA_SPAWN_SCALE")))
	return _spawn_scale


static var _evo_fast: float = -1.0
static func evo_fast() -> float:
	if _evo_fast < 0.0:
		_evo_fast = 1.0
		if OS.has_environment("LA_EVO_FAST"):
			_evo_fast = clampf(float(OS.get_environment("LA_EVO_FAST")), 1.0, 50.0)
	return _evo_fast
