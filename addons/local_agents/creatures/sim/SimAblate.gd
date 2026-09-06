class_name LAAblate
extends RefCounted


static var _set: Dictionary = {}
static var _parsed: bool = false
static var _nodes: Dictionary = {}        # name -> the node that IS that system

## `--ablate=a,b` on the command line, or LA_ABLATE in the environment.
static func off(system: String) -> bool:
	if not _parsed:
		_parsed = true
		var csv: String = OS.get_environment("LA_ABLATE")
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--ablate="):
				csv += "," + arg.substr("--ablate=".length())
		for n in csv.split(",", false):
			_set[n.strip_edges()] = true
	return _set.has(system)


## Every per-frame module answers to ONE name here. Off = no processing, no timers, not drawn.
static func adopt(name: String, node: Node) -> void:
	if node == null:
		return
	_nodes[name] = node
	if off(name):
		set_on(name, false)
		print("ABLATED={name:%s}" % name)


static func set_on(name: String, on: bool) -> void:
	var node: Node = _nodes.get(name, null)
	if node == null or not is_instance_valid(node):
		return
	node.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	if "visible" in node and not (node is Camera3D):
		node.set("visible", on)


static func names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray(_nodes.keys())
	out.sort()
	return out


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


static var _evo_fast: float = -1.0
static func evo_fast() -> float:
	if _evo_fast < 0.0:
		_evo_fast = 1.0
		if OS.has_environment("LA_EVO_FAST"):
			_evo_fast = clampf(float(OS.get_environment("LA_EVO_FAST")), 1.0, 50.0)
	return _evo_fast
