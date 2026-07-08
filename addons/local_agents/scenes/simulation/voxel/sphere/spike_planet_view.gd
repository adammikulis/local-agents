extends Node3D

## Phase A1 windowed integration test — builds the planet THROUGH LAVoxelTerrainService.build_planet (not the
## raw generator), proves it meshes + renders, and validates the radial surface queries (surface_radius /
## surface_point / altitude_at) by dropping markers on computed surface points — they must sit ON the ground.
## Run:
##   LA_NO_STREAMER=1 godot --rendering-driver metal --path . \
##     addons/local_agents/scenes/simulation/voxel/sphere/PlanetPreview.tscn -- --shoot=/tmp/planet.png --frames=180

const TerrainServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/terrain/VoxelTerrainService.gd")

var _frames_target: int = 180
var _shoot_path: String = ""
var _frame: int = 0
var _radius: float = 250.0
var _terrain: RefCounted = null
var _cam: Camera3D = null
var _checked: bool = false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr(8)
		elif arg.begins_with("--frames="):
			_frames_target = int(arg.substr(9))

	_terrain = TerrainServiceScript.new()
	_terrain.build_planet(self, {"radius": _radius, "relief": 16.0, "feature_size": 78.0, "seed": 7})

	_cam = Camera3D.new()
	var cam_pos: Vector3 = Vector3(1.0, 0.55, 1.6).normalized() * (_radius * 2.4)
	_cam.far = 6000.0
	add_child(_cam)
	_cam.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)
	_terrain.attach_viewer(_cam)

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -50, 0)
	sun.light_energy = 1.3
	add_child(sun)
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.02, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.3, 0.35, 0.45)
	e.ambient_light_energy = 0.5
	env.environment = e
	add_child(env)


func _process(_delta: float) -> void:
	_frame += 1

	# Once terrain has streamed + collided, validate radial queries + drop surface markers (visual proof).
	if not _checked and _frame == _frames_target - 30:
		_checked = true
		_validate_radial()

	if _shoot_path != "" and _frame == _frames_target:
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png(_shoot_path)
		print("PLANET_VIEW shot=", _shoot_path, " size=", img.get_size())
		get_tree().quit(0)
	elif _shoot_path == "" and _frame > 100000:
		get_tree().quit(0)


func _validate_radial() -> void:
	var dirs: Array[Vector3] = [
		Vector3(1, 0.4, 0.3).normalized(), Vector3(-0.5, 0.2, 1.0).normalized(),
		Vector3(0.2, 1.0, 0.1).normalized(), Vector3(0.9, -0.3, -0.4).normalized(),
		Vector3(-0.6, -0.6, 0.5).normalized(),
	]
	var radii: PackedFloat32Array = PackedFloat32Array()
	var alt_err: float = 0.0
	var hits: int = 0
	for d: Vector3 in dirs:
		var sr: float = _terrain.surface_radius(d)
		if is_nan(sr):
			continue
		hits += 1
		radii.append(sr)
		# a point 5 units above the computed surface must read altitude ~5 (query self-consistency)
		var probe: Vector3 = _terrain.planet_center() + d * (sr + 5.0)
		var alt: float = _terrain.altitude_at(probe)
		if not is_nan(alt):
			alt_err = maxf(alt_err, absf(alt - 5.0))
		# drop a bright marker exactly on the surface point — should rest ON the ground, not float/sink
		var mp: Vector3 = _terrain.surface_point(d)
		if not is_nan(mp.x):
			_drop_marker(mp)
	var rmin: float = 1e9
	var rmax: float = -1e9
	for r: float in radii:
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
	print("SERVICE_REPORT=", JSON.stringify({
		"is_planet": _terrain.is_planet(),
		"planet_radius": snappedf(_terrain.planet_radius(), 0.01),
		"sea_radius": snappedf(_terrain.sea_radius(), 0.01),
		"surface_hits": hits, "of": dirs.size(),
		"r_min": snappedf(rmin, 0.01), "r_max": snappedf(rmax, 0.01),
		"altitude_err": snappedf(alt_err, 0.01),
		"ok": hits == dirs.size() and alt_err < 2.0,
	}))


func _drop_marker(pos: Vector3) -> void:
	var m: MeshInstance3D = MeshInstance3D.new()
	var sph: SphereMesh = SphereMesh.new()
	sph.radius = 5.0
	sph.height = 10.0
	m.mesh = sph
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.25, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.1)
	m.material_override = mat
	m.position = pos
	add_child(m)
