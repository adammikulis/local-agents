@tool
class_name LAWaterSurfaceView
extends MeshInstance3D

## The free surface of the field's liquid water, meshed near the eye in the body's frame: its reflectance, the
## sunlight its column scatters and carries to what lies under it, and the rings an impact sends across it.

## Length of the ring buffer; the shader's copy is generated from this line.
const RIPPLE_MAX: int = 16
## The substance whose free surface this draws.
const LIQUID: String = "h2o"

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
var _sun: DirectionalLight3D = null
var _builder: LAWaterSurfaceMesh = null
## The field-frame point the mesh is laid about: the eye's, when it was last built.
var _anchor: Vector3 = Vector3.ZERO
## Each ring: its centre in the field's frame, the simulated second it was dug, its cavity radius and the
## gravity it runs in.
var _rings: Array[Dictionary] = []
var _accum: float = 0.0
var _last_radial: Vector3 = Vector3.ZERO


## Mesh the water `field` holds around `camera`, lit by `sun`, drawing what lies under the water through it
## when `transparent`.
func setup(field: LAMaterialField3D, camera: Node3D, sun: DirectionalLight3D, transparent: bool) -> void:
	_f = field
	_camera = camera
	_sun = sun
	_builder = LAWaterSurfaceMesh.new()
	_accum = rebuild_period_s
	var row: Dictionary = LASubstances.table()[LIQUID]
	var absorption: Vector3 = liquid_per_channel(row, "absorption_liquid_per_m")
	var scattering: Vector3 = liquid_per_channel(row, "scattering_liquid_per_m")
	var known: bool = absorption.is_finite() and scattering.is_finite()
	if not known:
		push_error("LAWaterSurfaceView: the %s row states no absorption or scattering at a channel's wavelength, so no light is drawn through the water." % LIQUID)
	var depol: float = float(row["scattering_liquid_depolarization"])
	var mat: ShaderMaterial = material_override as ShaderMaterial
	mat.set_shader_parameter("refractive_index", float(row["refractive_index_liquid"]))
	mat.set_shader_parameter("column_known", known)
	if known:
		mat.set_shader_parameter("absorption_per_m", absorption)
		mat.set_shader_parameter("scattering_per_m", scattering)
	mat.set_shader_parameter("scattering_cos2_weight", (1.0 - depol) / (1.0 + depol))
	mat.set_shader_parameter("transmit_bed", transparent)
	field.splashed.connect(_on_splashed)


## The liquid's coefficient `key`, 1/m, at each channel's wavelength; NAN in a channel no measurement covers.
static func liquid_per_channel(row: Dictionary, key: String) -> Vector3:
	var nm: Array = row["optics_liquid_nm"]
	var value: Array = row[key]
	var out: Vector3 = Vector3(NAN, NAN, NAN)
	for ch in 3:
		var i: int = nm.find(LASkyView.CHANNEL_WAVELENGTHS_NM[ch])
		if i >= 0:
			out[ch] = float(value[i])
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
	# The mesh is laid in the field's frame, which is the body's: it turns with the ground under it.
	var body: Node3D = _f._body as Node3D
	var basis: Basis = body.global_transform.basis.orthonormalized() if body != null else Basis.IDENTITY
	var pivot: Vector3 = _f.centre()
	var radial: Vector3 = (_camera.global_position - pivot).normalized()
	_accum += delta
	if _accum >= rebuild_period_s or _last_radial.dot(radial) < recentre_cos:
		_accum = 0.0
		_last_radial = radial
		_anchor = _f.point_to_field(_camera.global_position)
		_rebuild(_f.dir_to_field(radial))
	global_transform = Transform3D(basis, pivot + basis * (_anchor - pivot))
	_push_sun()
	_push_rings()


func _rebuild(cam_dir: Vector3) -> void:
	var out: Dictionary = _builder.build(_f, _anchor, cam_dir, cos(cap_angle_rad), LAMaterialField3D.MIN_MASS,
		LAMaterialField3D.MAX_MASS)
	var surface: ArrayMesh = mesh as ArrayMesh
	surface.clear_surfaces()
	if int(out["count"]) == 0 or (out["indices"] as PackedInt32Array).is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out["verts"]
	arrays[Mesh.ARRAY_NORMAL] = out["normals"]
	arrays[Mesh.ARRAY_TEX_UV] = out["uvs"]
	arrays[Mesh.ARRAY_INDEX] = out["indices"]
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## The star's direction and the share of its beam that reaches the ground, as the sky's light carries them.
func _push_sun() -> void:
	var mat: ShaderMaterial = material_override as ShaderMaterial
	var beam: Color = _sun.light_color.srgb_to_linear() * _sun.light_energy
	mat.set_shader_parameter("sun_dir_world", _sun.global_transform.basis.z.normalized())
	mat.set_shader_parameter("sun_beam", Vector3(beam.r, beam.g, beam.b))


## The rings still over the display's floor, in the mesh's frame, each carrying g t^2 for its age on the
## simulation's clock.
func _push_rings() -> void:
	var loop: LASimLoop = LASimLoop.active()
	var now_s: float = loop.elapsed_s() if loop != null else NAN
	var kept: Array[Dictionary] = []
	for ring in _rings:
		if _crest_m(ring, now_s) >= ring_floor_m:
			kept.push_back(ring)
	_rings = kept
	var at: Array = []
	var gt2: PackedFloat32Array = PackedFloat32Array()
	at.resize(RIPPLE_MAX)
	gt2.resize(RIPPLE_MAX)
	for i in RIPPLE_MAX:
		at[i] = Vector4.ZERO
		if i < _rings.size():
			var ring: Dictionary = _rings[i]
			var t: float = now_s - float(ring["born_s"])
			var local: Vector3 = (ring["at"] as Vector3) - _anchor
			at[i] = Vector4(local.x, local.y, local.z, float(ring["cavity_m"]))
			gt2[i] = float(ring["g"]) * t * t
	var mat: ShaderMaterial = material_override as ShaderMaterial
	mat.set_shader_parameter("ripples", at)
	mat.set_shader_parameter("ripple_gt2", gt2)
	mat.set_shader_parameter("ripple_count", _rings.size())


func _get_configuration_warnings() -> PackedStringArray:
	if not (mesh is ArrayMesh) or not (material_override is ShaderMaterial):
		return PackedStringArray(["No surface mesh or water material: instance WaterSurfaceView.tscn, which authors both."])
	return PackedStringArray()
