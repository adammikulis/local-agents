class_name LAOceanPlane
extends MeshInstance3D

## THE SEA IS THE SHELL AT `sea_radius`, MESHED AS THE CAP THE EYE CAN SEE. The cap reaches the eye's own
## horizon, so one ring count resolves the surface at every altitude.

## Rings from the sub-eye point to the horizon, and segments around it.
const RINGS: int = 64
const SEGMENTS: int = 128
const REBUILD_PERIOD: float = 0.22
## Rebuild once the eye has crossed this share of its own horizon, or changed altitude by this share.
const REBUILD_REACH_FRAC: float = 0.05
const REBUILD_ALT_FRAC: float = 0.10
const SphereWaterShader: Shader = preload("res://addons/local_agents/sim/shaders/VoxelWaterSphere.gdshader")

var _camera: Node3D = null
var _centre: Vector3 = Vector3.ZERO
var _sea_radius: float = 0.0
var _mat: ShaderMaterial = null
var _mesh: ArrayMesh = null
var _built_at: Vector3 = Vector3.ZERO
var _built_alt: float = -1.0
var _accum: float = REBUILD_PERIOD


## Build the sea around `centre` at `sea_radius`, seen from `camera`.
func setup(camera: Node3D, centre: Vector3, sea_radius: float, transparent: bool = true) -> void:
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_camera = camera
	_centre = centre
	_sea_radius = sea_radius
	_mesh = ArrayMesh.new()
	mesh = _mesh
	_mat = ShaderMaterial.new()
	_mat.shader = SphereWaterShader
	_mat.set_shader_parameter("shell_alpha", 0.72 if transparent else 1.0)
	# Water's own hue at the sea's own measured reflectance.
	_mat.set_shader_parameter("deep_color", _at_ocean_albedo(Color(0.03, 0.33, 0.90)))
	_mat.set_shader_parameter("shallow_color", _at_ocean_albedo(Color(0.09, 0.53, 0.82)))
	material_override = _mat


## A hue scaled so its luminance is LAPhysical.ALBEDO_OCEAN: the colour says which wavelengths the sea
## keeps, the albedo says how much.
func _at_ocean_albedo(hue: Color) -> Color:
	var l: float = hue.get_luminance()
	if l <= 0.0:
		return hue
	return hue * (LAPhysical.ALBEDO_OCEAN / l)


func _process(delta: float) -> void:
	if _mesh == null or _camera == null or not is_instance_valid(_camera) or _sea_radius <= 0.0:
		return
	_accum += delta
	if _accum < REBUILD_PERIOD:
		return
	_accum = 0.0
	var eye: Vector3 = _camera.global_position
	var alt: float = eye.distance_to(_centre) - _sea_radius
	if _built_alt > 0.0 and absf(alt - _built_alt) < REBUILD_ALT_FRAC * _built_alt \
		and eye.distance_to(_built_at) < REBUILD_REACH_FRAC * _horizon_m(_built_alt):
		return
	_rebuild(eye, alt)


## The distance to the sea horizon from altitude `alt`: the tangent from the eye to the shell.
func _horizon_m(alt: float) -> float:
	return sqrt(maxf(alt, 1.0) * (2.0 * _sea_radius + maxf(alt, 1.0)))


## One cap of the shell, centred under the eye and reaching its horizon. The node stands ON the shell at
## the sub-eye point and every vertex is an offset from it, never a planet-sized coordinate.
func _rebuild(eye: Vector3, alt: float) -> void:
	var radial: Vector3 = (eye - _centre).normalized()
	if radial.length_squared() <= 0.0:
		return
	_built_at = eye
	_built_alt = maxf(alt, 1.0)
	# The horizon's angular radius at the body centre, and a frame to sweep it in.
	var theta_h: float = acos(clampf(_sea_radius / (_sea_radius + _built_alt), -1.0, 1.0))
	var ref: Vector3 = Vector3.UP if absf(radial.y) < 0.95 else Vector3.RIGHT
	var u: Vector3 = ref.cross(radial).normalized()
	var v: Vector3 = radial.cross(u)

	var verts: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var idx: PackedInt32Array = PackedInt32Array()
	verts.resize((RINGS + 1) * (SEGMENTS + 1))
	norms.resize(verts.size())
	for i in RINGS + 1:
		var t: float = float(i) / float(RINGS)
		# Rings crowd toward the sub-eye point, where the sea is nearest and covers the most screen.
		var theta: float = theta_h * t * t
		var st: float = sin(theta)
		# cos(theta) - 1, written so the near rings do not vanish into a difference of ones.
		var vers: float = -2.0 * sin(0.5 * theta) * sin(0.5 * theta)
		for j in SEGMENTS + 1:
			var phi: float = TAU * float(j) / float(SEGMENTS)
			var tang: Vector3 = u * cos(phi) + v * sin(phi)
			var n: Vector3 = (radial * (1.0 + vers) + tang * st).normalized()
			var k: int = i * (SEGMENTS + 1) + j
			verts[k] = radial * float(_sea_radius * vers) + tang * float(_sea_radius * st)
			norms[k] = n
	for i in RINGS:
		for j in SEGMENTS:
			var a: int = i * (SEGMENTS + 1) + j
			var b: int = a + SEGMENTS + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	global_position = _centre + radial * _sea_radius
	# The cap is built around the eye, so its own bounds are the whole of it; nothing culls it early.
	custom_aabb = AABB(Vector3.ONE * -_horizon_m(_built_alt), Vector3.ONE * (2.0 * _horizon_m(_built_alt)))
	_mat.set_shader_parameter("eye_altitude_m", _built_alt)
