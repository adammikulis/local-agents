extends Resource
class_name LocalAgentsDreamInfluenceResource

@export var npc_id: String = ""
@export var payload: Dictionary = {}

func from_dict(next_payload: Dictionary) -> void:
    payload = next_payload.duplicate(true)

func to_dict() -> Dictionary:
    return payload.duplicate(true)
