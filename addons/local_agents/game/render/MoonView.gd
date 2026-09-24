@tool
class_name LAMoonView
extends MeshInstance3D

## The moon: a sphere of its own radius and its rock's reflectance, wherever the orbit integrator put it.

var _moon: LAMoon = null
var _radius_m: float = -1.0


## Size and shade the authored unit sphere off `moon`; a moon that cannot say either is not drawn.
func setup(moon: LAMoon) -> void:
	_moon = moon
	_radius_m = moon.radius() if moon != null else -1.0
	var albedo: float = moon.albedo() if moon != null else -1.0
	visible = _radius_m > 0.0 and albedo >= 0.0
	set_process(visible)
	if visible:
		(material_override as StandardMaterial3D).albedo_color = Color(albedo, albedo, albedo).linear_to_srgb()
		_follow()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _moon != null and is_instance_valid(_moon):
		_follow()


func _follow() -> void:
	global_transform = Transform3D(_moon.global_transform.basis.scaled(Vector3.ONE * _radius_m),
		_moon.global_position)


func _get_configuration_warnings() -> PackedStringArray:
	if mesh == null or not (material_override is StandardMaterial3D):
		return PackedStringArray(["No moon mesh or material: instance MoonView.tscn, which authors both."])
	return PackedStringArray()
