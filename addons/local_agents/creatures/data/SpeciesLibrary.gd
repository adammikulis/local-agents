class_name LASpeciesLibrary
extends RefCounted

## Loads per-species creature configs from easy-to-find DATA files, keeping tuning OUT of the
## ecology's business logic. Configs live under `creatures/species/<class>/<kind>.json` (clustered by
## type — `mammals/`, `birds/`, `people/`, …), one file per species, so a designer edits a single
## small JSON to retune a creature without touching code.
##
## JSON can't hold Godot types, so this loader converts on read:
##   * "color": [r,g,b] or [r,g,b,a]      -> Color
##   * "preys_on"/"flees_from": [strings] -> PackedStringArray
## Everything else (numbers, bools, strings) passes through unchanged. Results are cached, and the
## folder tree is indexed once (recursively) so class-folder layout is free to change.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const SPECIES_DIR: String = "res://addons/local_agents/creatures/species"
const STRING_ARRAY_KEYS: Array = ["preys_on", "flees_from"]

static var _cache: Dictionary = {}     # kind -> converted config
static var _index: Dictionary = {}     # kind -> res:// path
static var _indexed: bool = false


## The config Dictionary for `kind` (same shape the old hardcoded `_species_config` returned), or an
## empty Dictionary if there is no data file for it.
static func load_config(kind: String) -> Dictionary:
	if _cache.has(kind):
		return (_cache[kind] as Dictionary).duplicate(true)
	_build_index()
	if not _index.has(kind):
		return {}
	var text: String = _read_file(String(_index[kind]))
	if text == "":
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("LASpeciesLibrary: %s is not a JSON object" % _index[kind])
		return {}
	var cfg: Dictionary = _convert(parsed)
	# Inject the taxonomic class from the DATA FOLDER (data/species/<class>/<kind>.json) as host_class, unless
	# the file overrides it — so disease host-restriction, and anything else keyed on class, is data-driven off
	# the folder layout with no per-species field to maintain (mammals/, birds/, insects/, people/, plants/, …).
	if not cfg.has("host_class"):
		cfg["host_class"] = String(_index[kind]).get_base_dir().get_file()
	_cache[kind] = cfg
	return cfg.duplicate(true)


## Convert a RAW JSON species dictionary into engine form (color arrays → Color, string arrays →
## PackedStringArray). Public so callers holding a raw dict (a designer's inline config, a hand-loaded
## file) can normalize it the same way load_config does. Idempotent on already-converted values.
static func convert(raw: Dictionary) -> Dictionary:
	return _convert(raw)


## Load + parse + convert a species config from an explicit res:// (or absolute) JSON path — the
## standalone/library counterpart of load_config(kind) for files that live outside the species tree.
## Returns an empty Dictionary if the file is missing or not a JSON object.
static func load_path(path: String) -> Dictionary:
	if path == "":
		return {}
	var text: String = _read_file(path)
	if text == "":
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("LASpeciesLibrary: %s is not a JSON object" % path)
		return {}
	return _convert(parsed)


## Every species kind that has a data file (across all class folders).
static func known_kinds() -> Array:
	_build_index()
	return _index.keys()


static func _build_index() -> void:
	if _indexed:
		return
	_indexed = true
	_scan_dir(SPECIES_DIR)


static func _scan_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full: String = path + "/" + entry
			if d.current_is_dir():
				_scan_dir(full)                       # recurse into class folders (mammals/, birds/, …)
			elif entry.ends_with(".json"):
				_index[entry.get_basename()] = full
		entry = d.get_next()
	d.list_dir_end()


static func _read_file(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


static func _convert(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in raw.keys():
		var v = raw[key]
		if key == "color" and typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
			var a: Array = v
			var alpha: float = float(a[3]) if a.size() >= 4 else 1.0
			out[key] = Color(float(a[0]), float(a[1]), float(a[2]), alpha)
		elif STRING_ARRAY_KEYS.has(key) and typeof(v) == TYPE_ARRAY:
			var sa: PackedStringArray = PackedStringArray()
			for e in v:
				sa.append(String(e))
			out[key] = sa
		else:
			out[key] = v
	return out
