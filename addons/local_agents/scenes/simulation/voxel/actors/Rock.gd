class_name LARock
extends StaticBody3D

## A loose ambient rock lying on the terrain. Villagers pick these up
## (via take()) and throw them to hunt animals. Selectable/pickable through
## a layer-2 physics query, matching the other selectable actors.

var _terrain: Object = null

func setup(terrain) -> void:
	_terrain = terrain

	collision_layer = 2
	collision_mask = 0
	add_to_group("rock")
	add_to_group("selectable")

	var size: float = 0.45 + randf() * 0.4  # ~0.45-0.85 units

	# Natural irregular boulder (not a cube).
	var mesh: ArrayMesh = LARockMesh.make(size, randi(), 0.45)
	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.name = "RockMesh"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = LARockMesh.material(Color(0.42, 0.39, 0.35))
	mesh_instance.rotation = Vector3(randf_range(-0.3, 0.3), randf_range(0.0, TAU), randf_range(-0.3, 0.3))
	add_child(mesh_instance)

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = size * 0.85
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "RockCollision"
	collision.shape = shape
	add_child(collision)

	_snap_to_surface()

func _snap_to_surface() -> void:
	if _terrain == null or not _terrain.has_method("surface_height"):
		return
	var y = _terrain.surface_height(global_position.x, global_position.z)
	if typeof(y) != TYPE_FLOAT and typeof(y) != TYPE_INT:
		return
	if is_nan(float(y)):
		return
	var pos: Vector3 = global_position
	pos.y = float(y)
	global_position = pos

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Rock",
		"lines": ["A loose rock.", "Villagers throw these to hunt."],
	}

## Called when a villager picks this rock up.
func take() -> void:
	queue_free()
