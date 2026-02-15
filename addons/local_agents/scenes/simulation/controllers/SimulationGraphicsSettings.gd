extends RefCounted
class_name LocalAgentsSimulationGraphicsSettings

const DEFAULTS := {
	"transform_stage_a_system_enabled": true,
	"transform_stage_b_system_enabled": true,
	"transform_stage_c_system_enabled": true,
	"transform_stage_d_system_enabled": true,
	"resource_pipeline_enabled": true,
	"structure_lifecycle_enabled": true,
	"culture_cycle_enabled": true,
	"ecology_system_enabled": true,
	"settlement_system_enabled": true,
	"villager_system_enabled": true,
	"cognition_system_enabled": true,
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
	"simulation_locality_enabled": true,
	"simulation_locality_dynamic_enabled": true,
	"simulation_locality_radius_tiles": 1,
	"transform_stage_a_solver_decimation_enabled": false,
	"transform_stage_b_solver_decimation_enabled": false,
	"transform_stage_c_solver_decimation_enabled": false,
	"transform_stage_d_solver_decimation_enabled": false,
	"transform_stage_a_gpu_compute_enabled": true,
	"transform_stage_b_gpu_compute_enabled": true,
	"transform_stage_c_gpu_compute_enabled": true,
	"transform_stage_d_gpu_compute_enabled": true,
	"climate_fast_interval_ticks": 4,
	"climate_slow_interval_ticks": 8,
	"resource_pipeline_decimation_enabled": false,
	"structure_lifecycle_decimation_enabled": false,
	"culture_cycle_decimation_enabled": false,
	"society_fast_interval_ticks": 4,
	"society_slow_interval_ticks": 8,
	"transform_stage_a_texture_upload_decimation_enabled": false,
	"transform_stage_b_texture_upload_decimation_enabled": false,
	"transform_stage_d_texture_upload_decimation_enabled": false,
	"texture_upload_interval_ticks": 8,
	"texture_upload_budget_texels": 4096,
	"ecology_step_decimation_enabled": false,
	"ecology_step_interval_seconds": 0.2,
	"ecology_voxel_size_meters": 1.0,
	"ecology_vertical_extent_meters": 3.0,
	"smell_gpu_compute_enabled": false,
	"wind_gpu_compute_enabled": false,
	"smell_query_acceleration_enabled": true,
	"smell_query_top_k_per_layer": 48,
	"smell_query_update_interval_seconds": 0.25,
	"voxel_process_gating_enabled": true,
	"voxel_dynamic_tick_rate_enabled": true,
	"voxel_tick_min_interval_seconds": 0.05,
	"voxel_tick_max_interval_seconds": 0.6,
	"voxel_smell_step_radius_cells": 1,
	"voxel_gate_smell_enabled": true,
	"voxel_gate_plants_enabled": true,
	"voxel_gate_mammals_enabled": true,
	"voxel_gate_shelter_enabled": true,
	"voxel_gate_profile_refresh_enabled": true,
	"voxel_gate_edible_index_enabled": true,
	"frame_graph_total_enabled": true,
	"frame_graph_transform_stage_a_enabled": true,
	"frame_graph_transform_stage_b_enabled": true,
	"frame_graph_transform_stage_c_enabled": true,
	"frame_graph_transform_stage_d_enabled": true,
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
		var key := String(key_variant)
		merged[key] = state.get(key_variant)
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
		"simulation_locality_radius_tiles":
			return maxi(0, mini(6, int(round(float(value)))))
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
		"voxel_tick_min_interval_seconds":
			return clampf(float(value), 0.01, 1.2)
		"voxel_tick_max_interval_seconds":
			return clampf(float(value), 0.02, 3.0)
		"voxel_smell_step_radius_cells":
			return maxi(1, mini(4, int(round(float(value)))))
		"smell_query_top_k_per_layer":
			return maxi(8, mini(256, int(round(float(value)))))
		"smell_query_update_interval_seconds":
			return clampf(float(value), 0.01, 2.0)
		_:
			if DEFAULTS.has(option_id) and DEFAULTS[option_id] is bool:
				return bool(value)
			return value
