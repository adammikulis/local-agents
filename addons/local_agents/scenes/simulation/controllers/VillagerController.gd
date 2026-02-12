extends Node3D

@onready var villager_root: Node3D = $VillagerRoot

func clear_generated() -> void:
	for child in villager_root.get_children():
		child.queue_free()
