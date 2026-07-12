class_name LAMaterialFieldRender3D
extends MeshInstance3D

## The dynamic water-surface renderer — the module the VoxelWater.gdshader header has always named but which
## was never built. It turns the field's settled `water` column into a visible, flowing, rippling surface for
## every freshwater body (springs, rivers, waterfalls, lakes, floods). Until now that water was fully simulated
## but drawn NOWHERE, so rivers were invisible; this closes that gap.
##
## Behaviour lives here (NOT in the thin hubs): it owns the water ArrayMesh, the VoxelWater.gdshader material,
## the impact-ripple ring buffer, the rebuild cadence, and the near-cap LOD scan. The mesh math is delegated to
## LAWaterSurfaceMesh. Perf follows the "bubbles of compute" rule: the mesh is rebuilt only over the camera's
## near cap and only every REBUILD_PERIOD seconds (waves + ripples animate at full rate in-shader via TIME), so
## there is never a per-frame full-grid sweep. Reads the field's per-cell arrays directly (`_f._water`/`_solid`/
## `_static`) exactly as the sibling query/inject modules do. (Explicit types only — no ':=' .)

const WaterShader: Shader = preload("res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelWater.gdshader")
const MeshBuilderScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/WaterSurfaceMesh.gd")

const CAP_ANGLE: float = 0.8               # rebuild within this half-angle of the camera radial — a small NEAR patch
                                           # (nearly flat, so the flat Y-up shader stays correct; far sea = the sphere)
const FAR_ALT: float = 130.0               # above this altitude (world units over sea level) the dynamic surface is
                                           # skipped and the cheap ocean sphere shows. The flat/Y-up patch only reads
                                           # right when you're DOWN near the water (small, ~flat cap); from any pulled-
                                           # back view the curved cap looks blocky/weird, so hand those to the sphere.
const MAX_MASS: float = 1.0                # water kernel's MAX_MASS (a full cell) — for the sub-cell height fraction
const REBUILD_PERIOD: float = 0.22         # ~4.5 Hz geometry rebuild (stale a couple frames is imperceptible)
const RECENTER_DOT: float = 0.999          # rebuild early if the camera radial rotates past this (recentre the cap)
const RIPPLE_MAX: int = 16                 # must match VoxelWater.gdshader RIPPLE_MAX
const RIPPLE_SPEED: float = 9.0            # matches the shader (for age-out)
const RIPPLE_DECAY: float = 0.7            # matches the shader
const WIND_SCALE: float = 6.0              # field.wind() magnitude → shader wind_strength (0..2)

var _f = null                              # LAMaterialField3D
var _camera: Node3D = null
var _center: Vector3 = Vector3.ZERO
var _sea_radius: float = 0.0
var _grid: RefCounted = null
var _builder: RefCounted = null
var _mesh: ArrayMesh = null
var _mat: ShaderMaterial = null
var _ripples: Array = []                   # [{pos:Vector3, age:float, strength:float}]
var _accum: float = REBUILD_PERIOD          # force a build on the first frame
var _last_radial: Vector3 = Vector3.ZERO
var _ready: bool = false


func setup(field, camera: Node3D, terrain, _sun, center: Vector3, sea_radius: float) -> void:
	_f = field
	_camera = camera
	_center = center
	_sea_radius = sea_radius
	if field.has_method("sphere_grid"):
		_grid = field.sphere_grid()
	_builder = MeshBuilderScript.new()

	_mesh = ArrayMesh.new()
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Fresh-water look: clear teal, thin sheet (ignore scene thickness so a shallow lake isn't opaque-white),
	# use the per-vertex CA flow. Salt/sea uniforms come later when the ocean unifies into this surface (A2).
	_mat = ShaderMaterial.new()
	_mat.shader = WaterShader
	_mat.set_shader_parameter("salinity_from_vertex", 1.0)   # sea vs lake/river taken per-vertex from COLOR.a
	_mat.set_shader_parameter("flow_scale", 1.0)
	_mat.set_shader_parameter("depth_influence", 0.7)        # deep sea + reasonably solid lakes; shoreline foam on
	_mat.set_shader_parameter("base_alpha", 0.80)
	material_override = _mat

	# Ring the surface whenever anything splashes (meteor / tornado / fish / thrown rock / flood / plant).
	if field._inject != null and field._inject.has_signal("splashed"):
		field._inject.splashed.connect(_on_splashed)
	_ready = true


## Feed the emergent sea-ice coverage texture to the near-cap water material so a frozen sea reads WHITE up close
## too — matching the ocean shell so descending onto a frozen pole is continuous ice, not a blue cap under white.
## The mesh node sits at the planet centre, so the shader recovers the surface radial from its own MODEL_MATRIX;
## no centre uniform needed. Bound once by LASeaIceShaderController (disabled by LA_NO_SEAICE / on the flat island).
func set_sea_ice_texture(tex: Texture2DArray) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("sea_ice_tex", tex)
	_mat.set_shader_parameter("sea_ice_enabled", 1.0)


## Moon-driven tide: set the sea-surface radius the near-cap mesh builds against. The next throttled rebuild
## re-meshes the cap at the new level, so the shoreline advances/recedes with the tide for free. A scalar set
## (no rebuild here) — driven each frame by LASystemOrbits alongside the ocean-shell tide so the two stay in step.
func set_sea_radius(r: float) -> void:
	_sea_radius = r


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
	if not _ready or _camera == null or not is_instance_valid(_camera) or _grid == null:
		return
	var cam_pos: Vector3 = _camera.global_position
	var cam_dist: float = cam_pos.distance_to(_center)
	var radial: Vector3 = (cam_pos - _center) / maxf(cam_dist, 0.001)
	# FAR: from orbit/overview the flat-patch surface reads worse than the smooth ocean sphere — drop it (and the
	# rebuild cost). Clear once, then idle until the camera descends back within FAR_ALT of sea level.
	if cam_dist - _sea_radius > FAR_ALT:
		if _mesh.get_surface_count() > 0:
			_mesh.clear_surfaces()
		return

	# Anchor the local patch frame so +Y == the camera radial (the flat shader's world-up assumption holds
	# locally over the near cap). Update it every frame so the surface tracks a moving camera without a rebuild.
	var ref: Vector3 = Vector3.FORWARD
	if absf(radial.dot(ref)) > 0.99:
		ref = Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(radial).normalized()
	var z_axis: Vector3 = radial.cross(x_axis).normalized()
	global_transform = Transform3D(Basis(x_axis, radial, z_axis), _center)

	_age_ripples(delta)
	_push_frame_uniforms()

	# Rebuild geometry on a throttle, or early when the camera has orbited enough to move the cap.
	_accum += delta
	var moved: bool = _last_radial.dot(radial) < RECENTER_DOT
	if _accum < REBUILD_PERIOD and not moved:
		return
	_accum = 0.0
	_last_radial = radial
	_rebuild(radial)


func _rebuild(radial: Vector3) -> void:
	var grid: RefCounted = _grid
	if _f._water.size() != grid.cell_count:
		return
	var inv_xform: Transform3D = global_transform.affine_inverse()
	var out: Dictionary = _builder.build(grid, _f._water, _f._solid, _f._static,
		inv_xform, radial, cos(CAP_ANGLE), _f.RENDER_MIN, MAX_MASS, _sea_radius, _f.SEA_WAVE_EPS)
	if _mesh.get_surface_count() > 0:
		_mesh.clear_surfaces()
	if int(out["count"]) == 0 or (out["indices"] as PackedInt32Array).size() == 0:
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out["verts"]
	arrays[Mesh.ARRAY_NORMAL] = out["normals"]
	arrays[Mesh.ARRAY_COLOR] = out["colors"]
	arrays[Mesh.ARRAY_INDEX] = out["indices"]
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if OS.has_environment("LA_WATER_DEBUG"):
		print("WATER_SURFACE={verts:%d, tris:%d, wet:%d}" % [int(out["count"]),
			(out["indices"] as PackedInt32Array).size() / 3, _f.wet_cell_count()])


func _age_ripples(delta: float) -> void:
	var kept: Array = []
	for rp in _ripples:
		rp.age += delta
		var amp: float = rp.strength * exp(-rp.age * RIPPLE_DECAY)
		if amp > 0.02 and rp.age * RIPPLE_SPEED < 400.0:
			kept.push_back(rp)
	_ripples = kept


func _push_frame_uniforms() -> void:
	if _mat == null:
		return
	var w: Vector2 = _f.wind() if _f.has_method("wind") else Vector2.ZERO
	var wdir: Vector2 = w.normalized() if w.length() > 1.0e-4 else Vector2(1.0, 0.0)
	_mat.set_shader_parameter("wind_dir", wdir)
	_mat.set_shader_parameter("wind_strength", clampf(w.length() * WIND_SCALE, 0.0, 2.0))
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
