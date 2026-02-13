extends RefCounted
class_name LocalAgentsVoxelFeatureQuery

func find_volcano_by_tile_id(world_snapshot: Dictionary, tile_id: String) -> Dictionary:
	if tile_id == "":
		return {}
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		if String(volcano.get("tile_id", "")) == tile_id:
			return volcano
	return {}

func find_volcano_covering_tile(world_snapshot: Dictionary, tx: int, tz: int) -> Dictionary:
	var geology: Dictionary = world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	var best: Dictionary = {}
	var best_dist = 1e20
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		var vx = int(volcano.get("x", 0))
		var vz = int(volcano.get("y", 0))
		var radius = maxi(1, int(volcano.get("radius", 1)))
		var dx = tx - vx
		var dz = tz - vz
		var dist2 = float(dx * dx + dz * dz)
		if dist2 <= float((radius + 1) * (radius + 1)) and dist2 < best_dist:
			best_dist = dist2
			best = volcano
	return best

func find_spring_by_tile_id(world_snapshot: Dictionary, tile_id: String) -> Dictionary:
	var springs: Dictionary = world_snapshot.get("springs", {})
	var all_springs: Array = springs.get("all", [])
	for spring_variant in all_springs:
		if not (spring_variant is Dictionary):
			continue
		var spring = spring_variant as Dictionary
		if String(spring.get("tile_id", "")) == tile_id:
			return spring
	return {}

func build_inspect_text(selected_feature: Dictionary) -> String:
	if selected_feature.is_empty():
		return "Inspect: click terrain to select vent/spring."
	var kind = String(selected_feature.get("kind", "tile"))
	var tile_id = String(selected_feature.get("tile_id", ""))
	var data = selected_feature.get("data", {})
	if kind == "vent" and data is Dictionary:
		var vent = data as Dictionary
		return "Inspect Vent %s | x=%d z=%d | activity %.2f | radius %d | oceanic %.2f" % [
			tile_id,
			int(vent.get("x", 0)),
			int(vent.get("y", 0)),
			float(vent.get("activity", 0.0)),
			int(vent.get("radius", 1)),
			float(vent.get("oceanic", 0.0)),
		]
	if kind == "spring" and data is Dictionary:
		var spring = data as Dictionary
		return "Inspect Spring %s | %s | discharge %.2f | pressure %.2f | depth %.2f" % [
			tile_id,
			String(spring.get("type", "cold")),
			float(spring.get("discharge", 0.0)),
			float(spring.get("pressure", 0.0)),
			float(spring.get("depth", 0.0)),
		]
	return "Inspect Tile %s | no spawned feature" % tile_id
