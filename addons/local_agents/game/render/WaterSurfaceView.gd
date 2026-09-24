@tool
class_name LAWaterSurfaceView
extends MeshInstance3D

## The free surface of the field's liquid water, meshed near the eye: water's own reflectance, its absorption
## over the path to what lies under it, and the rings an impact sends across it on the simulation's clock.

## Length of the ring buffer; the shader's copy is generated from this line.
const RIPPLE_MAX: int = 16

@export_group("Mesh")
## Half-angle about the eye's vertical the surface is meshed over, rad.
@export var cap_angle_rad: float = 0.8
## Seconds between rebuilds of the surface mesh.
@export var rebuild_period_s: float = 0.22
## Rebuild at once when the eye's vertical turns past this cosine of the one the last mesh was built at.
@export var recentre_cos: float = 0.999
@export_group("Rings")
## Crest height, m, a ring is kept down to: the display shows no quieter wave.
@export var ring_floor_m: float = 1.0e-3

## The largest x^1.5 |sin x - x cos x| / x^3 takes: where a ring's crest stands on its own envelope.
static var _crest_shape: float = _peak_crest_shape()

var _f: LAMaterialField3D = null
var _camera: Node3D = null
var _center: Vector3 = Vector3.ZERO
var _builder: LAWaterSurfaceMesh = null
## Each ring: its centre in the field's frame, the simulated second it was dug, its cavity radius and the
## gravity it runs in.
var _rings: Array[Dictionary] = []
var _accum: float = 0.0
var _last_radial: Vector3 = Vector3.ZERO


## Mesh the water `field` holds around `camera` over a body centred at `center`, drawing what lies under the
## water through it when `transparent`.
func setup(field: LAMaterialField3D, camera: Node3D, center: Vector3, transparent: bool) -> void:
	_f = field
	_camera = camera
	_center = center
	_builder = LAWaterSurfaceMesh.new()
	_accum = rebuild_period_s
	var absorption: Vector3 = absorption_per_channel()
	if transparent and not absorption.is_finite():
		push_error("LAWaterSurfaceView: no measured absorption at a channel's wavelength, so no water is drawn through.")
	var mat: ShaderMaterial = material_override as ShaderMaterial
	mat.set_shader_parameter("refractive_index", LAPhysical.WATER_REFRACTIVE_INDEX)
	mat.set_shader_parameter("absorption_per_m", absorption if absorption.is_finite() else Vector3.ZERO)
	mat.set_shader_parameter("transmit_bed", transparent and absorption.is_finite())
	mat.set_shader_parameter("mesh_edge_m", field._grid.cell_size * pow(0.5, float(field._grid.max_level)))
	field.splashed.connect(_on_splashed)


## Pure water's absorption coefficient at each channel's wavelength, 1/m; NAN in a channel no measurement
## covers.
static func absorption_per_channel() -> Vector3:
	var out: Vector3 = Vector3(NAN, NAN, NAN)
	for ch in 3:
		var i: int = LAPhysical.WATER_ABSORPTION_NM.find(LASkyView.CHANNEL_WAVELENGTHS_NM[ch])
		if i >= 0:
			out[ch] = LAPhysical.WATER_ABSORPTION_PER_M[i]
	return out


func _on_splashed(world_pos: Vector3, joules: float) -> void:
	var loop: LASimLoop = LASimLoop.active()
	var g: float = LABallistics.g_at(world_pos).length()
	var cavity_m: float = LASplashView.cavity_radius_m(joules, g)
	if loop == null or not world_pos.is_finite() or not (cavity_m > 0.0):
		return
	var now_s: float = loop.elapsed_s()
	if _rings.size() >= RIPPLE_MAX:
		var weakest: int = 0
		for i in range(1, _rings.size()):
			if _crest_m(_rings[i], now_s) < _crest_m(_rings[weakest], now_s):
				weakest = i
		_rings.remove_at(weakest)
	_rings.push_back({"at": _f.point_to_field(world_pos), "born_s": now_s, "cavity_m": cavity_m, "g": g})


## The highest crest a ring stands at `now_s`, m: 2 sqrt 2 R^1.5 / sqrt(g t^2) times the crest's share of its
## envelope. Infinite before the cavity has been dug.
func _crest_m(ring: Dictionary, now_s: float) -> float:
	var t: float = now_s - float(ring["born_s"])
	if not (t > 0.0):
		return INF
	return 2.0 * sqrt(2.0) * pow(float(ring["cavity_m"]), 1.5) * _crest_shape / (sqrt(float(ring["g"])) * t)


static func _peak_crest_shape() -> float:
	var best: float = 0.0
	for i in range(1, 400):
		var x: float = 0.02 * float(i)
		best = maxf(best, pow(x, 1.5) * absf(sin(x) - x * cos(x)) / (x * x * x))
	return best


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _f == null or _f._grid == null or _camera == null or not is_instance_valid(_camera):
		return
	var radial: Vector3 = (_camera.global_position - _center).normalized()
	# The patch frame: right-handed, +Y along the eye's vertical; the rings and the normals live in it.
	var ref: Vector3 = Vector3.FORWARD if absf(radial.dot(Vector3.FORWARD)) <= 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(radial).normalized()
	var z_axis: Vector3 = x_axis.cross(radial).normalized()
	global_transform = Transform3D(Basis(x_axis, radial, z_axis), _center)
	_push_rings()
	_accum += delta
	if _accum < rebuild_period_s and _last_radial.dot(radial) >= recentre_cos:
		return
	_accum = 0.0
	_last_radial = radial
	_rebuild(radial)


func _rebuild(radial: Vector3) -> void:
	var out: Dictionary = _builder.build(_f, global_transform.affine_inverse(), radial, cos(cap_angle_rad),
		LAMaterialField3D.MIN_MASS, LAMaterialField3D.MAX_MASS)
	var surface: ArrayMesh = mesh as ArrayMesh
	surface.clear_surfaces()
	if int(out["count"]) == 0 or (out["indices"] as PackedInt32Array).is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out["verts"]
	arrays[Mesh.ARRAY_NORMAL] = out["normals"]
	arrays[Mesh.ARRAY_INDEX] = out["indices"]
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## The rings still over the display's floor, in the patch frame, each carrying g t^2 for its age on the
## simulation's clock.
func _push_rings() -> void:
	var loop: LASimLoop = LASimLoop.active()
	var now_s: float = loop.elapsed_s() if loop != null else NAN
	var kept: Array[Dictionary] = []
	for ring in _rings:
		if _crest_m(ring, now_s) >= ring_floor_m:
			kept.push_back(ring)
	_rings = kept
	var to_patch: Transform3D = global_transform.affine_inverse()
	var packed: Array = []
	packed.resize(RIPPLE_MAX)
	for i in RIPPLE_MAX:
		packed[i] = Vector4.ZERO
		if i < _rings.size():
			var ring: Dictionary = _rings[i]
			var at: Vector3 = to_patch * _f.field_to_point(ring["at"])
			var t: float = now_s - float(ring["born_s"])
			packed[i] = Vector4(at.x, at.z, float(ring["g"]) * t * t, float(ring["cavity_m"]))
	var mat: ShaderMaterial = material_override as ShaderMaterial
	mat.set_shader_parameter("ripples", packed)
	mat.set_shader_parameter("ripple_count", _rings.size())


func _get_configuration_warnings() -> PackedStringArray:
	if not (mesh is ArrayMesh) or not (material_override is ShaderMaterial):
		return PackedStringArray(["No surface mesh or water material: instance WaterSurfaceView.tscn, which authors both."])
	return PackedStringArray()
