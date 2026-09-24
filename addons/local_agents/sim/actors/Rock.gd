class_name LARock
extends StaticBody3D


var _terrain: Object = null

var mineral_mass: float = 0.0
var _radius: float = 0.5

func setup(terrain) -> void:
	_terrain = terrain

	collision_layer = 2
	collision_mask = 0
	add_to_group("rock")
	add_to_group("selectable")

	# "actors": placement-gated, so this draw count is not reproducible.
	var rng: LASimRng = LASimRng.for_domain("actors")
	var size: float = 0.45 + rng.randf() * 0.4  # units
	_radius = size

	# Natural irregular boulder (not a cube).
	var mesh: ArrayMesh = LARockMesh.make(size, rng.randi(), 0.45)
	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.name = "RockMesh"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = LARockMesh.material(Color(0.42, 0.39, 0.35))
	mesh_instance.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf_range(0.0, TAU), rng.randf_range(-0.3, 0.3))
	add_child(mesh_instance)

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = size * 0.85
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "RockCollision"
	collision.shape = shape
	add_child(collision)

	_snap_to_surface()

## Wire the shared material field so this boulder knows what it weighs in the substrate's own units. Injected
## by LAEcologyService at spawn, like every other actor's field handle.
func set_material_field(m) -> void:
	mineral_mass = mineral_mass_for(m)


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

## The boulder's mineral amount in the channel unit (mol/m^3 of its cell): a sphere of basalt of this
## rock's radius, against the cell volume, at rock's full amount. Returns 0 with no field (headless
## tests), which is honest: there is no ledger there to be consistent with.
func mineral_mass_for(field) -> float:
	if field == null or not ("_cell_size" in field):
		return 0.0
	var side: float = maxf(float(field._cell_size), 0.001)
	var rock_m3: float = (4.0 / 3.0) * PI * _radius * _radius * _radius
	return LASubstances.full_mol_m3("silicate") * rock_m3 / (side * side * side)


## Frees this boulder and returns its `mineral_mass`.
func take() -> float:
	var carried: float = mineral_mass
	queue_free()
	return carried
