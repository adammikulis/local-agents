extends RefCounted

var _owner: Variant
var _mammal_actors: Array[Node] = []
var _living_creatures: Array[Node] = []
var _actor_refresh_accumulator: float = 0.0
var _smell_query_config_refresh_accumulator: float = 0.0
var _last_smell_query_acceleration_enabled: bool = true
var _last_smell_query_top_k_per_layer: int = 48
var _last_smell_query_update_interval_seconds: float = 0.25
var _boids_behavior_controller
var _boids_runtime_settings_source: Variant = null
var _breed_accumulator: float = 0.0

func setup(owner: Variant) -> void:
	_owner = owner
	if _boids_behavior_controller != null and _boids_behavior_controller.has_method("set_runtime_settings_source"):
		_boids_behavior_controller.call("set_runtime_settings_source", _boids_runtime_settings_source)
	_sync_smell_query_runtime_config(true)

func set_boids_controller(controller: Variant) -> void:
	_boids_behavior_controller = controller
	if _boids_behavior_controller != null and _boids_behavior_controller.has_method("set_runtime_settings_source"):
		_boids_behavior_controller.call("set_runtime_settings_source", _boids_runtime_settings_source)

func set_boids_runtime_settings_source(source: Variant) -> void:
	_boids_runtime_settings_source = source
	if _boids_behavior_controller != null and _boids_behavior_controller.has_method("set_runtime_settings_source"):
		_boids_behavior_controller.call("set_runtime_settings_source", source)

func spawn_rabbit_at(world_position: Vector3) -> Node3D:
	_owner._rabbit_sequence += 1
	var rabbit = _owner.RabbitScene.instantiate()
	rabbit.rabbit_id = "rabbit_%d" % _owner._rabbit_sequence
	_owner.rabbit_root.add_child(rabbit)
	rabbit.global_position = _clamp_to_field(world_position, 0.18)
	rabbit.seed_dropped.connect(_owner._on_rabbit_seed_dropped)
	return rabbit

func spawn_initial_rabbits(count: int) -> void:
	var center: Vector3 = _owner.field_center
	var ring := maxf(1.8, float(_owner.world_bounds_radius) * 0.35)
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		spawn_rabbit_at(Vector3(center.x + cos(angle) * ring, 0.18, center.z + sin(angle) * ring))

func spawn_fox_at(world_position: Vector3) -> Node3D:
	_owner._fox_sequence += 1
	var fox = _owner.FoxScene.instantiate()
	fox.fox_id = "fox_%d" % _owner._fox_sequence
	_owner.fox_root.add_child(fox)
	fox.global_position = _clamp_to_field(world_position, 0.3)
	return fox

func spawn_initial_foxes(count: int) -> void:
	var center: Vector3 = _owner.field_center
	var ring := maxf(2.5, _owner.world_bounds_radius * 0.75)
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count)) + 0.6
		spawn_fox_at(Vector3(center.x + cos(angle) * ring, 0.3, center.z + sin(angle) * ring))

func refresh_actor_caches() -> void:
	_mammal_actors.clear()
	_living_creatures.clear()
	for node in _owner.get_tree().get_nodes_in_group("mammal_actor"):
		if node is Node:
			_mammal_actors.append(node)
	for node in _owner.get_tree().get_nodes_in_group("living_creature"):
		if node is Node:
			_living_creatures.append(node)

func step_mammals(delta: float) -> void:
	_actor_refresh_accumulator += maxf(0.0, delta)
	_smell_query_config_refresh_accumulator += maxf(0.0, delta)
	_sync_smell_query_runtime_config(false)
	if _actor_refresh_accumulator >= _owner.actor_refresh_interval_seconds:
		_actor_refresh_accumulator = 0.0
		refresh_actor_caches()
	var active_mammals: Array[Node] = []
	for mammal in _mammal_actors:
		if not is_instance_valid(mammal):
			continue
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_mammals_enabled and _owner._smell_field != null:
			var voxel: Vector3i = _owner._smell_field.world_to_voxel(mammal.global_position)
			if not _owner.should_process_voxel_system("mammal", voxel, delta, _owner.mammal_step_interval_seconds):
				_keep_inside_bounds(mammal)
				continue
		var can_smell_entity := true
		if mammal.has_method("can_smell"):
			can_smell_entity = bool(mammal.call("can_smell"))
		if can_smell_entity:
			var danger_radius := 4
			if mammal.has_method("get_danger_smell_radius_cells"):
				danger_radius = int(mammal.call("get_danger_smell_radius_cells"))
			var danger_weights: Dictionary = {}
			if mammal.has_method("get_danger_chemical_weights"):
				danger_weights = mammal.call("get_danger_chemical_weights")
			var danger = _owner._smell_field.strongest_weighted_chemical_score(mammal.global_position, danger_weights, danger_radius)
			var danger_threshold: float = float(_owner.rabbit_perceived_danger_threshold)
			if mammal.has_method("get_danger_threshold"):
				danger_threshold = float(mammal.call("get_danger_threshold"))
			if float(danger.get("score", 0.0)) >= danger_threshold:
				var danger_pos = danger.get("position", null)
				if danger_pos != null and mammal.has_method("trigger_flee"):
					mammal.trigger_flee(danger_pos, _owner.rabbit_flee_duration_seconds)
			elif (not mammal.has_method("is_fleeing")) or (not bool(mammal.call("is_fleeing"))):
				var food_radius := 8
				if mammal.has_method("get_food_smell_radius_cells"):
					food_radius = int(mammal.call("get_food_smell_radius_cells"))
				var food_weights: Dictionary = {}
				if mammal.has_method("get_food_chemical_weights"):
					food_weights = mammal.call("get_food_chemical_weights")
				var food = _owner._smell_field.strongest_weighted_chemical_position(mammal.global_position, food_weights, food_radius)
				if food != null and mammal.has_method("set_food_target"):
					mammal.set_food_target(food)
				elif mammal.has_method("clear_food_target"):
					mammal.clear_food_target()
		elif mammal.has_method("clear_food_target"):
			mammal.clear_food_target()
		active_mammals.append(mammal)
	if _boids_behavior_controller != null and _boids_behavior_controller.has_method("step_mammals"):
		_boids_behavior_controller.call("step_mammals", active_mammals, delta)
	for mammal in active_mammals:
		if not is_instance_valid(mammal):
			continue
		if mammal.has_method("simulation_step"):
			mammal.simulation_step(delta)
		_owner._plant_growth_controller.try_eat_nearby_plant(mammal)
		_keep_inside_bounds(mammal)
	_process_predation()
	_process_breeding(delta)

# Predators (foxes) catch prey (rabbits) they reach; a catch feeds the predator.
func _process_predation() -> void:
	var predators: Array = _owner.get_tree().get_nodes_in_group("predator_actor")
	for predator in predators:
		if not is_instance_valid(predator) or not (predator is Node3D):
			continue
		if not predator.has_method("get_prey_group"):
			continue
		var prey_group := String(predator.call("get_prey_group"))
		var catch_r := 0.5
		if predator.has_method("get_catch_radius"):
			catch_r = float(predator.call("get_catch_radius"))
		var catch_sq := catch_r * catch_r
		var predator_pos: Vector3 = (predator as Node3D).global_position
		for prey in _owner.get_tree().get_nodes_in_group(prey_group):
			if not is_instance_valid(prey) or not (prey is Node3D):
				continue
			if (prey as Node3D).global_position.distance_squared_to(predator_pos) <= catch_sq:
				if predator.has_method("mark_fed"):
					predator.call("mark_fed")
				prey.queue_free()
				break

# Adult same-species pairs that are close and off cooldown produce one offspring.
func _process_breeding(delta: float) -> void:
	_breed_accumulator += maxf(0.0, delta)
	if _breed_accumulator < 1.0:
		return
	_breed_accumulator = 0.0
	_breed_species("living_lagomorph", _owner.rabbit_root, _owner.max_rabbit_population, Callable(self, "spawn_rabbit_at"))
	_breed_species("living_canid", _owner.fox_root, _owner.max_fox_population, Callable(self, "spawn_fox_at"))

func _breed_species(group: String, root: Node, max_population: int, spawn_fn: Callable) -> void:
	if root == null or root.get_child_count() >= max_population:
		return
	var ready_parents: Array = []
	for member in _owner.get_tree().get_nodes_in_group(group):
		if is_instance_valid(member) and member is Node3D and member.has_method("can_reproduce") and bool(member.call("can_reproduce")):
			ready_parents.append(member)
	if ready_parents.size() < 2:
		return
	var breed_radius := 1.6
	var used: Dictionary = {}
	for i in range(ready_parents.size()):
		var parent_a = ready_parents[i]
		if used.has(parent_a):
			continue
		for j in range(i + 1, ready_parents.size()):
			var parent_b = ready_parents[j]
			if used.has(parent_b):
				continue
			if (parent_a as Node3D).global_position.distance_to((parent_b as Node3D).global_position) > breed_radius:
				continue
			var midpoint: Vector3 = ((parent_a as Node3D).global_position + (parent_b as Node3D).global_position) * 0.5
			var offset := Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
			var offspring = spawn_fn.call(midpoint + offset)
			if offspring != null and offspring.has_method("set_age_seconds"):
				offspring.call("set_age_seconds", 0.0)
			if parent_a.has_method("mark_bred"):
				parent_a.call("mark_bred")
			if parent_b.has_method("mark_bred"):
				parent_b.call("mark_bred")
			used[parent_a] = true
			used[parent_b] = true
			if root.get_child_count() >= max_population:
				return
			break

func _sync_smell_query_runtime_config(force: bool) -> void:
	if _owner == null or _owner._smell_field == null:
		return
	if not force and _smell_query_config_refresh_accumulator < 0.2:
		return
	_smell_query_config_refresh_accumulator = 0.0
	var enabled := bool(_owner.get_meta("smell_query_acceleration_enabled", true))
	var top_k := int(_owner.get_meta("smell_query_top_k_per_layer", 48))
	var update_interval := float(_owner.get_meta("smell_query_update_interval_seconds", 0.25))
	if not force and enabled == _last_smell_query_acceleration_enabled and top_k == _last_smell_query_top_k_per_layer and is_equal_approx(update_interval, _last_smell_query_update_interval_seconds):
		return
	_last_smell_query_acceleration_enabled = enabled
	_last_smell_query_top_k_per_layer = top_k
	_last_smell_query_update_interval_seconds = update_interval
	if _owner._smell_field.has_method("set_query_acceleration"):
		_owner._smell_field.call("set_query_acceleration", enabled, top_k, update_interval)

func refresh_living_entity_profiles(delta: float = 0.0) -> Array:
	var profiles: Array = []
	for node in _living_creatures:
		if not is_instance_valid(node):
			continue
		if _owner.voxel_process_gating_enabled and _owner.voxel_gate_profile_refresh_enabled and _owner._smell_field != null and node is Node3D:
			var voxel: Vector3i = _owner._smell_field.world_to_voxel((node as Node3D).global_position)
			if not _owner.should_process_voxel_system("profile_refresh", voxel, maxf(0.001, delta), _owner.living_profile_refresh_interval_seconds):
				continue
		if not node.has_method("get_living_entity_profile"):
			continue
		var payload_variant = node.call("get_living_entity_profile")
		if not (payload_variant is Dictionary):
			continue
		var payload = payload_variant as Dictionary
		if payload.is_empty():
			continue
		profiles.append(payload.duplicate(true))
	return profiles

func on_rabbit_seed_dropped(rabbit_id: String, count: int) -> void:
	var rabbit = find_rabbit_by_id(rabbit_id)
	if rabbit == null:
		return
	_owner._plant_growth_controller.spawn_seed_ring(rabbit.global_position, count)

func find_rabbit_by_id(rabbit_id: String) -> Node3D:
	for rabbit in _owner.rabbit_root.get_children():
		if String(rabbit.get("rabbit_id")) == rabbit_id:
			return rabbit
	return null

func clear_generated_rabbits() -> void:
	for child in _owner.rabbit_root.get_children():
		child.queue_free()
	_mammal_actors.clear()
	_living_creatures.clear()

func _keep_inside_bounds(rabbit: Node3D) -> void:
	var center: Vector3 = _owner.field_center
	var planar := Vector2(rabbit.global_position.x - center.x, rabbit.global_position.z - center.z)
	if planar.length() <= _owner.world_bounds_radius:
		return
	var clamped: Vector2 = planar.normalized() * float(_owner.world_bounds_radius)
	rabbit.global_position = Vector3(center.x + clamped.x, rabbit.global_position.y, center.z + clamped.y)

func _clamp_to_field(world_position: Vector3, y: float) -> Vector3:
	var center: Vector3 = _owner.field_center
	var planar := Vector2(world_position.x - center.x, world_position.z - center.z)
	if planar.length() > _owner.world_bounds_radius:
		planar = planar.normalized() * _owner.world_bounds_radius
	var world_x := center.x + planar.x
	var world_z := center.z + planar.y
	# Place directly on the live terrain collision (raycast) so creatures never fall
	# through progressively-built terrain; else drop-spawn; else fixed flat height.
	var spawn_y := y
	if _owner.has_method("has_surface") and _owner.has_surface():
		spawn_y = _owner.terrain_top_at(world_x, world_z) + 0.35
	elif float(_owner.spawn_drop_height) > 0.0:
		spawn_y = float(_owner.spawn_drop_height)
	return Vector3(world_x, spawn_y, world_z)
