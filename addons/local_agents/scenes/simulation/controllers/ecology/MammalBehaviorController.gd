extends RefCounted

var _owner: Variant
var _mammal_actors: Array[Node] = []
var _living_creatures: Array[Node] = []
var _actor_refresh_accumulator: float = 0.0

func setup(owner: Variant) -> void:
	_owner = owner

func spawn_rabbit_at(world_position: Vector3) -> Node3D:
	_owner._rabbit_sequence += 1
	var rabbit = _owner.RabbitScene.instantiate()
	rabbit.rabbit_id = "rabbit_%d" % _owner._rabbit_sequence
	_owner.rabbit_root.add_child(rabbit)
	rabbit.global_position = _clamp_to_field(world_position, 0.18)
	rabbit.seed_dropped.connect(_owner._on_rabbit_seed_dropped)
	return rabbit

func spawn_initial_rabbits(count: int) -> void:
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		spawn_rabbit_at(Vector3(cos(angle) * 1.8, 0.18, sin(angle) * 1.8))

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
	if _actor_refresh_accumulator >= _owner.actor_refresh_interval_seconds:
		_actor_refresh_accumulator = 0.0
		refresh_actor_caches()
	for mammal in _mammal_actors:
		if not is_instance_valid(mammal):
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
		if mammal.has_method("simulation_step"):
			mammal.simulation_step(delta)
		_owner._plant_growth_controller.try_eat_nearby_plant(mammal)
		_keep_inside_bounds(mammal)

func refresh_living_entity_profiles() -> Array:
	var profiles: Array = []
	for node in _living_creatures:
		if not is_instance_valid(node):
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
	var planar := Vector2(rabbit.global_position.x, rabbit.global_position.z)
	if planar.length() <= _owner.world_bounds_radius:
		return
	var clamped: Vector2 = planar.normalized() * float(_owner.world_bounds_radius)
	rabbit.global_position = Vector3(clamped.x, rabbit.global_position.y, clamped.y)

func _clamp_to_field(world_position: Vector3, y: float) -> Vector3:
	var planar := Vector2(world_position.x, world_position.z)
	var clamped: Vector2 = planar
	if planar.length() > _owner.world_bounds_radius:
		clamped = planar.normalized() * _owner.world_bounds_radius
	return Vector3(clamped.x, y, clamped.y)
