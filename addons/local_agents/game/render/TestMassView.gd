class_name LATestMassView
extends Node3D

## THE TEST MASSES, DRAWN: a marker where each probe is and the column it fell down, from the release
## point to where it stands now. The integrator carries the release point in the body's own frame, so
## the column stays over the ground it was dropped from while the planet turns under it.

const MARKER_COLOUR: Color = Color(1.0, 0.55, 0.10)
const TRAIL_COLOUR: Color = Color(1.0, 0.80, 0.38)
## Marker radius and column width as fractions of the distance from the eye, so a probe two kilometres
## away and one at your feet are both a few pixels across.
const MARKER_SUBTEND: float = 0.006
const TRAIL_SUBTEND: float = 0.003
## A COLUMN IS DRAWN IN PIECES, each sized at its OWN distance from the eye. One box over a two-kilometre
## fall has one width, so standing at its foot puts a wall across the frame and standing off it leaves
## nothing to see; in pieces the line recedes the way a line does.
const TRAIL_PIECES: int = 24

var _probes: Node = null
var _camera: Camera3D = null
var _markers: MultiMeshInstance3D = null
var _trails: MultiMeshInstance3D = null


func setup(probes: Node, camera: Camera3D) -> void:
	_probes = probes
	_camera = camera
	name = "TestMassView"
	_markers = _instances(_sphere(), MARKER_COLOUR)
	_trails = _instances(BoxMesh.new(), TRAIL_COLOUR)
	visible = _probes != null and _probes.has_method("rows")


func _process(_delta: float) -> void:
	if not visible or _camera == null or not is_instance_valid(_camera):
		return
	var rows: Array = _probes.rows()
	var eye: Vector3 = _camera.global_position
	_fit(_markers.multimesh, rows.size())
	_fit(_trails.multimesh, rows.size() * TRAIL_PIECES)
	for i in range(rows.size()):
		var pos: Vector3 = rows[i]["position"]
		var from: Vector3 = rows[i]["from"]
		_markers.multimesh.set_instance_transform(i, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ONE * MARKER_SUBTEND * eye.distance_to(pos)), pos))
		for k in TRAIL_PIECES:
			var a: Vector3 = from.lerp(pos, float(k) / float(TRAIL_PIECES))
			var b: Vector3 = from.lerp(pos, float(k + 1) / float(TRAIL_PIECES))
			_trails.multimesh.set_instance_transform(i * TRAIL_PIECES + k,
				_column(a, b, TRAIL_SUBTEND * eye.distance_to(0.5 * (a + b))))


## Room for `want` instances, and that many drawn.
static func _fit(mm: MultiMesh, want: int) -> void:
	if mm.instance_count < want:
		mm.instance_count = want
	mm.visible_instance_count = want


## A box spanning `a` to `b`, `w` across: the path the probe took, given a width the eye can find.
static func _column(a: Vector3, b: Vector3, w: float) -> Transform3D:
	var along: Vector3 = b - a
	var len_m: float = along.length()
	if len_m <= 0.0:
		return Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), a)
	var y: Vector3 = along / len_m
	var ref: Vector3 = Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x: Vector3 = ref.cross(y).normalized()
	return Transform3D(Basis(x * w, y * len_m, y.cross(x) * w), 0.5 * (a + b))


func _instances(mesh: Mesh, col: Color) -> MultiMeshInstance3D:
	var node: MultiMeshInstance3D = MultiMeshInstance3D.new()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 0
	node.multimesh = mm
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.disable_receive_shadows = true
	node.material_override = mat
	add_child(node)
	return node


static func _sphere() -> SphereMesh:
	var m: SphereMesh = SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = 12
	m.rings = 6
	return m
