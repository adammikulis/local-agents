class_name LAAblate
extends RefCounted

## Perf ablation kill-switches (dev tool). Set env LA_ABLATE to a comma-separated list of system names to
## SKIP their per-frame work, so you can "remove all systems, then add them back one at a time" to attribute
## per-system cost and pin a regression. Example: LA_ABLATE=plants,trees,field,water leaves only creatures +
## ecology running. Parsed once from the environment and cached; a bare `off()` call is a dictionary lookup.
##
## If a system cannot be ablated by a single guard at its per-frame entry, that is a refactor smell. Give it
## a real entry point so it becomes toggleable (per the project's per-subsystem kill-switch guidance).
## Known names: creatures, plants, trees, fish, ecology, field, water, veg.

static var _set: Dictionary = {}
static var _parsed: bool = false

## True when `system` is listed in LA_ABLATE (its per-frame work should be skipped this run).
static func off(system: String) -> bool:
	if not _parsed:
		_parsed = true
		if OS.has_environment("LA_ABLATE"):
			for n in OS.get_environment("LA_ABLATE").split(",", false):
				_set[n.strip_edges()] = true
	return _set.has(system)


# --- LIFE MODE — test the PLANET without paying for the biosphere ------------------------------------------
#
# The planet and the biosphere are separable concerns, and testing them together is what makes a planet run
# slow. This is the first-class switch for that, and it is deliberately SYMMETRIC: turning life back on is the
# ABSENCE of a flag, so nothing has to be undone later and the shipped game is unaffected.
#
#   FULL         (default)      planet + vegetation + animals. What the game ships.
#   NO_FAUNA     --no-fauna     vegetation stays, animals go. Keeps the carbon cycle intact — R19
#                               photosynthesis is what produces biomass/O₂/CO₂, so a planet with no plants is
#                               chemically a DIFFERENT planet, not merely a faster one. Right default for
#                               climate and hydrology work.
#   PLANET_ONLY  --planet-only  pure geophysics: no plants, no animals. Fastest, and the only mode that can be
#                               fully deterministic — actors inject into the field (splashes perturb the charge
#                               channel, which is why bolt counts vary run to run), so with none present that
#                               last source of run-to-run variance is gone.
#
# UNLIKE `off()` ABOVE, THIS SKIPS SPAWNING, NOT JUST PER-FRAME WORK. `LA_ABLATE=creatures` suppresses the
# tick but still pays to build every actor — which is most of the cost, and all of the field perturbation.
#
# Precedence follows the project rule (explicit flag > project/env > default):
# Engine meta, set by the CLI flag > LA_LIFE_MODE env > full.
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


## Benchmark population-scale knob (dev tool). LA_SPAWN_SCALE multiplies BOTH the initial spawn counts and
## the breeding pop_caps, so a scaling sweep can vary the steady-state actor count cleanly (hold grid /
## resolution / effects fixed, change only N) and fit the empirical Big-O. Default 1.0 = unchanged.
static var _spawn_scale: float = -1.0
static func spawn_scale() -> float:
	if _spawn_scale < 0.0:
		_spawn_scale = 1.0
		if OS.has_environment("LA_SPAWN_SCALE"):
			_spawn_scale = maxf(0.05, float(OS.get_environment("LA_SPAWN_SCALE")))
	return _spawn_scale


## Evolution-observation knob (dev tool). LA_EVO_FAST=N compresses the BIOLOGICAL cadence — gestation,
## post-birth cooldown, mate refractory, and the maturity/grow-time threshold all divide by N — so generations
## turn over in ~1/N the sim-time (and compute) without touching Engine.time_scale (which can't help: physics is
## the bottleneck, so N steps/frame just makes each frame N× heavier). Lets a selection experiment reach several
## generations inside one short run so gene-mean drift is observable. Default 1.0 = realtime biology, fully inert.
static var _evo_fast: float = -1.0
static func evo_fast() -> float:
	if _evo_fast < 0.0:
		_evo_fast = 1.0
		if OS.has_environment("LA_EVO_FAST"):
			_evo_fast = clampf(float(OS.get_environment("LA_EVO_FAST")), 1.0, 50.0)
	return _evo_fast
