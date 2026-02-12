extends Node3D

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot
var _generation_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}

func clear_generated() -> void:
	for child in terrain_root.get_children():
		child.queue_free()
	for child in water_root.get_children():
		child.queue_free()

func apply_generation_data(generation: Dictionary, hydrology: Dictionary) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	clear_generated()

	var source_tiles: Array = _hydrology_snapshot.get("source_tiles", [])
	source_tiles.sort()
	for tile_id_variant in source_tiles:
		var marker := Marker3D.new()
		marker.name = "WaterSource_%s" % String(tile_id_variant).replace(":", "_")
		var coords = String(tile_id_variant).split(":")
		if coords.size() == 2:
			marker.position = Vector3(float(coords[0]), 0.1, float(coords[1]))
		water_root.add_child(marker)

func get_generation_snapshot() -> Dictionary:
	return _generation_snapshot.duplicate(true)

func get_hydrology_snapshot() -> Dictionary:
	return _hydrology_snapshot.duplicate(true)
