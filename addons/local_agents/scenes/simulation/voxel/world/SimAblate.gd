class_name LAAblate
extends RefCounted

## Perf ablation kill-switches (dev tool). Set env LA_ABLATE to a comma-separated list of system names to
## SKIP their per-frame work, so you can "remove all systems, then add them back one at a time" to attribute
## per-system cost and pin a regression. Example: LA_ABLATE=plants,trees,field,water leaves only creatures +
## ecology running. Parsed once from the environment and cached; a bare `off()` call is a dictionary lookup.
##
## If a system cannot be ablated by a single guard at its per-frame entry, that is a refactor smell — give it
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
