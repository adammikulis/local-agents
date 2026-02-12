extends Node3D
class_name LocalAgentsWaterSourceRenderer

func rebuild_sources(water_root: Node3D, hydrology_snapshot: Dictionary) -> void:
	if water_root == null:
		return
	for child in water_root.get_children():
		child.queue_free()
	var source_tiles: Array = hydrology_snapshot.get("source_tiles", [])
	source_tiles.sort()
	for tile_id_variant in source_tiles:
		var marker := Marker3D.new()
		marker.name = "WaterSource_%s" % String(tile_id_variant).replace(":", "_")
		var coords = String(tile_id_variant).split(":")
		if coords.size() == 2:
			marker.position = Vector3(float(coords[0]), 0.1, float(coords[1]))
		water_root.add_child(marker)

