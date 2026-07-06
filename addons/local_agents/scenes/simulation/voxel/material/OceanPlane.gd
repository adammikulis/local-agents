class_name LAOceanPlane
extends MeshInstance3D

## LAOceanPlane — the sea around the island, as ONE GPU-shaded plane at sea level, now GPU-REACTIVE.
##
## The sea is a single large plane that follows the camera in XZ (so it always reaches the horizon and
## its wave subdivisions stay near the view) while the waves are computed in WORLD space in the shader
## (so the swell stays put on the water as the plane slides under the camera). It shares the ONE unified
## water shader (shaders/VoxelWater.gdshader) with every freshwater body — the sea just sets salinity≈1
## and a deep-body look via uniforms.
##
## Reactivity is GPU-only (no CPU CA):
##   • wind-driven swell — the shader sums crossed waves whose amplitude/choppiness track `wind_strength`;
##     we feed it `field.wind()` each frame, so the sea is glassy when calm and choppy in a storm;
##   • impact ripples — `add_ripple(world_pos, strength)` pushes an expanding ring into a small ring
##     buffer (RIPPLE_MAX) uploaded to the shader; rings are aged in `_process` and recycled. A meteor /
##     tornado / lightning splash over the sea ripples it automatically: the field's `splash()` drops
##     droplet bodies onto the field node, and we OBSERVE those (child_entered_tree) to seed a ripple —
##     a read-only hook, no edit to MaterialField3D. `add_ripple` is also public so the parent may wire
##     an impact to it directly.
## (Explicit types only — no ':=' inferred typing.)

const SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelWater.gdshader"

# The plane RESIZES with zoom so it always reaches the horizon when pulled out yet stays finely
# tessellated up close. Fine ripple detail comes from the fragment normals; the swell + impact rings
# come from the vertex displacement, so coarse far-cells still read as water.
const SUBDIVISIONS: int = 240
const SIZE_PER_DISTANCE: float = 9.0
const MIN_PLANE_SIZE: float = 2400.0
const MAX_PLANE_SIZE: float = 24000.0

const RIPPLE_MAX: int = 16
const RIPPLE_MAX_AGE: float = 5.0             # seconds before a ring has decayed to nothing → recycle
# field.wind() runs ~1.5 calm and ~5.4+ in a hurricane; map that span to a dramatic glassy→choppy swell.
const WIND_CALM: float = 0.8                  # wind magnitude at/below which the sea is glass
const WIND_SCALE: float = 0.34                # (magnitude − WIND_CALM) × this → shader wind_strength
const WIND_MIN: float = 0.05
const WIND_MAX: float = 1.7
# Observed-splash de-dup: splash() drops several droplets at once — collapse a cluster into one ripple.
const SPLASH_DEDUP_DIST: float = 2.0
const SPLASH_DEDUP_AGE: float = 0.25

var _camera: Node3D = null
var _field: Node = null
var _sea_y: float = 0.0
var _material: ShaderMaterial = null
var _plane: PlaneMesh = null
var _plane_size: float = 0.0
# Ring buffer of active impact ripples, each a Vector4(centre.x, centre.z, age_seconds, strength).
var _ripples: Array[Vector4] = []
# Self-harness: `-- --sea-ripple` fires a demonstrative impact ring on the sea in front of the camera
# after a short delay (exercises the real add_ripple path so a screenshot can show the splash).
var _ripple_test: bool = false
var _ripple_test_frame: int = -1
var _frame: int = 0
# Self-harness: `-- --sea-storm` frames the open sea close-up and forces a storm-strength wind so a
# screenshot can show the choppy wind swell + whitecaps (exercises the real wind()→swell path).
var _storm_test: bool = false
var _storm_framed: bool = false


## Build the ocean plane at world Y `sea_y`, following `camera` in XZ. Added as a child of the caller.
func setup(sea_y: float, camera: Node3D) -> void:
	_sea_y = sea_y
	_camera = camera
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_plane = PlaneMesh.new()
	_plane.subdivide_width = SUBDIVISIONS
	_plane.subdivide_depth = SUBDIVISIONS
	_resize_plane(MIN_PLANE_SIZE)
	mesh = _plane

	_material = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	if sh != null:
		_material.shader = sh
	# The sea look: full salt, a deep body (uses scene-depth thickness), no CA flow.
	_material.set_shader_parameter("salinity", 1.0)
	_material.set_shader_parameter("depth_influence", 1.0)
	_material.set_shader_parameter("flow_scale", 0.0)
	_material.set_shader_parameter("wind_strength", WIND_MIN)
	material_override = _material

	global_position = Vector3(0.0, _sea_y, 0.0)
	_discover_field()
	var cli: PackedStringArray = OS.get_cmdline_user_args()
	_ripple_test = cli.has("--sea-ripple")
	_storm_test = cli.has("--sea-storm")


# Find the sibling MaterialField3D (for wind + is_ocean_at) and subscribe to its splash droplets so the
# sea ripples on any impact — a read-only hook that needs no edit to the field itself.
func _discover_field() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	for child in parent.get_children():
		if child.has_method("wind") and child.has_method("is_ocean_at"):
			_field = child
			if not _field.child_entered_tree.is_connected(_on_field_child_entered):
				_field.child_entered_tree.connect(_on_field_child_entered)
			return


# A body entered the field node. splash() (the impact signal) adds RigidBody3D droplets — the ONLY thing
# that add_child()s to the field — so a droplet appearing over the sea means an impact hit the water.
func _on_field_child_entered(node: Node) -> void:
	if not (node is RigidBody3D):
		return
	# Defer one frame: splash() sets the droplet's position + upward velocity right after add_child, so
	# by idle time we can read them to place the ring and estimate the impact strength.
	node.call_deferred("set_meta", "la_ocean_seen", true)
	call_deferred("_seed_ripple_from_droplet", node)


func _seed_ripple_from_droplet(node: Node) -> void:
	if not is_instance_valid(node) or not (node is RigidBody3D):
		return
	var body: RigidBody3D = node as RigidBody3D
	var p: Vector3 = body.global_position
	if absf(p.y - _sea_y) > 6.0:
		return                                            # not a sea-surface splash (a lake/river droplet)
	if _field != null and _field.has_method("is_ocean_at") and not _field.is_ocean_at(p.x, p.z):
		return                                            # over land/freshwater, not the open sea
	# De-dup the droplet cluster: one ring per splash, not one per droplet.
	for r in _ripples:
		if r.z < SPLASH_DEDUP_AGE and Vector2(r.x - p.x, r.y - p.z).length() < SPLASH_DEDUP_DIST:
			return
	# Recover the splash strength from the droplet's launch speed (splash() scales velocity by strength).
	var strength: float = clampf(body.linear_velocity.y / 3.5, 0.5, 4.0)
	add_ripple(p, strength)


# Self-harness only: frame the open sea close-up and force a storm-strength wind so a windowed --shoot
# captures the choppy wind swell + whitecaps (the real field.wind() → wind_strength → swell path).
func _run_storm_test() -> void:
	if _camera == null or not is_instance_valid(_camera) or _frame < 150:
		return
	if _field != null and _field.has_method("set_wind"):
		_field.set_wind(Vector2(9.0, 3.0))              # a storm-force wind → choppy sea + whitecaps
	if not _storm_framed and _camera.has_method("frame_overview"):
		_camera.frame_overview(_find_open_sea(), 70.0)
		_storm_framed = true


# Self-harness only: seed a meteor-scale splash on the open sea in front of the camera so a windowed
# --shoot run can capture the expanding ripple. Fires a short burst of concentric rings, then latches.
func _run_ripple_test() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	if _ripple_test_frame < 0:
		_ripple_test_frame = _frame + 150          # let the world settle + finish its one-time vista frame
	if _frame < _ripple_test_frame or _frame > _ripple_test_frame + 30:
		return
	if (_frame - _ripple_test_frame) % 10 != 0:
		return
	# Find a patch of open sea near the island and frame the camera on it so the expanding splash is
	# centred in the shot, then drop a burst of concentric rings there (reassert framing each burst so
	# the world's one-time vista frame doesn't steal it).
	var target: Vector3 = _find_open_sea()
	if _camera.has_method("frame_overview"):
		_camera.frame_overview(target, 95.0)
	add_ripple(target, 4.0)


# Find a patch of OUTER open sea — scan from a large radius (well past the island) inward so we skip the
# inland basins that also read as sub-sea-level, giving a clean demo spot for the impact ripple.
func _find_open_sea() -> Vector3:
	if _field == null or not _field.has_method("is_ocean_at"):
		return Vector3(320.0, _sea_y, 0.0)
	for radius in range(320, 90, -20):
		for a in range(0, 8):
			var ang: float = float(a) * TAU / 8.0
			var px: float = cos(ang) * float(radius)
			var pz: float = sin(ang) * float(radius)
			if _field.is_ocean_at(px, pz) and _field.is_ocean_at(px + 30.0, pz) and _field.is_ocean_at(px, pz + 30.0):
				return Vector3(px, _sea_y, pz)
	return Vector3(320.0, _sea_y, 0.0)


## Push an expanding impact ring at `world_pos` with `strength` (meteor/tornado/lightning splash). Public
## so the parent can also wire an impact straight to the sea. Recycles the oldest ring when full.
func add_ripple(world_pos: Vector3, strength: float) -> void:
	var ring: Vector4 = Vector4(world_pos.x, world_pos.z, 0.0, clampf(strength, 0.1, 4.0))
	if _ripples.size() < RIPPLE_MAX:
		_ripples.push_back(ring)
	else:
		# Overwrite the oldest (largest age).
		var oldest: int = 0
		for i in range(_ripples.size()):
			if _ripples[i].z > _ripples[oldest].z:
				oldest = i
		_ripples[oldest] = ring


# Set the plane's side length + a matching oversized AABB (so it never frustum-culls along the sea).
func _resize_plane(size: float) -> void:
	_plane_size = size
	_plane.size = Vector2(size, size)
	custom_aabb = AABB(Vector3(-size, -4.0, -size), Vector3(size * 2.0, 8.0, size * 2.0))


## Set a shader uniform (tuning from the debug panel / VoxelWorld, e.g. wave_amp).
func set_ocean_param(param: String, value) -> void:
	if _material != null:
		_material.set_shader_parameter(param, value)


func _process(delta: float) -> void:
	if _field == null:
		_discover_field()
	_frame += 1
	if _ripple_test:
		_run_ripple_test()
	if _storm_test:
		_run_storm_test()
	_update_waves(delta)
	if _camera == null or not is_instance_valid(_camera):
		return
	# Follow the camera in XZ (snapped so the world-space wave phase doesn't shimmer), holding the sea
	# surface at sea level, and size the plane to the current zoom so it always reaches the horizon.
	if _camera.has_method("get_zoom_distance"):
		var target: float = clampf(_camera.get_zoom_distance() * SIZE_PER_DISTANCE, MIN_PLANE_SIZE, MAX_PLANE_SIZE)
		if absf(target - _plane_size) > _plane_size * 0.12:
			_resize_plane(target)
	var cp: Vector3 = _camera.global_position
	global_position = Vector3(round(cp.x), _sea_y, round(cp.z))


# Feed the shader the live wind (swell amplitude + direction) and age/upload the impact rings.
func _update_waves(delta: float) -> void:
	if _material == null:
		return
	if _field != null and (_field.has_method("wind_at") or _field.has_method("wind")):
		# Sample the LOCAL wind where the camera is looking (the sea the player sees), so the swell reflects
		# the wind actually at the coast rather than one global average; fall back to the domain mean.
		var w: Vector2 = _field.wind()
		if _field.has_method("wind_at") and _camera != null and is_instance_valid(_camera):
			var cp: Vector3 = _camera.global_position
			w = _field.wind_at(cp.x, cp.z)
		var mag: float = w.length()
		var strength: float = clampf((mag - WIND_CALM) * WIND_SCALE, WIND_MIN, WIND_MAX)
		_material.set_shader_parameter("wind_strength", strength)
		if mag > 1e-3:
			_material.set_shader_parameter("wind_dir", w / mag)
	# Age rings; drop the fully-decayed ones.
	var alive: Array[Vector4] = []
	for r in _ripples:
		var age: float = r.z + delta
		if age < RIPPLE_MAX_AGE:
			alive.push_back(Vector4(r.x, r.y, age, r.w))
	_ripples = alive
	var packed: PackedVector4Array = PackedVector4Array()
	for r in _ripples:
		packed.push_back(r)
	_material.set_shader_parameter("ripples", packed)
	_material.set_shader_parameter("ripple_count", _ripples.size())
