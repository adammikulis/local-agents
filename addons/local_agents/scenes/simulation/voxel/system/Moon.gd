class_name LAMoon
extends Node3D

## A moon: a light gravity body on a kinematic orbit about the planet (positioned each frame by LASystemOrbits).
## It joins the `gravity_body` group so meteors feel it and can slingshot around it, and it draws a simple grey
## cratered sphere. It has NO terrain/field sim of its own (a second full body is the 0.4 multi-planet
## migration), so meteors don't crater it — it is a gravity source + visual for now. Explicit types; no ':='.

const RADIUS: float = 42.0
const MASS: float = 8.0e4          # much less than the planet (6e5) so it perturbs meteors locally, never dominates

var _mesh: MeshInstance3D = null


func _ready() -> void:
	add_to_group("gravity_body")
	add_to_group("selectable")
	_build()


func center() -> Vector3:
	return global_position


func mass() -> float:
	return MASS


func radius() -> float:
	return RADIUS


func _build() -> void:
	_mesh = MeshInstance3D.new()
	var s: SphereMesh = SphereMesh.new()
	s.radius = RADIUS
	s.height = RADIUS * 2.0
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
