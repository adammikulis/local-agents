extends RefCounted
class_name LocalAgentsSimulationGraphicsSettings

const DEFAULTS := {
	"water_shader_enabled": false,
	"ocean_surface_enabled": false,
	"river_overlays_enabled": false,
	"terrain_chunk_size_blocks": 12,
	"rain_post_fx_enabled": false,
	"clouds_enabled": false,
	"cloud_quality": "low",
	"cloud_density_scale": 0.25,
	"rain_visual_intensity_scale": 0.25,
	"shadows_enabled": false,
	"ssr_enabled": false,
	"ssao_enabled": false,
	"ssil_enabled": false,
	"sdfgi_enabled": false,
	"glow_enabled": false,
	"fog_enabled": false,
	"volumetric_fog_enabled": false,
	"simulation_rate_override_enabled": false,
	"simulation_ticks_per_second_override": 2.0,
	"weather_solver_decimation_enabled": false,
	"hydrology_solver_decimation_enabled": false,
	"erosion_solver_decimation_enabled": false,
	"solar_solver_decimation_enabled": false,
	"climate_fast_interval_ticks": 4,
	"climate_slow_interval_ticks": 8,
	"resource_pipeline_decimation_enabled": false,
	"structure_lifecycle_decimation_enabled": false,
	"culture_cycle_decimation_enabled": false,
	"society_fast_interval_ticks": 4,
	"society_slow_interval_ticks": 8,
	"weather_texture_upload_decimation_enabled": false,
	"surface_texture_upload_decimation_enabled": false,
	"solar_texture_upload_decimation_enabled": false,
	"texture_upload_interval_ticks": 8,
	"texture_upload_budget_texels": 4096,
	"ecology_step_decimation_enabled": false,
	"ecology_step_interval_seconds": 0.2,
	"ecology_voxel_size_meters": 1.0,
	"ecology_vertical_extent_meters": 3.0,
	"frame_graph_total_enabled": true,
	"frame_graph_weather_enabled": true,
	"frame_graph_hydrology_enabled": true,
	"frame_graph_erosion_enabled": true,
	"frame_graph_solar_enabled": true,
	"frame_graph_resource_pipeline_enabled": true,
	"frame_graph_structure_enabled": true,
	"frame_graph_culture_enabled": true,
	"frame_graph_cognition_enabled": true,
	"frame_graph_snapshot_enabled": true,
}

static func default_state() -> Dictionary:
	return DEFAULTS.duplicate(true)

static func merge_with_defaults(state: Dictionary) -> Dictionary:
	var merged := default_state()
	for key_variant in state.keys():
		merged[String(key_variant)] = state.get(key_variant)
	return sanitize_state(merged)

static func sanitize_state(state: Dictionary) -> Dictionary:
	var out := {}
	for key_variant in state.keys():
		var key := String(key_variant)
		out[key] = sanitize_value(key, state.get(key_variant))
	return out

static func sanitize_value(option_id: String, value):
	match option_id:
		"cloud_quality":
			var tier = String(value).to_lower().strip_edges()
			return tier if tier in ["low", "medium", "high", "ultra"] else "low"
		"cloud_density_scale":
			return clampf(float(value), 0.2, 2.0)
		"terrain_chunk_size_blocks":
			return maxi(4, mini(64, int(round(float(value)))))
		"rain_visual_intensity_scale":
			return clampf(float(value), 0.1, 1.5)
		"simulation_ticks_per_second_override":
			return clampf(float(value), 0.5, 30.0)
		"climate_fast_interval_ticks":
			return maxi(1, mini(16, int(round(float(value)))))
		"climate_slow_interval_ticks":
			return maxi(1, mini(32, int(round(float(value)))))
		"society_fast_interval_ticks":
			return maxi(1, mini(16, int(round(float(value)))))
		"society_slow_interval_ticks":
			return maxi(1, mini(32, int(round(float(value)))))
		"texture_upload_interval_ticks":
			return maxi(1, mini(16, int(round(float(value)))))
		"texture_upload_budget_texels":
			return maxi(512, mini(65536, int(round(float(value) / 512.0)) * 512))
		"ecology_step_interval_seconds":
			return clampf(float(value), 0.05, 0.5)
		"ecology_voxel_size_meters":
			return clampf(float(value), 0.5, 3.0)
		"ecology_vertical_extent_meters":
			return clampf(float(value), 1.0, 8.0)
		_:
			if DEFAULTS.has(option_id) and DEFAULTS[option_id] is bool:
				return bool(value)
			return value
