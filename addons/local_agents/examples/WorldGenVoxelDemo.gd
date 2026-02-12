extends Node3D

const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const FlowArrowPulseShader = preload("res://addons/local_agents/scenes/simulation/shaders/FlowArrowPulse.gdshader")

@onready var _environment_controller: Node3D = $EnvironmentController
@onready var _flow_overlay_root: Node3D = $FlowOverlayRoot
@onready var _camera: Camera3D = $Camera3D
@onready var _sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var _world_environment: WorldEnvironment = $WorldEnvironment
@onready var _seed_line_edit: LineEdit = %SeedLineEdit
@onready var _random_seed_button: Button = %RandomSeedButton
@onready var _generate_button: Button = %GenerateButton
@onready var _width_spin: SpinBox = %WidthSpinBox
@onready var _depth_spin: SpinBox = %DepthSpinBox
@onready var _world_height_spin: SpinBox = %WorldHeightSpinBox
@onready var _sea_level_spin: SpinBox = %SeaLevelSpinBox
@onready var _surface_range_spin: SpinBox = %SurfaceRangeSpinBox
@onready var _noise_frequency_spin: SpinBox = %NoiseFrequencySpinBox
@onready var _cave_threshold_spin: SpinBox = %CaveThresholdSpinBox
@onready var _show_flow_checkbox: CheckBox = %ShowFlowCheckBox
@onready var _flow_strength_threshold_spin: SpinBox = %FlowStrengthThresholdSpinBox
@onready var _flow_stride_spin: SpinBox = %FlowStrideSpinBox
@onready var _water_flow_speed_spin: SpinBox = %WaterFlowSpeedSpinBox
@onready var _water_noise_scale_spin: SpinBox = %WaterNoiseScaleSpinBox
@onready var _water_foam_strength_spin: SpinBox = %WaterFoamStrengthSpinBox
@onready var _water_wave_strength_spin: SpinBox = %WaterWaveStrengthSpinBox
@onready var _water_flow_dir_x_spin: SpinBox = %WaterFlowDirXSpinBox
@onready var _water_flow_dir_z_spin: SpinBox = %WaterFlowDirZSpinBox
@onready var _stats_label: Label = %StatsLabel

var _world_generator = WorldGeneratorScript.new()
var _hydrology = HydrologySystemScript.new()
var _rng := RandomNumberGenerator.new()
@export var day_night_cycle_enabled: bool = true
@export var day_length_seconds: float = 140.0
@export_range(0.0, 1.0, 0.001) var start_time_of_day: float = 0.24
var _time_of_day: float = 0.24

func _ready() -> void:
	_rng.randomize()
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_random_seed_button.pressed.connect(_on_random_seed_pressed)
	_generate_button.pressed.connect(_generate_world)
	_show_flow_checkbox.toggled.connect(func(_enabled: bool): _generate_world())
	_seed_line_edit.text_submitted.connect(func(_text: String): _generate_world())
	_water_flow_speed_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_noise_scale_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_foam_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_wave_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_x_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_z_spin.value_changed.connect(_on_water_shader_control_changed)
	_on_random_seed_pressed()

func _process(delta: float) -> void:
	_update_day_night(delta)

func _on_random_seed_pressed() -> void:
	_seed_line_edit.text = "demo_%d" % _rng.randi_range(10000, 99999)
	_generate_world()

func _generate_world() -> void:
	var config = WorldGenConfigResourceScript.new()
	config.map_width = int(_width_spin.value)
	config.map_height = int(_depth_spin.value)
	config.voxel_world_height = int(_world_height_spin.value)
	config.voxel_sea_level = int(_sea_level_spin.value)
	config.voxel_surface_height_range = int(_surface_range_spin.value)
	config.voxel_noise_frequency = float(_noise_frequency_spin.value)
	config.cave_noise_threshold = float(_cave_threshold_spin.value)
	config.voxel_surface_height_base = maxi(2, int(float(config.voxel_world_height) * 0.22))

	var seed_text = _seed_line_edit.text.strip_edges()
	if seed_text == "":
		seed_text = "demo_seed"
		_seed_line_edit.text = seed_text
	var seed = int(hash(seed_text))
	var world = _world_generator.generate(seed, config)
	var hydrology = _hydrology.build_network(world, config)

	if _environment_controller.has_method("apply_generation_data"):
		_environment_controller.apply_generation_data(world, hydrology)
	_apply_water_shader_controls()
	_render_flow_overlay(world, config)
	_frame_camera(world)
	_update_stats(world, hydrology, seed)

func _on_water_shader_control_changed(_value: float) -> void:
	_apply_water_shader_controls()

func _apply_water_shader_controls() -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("set_water_shader_params"):
		return
	var flow_dir = Vector2(_water_flow_dir_x_spin.value, _water_flow_dir_z_spin.value)
	if flow_dir.length_squared() < 0.0001:
		flow_dir = Vector2(1.0, 0.0)
	_environment_controller.call("set_water_shader_params", {
		"flow_dir": flow_dir.normalized(),
		"flow_speed": _water_flow_speed_spin.value,
		"noise_scale": _water_noise_scale_spin.value,
		"foam_strength": _water_foam_strength_spin.value,
		"wave_strength": _water_wave_strength_spin.value,
	})

func _render_flow_overlay(world: Dictionary, config) -> void:
	for child in _flow_overlay_root.get_children():
		child.queue_free()
	if not _show_flow_checkbox.button_pressed:
		return
	var flow_map: Dictionary = world.get("flow_map", {})
	if flow_map.is_empty():
		return
	var rows: Array = flow_map.get("rows", [])
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var surface_by_tile: Dictionary = {}
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var tile_id = "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]
		surface_by_tile[tile_id] = int(column.get("surface_y", 0))

	var stride = maxi(1, int(_flow_stride_spin.value))
	var strength_threshold = clampf(float(_flow_strength_threshold_spin.value), 0.0, 1.0)
	for i in range(0, rows.size(), stride):
		var row_variant = rows[i]
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var strength = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
		if strength < strength_threshold:
			continue
		var dir_x = float(row.get("dir_x", 0.0))
		var dir_y = float(row.get("dir_y", 0.0))
		var direction = Vector2(dir_x, dir_y)
		if direction.length_squared() < 0.01:
			continue
		direction = direction.normalized()
		var x = int(row.get("x", 0))
		var z = int(row.get("y", 0))
		var tile_id = "%d:%d" % [x, z]
		var surface_y = int(surface_by_tile.get(tile_id, config.voxel_sea_level))
		var marker = MeshInstance3D.new()
		var mesh = BoxMesh.new()
		var length = 0.35 + strength * 0.8
		mesh.size = Vector3(0.08, 0.06, length)
		marker.mesh = mesh
		var color = Color(0.2, 0.75 + 0.2 * strength, 1.0 - 0.35 * strength, 1.0)
		var material = ShaderMaterial.new()
		material.shader = FlowArrowPulseShader
		material.set_shader_parameter("base_color", color)
		material.set_shader_parameter("strength", strength)
		material.set_shader_parameter("pulse_speed", 2.0 + strength * 3.0)
		marker.material_override = material
		marker.position = Vector3(float(x) + 0.5, float(surface_y) + 1.15, float(z) + 0.5)
		_flow_overlay_root.add_child(marker)
		marker.look_at(marker.global_position + Vector3(direction.x, 0.0, direction.y), Vector3.UP)

func _frame_camera(world: Dictionary) -> void:
	var width = float(world.get("width", 1))
	var depth = float(world.get("height", 1))
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var world_height = float(voxel_world.get("height", 24))
	var center = Vector3(width * 0.5, world_height * 0.35, depth * 0.5)
	var distance = maxf(width, depth) * 1.05
	_camera.position = center + Vector3(distance * 0.75, world_height * 0.6 + 10.0, distance)
	_camera.look_at(center, Vector3.UP)

func _update_stats(world: Dictionary, hydrology: Dictionary, seed: int) -> void:
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var block_counts: Dictionary = voxel_world.get("block_type_counts", {})
	var water_tiles: Dictionary = hydrology.get("water_tiles", {})
	var flow_map: Dictionary = world.get("flow_map", {})
	var max_flow = float(flow_map.get("max_flow", 0.0))
	_stats_label.text = "seed=%d | blocks=%d | water_tiles=%d | max_flow=%0.2f | tod=%0.2f" % [
		seed,
		int((voxel_world.get("block_rows", []) as Array).size()),
		int(water_tiles.size()),
		max_flow,
		_time_of_day
	]

func _update_day_night(delta: float) -> void:
	if _sun_light == null:
		return
	if day_night_cycle_enabled:
		var day_len = maxf(5.0, day_length_seconds)
		_time_of_day = fposmod(_time_of_day + delta / day_len, 1.0)

	var phase = _time_of_day * TAU
	var elevation_sin = sin(phase - PI * 0.5)
	var daylight = clampf((elevation_sin + 1.0) * 0.5, 0.0, 1.0)
	var elevation = deg_to_rad(lerpf(-12.0, 82.0, daylight))
	var azimuth = phase - PI * 0.5
	var dir = Vector3(
		cos(elevation) * cos(azimuth),
		sin(elevation),
		cos(elevation) * sin(azimuth)
	).normalized()
	_sun_light.look_at(_sun_light.global_position + dir, Vector3.UP)
	_sun_light.light_energy = lerpf(0.06, 1.38, pow(daylight, 1.45))
	_sun_light.light_indirect_energy = lerpf(0.04, 1.15, pow(daylight, 1.35))
	_sun_light.light_color = Color(
		lerpf(0.28, 1.0, daylight),
		lerpf(0.36, 0.96, daylight),
		lerpf(0.58, 0.88, daylight),
		1.0
	)
	if _world_environment != null and _world_environment.environment != null:
		_world_environment.environment.ambient_light_energy = lerpf(0.02, 1.0, pow(daylight, 1.25))
		_world_environment.environment.background_energy_multiplier = lerpf(0.05, 1.0, pow(daylight, 1.2))
