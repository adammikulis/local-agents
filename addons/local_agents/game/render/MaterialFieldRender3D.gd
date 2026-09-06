class_name LAMaterialFieldRender3D
extends MeshInstance3D


const WaterShader: Shader = preload("res://addons/local_agents/sim/shaders/VoxelWater.gdshader")

const REBUILD_PERIOD: float = 0.22         # ~4.5 Hz geometry rebuild (stale a couple frames is imperceptible)
const RECENTER_DOT: float = 0.999          # rebuild early if the camera radial rotates past this
const RIPPLE_MAX: int = 16                 # ring-buffer length; the shader's copy is generated
const RIPPLE_SPEED: float = 9.0            # ring expansion (world units / s)
const RIPPLE_DECAY: float = 0.7            # amplitude e-fold time (1/s)

var _f = null                              # LAMaterialField3D
var _camera: Node3D = null
var _center: Vector3 = Vector3.ZERO
var _mesh: ArrayMesh = null
var _mat: ShaderMaterial = null
var _ripples: Array = []                   # [{pos:Vector3, age:float, strength:float}]
var _accum: float = REBUILD_PERIOD          # force a build on the first frame
var _last_radial: Vector3 = Vector3.ZERO
var _ready: bool = false


func setup(field, camera: Node3D, terrain, _sun, center: Vector3, transparent: bool) -> void:
	_f = field
	_camera = camera
	_center = center
	_mesh = ArrayMesh.new()
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Fresh-water look: clear teal, thin sheet (ignore scene thickness so a shallow lake isn't opaque-white),
	# use the per-vertex CA flow. Salt/sea uniforms come later when the ocean unifies into this surface (A2).
	_mat = ShaderMaterial.new()
	_mat.shader = WaterShader
	# Nothing is dissolved in this world's water, so every surface draws as the fresh water it is.
	_mat.set_shader_parameter("salinity_from_vertex", 1.0)
	_mat.set_shader_parameter("flow_scale", 1.0)
	_mat.set_shader_parameter("depth_influence", 0.7)        # deep sea + reasonably solid lakes; shoreline foam on
	_mat.set_shader_parameter("base_alpha", 0.80 if transparent else 1.0)
	_mat.set_shader_parameter("ripple_speed", RIPPLE_SPEED)
	_mat.set_shader_parameter("ripple_decay", RIPPLE_DECAY)
	material_override = _mat

	# Ring the surface whenever anything splashes (meteor / tornado / fish / thrown rock / flood / plant).
	if field._inject != null and field._inject.has_signal("splashed"):
		field._inject.splashed.connect(_on_splashed)
	_ready = true


func _on_splashed(world_pos: Vector3, strength: float) -> void:
	add_ripple(world_pos, strength)


## Push an expanding impact ring at a world point. Evicts the weakest entry when the buffer is full.
func add_ripple(world_pos: Vector3, strength: float) -> void:
	if is_nan(world_pos.x):
		return
	if _ripples.size() >= RIPPLE_MAX:
		var weakest: int = 0
		for i in range(1, _ripples.size()):
			if _ripples[i].strength < _ripples[weakest].strength:
				weakest = i
		_ripples.remove_at(weakest)
	_ripples.push_back({"pos": world_pos, "age": 0.0, "strength": clampf(strength, 0.1, 4.0)})


func _process(delta: float) -> void:
	if not _ready or _camera == null or not is_instance_valid(_camera) or _f._grid == null:
		return
	var cam_pos: Vector3 = _camera.global_position
	var radial: Vector3 = (cam_pos - _center).normalized()
	# Anchor the local patch frame so +Y == the camera radial (the flat shader's world-up assumption holds
	# locally over the near cap). Update it every frame so the surface tracks a moving camera without a rebuild.
	var ref: Vector3 = Vector3.FORWARD
	if absf(radial.dot(ref)) > 0.99:
		ref = Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(radial).normalized()
	var z_axis: Vector3 = radial.cross(x_axis).normalized()
	global_transform = Transform3D(Basis(x_axis, radial, z_axis), _center)

	_age_ripples(delta)
	_push_frame_uniforms(radial)

	# Rebuild geometry on a throttle, or early when the camera has orbited enough to move the cap.
	_accum += delta
	var moved: bool = _last_radial.dot(radial) < RECENTER_DOT
	if _accum < REBUILD_PERIOD and not moved:
		return
	_accum = 0.0
	_last_radial = radial
	_rebuild(radial)


## THE MESH THE DETECTOR EXTRACTED, taken as it stands. Nothing here decides where the surface is.
func _rebuild(_radial: Vector3) -> void:
	var det = _f._gpu.pass_named("MeshExtractPass") if _f._gpu != null else null
	if _mesh.get_surface_count() > 0:
		_mesh.clear_surfaces()
	if det == null or det.verts.size() < 9 or det.indices.size() < 3:
		return
	var inv_xform: Transform3D = global_transform.affine_inverse()
	var n: int = det.verts.size() / 3
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	verts.resize(n)
	normals.resize(n)
	colors.resize(n)
	var basis_inv: Basis = global_transform.basis.inverse()
	for i in n:
		var w: Vector3 = Vector3(det.verts[i * 3], det.verts[i * 3 + 1], det.verts[i * 3 + 2])
		verts[i] = inv_xform * w
		# The vertex stands on the body's own radial, so that is the sheet's normal there.
		normals[i] = (basis_inv * (w - _center)).normalized()
		colors[i] = Color(0.5, 0.5, 0.0, 0.0)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = det.indices
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if OS.get_environment("LA_WATER_DEBUG") != "":
		print("WATER_SURFACE={verts:%d, tris:%d, wet:%d}" % [n, det.indices.size() / 3,
			_f.wet_cell_count()])


func _age_ripples(delta: float) -> void:
	var kept: Array = []
	for rp in _ripples:
		rp.age += delta
		var amp: float = rp.strength * exp(-rp.age * RIPPLE_DECAY)
		if amp > 0.02 and rp.age * RIPPLE_SPEED < 400.0:
			kept.push_back(rp)
	_ripples = kept


func _push_frame_uniforms(radial: Vector3) -> void:
	if _mat == null:
		return
	# THE WIND WHERE THE EYE STANDS, not a mean over the body, projected into the patch's own frame, which
	# is what the flat Y-up water shader reads. The wave dial saturates at the reference the arrow glyphs'
	# ramp does, so one reading drives both pictures.
	var eye: Vector3 = _camera.global_position
	var w3: Vector3 = _f.wind3_at(eye.x, eye.y, eye.z)
	var local: Vector3 = global_transform.basis.inverse() * w3
	var flat: Vector2 = Vector2(local.x, local.z)
	var wdir: Vector2 = flat.normalized() if flat.length() > 1.0e-4 else Vector2(1.0, 0.0)
	_mat.set_shader_parameter("wind_dir", wdir)
	_mat.set_shader_parameter("wind_strength",
		clampf(2.0 * w3.length() / LAFieldVectors.WIND_REF_M_S, 0.0, 2.0))
	# Impact ripples: pad to RIPPLE_MAX with (centre.x, centre.z, age, strength) in WORLD xz (what the shader reads).
	var packed: Array = []
	packed.resize(RIPPLE_MAX)
	for i in RIPPLE_MAX:
		if i < _ripples.size():
			var rp: Dictionary = _ripples[i]
			packed[i] = Vector4(rp.pos.x, rp.pos.z, rp.age, rp.strength)
		else:
			packed[i] = Vector4.ZERO
	_mat.set_shader_parameter("ripples", packed)
	_mat.set_shader_parameter("ripple_count", _ripples.size())
