class_name LARock
extends StaticBody3D

## The boulder has come to rest on the ground; `radius_m` is its radius, m.
signal settled(radius_m: float)

var _terrain: Object = null
var _radius: float = -1.0                  # m; -1 until setup() has drawn it

func setup(terrain) -> void:
	_terrain = terrain

	collision_layer = 2
	collision_mask = 0
	add_to_group("rock")
	add_to_group("selectable")

	# "actors": placement-gated, so this draw count is not reproducible.
	var rng: LASimRng = LASimRng.for_domain("actors")
	_radius = 0.45 + rng.randf() * 0.4  # m

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = _radius * 0.85
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "RockCollision"
	collision.shape = shape
	add_child(collision)

	_snap_to_surface()
	settled.emit(_radius)


## The boulder's radius, m; -1 before setup() has drawn it.
func radius_m() -> float:
	return _radius


func _snap_to_surface() -> void:
	if _terrain == null or not _terrain.has_method("ground_point"):
		return
	var sp: Vector3 = _terrain.ground_point(global_position)   # radial re-seat onto the ground
	if is_nan(sp.x):
		return
	global_position = sp

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Rock",
		"lines": ["A loose rock.", "Villagers throw these to hunt."],
	}

## Picked up: the boulder leaves the ground.
func take() -> void:
	queue_free()
