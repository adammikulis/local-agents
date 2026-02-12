extends Node3D

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot

func clear_generated() -> void:
	for child in terrain_root.get_children():
		child.queue_free()
	for child in water_root.get_children():
		child.queue_free()
