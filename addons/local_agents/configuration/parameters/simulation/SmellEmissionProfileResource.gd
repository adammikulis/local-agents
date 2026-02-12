extends Resource
class_name LocalAgentsSmellEmissionProfileResource

@export var schema_version: int = 1
@export var profile_id: String = "emission_default"
@export var base_strength: float = 1.0
@export var chemicals: Dictionary = {}

func to_payload(position: Vector3, source_id: String, kind: String) -> Dictionary:
	return {
		"id": source_id,
		"position": position,
		"strength": base_strength,
		"kind": kind,
		"chemicals": chemicals.duplicate(true),
	}
