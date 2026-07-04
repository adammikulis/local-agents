extends RefCounted

var _owner: Variant
var _edible_plants_by_voxel: Dictionary = {}

func setup(owner: Variant) -> void:
	_owner = owner

func spawn_plant_at(world_position: Vector3, initial_growth_ratio: float = 0.0) -> Node3D:
	var plant = _owner.PlantScene.instantiate()
	_owner.plant_root.add_child(plant)
	plant.global_position = _clamp_to_field(world_position, 0.14)
	if plant.has_method("set_initial_growth_ratio"):
		plant.call("set_initial_growth_ratio", initial_growth_ratio)
	return plant

func spawn_initial_plants(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		var ring := 2.4 + 1.8 * float(i % 3)
		spawn_plant_at(Vector3(cos(angle) * ring, 0.14, sin(angle) * ring), float(i % 5) / 5.0)

func step_plants(delta: float) -> void:
	for plant in _owner.plant_root.get_children():
		if not is_instance_valid(plant):
			continue
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_plants_enabled and _owner._smell_field != null:
			var voxel: Vector3i = _owner._smell_field.world_to_voxel(plant.global_position)
			if not _owner.should_process_voxel_system("plant", voxel, delta, _owner.plant_step_interval_seconds):
				continue
		var env_context = _owner._smell_system_controller.plant_environment_context(plant.global_position)
		if plant.has_method("simulation_step_with_environment"):
			plant.call("simulation_step_with_environment", delta, env_context)
		elif plant.has_method("simulation_step"):
			plant.call("simulation_step", delta)

func rebuild_edible_plant_index() -> void:
	_edible_plants_by_voxel.clear()
	if _owner._smell_field == null:
		return
	for plant in _owner.plant_root.get_children():
		if not is_instance_valid(plant):
			continue
		if not plant.has_method("is_edible") or not bool(plant.call("is_edible")):
			continue
		var voxel: Vector3i = _owner._smell_field.world_to_voxel(plant.global_position)
		if voxel == Vector3i(2147483647, 2147483647, 2147483647):
			continue
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_edible_index_enabled:
			if not _owner.is_voxel_region_active(voxel, 1):
				continue
		var key := _voxel_key(voxel)
		var bucket: Array = _edible_plants_by_voxel.get(key, [])
		bucket.append(plant)
		_edible_plants_by_voxel[key] = bucket

func try_eat_nearby_plant(rabbit: Node3D) -> void:
	if _owner._smell_field == null:
		return
	var rabbit_voxel: Vector3i = _owner._smell_field.world_to_voxel(rabbit.global_position)
	if rabbit_voxel == Vector3i(2147483647, 2147483647, 2147483647):
		return
	for z_offset in range(-1, 2):
		for y_offset in range(-1, 2):
			for x_offset in range(-1, 2):
				var key := _voxel_key(Vector3i(rabbit_voxel.x + x_offset, rabbit_voxel.y + y_offset, rabbit_voxel.z + z_offset))
				if not _edible_plants_by_voxel.has(key):
					continue
				var bucket: Array = _edible_plants_by_voxel[key]
				for plant in bucket:
					if not is_instance_valid(plant):
						continue
					if not plant.has_method("is_edible") or not bool(plant.call("is_edible")):
						continue
					if rabbit.global_position.distance_to(plant.global_position) > _owner.rabbit_eat_distance:
						continue
					var seeds := int(plant.call("consume"))
					if seeds > 0 and rabbit.has_method("ingest_seeds"):
						rabbit.call("ingest_seeds", seeds)
					return

func spawn_seed_ring(world_position: Vector3, count: int) -> void:
	for i in range(count):
		_owner._seed_sequence += 1
		var spawn_angle := float(_owner._seed_sequence) * 2.3999632
		var radius: float = 0.12 + (float(_owner.seed_spawn_radius) * (float((_owner._seed_sequence + i) % 7) / 7.0))
		var spawn_offset := Vector3(cos(spawn_angle) * radius, 0.14, sin(spawn_angle) * radius)
		spawn_plant_at(world_position + spawn_offset, 0.0)
	rebuild_edible_plant_index()

func clear_generated_plants() -> void:
	for child in _owner.plant_root.get_children():
		child.queue_free()
	_edible_plants_by_voxel.clear()

func deterministic_spawn_point(sequence: int, max_radius: float) -> Vector3:
	var center: Vector3 = _owner.field_center
	var angle := float(sequence) * 2.3999632
	var radial_step := float((sequence % 11) + 1) / 11.0
	var radius := max_radius * radial_step
	return Vector3(center.x + cos(angle) * radius, 0.14, center.z + sin(angle) * radius)

func _clamp_to_field(world_position: Vector3, y: float) -> Vector3:
	var center: Vector3 = _owner.field_center
	var planar := Vector2(world_position.x - center.x, world_position.z - center.z)
	if planar.length() > _owner.world_bounds_radius:
		planar = planar.normalized() * _owner.world_bounds_radius
	var world_x := center.x + planar.x
	var world_z := center.z + planar.y
	# Sit plants on the live terrain surface (raycast) when terrain is available.
	var world_y := y
	if _owner.has_method("has_surface") and _owner.has_surface():
		world_y = _owner.terrain_top_at(world_x, world_z) + 0.05
	return Vector3(world_x, world_y, world_z)

func _voxel_key(voxel: Vector3i) -> String:
	return "%d:%d:%d" % [voxel.x, voxel.y, voxel.z]
