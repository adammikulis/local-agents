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
