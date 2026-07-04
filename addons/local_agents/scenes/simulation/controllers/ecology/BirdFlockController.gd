extends RefCounted

# Drives a flock of BirdActors with full 3D Reynolds boids (separation / alignment /
# cohesion) plus a cruise-altitude band, soft world bounds, and a little wander. Each
# tick it computes a desired velocity per bird and pushes it through the shared
# apply_flock_output channel, then steps the bird (fly mode integrates it in 3D).

const BirdScene = preload("res://addons/local_agents/scenes/simulation/actors/BirdSphere.tscn")

const NEIGHBOR_RADIUS := 5.0
const SEPARATION_RADIUS := 1.7
const SEPARATION_WEIGHT := 2.4
const ALIGNMENT_WEIGHT := 1.1
const COHESION_WEIGHT := 0.9
const WANDER_WEIGHT := 1.2
const BOUNDS_WEIGHT := 2.0
const ALTITUDE_WEIGHT := 1.4
const MAX_SPEED := 5.0
const MIN_SPEED := 2.0

var _owner: Node = null
var _bird_root: Node3D = null
var _birds: Array[Node] = []
var _refresh_accumulator: float = 0.0
var _bird_sequence: int = 0

func setup(owner: Node, bird_root: Node3D) -> void:
	_owner = owner
	_bird_root = bird_root

const CRUISE_HEIGHT := 10.0

func _center() -> Vector3:
	return _owner.field_center

func _cruise_altitude() -> float:
	return _owner.field_center.y + CRUISE_HEIGHT

func spawn_initial_birds(count: int) -> void:
	var center: Vector3 = _center()
	var radius := maxf(3.0, _owner.world_bounds_radius * 0.6)
	var altitude := _cruise_altitude()
	for i in range(count):
		var angle := TAU * float(i) / float(maxi(1, count))
		var pos := Vector3(center.x + cos(angle) * radius, altitude + randf_range(-1.5, 1.5), center.z + sin(angle) * radius)
		spawn_bird_at(pos)

func spawn_bird_at(world_position: Vector3) -> Node3D:
	_bird_sequence += 1
	var bird = BirdScene.instantiate()
	bird.bird_id = "bird_%d" % _bird_sequence
	_bird_root.add_child(bird)
	bird.global_position = world_position
	# Give an initial tangential velocity so the flock starts in motion.
	var tangent := Vector3(-world_position.z, 0.0, world_position.x)
	if tangent.length_squared() > 0.001:
		bird.velocity = tangent.normalized() * MIN_SPEED
	return bird

func _refresh() -> void:
	_birds.clear()
	if _owner == null or _owner.get_tree() == null:
		return
	for node in _owner.get_tree().get_nodes_in_group("bird_actor"):
		if node is Node3D and is_instance_valid(node):
			_birds.append(node)

func step(delta: float) -> void:
	if delta <= 0.0:
		return
	_refresh_accumulator += delta
	if _birds.is_empty() or _refresh_accumulator >= 0.5:
		_refresh_accumulator = 0.0
		_refresh()
	if _birds.is_empty():
		return
	var bounds_radius := maxf(6.0, _owner.world_bounds_radius * 1.3)
	var cruise := _cruise_altitude()
	var center: Vector3 = _center()
	for bird in _birds:
		if not is_instance_valid(bird):
			continue
		var desired := _flock_velocity(bird, bounds_radius, cruise, center)
		bird.apply_flock_output(desired.normalized(), desired.length())
		if bird.has_method("simulation_step"):
			bird.simulation_step(delta)

func _flock_velocity(bird: Node3D, bounds_radius: float, cruise: float, center: Vector3) -> Vector3:
	var pos: Vector3 = bird.global_position
	var vel: Vector3 = bird.velocity
	var separation := Vector3.ZERO
	var alignment := Vector3.ZERO
	var cohesion := Vector3.ZERO
	var neighbors := 0
	for other in _birds:
		if other == bird or not is_instance_valid(other):
			continue
		var offset: Vector3 = pos - (other as Node3D).global_position
		var dist := offset.length()
		if dist > NEIGHBOR_RADIUS or dist <= 0.0001:
			continue
		neighbors += 1
		cohesion += (other as Node3D).global_position
		alignment += (other as Node3D).velocity
		if dist < SEPARATION_RADIUS:
			separation += offset / dist
	var steer := vel * 0.5
	if neighbors > 0:
		cohesion = (cohesion / float(neighbors)) - pos
		alignment = alignment / float(neighbors)
		steer += separation * SEPARATION_WEIGHT
		steer += alignment.normalized() * ALIGNMENT_WEIGHT if alignment.length_squared() > 0.0001 else Vector3.ZERO
		steer += cohesion.normalized() * COHESION_WEIGHT if cohesion.length_squared() > 0.0001 else Vector3.ZERO
	# Wander
	steer += Vector3(randf_range(-1.0, 1.0), randf_range(-0.4, 0.4), randf_range(-1.0, 1.0)) * WANDER_WEIGHT
	# Altitude band around cruise height
	steer.y += clampf(cruise - pos.y, -2.0, 2.0) * ALTITUDE_WEIGHT
	# Soft world bounds (horizontal, around the ecology centre)
	var horizontal := Vector3(pos.x - center.x, 0.0, pos.z - center.z)
	if horizontal.length() > bounds_radius:
		steer += -horizontal.normalized() * BOUNDS_WEIGHT * ((horizontal.length() - bounds_radius) + 1.0)
	# Clamp speed with a minimum so the flock never stalls.
	var speed := steer.length()
	if speed < 0.0001:
		return Vector3(0.0, 0.0, MIN_SPEED)
	speed = clampf(speed, MIN_SPEED, MAX_SPEED)
	return steer.normalized() * speed
