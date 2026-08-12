class_name LAMoon
extends Node3D


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
