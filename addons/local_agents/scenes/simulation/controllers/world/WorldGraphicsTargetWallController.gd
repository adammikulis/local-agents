extends RefCounted
class_name LocalAgentsWorldGraphicsTargetWallController

const TargetWallProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/TargetWallProfileResource.gd")

const _PROFILE_FLOAT_EPSILON := 0.0001
const _TARGET_WALL_GRAPHICS_OPTION_KEYS := {
	"pillar_height_scale": true,
	"pillar_density_scale": true,
}

func apply_hud_graphics_option(graphics_state: Dictionary, option_id: String, value, environment_sync_controller: Object) -> Dictionary:
	var key := String(option_id)
	var next_state: Dictionary = graphics_state.duplicate(true)
	if environment_sync_controller != null and environment_sync_controller.has_method("sanitize_graphics_value"):
		next_state[key] = environment_sync_controller.call("sanitize_graphics_value", key, value)
	else:
		next_state[key] = value
	return next_state

func apply_graphics_state(
	graphics_state: Dictionary,
	environment_sync_controller: Object,
	simulation_ticks_per_second: float,
	living_profile_push_interval_ticks: int
) -> Dictionary:
	if environment_sync_controller == null or not environment_sync_controller.has_method("apply_graphics_state"):
		return graphics_state.duplicate(true)
	return environment_sync_controller.call(
		"apply_graphics_state",
		graphics_state,
		simulation_ticks_per_second,
		living_profile_push_interval_ticks
	)

func consume_visual_environment_interval(graphics_state: Dictionary, current_interval: int) -> Dictionary:
	var next_state: Dictionary = graphics_state.duplicate(true)
	var next_interval := current_interval
	if next_state.has("_visual_environment_update_interval_ticks"):
		next_interval = maxi(1, int(next_state.get("_visual_environment_update_interval_ticks", current_interval)))
		next_state.erase("_visual_environment_update_interval_ticks")
	return {
		"graphics_state": next_state,
		"visual_environment_update_interval_ticks": next_interval,
	}

func is_target_wall_graphics_option(option_id: String) -> bool:
	return _TARGET_WALL_GRAPHICS_OPTION_KEYS.has(String(option_id).strip_edges())

func sync_target_wall_profile(
	target_wall_profile_override: Resource,
	graphics_state: Dictionary,
	simulation_controller: Node
) -> Dictionary:
	var profile_resource = target_wall_profile_override
	if profile_resource == null:
		profile_resource = TargetWallProfileResourceScript.new()
	var current_profile := _profile_values_from_resource(profile_resource)
	var next_profile: Dictionary = current_profile.duplicate(true)
	next_profile["pillar_height_scale"] = clampf(float(graphics_state.get("pillar_height_scale", current_profile.get("pillar_height_scale", 1.0))), 0.25, 3.0)
	next_profile["pillar_density_scale"] = clampf(float(graphics_state.get("pillar_density_scale", current_profile.get("pillar_density_scale", 1.0))), 0.25, 3.0)
	var profile_changed := _profile_values_changed(current_profile, next_profile)
	if profile_changed:
		_apply_profile_values(profile_resource, next_profile)
	if simulation_controller != null and simulation_controller.has_method("set_target_wall_profile"):
		simulation_controller.call("set_target_wall_profile", profile_resource)
	return {
		"profile": profile_resource,
		"profile_changed": profile_changed,
		"profile_values": next_profile,
	}

func stamp_target_wall(simulation_controller: Node, world_camera: Camera3D, tick: int, strict: bool = false) -> Dictionary:
	if simulation_controller == null or world_camera == null:
		return {}
	if not simulation_controller.has_method("stamp_default_voxel_target_wall"):
		return {}
	var wall_result = simulation_controller.call("stamp_default_voxel_target_wall", tick, world_camera.global_transform, strict)
	if wall_result is Dictionary:
		return (wall_result as Dictionary).duplicate(true)
	return {}

func normalize_gpu_backend_used(dispatch: Dictionary) -> String:
	var backend_used := String(dispatch.get("backend_used", "")).strip_edges().to_lower()
	if backend_used == "":
		var voxel_result_variant = dispatch.get("voxel_result", {})
		if voxel_result_variant is Dictionary and bool((voxel_result_variant as Dictionary).get("gpu_dispatched", false)):
			backend_used = "gpu"
	if backend_used == "":
		var result_variant = dispatch.get("result", {})
		if result_variant is Dictionary:
			var execution_variant = (result_variant as Dictionary).get("execution", {})
			if execution_variant is Dictionary and bool((execution_variant as Dictionary).get("gpu_dispatched", false)):
				backend_used = "gpu"
	if backend_used == "" and bool(dispatch.get("dispatched", false)):
		backend_used = "gpu"
	if backend_used.findn("gpu") != -1:
		return "gpu"
	return backend_used

func _profile_values_from_resource(profile_resource: Resource) -> Dictionary:
	if profile_resource == null:
		return {
			"wall_height_levels": 6,
			"column_extra_levels": 4,
			"column_span_interval": 3,
			"material_profile_key": "rock",
			"destructible_tag": "target_wall",
			"brittleness": 1.0,
			"pillar_height_scale": 1.0,
			"pillar_density_scale": 1.0,
		}
	if profile_resource.has_method("to_dict"):
		var values_variant = profile_resource.call("to_dict")
		if values_variant is Dictionary:
			return (values_variant as Dictionary).duplicate(true)
	return {
		"wall_height_levels": int(profile_resource.get("wall_height_levels")),
		"column_extra_levels": int(profile_resource.get("column_extra_levels")),
		"column_span_interval": int(profile_resource.get("column_span_interval")),
		"material_profile_key": String(profile_resource.get("material_profile_key")),
		"destructible_tag": String(profile_resource.get("destructible_tag")),
		"brittleness": float(profile_resource.get("brittleness")),
		"pillar_height_scale": float(profile_resource.get("pillar_height_scale")),
		"pillar_density_scale": float(profile_resource.get("pillar_density_scale")),
	}

func _profile_values_changed(current_profile: Dictionary, next_profile: Dictionary) -> bool:
	if int(current_profile.get("wall_height_levels", 6)) != int(next_profile.get("wall_height_levels", 6)):
		return true
	if int(current_profile.get("column_extra_levels", 4)) != int(next_profile.get("column_extra_levels", 4)):
		return true
	if int(current_profile.get("column_span_interval", 3)) != int(next_profile.get("column_span_interval", 3)):
		return true
	if String(current_profile.get("material_profile_key", "rock")) != String(next_profile.get("material_profile_key", "rock")):
		return true
	if String(current_profile.get("destructible_tag", "target_wall")) != String(next_profile.get("destructible_tag", "target_wall")):
		return true
	if absf(float(current_profile.get("brittleness", 1.0)) - float(next_profile.get("brittleness", 1.0))) > _PROFILE_FLOAT_EPSILON:
		return true
	if absf(float(current_profile.get("pillar_height_scale", 1.0)) - float(next_profile.get("pillar_height_scale", 1.0))) > _PROFILE_FLOAT_EPSILON:
		return true
	if absf(float(current_profile.get("pillar_density_scale", 1.0)) - float(next_profile.get("pillar_density_scale", 1.0))) > _PROFILE_FLOAT_EPSILON:
		return true
	return false

func _apply_profile_values(profile_resource: Resource, next_profile: Dictionary) -> void:
	if profile_resource == null:
		return
	profile_resource.set("wall_height_levels", maxi(1, int(next_profile.get("wall_height_levels", 6))))
	profile_resource.set("column_extra_levels", maxi(0, int(next_profile.get("column_extra_levels", 4))))
	profile_resource.set("column_span_interval", maxi(1, int(next_profile.get("column_span_interval", 3))))
	profile_resource.set("material_profile_key", String(next_profile.get("material_profile_key", "rock")))
	profile_resource.set("destructible_tag", String(next_profile.get("destructible_tag", "target_wall")))
	profile_resource.set("brittleness", maxf(0.0, float(next_profile.get("brittleness", 1.0))))
	profile_resource.set("pillar_height_scale", clampf(float(next_profile.get("pillar_height_scale", 1.0)), 0.25, 3.0))
	profile_resource.set("pillar_density_scale", clampf(float(next_profile.get("pillar_density_scale", 1.0)), 0.25, 3.0))
