@tool
class_name LAEjectaView
extends MultiMeshInstance3D

## The ejecta in flight: one ember where the integrator has each parcel the field's ejecta module carries.

@export_group("Budget")
## Embers drawn at most, up to the MultiMesh's instance count. The settings applier sets it.
@export var max_drawn: int = 256

var _field: LAMaterialField3D = null


func setup(field: LAMaterialField3D) -> void:
	_field = field


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _field == null or _field._ejecta == null:
		return
	var at: PackedVector3Array = _field._ejecta.parcel_positions()
	var n: int = mini(at.size(), mini(max_drawn, multimesh.instance_count))
	for i in n:
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, at[i]))
	multimesh.visible_instance_count = n


func _get_configuration_warnings() -> PackedStringArray:
	if multimesh == null or multimesh.mesh == null:
		return PackedStringArray(["No ember MultiMesh: instance EjectaView.tscn, which authors it."])
	return PackedStringArray()
