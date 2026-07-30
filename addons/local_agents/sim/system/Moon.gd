class_name LAMoon
extends Node3D

## A moon: a light gravity body in a REAL orbit about the planet, integrated by LASystemOrbits through the same
## LAGravity sum as everything else. It joins the `gravity_body` group so meteors feel it and can slingshot
## around it, and it draws a simple grey cratered sphere. It has NO terrain/field sim of its own (a second full
## body is the 0.4 multi-planet migration), so meteors don't crater it. Explicit types; no ':='.
##
## It stopped being a kinematic prop on 2026-07-30. It used to be placed at cos/sin of a `MOON_RATE` angle each
## frame — a circle drawn next to the physics rather than by it, so it could not be perturbed, could not perturb
## its own orbit back, and its "month" was a constant nobody could derive from its mass or its distance. Its
## period now falls out of sqrt(a³/G(M_planet + M_moon)) like any other orbit (~104 s at 3.2 planet radii, which
## is within half a second of the old hand-set rate — the constant was a good guess, but it was still a guess).

const RADIUS: float = 42.0
const MASS: float = 8.0e4          # 8% of the planet's 1e6: enough to bend a passing meteor, never enough to dominate

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
