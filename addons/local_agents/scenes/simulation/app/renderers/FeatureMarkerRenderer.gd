extends RefCounted
class_name LocalAgentsFeatureMarkerRenderer

func ensure_marker(parent: Node3D, marker: MeshInstance3D) -> MeshInstance3D:
	if marker != null and is_instance_valid(marker):
		return marker
	var created := MeshInstance3D.new()
	created.name = "FeatureSelectMarker"
	var ring := CylinderMesh.new()
	ring.top_radius = 0.62
	ring.bottom_radius = 0.62
	ring.height = 0.1
	created.mesh = ring
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	created.material_override = mat
	created.visible = false
	if parent != null:
		parent.add_child(created)
	return created

func update_marker(marker: MeshInstance3D, x: int, z: int, y: float, visible: bool) -> void:
	if marker == null or not is_instance_valid(marker):
		return
	marker.global_position = Vector3(float(x) + 0.5, y, float(z) + 0.5)
	marker.visible = visible
