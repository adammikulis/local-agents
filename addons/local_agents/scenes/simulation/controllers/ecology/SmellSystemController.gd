extends RefCounted

var _owner: Variant
var _smell_sources: Array[Node] = []
var _smell_emit_accumulator: float = 0.0
var _smell_step_accumulator: float = 0.0
var _wind_step_accumulator: float = 0.0
var _smell_source_refresh_accumulator: float = 0.0
var _last_compute_request: bool = false

func setup(owner: Variant) -> void:
	_owner = owner
	_sync_compute_preference()

func emit_smell(delta: float) -> void:
	_smell_emit_accumulator += delta
	_smell_source_refresh_accumulator += delta
	if _smell_source_refresh_accumulator >= 1.0:
		_smell_source_refresh_accumulator = 0.0
		refresh_smell_sources()
	if _smell_emit_accumulator < _owner.smell_emit_interval_seconds:
		return
	_smell_emit_accumulator = 0.0
	for source in _smell_sources:
		if not is_instance_valid(source):
			continue
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_smell_enabled and _owner._smell_field != null:
			var source_voxel: Vector3i = _owner._smell_field.world_to_voxel(source.global_position)
			if not _owner.should_process_voxel_system("smell_emit", source_voxel, _owner.smell_emit_interval_seconds, _owner.smell_emit_interval_seconds):
				continue
		if source.has_method("can_emit_smell") and not bool(source.call("can_emit_smell")):
			continue
		if not source.has_method("get_smell_source_payload"):
			continue
		var payload: Dictionary = source.call("get_smell_source_payload")
		if payload.is_empty():
			continue
		var position := Vector3(payload.get("position", Vector3.ZERO))
		var base_strength := float(payload.get("strength", 0.0))
		var chemicals_variant = payload.get("chemicals", null)
		if chemicals_variant is Dictionary:
			var chemicals: Dictionary = chemicals_variant
			for chem_name_variant in chemicals.keys():
				var chem_name := String(chem_name_variant)
				var concentration := float(chemicals[chem_name_variant])
				_owner._smell_field.deposit_chemical(chem_name, position, base_strength * concentration)
		else:
			_owner._smell_field.deposit(String(payload.get("kind", "")), position, base_strength)

func refresh_smell_sources() -> void:
	_smell_sources.clear()
	for node in _owner.get_tree().get_nodes_in_group("living_smell_source"):
		if node is Node:
			_smell_sources.append(node)

func clear_sources() -> void:
	_smell_sources.clear()

func step_smell_field(delta: float) -> void:
	_sync_compute_preference()
	_smell_step_accumulator += delta
	var steps := 0
	while _smell_step_accumulator >= _owner.smell_sim_step_seconds and steps < maxi(1, _owner.max_smell_substeps_per_physics_frame):
		steps += 1
		_smell_step_accumulator -= _owner.smell_sim_step_seconds
		var wind_source: Variant = Vector2.ZERO
		if _owner.wind_enabled and _owner.wind_intensity > 0.0 and _owner._wind_field != null:
			_wind_step_accumulator += _owner.smell_sim_step_seconds
			if _wind_step_accumulator >= _owner.wind_sim_step_seconds:
				var wind_delta := _wind_step_accumulator
				_wind_step_accumulator = 0.0
				_owner._wind_field.set_global_wind(_owner.wind_direction, _owner.wind_intensity, _owner.wind_speed)
				var diurnal_phase := fmod(_owner._sim_time_seconds / 24.0, TAU)
				_owner._wind_field.step(wind_delta, 0.52, diurnal_phase, float(_owner.transform_stage_intensity), _transform_stage_d_air_context())
			wind_source = Callable(_owner._wind_field, "sample_wind")
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_smell_enabled:
			var active_voxels: Array[Vector3i] = _owner.collect_active_smell_voxels()
			if active_voxels.is_empty():
				continue
				_owner._smell_field.step_local(
					_owner.smell_sim_step_seconds,
					active_voxels,
					maxi(1, int(_owner.voxel_smell_step_radius_cells)),
					wind_source,
					_owner.smell_base_decay_per_second,
					float(_owner.transform_stage_intensity),
					_owner.transform_decay_multiplier
				)
		else:
			_owner._smell_field.step(_owner.smell_sim_step_seconds, wind_source, _owner.smell_base_decay_per_second, float(_owner.transform_stage_intensity), _owner.transform_decay_multiplier)
	if _smell_step_accumulator > _owner.smell_sim_step_seconds * float(maxi(1, _owner.max_smell_substeps_per_physics_frame)):
		_smell_step_accumulator = _owner.smell_sim_step_seconds * float(maxi(1, _owner.max_smell_substeps_per_physics_frame))

func reconfigure_spatial_fields() -> void:
	if _owner._smell_field != null:
		_owner._smell_field.configure(_owner.world_bounds_radius, _owner.smell_voxel_size, _owner.smell_vertical_half_extent)
	if _owner._wind_field != null:
		_owner._wind_field.configure(_owner.world_bounds_radius, _owner.smell_voxel_size, _owner.smell_vertical_half_extent)
		_owner._wind_field.set_global_wind(_owner.wind_direction, _owner.wind_intensity if _owner.wind_enabled else 0.0, _owner.wind_speed)
	_owner._plant_growth_controller.rebuild_edible_plant_index()
	_owner._debug_renderer.mark_voxel_mesh_dirty()

func plant_environment_context(world_position: Vector3) -> Dictionary:
	var tile = _tile_at_world(world_position)
	var sunlight = clampf(float(tile.get("sunlight_absorbed", tile.get("sunlight_total", 0.5))), 0.0, 1.5)
	var uv = clampf(float(tile.get("uv_index", 0.0)), 0.0, 3.0)
	var heat_load = clampf(float(tile.get("heat_load", 0.5)), 0.0, 2.0)
	var growth = clampf(float(tile.get("plant_growth_factor", 0.5)), 0.0, 1.0)
	var moisture = clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0)
	var air_temp = 0.5
	if _owner._wind_field != null:
		air_temp = clampf(_owner._wind_field.sample_temperature(world_position + Vector3(0.0, _owner.smell_voxel_size, 0.0)), 0.0, 1.2)
	return {
		"sunlight_absorbed": sunlight,
		"uv_index": uv,
		"heat_load": heat_load,
		"plant_growth_factor": growth,
		"moisture": moisture,
		"air_temperature": air_temp,
		"rain_intensity": float(_owner.transform_stage_intensity),
	}

func _tile_at_world(world_position: Vector3) -> Dictionary:
	var tile_index: Dictionary = _owner._environment_snapshot.get("tile_index", {})
	if tile_index.is_empty():
		return {}
	var tile_id = _owner.TileKeyUtilsScript.from_world_xz(world_position)
	var row = tile_index.get(tile_id, {})
	return row as Dictionary if row is Dictionary else {}

func _transform_stage_d_air_context() -> Dictionary:
	return {
		"sun_altitude": clampf(float(_owner._transform_stage_d_state.get("sun_altitude", 0.0)), 0.0, 1.0),
		"avg_insolation": clampf(float(_owner._transform_stage_d_state.get("avg_insolation", 0.0)), 0.0, 1.0),
		"avg_uv_index": clampf(float(_owner._transform_stage_d_state.get("avg_uv_index", 0.0)), 0.0, 2.0),
		"avg_heat_load": clampf(float(_owner._transform_stage_d_state.get("avg_heat_load", 0.0)), 0.0, 1.5),
		"air_heating_scalar": 1.0,
	}

func _sync_compute_preference() -> void:
	if _owner == null or _owner._smell_field == null:
		return
	if not _owner._smell_field.has_method("set_compute_enabled"):
		return
	var requested: bool = _owner.get("smell_gpu_compute_enabled") == true
	if requested == _last_compute_request:
		return
	_last_compute_request = requested
	_owner._smell_field.set_compute_enabled(requested)
