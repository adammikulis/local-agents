extends CharacterBody3D

@export var npc_id: String = ""
@export var role: String = "gatherer"
@export var move_speed: float = 2.0

func set_identity(next_npc_id: String, next_role: String) -> void:
	npc_id = next_npc_id
	role = next_role
	name = "Villager_%s" % npc_id
