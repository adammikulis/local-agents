class_name LACreatureStandalone
extends RefCounted

## Standalone (library drop-in) configuration for LACreature, factored out of the main brain so the monolith
## stays lean. A Creature placed in a scene as a NODE (Creature.tscn) with no ecology / MaterialField / planet
## wiring is configured here: it gets an LAFlatGroundTerrain + sensible defaults and runs on its pure fast/
## reinforced brain (no slow-LLM escalation, no shared field reads, no ecology broadcasts). Static access on the
## passed creature so there is no cyclic class reference. (Explicit types only — project rule: no ':=' typing.)


## Configure `c` to live on a bare FLAT floor with NONE of the sim's optional services. `config_source` may be a
## Dictionary, a ".json" path, a species id ("rabbit", …), or "" (a generic walker). `opts` may carry
## {ground_y: float, cognition_scheduler} to sit the floor elsewhere or opt IN to a shared slow brain.
static func setup(c, config_source, opts: Dictionary) -> void:
	var cfg: Dictionary = resolve_config(config_source)
	var ground_y: float = float(opts.get("ground_y", 0.0))
	# Terrain is the one hard dependency: a flat-ground adapter (y = ground_y). setup() still defaults this when
	# passed null, but pass it explicitly so a caller-chosen floor height is honoured.
	c.setup(LAFlatGroundTerrain.new(ground_y), cfg)
	if opts.has("cognition_scheduler") and opts["cognition_scheduler"] != null:
		c.set_cognition_scheduler(opts["cognition_scheduler"])   # optional shared slow brain


## Resolve a config source (Dictionary | ".json" path | species id | empty) to a normalized (engine-typed)
## config Dictionary, falling back to a generic walker so a bare drop-in still stands + wanders.
static func resolve_config(src) -> Dictionary:
	if src is Dictionary and not (src as Dictionary).is_empty():
		return LASpeciesLibrary.convert(src as Dictionary)
	if src is String and String(src) != "":
		var s: String = String(src)
		if s.ends_with(".json"):
			var from_file: Dictionary = LASpeciesLibrary.load_path(s)
			if not from_file.is_empty():
				return from_file
		else:
			var by_id: Dictionary = LASpeciesLibrary.load_config(s)
			if not by_id.is_empty():
				return by_id
	# Generic ground walker — enough config for a visible, wandering creature with no data file.
	return {
		"species": "walker", "diet": "herbivore", "speed": 3.0, "size": 0.6,
		"color": Color(0.72, 0.6, 0.46), "sense_radius": 9.0, "herd": false,
	}
