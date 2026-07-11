class_name LADiseaseLibrary
extends RefCounted

## Loads DISEASE STRAIN records from data files, exactly like LASpeciesLibrary loads creatures — a disease is a
## DATA record, never an `if strain == "X"` branch (config-over-cases). Each strain lives in one small JSON under
## `data/diseases/<id>.json`, so a designer adds a new plague by dropping in a file: the transmission + immune +
## symptom code all read the record generically, so the new disease composes in with zero code.
##
## Strain record schema (all optional; sane defaults below):
##   name           display name
##   vector         "contact" | "airborne" | "waterborne" | "pest"   (how it spreads)
##   transmissibility  dose passed per second of close exposure (0..1+)
##   range          shedding/exposure radius, world units
##   incubation     seconds after infection before it turns symptomatic + infectious
##   virulence      load growth per second once active (how fast it worsens)
##   lethality      HP damage per second at full load
##   drain          energy drained per second at full load (wasting)
##   slow           movement slowdown 0..1 at full load (lethargy → easy prey)
##   fever          °C the sick body adds to its own cell at full load (emergent overheat + a warm-body cue)
##   resolve        immune clearance per second (baseline; scaled by constitution + acquired immunity)
##   immunity_gain  acquired-immunity level granted on recovery (0..1)
##   hosts          array of host tags it can infect ("mammal","bird","insect","people","any"); empty = any
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const DISEASE_DIR: String = "res://addons/local_agents/scenes/simulation/voxel/data/diseases"

const DEFAULTS: Dictionary = {
	"name": "Plague", "vector": "contact", "transmissibility": 0.5, "range": 3.0,
	"incubation": 5.0, "virulence": 0.06, "lethality": 0.0, "drain": 0.4, "slow": 0.3,
	"fever": 0.0, "resolve": 0.03, "immunity_gain": 0.85, "hosts": [],
}

static var _cache: Dictionary = {}     # id -> record (with defaults filled)
static var _index: Dictionary = {}     # id -> res:// path
static var _ids: Array = []
static var _indexed: bool = false


## The strain record for `id` (defaults filled), or an empty Dictionary if there is no such disease.
static func strain(id: String) -> Dictionary:
	if _cache.has(id):
		return (_cache[id] as Dictionary).duplicate(true)
	_build_index()
	if not _index.has(id):
		return {}
	var text: String = _read_file(String(_index[id]))
	if text == "":
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("LADiseaseLibrary: %s is not a JSON object" % _index[id])
		return {}
	var rec: Dictionary = DEFAULTS.duplicate(true)
	for k in (parsed as Dictionary).keys():
		rec[k] = parsed[k]
	rec["id"] = id
	_cache[id] = rec
	return rec.duplicate(true)


## Every strain id that has a data file (indexed once).
static func known_strains() -> Array:
	_build_index()
	return _ids.duplicate()


## True if `host_tag` (e.g. "mammal") is a valid host for this strain record (empty hosts list = infects any).
static func infects_host(rec: Dictionary, host_tag: String) -> bool:
	var hosts: Array = rec.get("hosts", [])
	if hosts.is_empty():
		return true
	return hosts.has(host_tag) or hosts.has("any")


static func _build_index() -> void:
	if _indexed:
		return
	_indexed = true
	var d: DirAccess = DirAccess.open(DISEASE_DIR)
	if d == null:
		return
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		if not entry.begins_with(".") and entry.ends_with(".json"):
			var id: String = entry.get_basename()
			_index[id] = DISEASE_DIR + "/" + entry
			_ids.append(id)
		entry = d.get_next()
	d.list_dir_end()


static func _read_file(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text
