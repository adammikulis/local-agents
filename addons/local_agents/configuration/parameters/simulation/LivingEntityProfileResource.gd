extends Resource
class_name LocalAgentsLivingEntityProfileResource

@export var schema_version: int = 1
@export var entity_id: String = ""
@export var taxonomy_path: Array[String] = ["living_creature"]
@export var display_kind: String = ""
@export var ownership_weight: float = 0.0
@export var belonging_weight: float = 0.0
@export var gather_tendency: float = 0.0
@export var mobility: float = 0.0
@export var carry_channels: Dictionary = {}
@export var build_channels: Dictionary = {}
@export var shelter_preferences: Dictionary = {}
@export var tags: Array[String] = []
@export var metadata: Dictionary = {}

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"entity_id": entity_id,
		"taxonomy_path": taxonomy_path.duplicate(),
		"display_kind": display_kind,
		"ownership_weight": ownership_weight,
		"belonging_weight": belonging_weight,
		"gather_tendency": gather_tendency,
		"mobility": mobility,
		"carry_channels": carry_channels.duplicate(true),
		"build_channels": build_channels.duplicate(true),
		"shelter_preferences": shelter_preferences.duplicate(true),
		"tags": tags.duplicate(),
		"metadata": metadata.duplicate(true),
	}

func from_dict(payload: Dictionary) -> void:
	schema_version = int(payload.get("schema_version", schema_version))
	entity_id = String(payload.get("entity_id", entity_id))
	display_kind = String(payload.get("display_kind", display_kind))
	ownership_weight = clampf(float(payload.get("ownership_weight", ownership_weight)), 0.0, 1.0)
	belonging_weight = clampf(float(payload.get("belonging_weight", belonging_weight)), 0.0, 1.0)
	gather_tendency = clampf(float(payload.get("gather_tendency", gather_tendency)), 0.0, 1.0)
	mobility = clampf(float(payload.get("mobility", mobility)), 0.0, 1.0)
	var carry_variant = payload.get("carry_channels", {})
	if carry_variant is Dictionary:
		carry_channels = (carry_variant as Dictionary).duplicate(true)
	else:
		carry_channels = {}
	var build_variant = payload.get("build_channels", {})
	if build_variant is Dictionary:
		build_channels = (build_variant as Dictionary).duplicate(true)
	else:
		build_channels = {}
	var shelter_variant = payload.get("shelter_preferences", {})
	if shelter_variant is Dictionary:
		shelter_preferences = (shelter_variant as Dictionary).duplicate(true)
	else:
		shelter_preferences = {}
	taxonomy_path.clear()
	var taxonomy_variant = payload.get("taxonomy_path", [])
	if taxonomy_variant is Array:
		for item in (taxonomy_variant as Array):
			var token = String(item).strip_edges().to_lower()
			if token != "":
				taxonomy_path.append(token)
	if taxonomy_path.is_empty():
		taxonomy_path.append("living_creature")
	tags.clear()
	var tags_variant = payload.get("tags", [])
	if tags_variant is Array:
		for item in (tags_variant as Array):
			var tag = String(item).strip_edges().to_lower()
			if tag != "":
				tags.append(tag)
	var meta_variant = payload.get("metadata", {})
	if meta_variant is Dictionary:
		metadata = (meta_variant as Dictionary).duplicate(true)
	else:
		metadata = {}
