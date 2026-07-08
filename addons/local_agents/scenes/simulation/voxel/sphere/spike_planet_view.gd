extends Node3D

## Phase A1 windowed preview — proves the native sphere generator actually MESHES + RENDERS as a planet
## (Transvoxel over the spherical SDF, distance-LOD via VoxelViewer). Standalone: touches nothing in the
## live flat VoxelWorld scene. Run:
##   LA_NO_STREAMER=1 godot --rendering-driver metal --path . \
##     addons/local_agents/scenes/simulation/voxel/sphere/PlanetPreview.tscn -- --shoot=/tmp/planet.png --frames=140
## Screenshots after --frames frames (terrain needs time to stream+mesh), then quits.

const Planet = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SpherePlanetGenerator.gd")

var _frames_target: int = 140
var _shoot_path: String = ""
var _frame: int = 0
var _radius: float = 250.0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr(8)
		elif arg.begins_with("--frames="):
			_frames_target = int(arg.substr(9))

	var p: RefCounted = Planet.new()
	var gen: VoxelGeneratorGraph = p.build({"radius": _radius, "relief": 16.0, "feature_size": 78.0, "octaves": 4, "seed": 7})

	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()
	mesher.texturing_mode = 0

	var terrain: VoxelLodTerrain = VoxelLodTerrain.new()
	terrain.mesher = mesher
	terrain.generator = gen
	terrain.material = _rock_material()
	terrain.lod_count = 5
	terrain.lod_distance = 60.0
	terrain.view_distance = 2000
	var rr: int = int(_radius) + 60
	terrain.voxel_bounds = AABB(Vector3(-rr, -rr, -rr), Vector3(rr * 2, rr * 2, rr * 2))
	add_child(terrain)

	# Camera looks at the planet from 2.4R out; a VoxelViewer under it streams/meshes the near hemisphere.
	var cam: Camera3D = Camera3D.new()
	var cam_pos: Vector3 = Vector3(1.0, 0.55, 1.6).normalized() * (_radius * 2.4)
	cam.far = 6000.0
	add_child(cam)
	cam.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)
	var viewer: VoxelViewer = VoxelViewer.new()
	viewer.view_distance = 2000
	viewer.requires_visuals = true
	cam.add_child(viewer)

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
	if _shoot_path != "" and _frame == _frames_target:
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png(_shoot_path)
		print("PLANET_VIEW shot=", _shoot_path, " size=", img.get_size())
		get_tree().quit(0)
	elif _shoot_path == "" and _frame > 100000:
		get_tree().quit(0)


func _rock_material() -> Material:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.40, 0.36)
	m.roughness = 0.9
	return m
