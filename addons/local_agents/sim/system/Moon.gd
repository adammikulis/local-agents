class_name LAMoon
extends Node3D


var _mesh: MeshInstance3D = null
var _seed_key: String = "moon"


func _ready() -> void:
	add_to_group(LAGravity.GROUP)
	add_to_group("selectable")
	_build()


func seed_row() -> Dictionary:
	return LABodySeeds.of(_seed_key)


func center() -> Vector3:
	return global_position


func mass() -> float:
	return float(seed_row().get("mass_kg", 0.0))


## The moon is not on a grid of its own, so its size comes from its seeded mass and the density of the rock
## it is made of rather than from a measurement it has no way to take.
func radius() -> float:
	var rho: float = LASubstances.table().get("silicate", {}).get("density_solid", 0.0)
	if rho <= 0.0:
		return -1.0
	return pow(3.0 * mass() / (4.0 * PI * rho), 1.0 / 3.0)


func _build() -> void:
	_mesh = MeshInstance3D.new()
	var s: SphereMesh = SphereMesh.new()
	s.radius = radius()
	s.height = radius() * 2.0
	s.radial_segments = 28
	s.rings = 18
	_mesh.mesh = s
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.62, 0.66)
	mat.roughness = 1.0
	mat.metallic = 0.0
	_mesh.material_override = mat
	_mesh.extra_cull_margin = 4096.0     # never cull the moon when the camera frames the planet from space
	add_child(_mesh)
