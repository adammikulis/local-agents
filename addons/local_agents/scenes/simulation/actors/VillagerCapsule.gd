extends CharacterBody3D

@export var npc_id: String = ""
@export var role: String = "gatherer"
@export var move_speed: float = 2.0
@export var smell_kind: String = "villager"
@export var smell_strength: float = 0.45

func set_identity(next_npc_id: String, next_role: String) -> void:
	npc_id = next_npc_id
	role = next_role
	name = "Villager_%s" % npc_id

func _ready() -> void:
	add_to_group("living_smell_source")

func get_smell_source_payload() -> Dictionary:
	return {
		"id": _smell_id(),
		"position": global_position,
		"strength": smell_strength,
		"kind": smell_kind,
	}

func _smell_id() -> String:
	if npc_id.strip_edges() != "":
		return "villager_%s" % npc_id
	return "villager_%d" % get_instance_id()
