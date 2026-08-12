class_name LACreatureStandalone
extends RefCounted


const COGNITION_GROUP: StringName = &"la_creatures"


static func setup(c, config_source, opts: Dictionary) -> void:
	var cfg: Dictionary = resolve_config(config_source)
	var ground_y: float = float(opts.get("ground_y", 0.0))
	# Terrain is the one hard dependency: a flat-ground adapter (y = ground_y). setup() still defaults this when
	# passed null, but pass it explicitly so a caller-chosen floor height is honoured.
	c.setup(LAFlatGroundTerrain.new(ground_y), cfg)
	c.add_to_group(COGNITION_GROUP)
	if opts.has("cognition_scheduler") and opts["cognition_scheduler"] != null:
		c.set_cognition_scheduler(opts["cognition_scheduler"])   # optional shared slow brain


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
