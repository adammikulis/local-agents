extends RefCounted
class_name LocalAgentsHudController

func build_status_text(year: float, elapsed: String, tick: int, branch_id: String, mode: String, speed: int) -> String:
	return "Year %.1f | T+%s | Tick %d | Branch %s | %s x%d" % [year, elapsed, tick, branch_id, mode, speed]

func build_details_text(weather_snapshot: Dictionary, solar_snapshot: Dictionary, landslides: int, moon_phase_percent: float, moon_state: String, tide_multiplier: float, backend_mode: String, ocean_quality: String) -> String:
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_cloud = clampf(float(weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var avg_fog = clampf(float(weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
	var avg_sun = clampf(float(solar_snapshot.get("avg_insolation", 0.0)), 0.0, 1.0)
	var avg_uv = clampf(float(solar_snapshot.get("avg_uv_index", 0.0)), 0.0, 2.0)
	return "Rain: %.2f | Cloud: %.2f | Fog: %.2f | Sun: %.2f | UV: %.2f | Landslides: %d | Moon: %.0f%% %s | Tide x%.2f | Backend: %s | OceanQ: %s" % [avg_rain, avg_cloud, avg_fog, avg_sun, avg_uv, landslides, moon_phase_percent, moon_state, tide_multiplier, backend_mode, ocean_quality]
