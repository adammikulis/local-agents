class_name LAMoon
extends Node3D

## A moon: a light gravity body in a REAL orbit about the planet, integrated by LASystemOrbits through the same
## LAGravity sum as everything else. It joins the `gravity_body` group so meteors feel it and can slingshot
## around it, and it draws a simple grey cratered sphere. It has NO terrain/field sim of its own (a second full
## body is the 0.4 multi-planet migration), so meteors don't crater it. Explicit types; no ':='.
##
## Its period falls out of sqrt(a³/G(M_planet + M_moon)) like any other orbit; nothing sets a month directly.

const RADIUS: float = 42.0
const MASS: float = 8.0e4          # model units: enough to bend a passing meteor, never enough to dominate

var _mesh: MeshInstance3D = null


func _ready() -> void:
	add_to_group(LAGravity.GROUP)
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
