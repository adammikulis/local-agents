extends Node3D

## Phase A1 windowed integration test for the SOLAR-SYSTEM node spine: assembles LAStar + LAPlanetBody (no
## VoxelWorld), proves the body builds+meshes+renders a planet lit by the positioned star, and validates the
## body's radial contract (up_at/altitude_at/surface_point) by dropping markers that must rest ON the ground.
## Run:
##   LA_NO_STREAMER=1 godot --rendering-driver metal --path . \
##     addons/local_agents/scenes/simulation/voxel/sphere/PlanetPreview.tscn -- --shoot=/tmp/planet.png --frames=180

const StarScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/Star.gd")
const PlanetBodyScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/PlanetBody.gd")

var _frames_target: int = 180
var _shoot_path: String = ""
var _frame: int = 0
var _radius: float = 250.0
var _star: Node3D = null
var _body: Node3D = null
var _cam: Camera3D = null
var _checked: bool = false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr(8)
		elif arg.begins_with("--frames="):
			_frames_target = int(arg.substr(9))

	# The star: positioned light + gravity + solar driver.
	_star = StarScript.new()
	_star.name = "Star"
	add_child(_star)
	_star.setup({"position": Vector3(900.0, 320.0, 620.0), "energy": 1.4})

	# One planet body at the origin (identity transform).
	_body = PlanetBodyScript.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({"radius": _radius, "relief": 16.0, "feature_size": 78.0, "seed": 7})

	_cam = Camera3D.new()
	var cam_pos: Vector3 = Vector3(1.0, 0.55, 1.6).normalized() * (_radius * 2.4)
	_cam.far = 6000.0
	add_child(_cam)
	_cam.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)
	_body.attach_viewer(_cam)

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
	var hits: int = 0
	var alt_err: float = 0.0
	for d: Vector3 in dirs:
		var sr: float = _body.surface_radius(d)
		if is_nan(sr):
			continue
		hits += 1
		var probe: Vector3 = _body.center() + d * (sr + 5.0)
		var alt: float = _body.altitude_at(probe)
		if not is_nan(alt):
			alt_err = maxf(alt_err, absf(alt - 5.0))
		var mp: Vector3 = _body.surface_point(d)
		if not is_nan(mp.x):
			_drop_marker(mp)
	print("SYSTEM_REPORT=", JSON.stringify({
		"body_radius": snappedf(_body.radius(), 0.01),
		"sea_radius": snappedf(_body.sea_radius(), 0.01),
		"atmosphere_radius": snappedf(_body.atmosphere_radius(), 0.01),
		"star_sun_dir": str(_star.sun_dir_for(_body.center()).snappedf(0.001)),
		"star_insolation": snappedf(_star.insolation_at(_body.center()), 0.01),
		"surface_hits": hits, "of": dirs.size(),
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
