@tool
extends RefCounted

const ErosionSystemScript = preload("res://addons/local_agents/simulation/ErosionSystem.gd")

func run_test(_tree: SceneTree) -> bool:
	var erosion = ErosionSystemScript.new()
	var environment := {
		"width": 1,
		"height": 1,
		"tiles": [{
			"tile_id": "0:0",
			"x": 0,
			"y": 0,
			"elevation": 0.64,
			"slope": 0.72,
			"moisture": 0.6,
			"temperature": 0.34,
		}],
		"tile_index": {
			"0:0": {
				"tile_id": "0:0",
				"x": 0,
				"y": 0,
				"elevation": 0.64,
				"slope": 0.72,
				"moisture": 0.6,
				"temperature": 0.34,
			}
		},
		"voxel_world": {
			"height": 24,
			"sea_level": 8,
			"columns": [{
				"x": 0,
				"z": 0,
				"surface_y": 12,
				"top_block": "stone",
				"subsoil_block": "stone",
			}],
			"block_rows": [],
			"block_type_counts": {},
		},
	}
	var hydrology := {
		"water_tiles": {
			"0:0": {
				"flow": 1.0,
				"water_reliability": 0.85,
				"flood_risk": 0.2,
			}
		}
	}
	erosion.configure_environment(environment, hydrology, 12345)

	var saw_frost_damage = false
	var saw_changed = false
	for tick in range(1, 56):
		var weather := {
			"avg_rain_intensity": 0.62,
			"avg_cloud_cover": 0.68,
			"avg_humidity": 0.71,
			"tile_index": {
				"0:0": {
					"rain": 0.62,
					"cloud": 0.68,
					"wetness": 0.76,
					"humidity": 0.71,
				}
			}
		}
		var result: Dictionary = erosion.step(tick, 1.0, environment, hydrology, weather)
		if bool(result.get("changed", false)):
			saw_changed = true
		var erosion_snapshot: Dictionary = result.get("erosion", {})
		var rows: Array = erosion_snapshot.get("rows", [])
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			if float(row.get("frost_damage", 0.0)) > 0.0:
				saw_frost_damage = true
				break
		if saw_frost_damage and saw_changed:
			break

	if not saw_frost_damage:
		push_error("Freeze-thaw erosion test did not accumulate frost damage")
		return false
	if not saw_changed:
		push_error("Freeze-thaw erosion test did not produce terrain changes")
		return false
	print("Freeze-thaw erosion test passed.")
	return true
