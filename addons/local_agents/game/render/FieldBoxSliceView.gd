@tool
class_name LAFieldBoxSliceView
extends MultiMeshInstance3D

## One plane of a LocalAgentFieldBox's cells, a cube per cell tinted by its temperature above ambient.

const AXES: PackedStringArray = ["X", "Y", "Z"]

@export_group("Wiring")
## The box whose field this view draws.
@export var field_box: LocalAgentFieldBox:
	set(value):
		field_box = value
		_laid_out = false
		update_configuration_warnings()

@export_group("Slice")
## Axis the slice plane cuts across. "Z" gives a vertical wall facing the camera; "Y" a floor plan.
@export_enum("X", "Y", "Z") var slice_axis: String = "Z":
	set(value):
		slice_axis = value
		_laid_out = false
## Where the slice sits along slice_axis: 0 = the low face of the box, 1 = the high face.
@export_range(0.0, 1.0, 0.01) var slice_position: float = 0.5:
	set(value):
		slice_position = value
		_laid_out = false
## Cube edge as a fraction of the box's cell edge. 1.0 = cubes touch; lower leaves gaps to see through.
@export_range(0.05, 1.0, 0.05) var cube_fill: float = 0.85:
	set(value):
		cube_fill = value
		_laid_out = false

@export_group("Colour")
## Degrees C above ambient that reach hot_color. Smaller = a more sensitive display.
@export_range(1.0, 400.0, 1.0, "suffix:C") var color_span: float = 60.0
## Colour of a cell at ambient temperature.
@export_color_no_alpha var cold_color: Color = Color(0.15, 0.2, 0.5)
## Colour of a cell color_span degrees above ambient, and of anything hotter.
@export_color_no_alpha var hot_color: Color = Color(1.0, 0.35, 0.1)

var _points: PackedVector3Array = PackedVector3Array()   # world sample point per instance
var _laid_out: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	set_notify_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_laid_out = false


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if multimesh == null or field_box == null or field_box.field() == null or not is_visible_in_tree():
		return
	var field: Node = field_box.field()
	if not _laid_out:
		_lay_out(field)
	var ambient: float = LABodySeeds.surface_temp_c()
	for i in range(_points.size()):
		var f: float = clampf((field.temp_at(_points[i]) - ambient) / color_span, 0.0, 1.0)
		multimesh.set_instance_color(i, cold_color.lerp(hot_color, f))


# Transforms are written here once per layout; a frame touches only the colours.
func _lay_out(field: Node) -> void:
	_laid_out = true
	var dims: Vector3i = field_box.dims()
	var axis: int = AXES.find(slice_axis)
	var inner: int = 2 if axis == 0 else 0
	var outer: int = 2 if axis == 1 else 1
	var cell: Vector3i = Vector3i.ZERO
	cell[axis] = clampi(int(round(slice_position * float(dims[axis] - 1))), 0, dims[axis] - 1)
	_points = PackedVector3Array()
	for b in range(dims[outer]):
		for a in range(dims[inner]):
			cell[outer] = b
			cell[inner] = a
			_points.append(field_box.cell_point(cell.x, cell.y, cell.z))
	var edge: float = float(field.cell_size()) * cube_fill
	var cube: Basis = Basis.from_scale(Vector3(edge, edge, edge))
	var to_view: Transform3D = global_transform.affine_inverse()
	multimesh.instance_count = _points.size()
	for i in range(_points.size()):
		multimesh.set_instance_transform(i, to_view * Transform3D(cube, _points[i]))
		multimesh.set_instance_color(i, cold_color)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if field_box == null:
		out.append("Field Box is unset, so there is no field to draw. Point it at a LocalAgentFieldBox.")
	if multimesh == null:
		out.append("No MultiMesh to draw into. Instance FieldBoxSliceView.tscn, which authors one.")
	return out
