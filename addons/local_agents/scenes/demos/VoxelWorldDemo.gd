extends Node3D

const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const WeatherSystemScript = preload("res://addons/local_agents/simulation/WeatherSystem.gd")
const ErosionSystemScript = preload("res://addons/local_agents/simulation/ErosionSystem.gd")
const SolarExposureSystemScript = preload("res://addons/local_agents/simulation/SolarExposureSystem.gd")
const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const WorldProgressionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfileResource.gd")
const WorldProgressionProfileDefault = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfile_Default.tres")
const VoxelTimelapseSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VoxelTimelapseSnapshotResource.gd")
const FlowFieldInstancedShader = preload("res://addons/local_agents/scenes/simulation/shaders/FlowFieldInstanced.gdshader")
const LavaSurfaceShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelLavaSurface.gdshader")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")
const SettlementControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/SettlementController.gd")
const VillagerControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/VillagerController.gd")
const CultureControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/CultureController.gd")
const EcologyControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/EcologyController.gd")

@onready var _environment_controller: Node3D = $EnvironmentController
@onready var _flow_overlay_root: Node3D = $FlowOverlayRoot
@onready var _debug_overlay_root: Node3D = $DebugOverlayRoot
@onready var _settlement_controller: Node3D = $SettlementController
@onready var _culture_controller: Node3D = $CultureController
@onready var _villager_controller: Node3D = $VillagerController
@onready var _ecology_controller: Node3D = $EcologyController
@onready var _camera: Camera3D = $Camera3D
@onready var _sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var _world_environment: WorldEnvironment = $WorldEnvironment
@onready var _seed_line_edit: LineEdit = %SeedLineEdit
@onready var _random_seed_button: Button = %RandomSeedButton
@onready var _generate_button: Button = %GenerateButton
@onready var _graphics_button: Button = %GraphicsButton
@onready var _width_spin: SpinBox = %WidthSpinBox
@onready var _depth_spin: SpinBox = %DepthSpinBox
@onready var _terrain_preset_option: OptionButton = %TerrainPresetOption
@onready var _apply_terrain_preset_button: Button = %ApplyTerrainPresetButton
@onready var _world_height_spin: SpinBox = %WorldHeightSpinBox
@onready var _sea_level_spin: SpinBox = %SeaLevelSpinBox
@onready var _surface_base_spin: SpinBox = %SurfaceBaseSpinBox
@onready var _surface_range_spin: SpinBox = %SurfaceRangeSpinBox
@onready var _noise_frequency_spin: SpinBox = %NoiseFrequencySpinBox
@onready var _noise_octaves_spin: SpinBox = %NoiseOctavesSpinBox
@onready var _noise_lacunarity_spin: SpinBox = %NoiseLacunaritySpinBox
@onready var _noise_gain_spin: SpinBox = %NoiseGainSpinBox
@onready var _surface_smoothing_spin: SpinBox = %SurfaceSmoothingSpinBox
@onready var _cave_threshold_spin: SpinBox = %CaveThresholdSpinBox
@onready var _start_year_spin: SpinBox = %StartYearSpinBox
@onready var _years_per_tick_spin: SpinBox = %YearsPerTickSpinBox
@onready var _show_flow_checkbox: CheckBox = %ShowFlowCheckBox
@onready var _flow_strength_threshold_spin: SpinBox = %FlowStrengthThresholdSpinBox
@onready var _flow_stride_spin: SpinBox = %FlowStrideSpinBox
@onready var _cloud_quality_option: OptionButton = %CloudQualityOption
@onready var _cloud_density_spin: SpinBox = %CloudDensitySpinBox
@onready var _debug_density_spin: SpinBox = %DebugDensitySpinBox
@onready var _ocean_quality_option: OptionButton = %OceanQualityOption
@onready var _sim_backend_option: OptionButton = %SimBackendOption
@onready var _auto_scale_checkbox: CheckBox = %AutoScaleCheckBox
@onready var _enable_fog_checkbox: CheckBox = %EnableFogCheckBox
@onready var _enable_sdfgi_checkbox: CheckBox = %EnableSdfgiCheckBox
@onready var _enable_glow_checkbox: CheckBox = %EnableGlowCheckBox
@onready var _enable_clouds_checkbox: CheckBox = %EnableCloudsCheckBox
@onready var _enable_shadows_checkbox: CheckBox = %EnableShadowsCheckBox
@onready var _lightning_intensity_spin: SpinBox = %LightningIntensitySpinBox
@onready var _lightning_button: Button = %LightningStrikeButton
@onready var _water_flow_speed_spin: SpinBox = %WaterFlowSpeedSpinBox
@onready var _water_noise_scale_spin: SpinBox = %WaterNoiseScaleSpinBox
@onready var _water_foam_strength_spin: SpinBox = %WaterFoamStrengthSpinBox
@onready var _water_wave_strength_spin: SpinBox = %WaterWaveStrengthSpinBox
@onready var _water_flow_dir_x_spin: SpinBox = %WaterFlowDirXSpinBox
@onready var _water_flow_dir_z_spin: SpinBox = %WaterFlowDirZSpinBox
@onready var _eruption_interval_spin: SpinBox = %EruptionIntervalSpinBox
@onready var _island_growth_spin: SpinBox = %IslandGrowthSpinBox
@onready var _new_vent_chance_spin: SpinBox = %NewVentChanceSpinBox
@onready var _moon_cycle_days_spin: SpinBox = %MoonCycleDaysSpinBox
@onready var _moon_tide_strength_spin: SpinBox = %MoonTideStrengthSpinBox
@onready var _moon_tide_range_spin: SpinBox = %MoonTideRangeSpinBox
@onready var _gravity_strength_spin: SpinBox = %GravityStrengthSpinBox
@onready var _gravity_radius_spin: SpinBox = %GravityRadiusSpinBox
@onready var _ocean_amplitude_spin: SpinBox = %OceanAmplitudeSpinBox
@onready var _ocean_frequency_spin: SpinBox = %OceanFrequencySpinBox
@onready var _ocean_chop_spin: SpinBox = %OceanChopSpinBox
@onready var _water_lod_start_spin: SpinBox = %WaterLodStartSpinBox
@onready var _water_lod_end_spin: SpinBox = %WaterLodEndSpinBox
@onready var _water_lod_min_spin: SpinBox = %WaterLodMinSpinBox
@onready var _sim_tick_cap_spin: SpinBox = %SimTickCapSpinBox
@onready var _dynamic_target_fps_spin: SpinBox = %DynamicTargetFpsSpinBox
@onready var _dynamic_check_spin: SpinBox = %DynamicCheckSpinBox
@onready var _terrain_chunk_spin: SpinBox = %TerrainChunkSpinBox
@onready var _sim_budget_ms_spin: SpinBox = %SimBudgetMsSpinBox
@onready var _timelapse_stride_spin: SpinBox = %TimelapseStrideSpinBox
@onready var _flow_refresh_spin: SpinBox = %FlowRefreshSpinBox
@onready var _terrain_apply_spin: SpinBox = %TerrainApplySpinBox
@onready var _stats_label: Label = %StatsLabel
@onready var _perf_compare_label: Label = %PerfCompareLabel
@onready var _simulation_hud: CanvasLayer = $SimulationHud

var _world_generator = WorldGeneratorScript.new()
var _hydrology = HydrologySystemScript.new()
var _weather = WeatherSystemScript.new()
var _erosion = ErosionSystemScript.new()
var _solar = SolarExposureSystemScript.new()
var _world_progression_profile = WorldProgressionProfileDefault.duplicate(true)
var _rng := RandomNumberGenerator.new()
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()
@export var day_night_cycle_enabled: bool = true
@export var day_length_seconds: float = 140.0
@export_range(0.0, 1.0, 0.001) var start_time_of_day: float = 0.24
@export var weather_simulation_enabled: bool = true
@export_range(0.1, 8.0, 0.1) var weather_ticks_per_second: float = 2.0
@export_range(0.1, 30.0, 0.1) var eruption_interval_seconds: float = 2.2
@export_range(0.0, 4.0, 0.05) var island_growth_per_eruption: float = 0.9
@export_range(0.0, 1.0, 0.01) var new_vent_spawn_chance: float = 0.08
@export_range(1.0, 60.0, 0.1) var lunar_cycle_days: float = 29.53
@export_range(1.0, 30.0, 1.0) var tide_uniform_updates_per_second: float = 6.0
@export_range(1, 64, 1) var max_active_lava_fx: int = 20
@export_range(1, 24, 1) var max_sim_ticks_per_frame: int = 6
@export_range(1, 12, 1) var hydrology_rebake_every_eruption_events: int = 2
@export_range(0.1, 30.0, 0.1) var hydrology_rebake_max_seconds: float = 4.0
@export_range(0.2, 5.0, 0.1) var dynamic_quality_check_seconds: float = 1.0
@export_range(20.0, 120.0, 1.0) var dynamic_target_fps: float = 55.0
@export_range(1.0, 25.0, 0.5) var sim_budget_ms_per_frame: float = 6.0
@export_range(1, 64, 1) var timelapse_record_every_ticks: int = 1
@export_range(0.02, 2.0, 0.01) var flow_overlay_refresh_seconds: float = 0.2
@export_range(0.0, 1.0, 0.01) var terrain_apply_interval_seconds: float = 0.08
var _time_of_day: float = 0.24
var _sim_accum: float = 0.0
var _sim_tick: int = 0
var _simulated_seconds: float = 0.0
var _world_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _erosion_snapshot: Dictionary = {}
var _solar_snapshot: Dictionary = {}
var _solar_seed: int = 0
var _landslide_count: int = 0
var _is_playing: bool = true
var _ticks_per_frame: int = 1
var _fork_index: int = 0
var _active_branch_id: String = "main"
var _timelapse_snapshots: Dictionary = {}
var _flow_overlay_mm_instance: MultiMeshInstance3D
var _flow_overlay_mesh: BoxMesh
var _flow_overlay_material: ShaderMaterial
var _flow_overlay_dir_image: Image
var _flow_overlay_height_image: Image
var _flow_overlay_dir_texture: ImageTexture
var _flow_overlay_height_texture: ImageTexture
var _flow_overlay_grid_w: int = 0
var _flow_overlay_grid_h: int = 0
var _flow_overlay_stride: int = 1
var _flow_overlay_instance_count: int = 0
var _flow_overlay_dirty: bool = true
var _clouds_enabled: bool = true
var _eruption_accum: float = 0.0
var _lava_root: Node3D
var _lava_fx: Array = []
var _tide_uniform_accum: float = 0.0
var _tide_uniform_signature: String = ""
var _pending_hydro_changed_tiles: Dictionary = {}
var _pending_hydro_rebake_events: int = 0
var _pending_hydro_rebake_seconds: float = 0.0
var _lava_pool_cursor: int = 0
var _ocean_detail: float = 0.66
var _graphics_options_expanded: bool = false
var _sim_backend_mode: String = "gpu_hybrid"
var _dynamic_quality_accum: float = 0.0
var _dynamic_pressure_low: int = 0
var _dynamic_pressure_high: int = 0
var _sim_budget_debt_ms: float = 0.0
var _sim_budget_credit_ms: float = 0.0
var _weather_tick_accum: float = 0.0
var _erosion_tick_accum: float = 0.0
var _solar_tick_accum: float = 0.0
var _flow_overlay_accum: float = 0.0
var _terrain_apply_accum: float = 0.0
var _pending_terrain_changed_tiles: Dictionary = {}
var _local_activity_by_tile: Dictionary = {}
var _ultra_perf_mode: bool = false
var _erosion_thread: Thread
var _erosion_thread_mutex := Mutex.new()
var _erosion_thread_busy: bool = false
var _erosion_thread_result: Dictionary = {}
var _weather_thread: Thread
var _weather_thread_mutex := Mutex.new()
var _weather_thread_busy: bool = false
var _weather_thread_result: Dictionary = {}
var _solar_thread: Thread
var _solar_thread_mutex := Mutex.new()
var _solar_thread_busy: bool = false
var _solar_thread_result: Dictionary = {}
var _weather_bench_cpu_ms: float = -1.0
var _weather_bench_gpu_ms: float = -1.0
var _solar_bench_cpu_ms: float = -1.0
var _solar_bench_gpu_ms: float = -1.0
var _perf_ewma_by_mode := {
	"cpu": {},
	"gpu_hybrid": {},
	"gpu_aggressive": {},
	"ultra": {},
}

func _ready() -> void:
	_rng.randomize()
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_random_seed_button.pressed.connect(_on_random_seed_pressed)
	_generate_button.pressed.connect(_generate_world)
	_graphics_button.pressed.connect(_on_graphics_button_pressed)
	_apply_terrain_preset_button.pressed.connect(_on_apply_terrain_preset_pressed)
	_show_flow_checkbox.toggled.connect(func(_enabled: bool): _generate_world())
	_seed_line_edit.text_submitted.connect(func(_text: String): _generate_world())
	_water_flow_speed_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_noise_scale_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_foam_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_wave_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_x_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_z_spin.value_changed.connect(_on_water_shader_control_changed)
	_eruption_interval_spin.value_changed.connect(func(v: float): eruption_interval_seconds = maxf(0.1, v))
	_island_growth_spin.value_changed.connect(func(v: float): island_growth_per_eruption = maxf(0.0, v))
	_new_vent_chance_spin.value_changed.connect(func(v: float): new_vent_spawn_chance = clampf(v, 0.0, 1.0))
	_moon_cycle_days_spin.value_changed.connect(func(v: float):
		lunar_cycle_days = maxf(1.0, v)
		_apply_tide_shader_controls(true)
	)
	_moon_tide_strength_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_moon_tide_range_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_gravity_strength_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_gravity_radius_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_amplitude_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_frequency_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_chop_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_start_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_end_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_min_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_cloud_quality_option.item_selected.connect(func(_index: int): _apply_cloud_and_debug_quality())
	_cloud_density_spin.value_changed.connect(func(_v: float): _apply_cloud_and_debug_quality())
	_debug_density_spin.value_changed.connect(func(_v: float): _apply_cloud_and_debug_quality())
	_ocean_quality_option.item_selected.connect(func(_i: int): _apply_ocean_quality_preset())
	_sim_backend_option.item_selected.connect(func(_i: int): _apply_sim_backend_mode())
	if _sim_backend_option.item_count < 4:
		_sim_backend_option.add_item("Ultra Performance")
	_sim_tick_cap_spin.value_changed.connect(func(v: float): max_sim_ticks_per_frame = clampi(int(round(v)), 1, 24))
	_dynamic_target_fps_spin.value_changed.connect(func(v: float): dynamic_target_fps = clampf(v, 20.0, 120.0))
	_dynamic_check_spin.value_changed.connect(func(v: float): dynamic_quality_check_seconds = clampf(v, 0.2, 5.0))
	_terrain_chunk_spin.value_changed.connect(_on_terrain_chunk_size_changed)
	_sim_budget_ms_spin.value_changed.connect(func(v: float): sim_budget_ms_per_frame = clampf(v, 1.0, 25.0))
	_timelapse_stride_spin.value_changed.connect(func(v: float): timelapse_record_every_ticks = clampi(int(round(v)), 1, 64))
	_flow_refresh_spin.value_changed.connect(func(v: float): flow_overlay_refresh_seconds = clampf(v, 0.02, 2.0))
	_terrain_apply_spin.value_changed.connect(func(v: float): terrain_apply_interval_seconds = clampf(v, 0.0, 1.0))
	_enable_fog_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_sdfgi_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_glow_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_clouds_checkbox.toggled.connect(func(_v: bool):
		_clouds_enabled = _v
		_apply_cloud_and_debug_quality()
	)
	_enable_shadows_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_lightning_button.pressed.connect(_on_lightning_strike_pressed)
	_start_year_spin.value_changed.connect(func(_v: float): _generate_world())
	_years_per_tick_spin.value_changed.connect(func(_v: float): _refresh_hud())
	if _simulation_hud != null:
		_simulation_hud.play_pressed.connect(_on_hud_play_pressed)
		_simulation_hud.pause_pressed.connect(_on_hud_pause_pressed)
		_simulation_hud.fast_forward_pressed.connect(_on_hud_fast_forward_pressed)
		_simulation_hud.rewind_pressed.connect(_on_hud_rewind_pressed)
		_simulation_hud.fork_pressed.connect(_on_hud_fork_pressed)
		if _simulation_hud.has_signal("overlays_changed"):
			_simulation_hud.overlays_changed.connect(_on_hud_overlays_changed)
	if _ecology_controller != null and _ecology_controller.has_method("set_debug_overlay"):
		_ecology_controller.call("set_debug_overlay", _debug_overlay_root)
	_sim_tick_cap_spin.value = max_sim_ticks_per_frame
	_dynamic_target_fps_spin.value = dynamic_target_fps
	_dynamic_check_spin.value = dynamic_quality_check_seconds
	_sim_budget_ms_spin.value = sim_budget_ms_per_frame
	_timelapse_stride_spin.value = timelapse_record_every_ticks
	_flow_refresh_spin.value = flow_overlay_refresh_seconds
	_terrain_apply_spin.value = terrain_apply_interval_seconds
	_apply_cloud_and_debug_quality()
	_apply_ocean_quality_preset()
	_apply_sim_backend_mode()
	_on_terrain_chunk_size_changed(_terrain_chunk_spin.value)
	_apply_environment_toggles()
	_apply_tide_shader_controls(true)
	_set_graphics_options_expanded(false)
	_on_hud_overlays_changed(true, true, true, true, true, true)
	_on_random_seed_pressed()

func _on_graphics_button_pressed() -> void:
	_set_graphics_options_expanded(_graphics_button.button_pressed)

func _set_graphics_options_expanded(expanded: bool) -> void:
	_graphics_options_expanded = expanded
	if _graphics_button != null:
		_graphics_button.button_pressed = expanded
		_graphics_button.text = "Graphics ▾" if expanded else "Graphics ▸"
	var graphics_nodes = [
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/QualityRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/EnvironmentRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/LightningRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/EruptionRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/TideGrid"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/PerfGrid"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/WaterShaderGrid"),
	]
	for node_variant in graphics_nodes:
		if node_variant is CanvasItem:
			(node_variant as CanvasItem).visible = expanded

func _process(delta: float) -> void:
	_update_day_night(delta)
	_tide_uniform_accum += maxf(0.0, delta)
	_apply_tide_shader_controls(false)
	_update_lava_fx(delta)
	_apply_dynamic_quality(delta)
	if _is_playing:
		_step_environment_simulation(delta * float(_ticks_per_frame))
	_refresh_hud()

func _on_random_seed_pressed() -> void:
	_seed_line_edit.text = "demo_%d" % _rng.randi_range(10000, 99999)
	_generate_world()

func _generate_world() -> void:
	_stop_async_workers()
	var config = _current_worldgen_config_for_tick(0)

	var seed_text = _seed_line_edit.text.strip_edges()
	if seed_text == "":
		seed_text = "demo_seed"
		_seed_line_edit.text = seed_text
	var seed = int(hash(seed_text))
	var world = _world_generator.generate(seed, config)
	var hydrology = _hydrology.build_network(world, config)
	_world_snapshot = world.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_sim_tick = 0
	_simulated_seconds = 0.0
	_sim_accum = 0.0
	_landslide_count = 0
	_active_branch_id = "main"
	_is_playing = true
	_ticks_per_frame = 1
	_timelapse_snapshots.clear()
	_eruption_accum = 0.0
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_weather_tick_accum = 0.0
	_erosion_tick_accum = 0.0
	_solar_tick_accum = 0.0
	_flow_overlay_accum = flow_overlay_refresh_seconds
	_terrain_apply_accum = terrain_apply_interval_seconds
	_pending_terrain_changed_tiles.clear()
	_local_activity_by_tile.clear()
	_flow_overlay_dirty = true
	_weather_bench_cpu_ms = -1.0
	_weather_bench_gpu_ms = -1.0
	_solar_bench_cpu_ms = -1.0
	_solar_bench_gpu_ms = -1.0
	_dynamic_pressure_low = 0
	_dynamic_pressure_high = 0
	_sim_budget_debt_ms = 0.0
	_sim_budget_credit_ms = 0.0
	_clear_lava_fx()
	var weather_seed = int(hash("%s_weather" % seed_text))
	var erosion_seed = int(hash("%s_erosion" % seed_text))
	var solar_seed = int(hash("%s_solar" % seed_text))
	_solar_seed = solar_seed
	_apply_sim_backend_mode()
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, weather_seed)
	_weather_snapshot = _weather.current_snapshot(0)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, erosion_seed)
	_erosion_snapshot = _erosion.current_snapshot(0)
	_solar.configure_environment(_world_snapshot, solar_seed)
	_solar_snapshot = _solar.current_snapshot(0)
	_solar_snapshot["seed"] = solar_seed

	if _environment_controller.has_method("apply_generation_data"):
		if _environment_controller.has_method("set_terrain_chunk_size"):
			_environment_controller.call("set_terrain_chunk_size", int(round(_terrain_chunk_spin.value)))
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	if _environment_controller.has_method("set_solar_state"):
		_environment_controller.set_solar_state(_solar_snapshot)
	_sync_living_world_features(true)
	_apply_water_shader_controls()
	_render_flow_overlay(_world_snapshot, config)
	_frame_camera(_world_snapshot)
	_update_stats(_world_snapshot, _hydrology_snapshot, seed)
	_record_timelapse_snapshot(_sim_tick)
	call_deferred("_run_gpu_benchmarks")

func _on_water_shader_control_changed(_value: float) -> void:
	_apply_water_shader_controls()

func _on_lightning_strike_pressed() -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("trigger_lightning"):
		return
	_environment_controller.call("trigger_lightning", clampf(float(_lightning_intensity_spin.value), 0.1, 2.0))

func _on_terrain_chunk_size_changed(v: float) -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("set_terrain_chunk_size"):
		return
	_environment_controller.call("set_terrain_chunk_size", int(round(v)))

func _on_apply_terrain_preset_pressed() -> void:
	match _terrain_preset_option.selected:
		0:
			_surface_base_spin.value = 3.0
			_surface_range_spin.value = 7.0
			_sea_level_spin.value = 12.0
			_noise_frequency_spin.value = 0.06
			_noise_octaves_spin.value = 4.0
			_noise_lacunarity_spin.value = 1.95
			_noise_gain_spin.value = 0.48
			_surface_smoothing_spin.value = 0.58
		1:
			_surface_base_spin.value = 7.0
			_surface_range_spin.value = 8.0
			_sea_level_spin.value = 11.0
			_noise_frequency_spin.value = 0.05
			_noise_octaves_spin.value = 3.0
			_noise_lacunarity_spin.value = 1.75
			_noise_gain_spin.value = 0.38
			_surface_smoothing_spin.value = 0.62
		2:
			_surface_base_spin.value = 8.0
			_surface_range_spin.value = 12.0
			_sea_level_spin.value = 12.0
			_noise_frequency_spin.value = 0.06
			_noise_octaves_spin.value = 4.0
			_noise_lacunarity_spin.value = 1.9
			_noise_gain_spin.value = 0.44
			_surface_smoothing_spin.value = 0.48
		_:
			_surface_base_spin.value = 10.0
			_surface_range_spin.value = 18.0
			_sea_level_spin.value = 13.0
			_noise_frequency_spin.value = 0.075
			_noise_octaves_spin.value = 5.0
			_noise_lacunarity_spin.value = 2.2
			_noise_gain_spin.value = 0.54
			_surface_smoothing_spin.value = 0.3
	_generate_world()

func _apply_cloud_and_debug_quality() -> void:
	if _environment_controller != null and _environment_controller.has_method("set_cloud_quality_settings"):
		var density = float(_cloud_density_spin.value)
		if not _clouds_enabled:
			density = 0.0
		var tier = "medium"
		match _cloud_quality_option.selected:
			0:
				tier = "low"
			1:
				tier = "medium"
			2:
				tier = "high"
			_:
				tier = "ultra"
		_environment_controller.call("set_cloud_quality_settings", tier, density)
	if _ecology_controller != null and _ecology_controller.has_method("set_debug_quality"):
		_ecology_controller.call("set_debug_quality", float(_debug_density_spin.value))

func _apply_ocean_quality_preset() -> void:
	match _ocean_quality_option.selected:
		0:
			tide_uniform_updates_per_second = 2.0
			_ocean_detail = 0.35
		1:
			tide_uniform_updates_per_second = 6.0
			_ocean_detail = 0.66
		2:
			tide_uniform_updates_per_second = 10.0
			_ocean_detail = 0.82
		_:
			tide_uniform_updates_per_second = 16.0
			_ocean_detail = 1.0
	_apply_tide_shader_controls(true)

func _apply_sim_backend_mode() -> void:
	match _sim_backend_option.selected:
		0:
			_sim_backend_mode = "cpu"
		1:
			_sim_backend_mode = "gpu_hybrid"
		2:
			_sim_backend_mode = "gpu_aggressive"
		_:
			_sim_backend_mode = "ultra"
	var compact = _sim_backend_mode != "cpu"
	_ultra_perf_mode = _sim_backend_mode == "ultra"
	if _weather != null and _weather.has_method("set_emit_rows"):
		_weather.call("set_emit_rows", not compact)
	if _weather != null and _weather.has_method("set_compute_enabled"):
		_weather.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _erosion != null and _erosion.has_method("set_emit_rows"):
		_erosion.call("set_emit_rows", not compact)
	if _erosion != null and _erosion.has_method("set_compute_enabled"):
		_erosion.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _solar != null and _solar.has_method("set_emit_rows"):
		_solar.call("set_emit_rows", not compact)
	if _solar != null and _solar.has_method("set_compute_enabled"):
		_solar.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _solar != null and _solar.has_method("set_sync_stride"):
		var sync_stride = 1
		if _sim_backend_mode == "gpu_hybrid":
			sync_stride = 2
		elif _sim_backend_mode == "gpu_aggressive":
			sync_stride = 4
		elif _sim_backend_mode == "ultra":
			sync_stride = 8
		_solar.call("set_sync_stride", sync_stride)
	if _sim_backend_mode == "ultra":
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 2)
		timelapse_record_every_ticks = maxi(8, timelapse_record_every_ticks)
		flow_overlay_refresh_seconds = maxf(flow_overlay_refresh_seconds, 0.5)
		terrain_apply_interval_seconds = maxf(terrain_apply_interval_seconds, 0.18)
		sim_budget_ms_per_frame = minf(sim_budget_ms_per_frame, 3.0)
	elif _sim_backend_mode == "gpu_aggressive":
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 3)
		timelapse_record_every_ticks = maxi(4, timelapse_record_every_ticks)
		flow_overlay_refresh_seconds = maxf(flow_overlay_refresh_seconds, 0.35)
		terrain_apply_interval_seconds = maxf(terrain_apply_interval_seconds, 0.12)
		sim_budget_ms_per_frame = minf(sim_budget_ms_per_frame, 5.0)
	elif compact:
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 4)
	else:
		max_sim_ticks_per_frame = maxi(max_sim_ticks_per_frame, 6)
	_sim_tick_cap_spin.value = max_sim_ticks_per_frame
	_timelapse_stride_spin.value = timelapse_record_every_ticks
	_flow_refresh_spin.value = flow_overlay_refresh_seconds
	_terrain_apply_spin.value = terrain_apply_interval_seconds
	_sim_budget_ms_spin.value = sim_budget_ms_per_frame

func _apply_dynamic_quality(delta: float) -> void:
	if _auto_scale_checkbox == null or not _auto_scale_checkbox.button_pressed:
		return
	_dynamic_quality_accum += maxf(0.0, delta)
	if _dynamic_quality_accum < dynamic_quality_check_seconds:
		return
	_dynamic_quality_accum = 0.0
	var fps = Engine.get_frames_per_second()
	if fps <= 0:
		return
	var mode_perf = (_perf_ewma_by_mode.get(_sim_backend_mode, {}) as Dictionary)
	var tick_ms = float(mode_perf.get("tick_total_ms", 0.0))
	var target_frame_ms = 1000.0 / maxf(1.0, dynamic_target_fps)
	var target_sim_ms = minf(sim_budget_ms_per_frame, target_frame_ms * 0.5)
	if tick_ms > 0.0:
		if tick_ms > target_sim_ms * 1.08:
			_sim_budget_debt_ms += tick_ms - target_sim_ms
			_sim_budget_credit_ms = maxf(0.0, _sim_budget_credit_ms - 0.5)
		elif tick_ms < target_sim_ms * 0.82:
			_sim_budget_credit_ms += target_sim_ms - tick_ms
			_sim_budget_debt_ms = maxf(0.0, _sim_budget_debt_ms - 0.5)
	var low_pressure = float(fps) < dynamic_target_fps - 6.0 or _sim_budget_debt_ms > target_sim_ms * 2.0
	var high_pressure = float(fps) > dynamic_target_fps + 8.0 and _sim_budget_credit_ms > target_sim_ms * 2.0
	_dynamic_pressure_low = _dynamic_pressure_low + 1 if low_pressure else maxi(0, _dynamic_pressure_low - 1)
	_dynamic_pressure_high = _dynamic_pressure_high + 1 if high_pressure else maxi(0, _dynamic_pressure_high - 1)
	if _dynamic_pressure_low >= 2:
		_dynamic_pressure_low = 0
		if _ocean_quality_option.selected > 0:
			_ocean_quality_option.selected -= 1
			_apply_ocean_quality_preset()
		elif _cloud_quality_option.selected > 0:
			_cloud_quality_option.selected -= 1
			_apply_cloud_and_debug_quality()
		elif _enable_sdfgi_checkbox.button_pressed:
			_enable_sdfgi_checkbox.button_pressed = false
			_apply_environment_toggles()
		elif _enable_glow_checkbox.button_pressed:
			_enable_glow_checkbox.button_pressed = false
			_apply_environment_toggles()
		elif _enable_shadows_checkbox.button_pressed:
			_enable_shadows_checkbox.button_pressed = false
			_apply_environment_toggles()
		max_sim_ticks_per_frame = maxi(1, max_sim_ticks_per_frame - 1)
		sim_budget_ms_per_frame = clampf(sim_budget_ms_per_frame - 0.5, 1.0, 25.0)
		_sim_budget_ms_spin.value = sim_budget_ms_per_frame
		_sim_tick_cap_spin.value = max_sim_ticks_per_frame
		_sim_budget_debt_ms = maxf(0.0, _sim_budget_debt_ms - target_sim_ms * 0.5)
	elif _dynamic_pressure_high >= 3:
		_dynamic_pressure_high = 0
		if _cloud_quality_option.selected < _cloud_quality_option.item_count - 1:
			_cloud_quality_option.selected += 1
			_apply_cloud_and_debug_quality()
		elif _ocean_quality_option.selected < _ocean_quality_option.item_count - 1:
			_ocean_quality_option.selected += 1
			_apply_ocean_quality_preset()
		elif not _enable_shadows_checkbox.button_pressed:
			_enable_shadows_checkbox.button_pressed = true
			_apply_environment_toggles()
		elif not _enable_glow_checkbox.button_pressed:
			_enable_glow_checkbox.button_pressed = true
			_apply_environment_toggles()
		elif not _enable_sdfgi_checkbox.button_pressed:
			_enable_sdfgi_checkbox.button_pressed = true
			_apply_environment_toggles()
		max_sim_ticks_per_frame = mini(12, max_sim_ticks_per_frame + 1)
		sim_budget_ms_per_frame = clampf(sim_budget_ms_per_frame + 0.5, 1.0, 25.0)
		_sim_budget_ms_spin.value = sim_budget_ms_per_frame
		_sim_tick_cap_spin.value = max_sim_ticks_per_frame
		_sim_budget_credit_ms = maxf(0.0, _sim_budget_credit_ms - target_sim_ms * 0.5)

func _apply_environment_toggles() -> void:
	if _sun_light != null:
		_sun_light.shadow_enabled = _enable_shadows_checkbox.button_pressed
	if _world_environment == null or _world_environment.environment == null:
		return
	var env: Environment = _world_environment.environment
	env.sdfgi_enabled = _enable_sdfgi_checkbox.button_pressed
	env.glow_enabled = _enable_glow_checkbox.button_pressed
	_apply_demo_fog()

func _apply_water_shader_controls() -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("set_water_shader_params"):
		return
	var flow_dir = Vector2(_water_flow_dir_x_spin.value, _water_flow_dir_z_spin.value)
	if flow_dir.length_squared() < 0.0001:
		flow_dir = Vector2(1.0, 0.0)
	var params = {
		"flow_dir": flow_dir.normalized(),
		"flow_speed": _water_flow_speed_spin.value,
		"noise_scale": _water_noise_scale_spin.value,
		"foam_strength": _water_foam_strength_spin.value,
		"wave_strength": _water_wave_strength_spin.value,
	}
	params.merge(_build_tide_shader_params(), true)
	_environment_controller.call("set_water_shader_params", params)

func _apply_tide_shader_controls(force: bool = false) -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("set_water_shader_params"):
		return
	var update_interval = 1.0 / maxf(1.0, tide_uniform_updates_per_second)
	if not force and _tide_uniform_accum < update_interval:
		return
	_tide_uniform_accum = 0.0
	var params = _build_tide_shader_params()
	var signature = "%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f" % [
		float(params.get("moon_phase", 0.0)),
		float((params.get("moon_dir", Vector2.ONE) as Vector2).x),
		float((params.get("moon_dir", Vector2.ONE) as Vector2).y),
		float(params.get("moon_tidal_strength", 0.0)),
		float(params.get("moon_tide_range", 0.0)),
		float(params.get("lunar_wave_boost", 0.0)),
		float(params.get("gravity_source_strength", 0.0)),
		float(params.get("gravity_source_radius", 0.0)),
		float(params.get("ocean_wave_amplitude", 0.0)),
		float(params.get("ocean_wave_frequency", 0.0)),
		float(params.get("ocean_chop", 0.0)),
		float((params.get("gravity_source_pos", Vector2.ZERO) as Vector2).x),
		float((params.get("gravity_source_pos", Vector2.ZERO) as Vector2).y),
	]
	if not force and signature == _tide_uniform_signature:
		return
	_tide_uniform_signature = signature
	_environment_controller.call("set_water_shader_params", params)

func _build_tide_shader_params() -> Dictionary:
	var cycle_days = maxf(1.0, float(_moon_cycle_days_spin.value)) if _moon_cycle_days_spin != null else lunar_cycle_days
	var lunar_period_seconds = maxf(1.0, cycle_days * maxf(10.0, day_length_seconds))
	var moon_phase = fposmod(_simulated_seconds, lunar_period_seconds) / lunar_period_seconds
	var moon_angle = moon_phase * TAU
	var moon_dir = Vector2(cos(moon_angle), sin(moon_angle))
	if moon_dir.length_squared() < 0.0001:
		moon_dir = Vector2(1.0, 0.0)
	var world_width = float(_world_snapshot.get("width", int(_width_spin.value)))
	var world_depth = float(_world_snapshot.get("height", int(_depth_spin.value)))
	var camera_pos = _camera.global_position if _camera != null else Vector3.ZERO
	var far_start = maxf(world_width, world_depth) * 0.35
	var far_end = maxf(world_width, world_depth) * 1.2
	var gravity_orbit = maxf(world_width, world_depth) * 0.55
	var gravity_pos = Vector2(world_width * 0.5, world_depth * 0.5) + moon_dir * gravity_orbit
	var spring_neap = absf(cos(moon_phase * TAU))
	return {
		"moon_dir": moon_dir.normalized(),
		"moon_phase": moon_phase,
		"moon_tidal_strength": float(_moon_tide_strength_spin.value) if _moon_tide_strength_spin != null else 1.0,
		"moon_tide_range": float(_moon_tide_range_spin.value) if _moon_tide_range_spin != null else 0.26,
		"lunar_wave_boost": lerpf(0.25, 1.0, spring_neap),
		"gravity_source_pos": gravity_pos,
		"gravity_source_strength": float(_gravity_strength_spin.value) if _gravity_strength_spin != null else 1.0,
		"gravity_source_radius": float(_gravity_radius_spin.value) if _gravity_radius_spin != null else 96.0,
		"ocean_wave_amplitude": float(_ocean_amplitude_spin.value) if _ocean_amplitude_spin != null else 0.18,
		"ocean_wave_frequency": float(_ocean_frequency_spin.value) if _ocean_frequency_spin != null else 0.65,
		"ocean_chop": float(_ocean_chop_spin.value) if _ocean_chop_spin != null else 0.55,
		"ocean_detail": _ocean_detail,
		"camera_world_pos": camera_pos,
		"far_simplify_start": float(_water_lod_start_spin.value) if _water_lod_start_spin != null else far_start,
		"far_simplify_end": float(_water_lod_end_spin.value) if _water_lod_end_spin != null else far_end,
		"far_detail_min": float(_water_lod_min_spin.value) if _water_lod_min_spin != null else 0.28,
	}

func _step_environment_simulation(delta: float) -> void:
	if not weather_simulation_enabled:
		return
	if _world_snapshot.is_empty() or _hydrology_snapshot.is_empty():
		return
	var tick_duration = 1.0 / maxf(0.1, weather_ticks_per_second)
	_sim_accum += maxf(0.0, delta)
	var terrain_changed = false
	var changed_tiles_map: Dictionary = {}
	var weather_ms_acc = 0.0
	var volcanic_ms_acc = 0.0
	var erosion_ms_acc = 0.0
	var solar_ms_acc = 0.0
	var tick_total_ms_acc = 0.0
	var processed_ticks = 0
	var max_ticks = maxi(1, max_sim_ticks_per_frame)
	var frame_start_us = Time.get_ticks_usec()
	var budget_us = int(round(maxf(1.0, sim_budget_ms_per_frame) * 1000.0))
	var async_weather_result = _consume_weather_worker_result()
	if not async_weather_result.is_empty():
		_weather_snapshot = async_weather_result.get("snapshot", _weather_snapshot)
		weather_ms_acc += float(async_weather_result.get("step_ms", 0.0))
	var async_erosion_result = _consume_erosion_worker_result()
	if not async_erosion_result.is_empty():
		_world_snapshot = async_erosion_result.get("environment", _world_snapshot)
		_hydrology_snapshot = async_erosion_result.get("hydrology", _hydrology_snapshot)
		_erosion_snapshot = async_erosion_result.get("erosion", _erosion_snapshot)
		erosion_ms_acc += float(async_erosion_result.get("step_ms", 0.0))
		terrain_changed = terrain_changed or bool(async_erosion_result.get("changed", false))
		for tile_variant in async_erosion_result.get("changed_tiles", []):
			var tile_id = String(tile_variant)
			changed_tiles_map[tile_id] = true
			_pending_terrain_changed_tiles[tile_id] = true
	var async_solar_result = _consume_solar_worker_result()
	if not async_solar_result.is_empty():
		_solar_snapshot = async_solar_result.get("snapshot", _solar_snapshot)
		solar_ms_acc += float(async_solar_result.get("step_ms", 0.0))
		_solar_snapshot["seed"] = _solar_seed
	while _sim_accum >= tick_duration and processed_ticks < max_ticks:
		var tick_start_us = Time.get_ticks_usec()
		_sim_accum -= tick_duration
		processed_ticks += 1
		_sim_tick += 1
		_simulated_seconds += tick_duration
		var weather_interval = 1 if _sim_backend_mode == "cpu" else (2 if _sim_backend_mode == "gpu_hybrid" else (3 if _sim_backend_mode == "gpu_aggressive" else 4))
		var erosion_interval = 1 if _sim_backend_mode == "cpu" else (2 if _sim_backend_mode == "gpu_hybrid" else (3 if _sim_backend_mode == "gpu_aggressive" else 4))
		var solar_interval = 1 if _sim_backend_mode == "cpu" else (3 if _sim_backend_mode == "gpu_hybrid" else (4 if _sim_backend_mode == "gpu_aggressive" else 6))
		_weather_tick_accum += tick_duration
		_erosion_tick_accum += tick_duration
		_solar_tick_accum += tick_duration
		var local_activity = _build_local_activity_field()
		if (_sim_tick % weather_interval == 0) or (_weather_snapshot.is_empty()):
			var weather_compute_active = _weather != null and _weather.has_method("is_compute_active") and bool(_weather.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not weather_compute_active and not _weather_thread_busy:
				_start_weather_worker(_sim_tick, _weather_tick_accum, local_activity)
				_weather_tick_accum = 0.0
			elif not _weather_thread_busy:
				var weather_start_us = Time.get_ticks_usec()
				_weather_snapshot = _weather.step(_sim_tick, _weather_tick_accum, local_activity)
				_weather_tick_accum = 0.0
				weather_ms_acc += float(Time.get_ticks_usec() - weather_start_us) / 1000.0
		var volcanic_start_us = Time.get_ticks_usec()
		var volcanic_change = _step_volcanic_island_growth(tick_duration)
		volcanic_ms_acc += float(Time.get_ticks_usec() - volcanic_start_us) / 1000.0
		if bool(volcanic_change.get("changed", false)):
			terrain_changed = true
			for tile_variant in volcanic_change.get("changed_tiles", []):
				var tile_id = String(tile_variant)
				changed_tiles_map[tile_id] = true
				_pending_terrain_changed_tiles[tile_id] = true
		if _sim_tick % erosion_interval == 0:
			var erosion_compute_active = _erosion != null and _erosion.has_method("is_compute_active") and bool(_erosion.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not erosion_compute_active and not _erosion_thread_busy:
				_start_erosion_worker(_sim_tick, _erosion_tick_accum, local_activity)
				_erosion_tick_accum = 0.0
			elif not _erosion_thread_busy:
				var erosion_start_us = Time.get_ticks_usec()
				var erosion_result: Dictionary = _erosion.step(
					_sim_tick,
					_erosion_tick_accum,
					_world_snapshot,
					_hydrology_snapshot,
					_weather_snapshot,
					local_activity
				)
				erosion_ms_acc += float(Time.get_ticks_usec() - erosion_start_us) / 1000.0
				_erosion_tick_accum = 0.0
				_world_snapshot = erosion_result.get("environment", _world_snapshot)
				_hydrology_snapshot = erosion_result.get("hydrology", _hydrology_snapshot)
				_erosion_snapshot = erosion_result.get("erosion", _erosion_snapshot)
				terrain_changed = terrain_changed or bool(erosion_result.get("changed", false))
				var changed_tiles: Array = erosion_result.get("changed_tiles", [])
				for tile_variant in changed_tiles:
					var tile_id = String(tile_variant)
					changed_tiles_map[tile_id] = true
					_pending_terrain_changed_tiles[tile_id] = true
		if _sim_tick % solar_interval == 0:
			var solar_compute_active = _solar != null and _solar.has_method("is_compute_active") and bool(_solar.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not solar_compute_active and not _solar_thread_busy:
				_start_solar_worker(_sim_tick, _solar_tick_accum, local_activity)
				_solar_tick_accum = 0.0
			elif not _solar_thread_busy:
				var solar_start_us = Time.get_ticks_usec()
				_solar_snapshot = _solar.step(_sim_tick, _solar_tick_accum, _world_snapshot, _weather_snapshot, local_activity)
				solar_ms_acc += float(Time.get_ticks_usec() - solar_start_us) / 1000.0
				_solar_tick_accum = 0.0
				_solar_snapshot["seed"] = _solar_seed
		if _sim_tick % maxi(1, timelapse_record_every_ticks) == 0:
			_record_timelapse_snapshot(_sim_tick)
		tick_total_ms_acc += float(Time.get_ticks_usec() - tick_start_us) / 1000.0
		if Time.get_ticks_usec() - frame_start_us >= budget_us:
			break
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	if _environment_controller.has_method("set_solar_state"):
		_environment_controller.set_solar_state(_solar_snapshot)
	_sync_living_world_features(false)
	_apply_water_shader_controls()
	_terrain_apply_accum += maxf(0.0, delta)
	_flow_overlay_accum += maxf(0.0, delta)
	var must_apply_now = _pending_terrain_changed_tiles.size() >= 256
	var apply_interval = maxf(0.0, terrain_apply_interval_seconds)
	if _ultra_perf_mode:
		apply_interval = maxf(0.22, apply_interval)
	var should_apply = not _pending_terrain_changed_tiles.is_empty() and (must_apply_now or apply_interval <= 0.0 or _terrain_apply_accum >= apply_interval)
	var did_apply = false
	if should_apply and _environment_controller.has_method("apply_generation_delta"):
		var apply_start_us = Time.get_ticks_usec()
		_environment_controller.apply_generation_delta(_world_snapshot, _hydrology_snapshot, _pending_terrain_changed_tiles.keys())
		_pending_terrain_changed_tiles.clear()
		_terrain_apply_accum = 0.0
		did_apply = true
		_flow_overlay_dirty = true
		_perf_record("terrain_apply_ms", float(Time.get_ticks_usec() - apply_start_us) / 1000.0)
	elif should_apply and _environment_controller.has_method("apply_generation_data"):
		var apply_full_start_us = Time.get_ticks_usec()
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
		_pending_terrain_changed_tiles.clear()
		_terrain_apply_accum = 0.0
		did_apply = true
		_flow_overlay_dirty = true
		_perf_record("terrain_apply_ms", float(Time.get_ticks_usec() - apply_full_start_us) / 1000.0)
	if _show_flow_checkbox.button_pressed:
		var flow_interval = maxf(0.02, flow_overlay_refresh_seconds)
		if _ultra_perf_mode:
			flow_interval = maxf(flow_interval, 0.6)
		if did_apply or _flow_overlay_accum >= flow_interval:
			var config = _current_worldgen_config()
			_render_flow_overlay(_world_snapshot, config)
			_flow_overlay_accum = 0.0
	if processed_ticks > 0:
		var inv = 1.0 / float(processed_ticks)
		_perf_record("weather_ms", weather_ms_acc * inv)
		_perf_record("volcanic_ms", volcanic_ms_acc * inv)
		_perf_record("erosion_ms", erosion_ms_acc * inv)
		_perf_record("solar_ms", solar_ms_acc * inv)
		_perf_record("tick_total_ms", tick_total_ms_acc * inv)
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))

func _step_volcanic_island_growth(tick_duration: float) -> Dictionary:
	if _world_snapshot.is_empty():
		return {"changed": false, "changed_tiles": []}
	var geology: Dictionary = _world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	if volcanoes.is_empty():
		return {"changed": false, "changed_tiles": []}
	_pending_hydro_rebake_seconds += maxf(0.0, tick_duration)
	_eruption_accum += maxf(0.0, tick_duration)
	var eruption_interval = maxf(0.1, float(_eruption_interval_spin.value)) if _eruption_interval_spin != null else maxf(0.1, eruption_interval_seconds)
	if _eruption_accum < eruption_interval:
		return {"changed": false, "changed_tiles": []}
	_eruption_accum = 0.0
	var new_vent_chance = clampf(float(_new_vent_chance_spin.value), 0.0, 1.0) if _new_vent_chance_spin != null else clampf(new_vent_spawn_chance, 0.0, 1.0)
	if _rng.randf() <= new_vent_chance:
		_try_spawn_new_vent()
		geology = _world_snapshot.get("geology", {})
		volcanoes = geology.get("volcanic_features", [])
	var changed_tiles_map: Dictionary = {}
	var eruption_count = mini(2, maxi(1, int(round(float(_ticks_per_frame) * 0.5))))
	for _i in range(eruption_count):
		var volcano = _pick_eruption_volcano(volcanoes)
		if volcano.is_empty():
			continue
		var changed = _apply_eruption_to_world(volcano)
		for tile_variant in changed:
			changed_tiles_map[String(tile_variant)] = true
		_spawn_lava_plume(volcano)
	if changed_tiles_map.is_empty():
		if _pending_hydro_rebake_events > 0 and _pending_hydro_rebake_seconds >= hydrology_rebake_max_seconds:
			_rebake_hydrology_from_pending()
		return {"changed": false, "changed_tiles": []}
	_pending_hydro_rebake_events += 1
	for tile_variant in changed_tiles_map.keys():
		_pending_hydro_changed_tiles[String(tile_variant)] = true
	if _pending_hydro_rebake_events >= maxi(1, hydrology_rebake_every_eruption_events) or _pending_hydro_rebake_seconds >= hydrology_rebake_max_seconds:
		_rebake_hydrology_from_pending()
	return {"changed": true, "changed_tiles": changed_tiles_map.keys()}

func _rebake_hydrology_from_pending() -> void:
	if _pending_hydro_rebake_events <= 0 and _pending_hydro_changed_tiles.is_empty():
		return
	_stop_async_workers()
	var config = _current_worldgen_config()
	_world_snapshot["flow_map"] = _world_generator.rebake_flow_map(_world_snapshot)
	_hydrology_snapshot = _hydrology.build_network(_world_snapshot, config)
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, int(_weather_snapshot.get("seed", 0)))
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, int(_erosion_snapshot.get("seed", 0)))
	_solar.configure_environment(_world_snapshot, _solar_seed)
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_flow_overlay_dirty = true

func _pick_eruption_volcano(volcanoes: Array) -> Dictionary:
	if volcanoes.is_empty():
		return {}
	var best_score = -1.0
	var best: Dictionary = {}
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		var activity = clampf(float(volcano.get("activity", 0.0)), 0.0, 1.0)
		var oceanic = clampf(float(volcano.get("oceanic", 0.0)), 0.0, 1.0)
		var jitter = _rng.randf() * 0.45
		var score = activity * 0.85 + oceanic * 0.25 + jitter
		if score > best_score:
			best_score = score
			best = volcano
	return best

func _try_spawn_new_vent() -> void:
	var geology: Dictionary = _world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	var by_id: Dictionary = {}
	for v_variant in volcanoes:
		if not (v_variant is Dictionary):
			continue
		var v = v_variant as Dictionary
		by_id[String(v.get("tile_id", ""))] = true
	var tiles: Array = _world_snapshot.get("tiles", [])
	var best_tile: Dictionary = {}
	var best_score = -1.0
	for tile_variant in tiles:
		if not (tile_variant is Dictionary):
			continue
		var tile = tile_variant as Dictionary
		var tile_id = String(tile.get("tile_id", ""))
		if tile_id == "" or by_id.has(tile_id):
			continue
		var elev = clampf(float(tile.get("elevation", 0.0)), 0.0, 1.0)
		var geothermal = clampf(float(tile.get("geothermal_activity", 0.0)), 0.0, 1.0)
		var continentalness = clampf(float(tile.get("continentalness", 0.5)), 0.0, 1.0)
		var oceanic = clampf((0.62 - continentalness) * 2.0, 0.0, 1.0)
		var near_sea = clampf(1.0 - absf(elev - 0.34) * 2.0, 0.0, 1.0)
		var score = geothermal * 0.58 + oceanic * 0.26 + near_sea * 0.16 + _rng.randf() * 0.15
		if score > best_score:
			best_score = score
			best_tile = tile
	if best_tile.is_empty() or best_score < 0.56:
		return
	var tx = int(best_tile.get("x", 0))
	var tz = int(best_tile.get("y", 0))
	var feature = {
		"id": "volcano:%d:%d:%d" % [tx, tz, _sim_tick],
		"tile_id": "%d:%d" % [tx, tz],
		"x": tx,
		"y": tz,
		"radius": _rng.randi_range(1, 3),
		"cone_height": 3.0 + _rng.randf() * 2.4,
		"crater_depth": 1.0 + _rng.randf() * 1.2,
		"activity": clampf(float(best_tile.get("geothermal_activity", 0.5)) * 0.9 + 0.1, 0.2, 1.0),
		"oceanic": clampf((0.62 - float(best_tile.get("continentalness", 0.5))) * 2.0, 0.0, 1.0),
	}
	volcanoes.append(feature)
	geology["volcanic_features"] = volcanoes
	_world_snapshot["geology"] = geology

func _apply_eruption_to_world(volcano: Dictionary) -> Array:
	var changed: Array = []
	var voxel_world: Dictionary = _world_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var tile_index: Dictionary = _world_snapshot.get("tile_index", {})
	var tiles: Array = _world_snapshot.get("tiles", [])
	var sea_level = int(voxel_world.get("sea_level", 1))
	var world_height = int(voxel_world.get("height", 36))
	var chunk_size = maxi(4, int(voxel_world.get("block_rows_chunk_size", 12)))
	var vx = int(volcano.get("x", 0))
	var vz = int(volcano.get("y", 0))
	var radius = maxi(1, int(volcano.get("radius", 2)))
	var lava_yield = maxf(0.0, float(_island_growth_spin.value)) if _island_growth_spin != null else island_growth_per_eruption
	var growth_base = maxf(0.2, lava_yield * (0.7 + float(volcano.get("activity", 0.5))))

	var column_by_tile: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_by_tile.is_empty():
		for i in range(columns.size()):
			var column_variant = columns[i]
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			column_by_tile["%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]] = i

	var affected_chunks: Dictionary = {}
	for dz in range(-radius - 1, radius + 2):
		for dx in range(-radius - 1, radius + 2):
			var tx = vx + dx
			var tz = vz + dz
			if tx < 0 or tz < 0 or tx >= int(_world_snapshot.get("width", 0)) or tz >= int(_world_snapshot.get("height", 0)):
				continue
			var dist = sqrt(float(dx * dx + dz * dz))
			if dist > float(radius) + 1.0:
				continue
			var falloff = clampf(1.0 - dist / (float(radius) + 1.0), 0.0, 1.0)
			var growth = int(round(growth_base * falloff * 2.2))
			if growth <= 0:
				continue
			var tile_id = "%d:%d" % [tx, tz]
			if not column_by_tile.has(tile_id):
				continue
			affected_chunks["%d:%d" % [int(floor(float(tx) / float(chunk_size))), int(floor(float(tz) / float(chunk_size)))]] = true
			var col_idx = int(column_by_tile[tile_id])
			var col = columns[col_idx] as Dictionary
			var surface_y = int(col.get("surface_y", sea_level))
			var next_surface = clampi(surface_y + growth, 1, world_height - 2)
			col["surface_y"] = next_surface
			col["top_block"] = "basalt" if falloff > 0.34 else "obsidian"
			col["subsoil_block"] = "basalt"
			columns[col_idx] = col
			var tile = tile_index.get(tile_id, {})
			if tile is Dictionary:
				var row = tile as Dictionary
				row["elevation"] = clampf(float(next_surface) / float(maxi(1, world_height - 1)), 0.0, 1.0)
				row["geothermal_activity"] = clampf(float(row.get("geothermal_activity", 0.0)) + 0.06 + falloff * 0.12, 0.0, 1.0)
				row["temperature"] = clampf(float(row.get("temperature", 0.0)) + 0.03 + falloff * 0.08, 0.0, 1.0)
				row["water_table_depth"] = maxf(0.0, float(row.get("water_table_depth", 8.0)) + float(growth) * 0.35 - falloff * 1.3)
				row["hydraulic_pressure"] = clampf(float(row.get("hydraulic_pressure", 0.0)) + falloff * 0.08, 0.0, 1.0)
				row["groundwater_recharge"] = clampf(float(row.get("groundwater_recharge", 0.0)) + falloff * 0.03, 0.0, 1.0)
				row["biome"] = "highland" if next_surface > sea_level + 8 else String(row.get("biome", "plains"))
				tile_index[tile_id] = row
			changed.append(tile_id)

	for i in range(tiles.size()):
		var tile_variant = tiles[i]
		if not (tile_variant is Dictionary):
			continue
		var tile = tile_variant as Dictionary
		var tile_id = String(tile.get("tile_id", ""))
		if tile_id == "" or not tile_index.has(tile_id):
			continue
		tiles[i] = (tile_index[tile_id] as Dictionary).duplicate(true)

	var chunk_rows_by_chunk: Dictionary = voxel_world.get("block_rows_by_chunk", {})
	_rebuild_chunk_rows_from_columns(columns, chunk_rows_by_chunk, chunk_size, sea_level, affected_chunks.keys())
	var block_rows: Array = []
	var counts: Dictionary = {}
	var keys = chunk_rows_by_chunk.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var rows_variant = chunk_rows_by_chunk.get(key_variant, [])
		if not (rows_variant is Array):
			continue
		var rows = rows_variant as Array
		block_rows.append_array(rows)
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var block_type = String(row.get("type", "air"))
			counts[block_type] = int(counts.get(block_type, 0)) + 1
	voxel_world["columns"] = columns
	voxel_world["column_index_by_tile"] = column_by_tile
	voxel_world["block_rows"] = block_rows
	voxel_world["block_rows_by_chunk"] = chunk_rows_by_chunk
	voxel_world["block_rows_chunk_size"] = chunk_size
	voxel_world["block_type_counts"] = counts
	voxel_world["surface_y_buffer"] = _pack_surface_y_buffer(columns, int(_world_snapshot.get("width", 0)), int(_world_snapshot.get("height", 0)))
	_world_snapshot["voxel_world"] = voxel_world
	_world_snapshot["tile_index"] = tile_index
	_world_snapshot["tiles"] = tiles
	return changed

func _rebuild_chunk_rows_from_columns(
	columns: Array,
	chunk_rows_by_chunk: Dictionary,
	chunk_size: int,
	sea_level: int,
	target_chunk_keys: Array
) -> void:
	var target: Dictionary = {}
	for key_variant in target_chunk_keys:
		var key = String(key_variant)
		if key == "":
			continue
		target[key] = true
	for key_variant in target.keys():
		var key = String(key_variant)
		var parts = key.split(":")
		if parts.size() != 2:
			continue
		var cx = int(parts[0])
		var cz = int(parts[1])
		var rows: Array = []
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x = int(column.get("x", 0))
			var z = int(column.get("z", 0))
			if int(floor(float(x) / float(chunk_size))) != cx or int(floor(float(z) / float(chunk_size))) != cz:
				continue
			var surface_y = int(column.get("surface_y", sea_level))
			var top_block = String(column.get("top_block", "stone"))
			var subsoil = String(column.get("subsoil_block", "stone"))
			for y in range(surface_y + 1):
				var block_type = "stone"
				if y == surface_y:
					block_type = top_block
				elif y >= surface_y - 2:
					block_type = subsoil
				rows.append({"x": x, "y": y, "z": z, "type": block_type})
			if surface_y < sea_level:
				for wy in range(surface_y + 1, sea_level + 1):
					rows.append({"x": x, "y": wy, "z": z, "type": "water"})
			chunk_rows_by_chunk[key] = rows

func _pack_surface_y_buffer(columns: Array, width: int, height: int) -> PackedInt32Array:
	var packed := PackedInt32Array()
	if width <= 0 or height <= 0:
		return packed
	packed.resize(width * height)
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var x = int(column.get("x", 0))
		var z = int(column.get("z", 0))
		if x < 0 or x >= width or z < 0 or z >= height:
			continue
		packed[z * width + x] = int(column.get("surface_y", 0))
	return packed

func _ensure_lava_root() -> void:
	if _lava_root != null and is_instance_valid(_lava_root):
		return
	_lava_root = Node3D.new()
	_lava_root.name = "LavaFXRoot"
	add_child(_lava_root)
	_lava_pool_cursor = 0

func _clear_lava_fx() -> void:
	_lava_pool_cursor = 0
	for fx_variant in _lava_fx:
		if not (fx_variant is Dictionary):
			continue
		var fx = fx_variant as Dictionary
		fx["ttl"] = 0.0
		var node = fx.get("node", null)
		if node is Node3D and is_instance_valid(node):
			(node as Node3D).visible = false
	if _lava_root != null and is_instance_valid(_lava_root):
		for child in _lava_root.get_children():
			child.queue_free()
	_lava_fx.clear()

func _ensure_lava_pool() -> void:
	_ensure_lava_root()
	var pool_size = maxi(4, max_active_lava_fx)
	if _lava_fx.size() >= pool_size:
		return
	for _i in range(_lava_fx.size(), pool_size):
		var root := Node3D.new()
		root.visible = false
		_lava_root.add_child(root)
		var mesh := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.7
		disc.bottom_radius = 0.95
		disc.height = 0.28
		mesh.mesh = disc
		var lava_mat := ShaderMaterial.new()
		lava_mat.shader = LavaSurfaceShader
		mesh.material_override = lava_mat
		root.add_child(mesh)
		var particles := GPUParticles3D.new()
		particles.amount = 84
		particles.lifetime = 1.4
		particles.preprocess = 0.4
		particles.one_shot = true
		particles.explosiveness = 0.78
		particles.randomness = 0.45
		particles.draw_pass_1 = SphereMesh.new()
		var process := ParticleProcessMaterial.new()
		process.direction = Vector3(0.0, 1.0, 0.0)
		process.initial_velocity_min = 2.3
		process.initial_velocity_max = 5.8
		process.gravity = Vector3(0.0, -8.5, 0.0)
		process.scale_min = 0.08
		process.scale_max = 0.22
		process.color = Color(1.0, 0.38, 0.1, 1.0)
		particles.process_material = process
		root.add_child(particles)
		_lava_fx.append({
			"node": root,
			"material": lava_mat,
			"particles": particles,
			"ttl": 0.0,
		})

func _spawn_lava_plume(volcano: Dictionary) -> void:
	_ensure_lava_pool()
	if _lava_fx.is_empty():
		return
	var pool_size = _lava_fx.size()
	var fx_idx = _lava_pool_cursor % pool_size
	_lava_pool_cursor = (_lava_pool_cursor + 1) % pool_size
	var fx = _lava_fx[fx_idx] as Dictionary
	var vx = float(volcano.get("x", 0)) + 0.5
	var vz = float(volcano.get("y", 0)) + 0.5
	var tile_id = "%d:%d" % [int(volcano.get("x", 0)), int(volcano.get("y", 0))]
	var height = _surface_height_for_tile(tile_id) + 1.1
	var root = fx.get("node", null)
	if not (root is Node3D) or not is_instance_valid(root):
		return
	var root_node = root as Node3D
	root_node.name = "LavaFX_%s" % tile_id.replace(":", "_")
	root_node.visible = true
	root_node.position = Vector3(vx, height, vz)
	var lava_mat = fx.get("material", null)
	if lava_mat is ShaderMaterial:
		var smat := lava_mat as ShaderMaterial
		smat.set_shader_parameter("flow_speed", 1.6 + float(volcano.get("activity", 0.5)) * 2.2)
		smat.set_shader_parameter("pulse_strength", 1.0 + float(volcano.get("activity", 0.5)))
		smat.set_shader_parameter("cooling", 0.0)
	var particles = fx.get("particles", null)
	if particles is GPUParticles3D:
		var p = particles as GPUParticles3D
		p.emitting = false
		p.restart()
		p.emitting = true
	fx["ttl"] = 4.0
	_lava_fx[fx_idx] = fx

func _update_lava_fx(delta: float) -> void:
	if _lava_fx.is_empty():
		return
	for i in range(_lava_fx.size()):
		var fx_variant = _lava_fx[i]
		if not (fx_variant is Dictionary):
			continue
		var fx = fx_variant as Dictionary
		var ttl = float(fx.get("ttl", 0.0)) - delta
		var node = fx.get("node", null)
		var material = fx.get("material", null)
		if material is ShaderMaterial:
			var cool = clampf(1.0 - ttl / 4.0, 0.0, 1.0)
			(material as ShaderMaterial).set_shader_parameter("cooling", cool)
		if ttl <= 0.0:
			if node is Node3D and is_instance_valid(node):
				(node as Node3D).visible = false
			fx["ttl"] = 0.0
			_lava_fx[i] = fx
			continue
		fx["ttl"] = ttl
		_lava_fx[i] = fx

func _surface_height_for_tile(tile_id: String) -> float:
	var voxel_world: Dictionary = _world_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var column_index: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_index.has(tile_id):
		var idx = int(column_index.get(tile_id, -1))
		if idx >= 0 and idx < columns.size() and columns[idx] is Dictionary:
			return float((columns[idx] as Dictionary).get("surface_y", 0))
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var cid = "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]
		if cid == tile_id:
			return float(column.get("surface_y", 0))
	return float(voxel_world.get("sea_level", 1))

func _record_timelapse_snapshot(tick: int) -> void:
	var snapshot_resource = VoxelTimelapseSnapshotResourceScript.new()
	snapshot_resource.tick = tick
	snapshot_resource.time_of_day = _time_of_day
	snapshot_resource.simulated_year = _year_at_tick(tick)
	snapshot_resource.simulated_seconds = _simulated_seconds
	snapshot_resource.world = _world_snapshot.duplicate(true)
	snapshot_resource.hydrology = _hydrology_snapshot.duplicate(true)
	snapshot_resource.weather = _weather_snapshot.duplicate(true)
	snapshot_resource.erosion = _erosion_snapshot.duplicate(true)
	snapshot_resource.solar = _solar_snapshot.duplicate(true)
	_timelapse_snapshots[tick] = snapshot_resource
	var keys = _timelapse_snapshots.keys()
	var max_snapshots = 192 if _ultra_perf_mode else 480
	if keys.size() <= max_snapshots:
		return
	keys.sort()
	var drop_count = keys.size() - max_snapshots
	for i in range(drop_count):
		_timelapse_snapshots.erase(keys[i])

func _render_flow_overlay(world: Dictionary, config) -> void:
	_ensure_flow_overlay_multimesh()
	if _flow_overlay_mm_instance == null or _flow_overlay_mm_instance.multimesh == null:
		return
	var mm := _flow_overlay_mm_instance.multimesh
	if not _show_flow_checkbox.button_pressed:
		mm.instance_count = 0
		return
	var flow_map: Dictionary = world.get("flow_map", {})
	if flow_map.is_empty():
		mm.instance_count = 0
		return
	var width = int(flow_map.get("width", int(world.get("width", 0))))
	var height = int(flow_map.get("height", int(world.get("height", 0))))
	if width <= 0 or height <= 0:
		mm.instance_count = 0
		return
	var stride = maxi(1, int(_flow_stride_spin.value))
	var grid_w = maxi(1, int(ceil(float(width) / float(stride))))
	var grid_h = maxi(1, int(ceil(float(height) / float(stride))))
	var instance_count = grid_w * grid_h
	if _flow_overlay_grid_w != grid_w or _flow_overlay_grid_h != grid_h or _flow_overlay_stride != stride:
		_flow_overlay_grid_w = grid_w
		_flow_overlay_grid_h = grid_h
		_flow_overlay_stride = stride
		_flow_overlay_instance_count = instance_count
		mm.instance_count = instance_count
		for i in range(instance_count):
			mm.set_instance_transform(i, Transform3D.IDENTITY)
	else:
		mm.instance_count = instance_count
	if _flow_overlay_dirty:
		_update_flow_overlay_textures(world, flow_map, config)
		_flow_overlay_dirty = false
	if _flow_overlay_material != null:
		_flow_overlay_material.set_shader_parameter("flow_texture", _flow_overlay_dir_texture)
		_flow_overlay_material.set_shader_parameter("height_texture", _flow_overlay_height_texture)
		_flow_overlay_material.set_shader_parameter("grid_width", grid_w)
		_flow_overlay_material.set_shader_parameter("grid_height", grid_h)
		_flow_overlay_material.set_shader_parameter("sample_stride", stride)
		_flow_overlay_material.set_shader_parameter("strength_threshold", clampf(float(_flow_strength_threshold_spin.value), 0.0, 1.0))
		_flow_overlay_material.set_shader_parameter("sea_level", float(config.voxel_sea_level))
		_flow_overlay_material.set_shader_parameter("time_sec", _simulated_seconds)
		_flow_overlay_material.set_shader_parameter("cell_size", 1.0)

func _ensure_flow_overlay_multimesh() -> void:
	if _flow_overlay_root == null:
		return
	if _flow_overlay_mesh == null:
		_flow_overlay_mesh = BoxMesh.new()
		_flow_overlay_mesh.size = Vector3(0.08, 0.06, 1.0)
	if _flow_overlay_material == null:
		_flow_overlay_material = ShaderMaterial.new()
		_flow_overlay_material.shader = FlowFieldInstancedShader
	if _flow_overlay_mm_instance != null and is_instance_valid(_flow_overlay_mm_instance):
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.mesh = _flow_overlay_mesh
	mm.instance_count = 0
	_flow_overlay_mm_instance = MultiMeshInstance3D.new()
	_flow_overlay_mm_instance.multimesh = mm
	_flow_overlay_mm_instance.material_override = _flow_overlay_material
	_flow_overlay_mm_instance.name = "FlowOverlayMultiMesh"
	_flow_overlay_root.add_child(_flow_overlay_mm_instance)

func _update_flow_overlay_textures(world: Dictionary, flow_map: Dictionary, config) -> void:
	var width = int(flow_map.get("width", int(world.get("width", 0))))
	var height = int(flow_map.get("height", int(world.get("height", 0))))
	if width <= 0 or height <= 0:
		return
	if _flow_overlay_dir_image == null or _flow_overlay_dir_image.get_width() != width or _flow_overlay_dir_image.get_height() != height:
		_flow_overlay_dir_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
		_flow_overlay_height_image = Image.create(width, height, false, Image.FORMAT_RF)
		_flow_overlay_dir_texture = ImageTexture.create_from_image(_flow_overlay_dir_image)
		_flow_overlay_height_texture = ImageTexture.create_from_image(_flow_overlay_height_image)
	_flow_overlay_dir_image.fill(Color(0.5, 0.5, 0.0, 1.0))
	_flow_overlay_height_image.fill(Color(float(config.voxel_sea_level), 0.0, 0.0, 1.0))
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var surface_buf: PackedInt32Array = voxel_world.get("surface_y_buffer", PackedInt32Array())
	if surface_buf.size() == width * height:
		for z in range(height):
			for x in range(width):
				var flat = z * width + x
				var h = float(surface_buf[flat])
				_flow_overlay_height_image.set_pixel(x, z, Color(h, 0.0, 0.0, 1.0))
	else:
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x = int(column.get("x", 0))
			var z = int(column.get("z", 0))
			if x < 0 or x >= width or z < 0 or z >= height:
				continue
			var h = float(int(column.get("surface_y", config.voxel_sea_level)))
			_flow_overlay_height_image.set_pixel(x, z, Color(h, 0.0, 0.0, 1.0))
	var rows: Array = flow_map.get("rows", [])
	var packed_dx: PackedFloat32Array = flow_map.get("flow_dir_x_buffer", PackedFloat32Array())
	var packed_dy: PackedFloat32Array = flow_map.get("flow_dir_y_buffer", PackedFloat32Array())
	var packed_strength: PackedFloat32Array = flow_map.get("flow_strength_buffer", PackedFloat32Array())
	if packed_dx.size() == width * height and packed_dy.size() == width * height and packed_strength.size() == width * height:
		for z in range(height):
			for x in range(width):
				var flat = z * width + x
				var dir = Vector2(float(packed_dx[flat]), float(packed_dy[flat]))
				var strength = clampf(float(packed_strength[flat]), 0.0, 1.0)
				if dir.length_squared() > 0.00001:
					dir = dir.normalized()
				_flow_overlay_dir_image.set_pixel(x, z, Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, strength, 1.0))
	else:
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var x = int(row.get("x", 0))
			var z = int(row.get("y", 0))
			if x < 0 or x >= width or z < 0 or z >= height:
				continue
			var dir = Vector2(float(row.get("dir_x", 0.0)), float(row.get("dir_y", 0.0)))
			var strength = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
			if dir.length_squared() > 0.00001:
				dir = dir.normalized()
			_flow_overlay_dir_image.set_pixel(x, z, Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, strength, 1.0))
	if _flow_overlay_dir_texture != null:
		_flow_overlay_dir_texture.update(_flow_overlay_dir_image)
	if _flow_overlay_height_texture != null:
		_flow_overlay_height_texture.update(_flow_overlay_height_image)

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
	var avg_rain = float(_weather_snapshot.get("avg_rain_intensity", 0.0))
	var avg_fog = float(_weather_snapshot.get("avg_fog_intensity", 0.0))
	var avg_sun = float(_solar_snapshot.get("avg_insolation", 0.0))
	var avg_uv = float(_solar_snapshot.get("avg_uv_index", 0.0))
	var geology: Dictionary = world.get("geology", {})
	var volcanoes = int((geology.get("volcanic_features", []) as Array).size())
	var springs: Dictionary = world.get("springs", {})
	var spring_count = int((springs.get("all", []) as Array).size())
	_stats_label.text = "seed=%d | mode=%s | blocks=%d | water_tiles=%d | max_flow=%0.2f | rain=%0.2f | fog=%0.2f | sun=%0.2f | uv=%0.2f | volcanoes=%d | springs=%d | slides=%d | tod=%0.2f" % [
		seed,
		_sim_backend_mode,
		int((voxel_world.get("block_rows", []) as Array).size()),
		int(water_tiles.size()),
		max_flow,
		avg_rain,
		avg_fog,
		avg_sun,
		avg_uv,
		volcanoes,
		spring_count,
		_landslide_count,
		_time_of_day
	]
	var year = _year_at_tick(_sim_tick)
	_stats_label.text += " | year=%0.1f | sim_t=%s" % [year, _format_duration_hms(_simulated_seconds)]

func _current_worldgen_config_for_tick(tick: int) -> Resource:
	var config = WorldGenConfigResourceScript.new()
	config.map_width = int(_width_spin.value)
	config.map_height = int(_depth_spin.value)
	config.voxel_world_height = int(_world_height_spin.value)
	config.voxel_sea_level = int(_sea_level_spin.value)
	config.voxel_surface_height_base = int(_surface_base_spin.value)
	config.voxel_surface_height_range = int(_surface_range_spin.value)
	config.voxel_noise_frequency = float(_noise_frequency_spin.value)
	config.voxel_noise_octaves = int(_noise_octaves_spin.value)
	config.voxel_noise_lacunarity = float(_noise_lacunarity_spin.value)
	config.voxel_noise_gain = float(_noise_gain_spin.value)
	config.voxel_surface_smoothing = float(_surface_smoothing_spin.value)
	config.cave_noise_threshold = float(_cave_threshold_spin.value)
	config.voxel_surface_height_base = clampi(config.voxel_surface_height_base, 2, maxi(3, config.voxel_world_height - 2))
	_apply_year_progression(config, tick)
	return config

func _year_at_tick(tick: int) -> float:
	return float(_start_year_spin.value) + float(tick) * float(_years_per_tick_spin.value)

func _apply_year_progression(config: Resource, tick: int) -> void:
	if config == null:
		return
	var year = _year_at_tick(tick)
	if _world_progression_profile != null and _world_progression_profile.has_method("apply_to_worldgen_config"):
		_world_progression_profile.call("apply_to_worldgen_config", config, year)
		return
	config.simulated_year = year
	config.progression_profile_id = "year_%d" % int(round(year))
	config.progression_temperature_shift = 0.0
	config.progression_moisture_shift = 0.0
	config.progression_food_density_multiplier = 1.0
	config.progression_wood_density_multiplier = 1.0
	config.progression_stone_density_multiplier = 1.0

func _current_worldgen_config() -> Resource:
	return _current_worldgen_config_for_tick(_sim_tick)

func _legacy_stats_placeholder() -> void:
	# Removed by refactor; kept as no-op to avoid accidental merge conflicts.
	pass

func _update_day_night(delta: float) -> void:
	if _sun_light == null:
		return
	_time_of_day = _atmosphere_cycle.advance_time(_time_of_day, delta, day_night_cycle_enabled, day_length_seconds)
	_atmosphere_cycle.apply_to_light_and_environment(
		_time_of_day,
		_sun_light,
		_world_environment,
		0.06,
		1.38,
		0.04,
		1.15,
		0.02,
		1.0,
		0.05,
		1.0
	)
	_apply_demo_fog()

func _apply_demo_fog() -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var env: Environment = _world_environment.environment
	var fog_on = _enable_fog_checkbox.button_pressed
	env.volumetric_fog_enabled = fog_on
	if fog_on:
		env.volumetric_fog_density = 0.02
		env.volumetric_fog_albedo = Color(0.82, 0.87, 0.93, 1.0)
		env.volumetric_fog_emission_energy = 0.02

func _restore_to_tick(target_tick: int) -> void:
	if _timelapse_snapshots.is_empty():
		return
	_stop_async_workers()
	_clear_lava_fx()
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_pending_terrain_changed_tiles.clear()
	_flow_overlay_accum = flow_overlay_refresh_seconds
	_terrain_apply_accum = terrain_apply_interval_seconds
	_flow_overlay_dirty = true
	var keys = _timelapse_snapshots.keys()
	keys.sort()
	var selected_tick = -1
	for key_variant in keys:
		var key = int(key_variant)
		if key <= target_tick:
			selected_tick = key
		else:
			break
	if selected_tick < 0:
		selected_tick = int(keys[0])
	var snapshot_variant = _timelapse_snapshots.get(selected_tick, null)
	if snapshot_variant == null:
		return
	var snapshot_dict: Dictionary = {}
	if snapshot_variant is Resource and snapshot_variant.has_method("to_dict"):
		snapshot_dict = snapshot_variant.to_dict()
	elif snapshot_variant is Dictionary:
		snapshot_dict = (snapshot_variant as Dictionary).duplicate(true)
	if snapshot_dict.is_empty():
		return
	_sim_tick = int(snapshot_dict.get("tick", selected_tick))
	_simulated_seconds = maxf(0.0, float(snapshot_dict.get("simulated_seconds", float(_sim_tick) / maxf(0.1, weather_ticks_per_second))))
	_time_of_day = clampf(float(snapshot_dict.get("time_of_day", _time_of_day)), 0.0, 1.0)
	_world_snapshot = snapshot_dict.get("world", {}).duplicate(true)
	_hydrology_snapshot = snapshot_dict.get("hydrology", {}).duplicate(true)
	_weather_snapshot = snapshot_dict.get("weather", {}).duplicate(true)
	_erosion_snapshot = snapshot_dict.get("erosion", {}).duplicate(true)
	_solar_snapshot = snapshot_dict.get("solar", {}).duplicate(true)
	_solar_seed = int(_solar_snapshot.get("seed", 0))
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, int(_weather_snapshot.get("seed", 0)))
	_weather.import_snapshot(_weather_snapshot)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, int(_erosion_snapshot.get("seed", 0)))
	_erosion.import_snapshot(_erosion_snapshot)
	_solar.configure_environment(_world_snapshot, _solar_seed)
	_solar.import_snapshot(_solar_snapshot)
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	if _environment_controller.has_method("apply_generation_data"):
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
	if _show_flow_checkbox.button_pressed:
		_render_flow_overlay(_world_snapshot, _current_worldgen_config())
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	if _environment_controller.has_method("set_solar_state"):
		_environment_controller.set_solar_state(_solar_snapshot)
	_sync_living_world_features(true)
	_apply_water_shader_controls()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))

func _refresh_hud() -> void:
	if _simulation_hud == null:
		return
	var mode = "playing" if _is_playing else "paused"
	var year = _year_at_tick(_sim_tick)
	_simulation_hud.set_status_text("Year %.1f | T+%s | Tick %d | Branch %s | %s x%d" % [year, _format_duration_hms(_simulated_seconds), _sim_tick, _active_branch_id, mode, _ticks_per_frame])
	var avg_rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_cloud = clampf(float(_weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var avg_fog = clampf(float(_weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
	var avg_sun = clampf(float(_solar_snapshot.get("avg_insolation", 0.0)), 0.0, 1.0)
	var avg_uv = clampf(float(_solar_snapshot.get("avg_uv_index", 0.0)), 0.0, 2.0)
	var lunar = _current_lunar_debug()
	var details = "Rain: %.2f | Cloud: %.2f | Fog: %.2f | Sun: %.2f | UV: %.2f | Landslides: %d | Moon: %.0f%% %s | Tide x%.2f" % [
		avg_rain,
		avg_cloud,
		avg_fog,
		avg_sun,
		avg_uv,
		_landslide_count,
		float(lunar.get("phase_percent", 0.0)),
		String(lunar.get("state", "Neap")),
		float(lunar.get("multiplier", 1.0)),
	]
	if _simulation_hud.has_method("set_details_text"):
		_simulation_hud.set_details_text("%s | Backend: %s | OceanQ: %s" % [details, _sim_backend_mode, _ocean_quality_option.get_item_text(_ocean_quality_option.selected)])
	_update_perf_compare_label()

func _update_perf_compare_label() -> void:
	if _perf_compare_label == null:
		return
	var modes = ["cpu", "gpu_hybrid", "gpu_aggressive", "ultra"]
	var lines: Array[String] = []
	for mode in modes:
		var row = (_perf_ewma_by_mode.get(mode, {}) as Dictionary)
		var marker = "*" if mode == _sim_backend_mode else " "
		lines.append("%s %s: tick %.2fms | w %.2f e %.2f s %.2f v %.2f t %.2f" % [
			marker,
			mode,
			float(row.get("tick_total_ms", 0.0)),
			float(row.get("weather_ms", 0.0)),
			float(row.get("erosion_ms", 0.0)),
			float(row.get("solar_ms", 0.0)),
			float(row.get("volcanic_ms", 0.0)),
			float(row.get("terrain_apply_ms", 0.0)),
		])
	var weather_bench_text = "weather bench cpu %.2fms gpu %.2fms" % [_weather_bench_cpu_ms, _weather_bench_gpu_ms] if _weather_bench_cpu_ms >= 0.0 else "weather bench pending"
	var solar_bench_text = "solar bench cpu %.2fms gpu %.2fms" % [_solar_bench_cpu_ms, _solar_bench_gpu_ms] if _solar_bench_cpu_ms >= 0.0 else "solar bench pending"
	var budget_text = "budget %.1fms debt %.2f credit %.2f" % [sim_budget_ms_per_frame, _sim_budget_debt_ms, _sim_budget_credit_ms]
	lines.append(weather_bench_text)
	lines.append(solar_bench_text)
	lines.append(budget_text)
	_perf_compare_label.text = "\n".join(lines)

func _run_gpu_benchmarks() -> void:
	_run_weather_compute_benchmark()
	_run_solar_compute_benchmark()

func _run_weather_compute_benchmark() -> void:
	if _weather == null or not _weather.has_method("benchmark_cpu_vs_compute"):
		return
	var result = _weather.call("benchmark_cpu_vs_compute", 12, 0.5)
	if not (result is Dictionary):
		return
	var row = result as Dictionary
	if not bool(row.get("ok", false)):
		return
	_weather_bench_cpu_ms = float(row.get("cpu_ms_per_step", -1.0))
	_weather_bench_gpu_ms = float(row.get("gpu_ms_per_step", -1.0))

func _run_solar_compute_benchmark() -> void:
	if _solar == null or not _solar.has_method("benchmark_cpu_vs_compute"):
		return
	var result = _solar.call("benchmark_cpu_vs_compute", _world_snapshot, _weather_snapshot, 12, 0.5)
	if not (result is Dictionary):
		return
	var row = result as Dictionary
	if not bool(row.get("ok", false)):
		return
	_solar_bench_cpu_ms = float(row.get("cpu_ms_per_step", -1.0))
	_solar_bench_gpu_ms = float(row.get("gpu_ms_per_step", -1.0))

func _current_lunar_debug() -> Dictionary:
	var cycle_days = maxf(1.0, float(_moon_cycle_days_spin.value)) if _moon_cycle_days_spin != null else lunar_cycle_days
	var lunar_period_seconds = maxf(1.0, cycle_days * maxf(10.0, day_length_seconds))
	var moon_phase = fposmod(_simulated_seconds, lunar_period_seconds) / lunar_period_seconds
	var spring_neap = absf(cos(moon_phase * TAU))
	return {
		"phase_percent": moon_phase * 100.0,
		"state": "Spring" if spring_neap > 0.72 else "Neap",
		"multiplier": lerpf(0.25, 1.0, spring_neap),
	}

func _perf_record(metric: String, ms: float) -> void:
	var mode = _sim_backend_mode
	if not _perf_ewma_by_mode.has(mode):
		_perf_ewma_by_mode[mode] = {}
	var row = _perf_ewma_by_mode[mode] as Dictionary
	var prev = float(row.get(metric, ms))
	var alpha = 0.14
	row[metric] = lerpf(prev, ms, alpha)
	_perf_ewma_by_mode[mode] = row

func _exit_tree() -> void:
	_stop_async_workers()

func _stop_async_workers() -> void:
	_stop_weather_worker()
	_stop_erosion_worker()
	_stop_solar_worker()

func _stop_weather_worker() -> void:
	if _weather_thread != null and _weather_thread.is_alive():
		_weather_thread.wait_to_finish()
	_weather_thread = null
	_weather_thread_busy = false
	_weather_thread_mutex.lock()
	_weather_thread_result = {}
	_weather_thread_mutex.unlock()

func _stop_erosion_worker() -> void:
	if _erosion_thread != null and _erosion_thread.is_alive():
		_erosion_thread.wait_to_finish()
	_erosion_thread = null
	_erosion_thread_busy = false
	_erosion_thread_mutex.lock()
	_erosion_thread_result = {}
	_erosion_thread_mutex.unlock()

func _start_erosion_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _erosion_thread_busy:
		return
	var world_copy = _world_snapshot.duplicate(true)
	var hydro_copy = _hydrology_snapshot.duplicate(true)
	var weather_copy = _weather_snapshot.duplicate(true)
	if _erosion_thread == null:
		_erosion_thread = Thread.new()
	_erosion_thread_busy = true
	var callable = Callable(self, "_erosion_thread_entry").bind(tick, delta, world_copy, hydro_copy, weather_copy, local_activity.duplicate(true))
	_erosion_thread.start(callable)

func _erosion_thread_entry(tick: int, delta: float, world_copy: Dictionary, hydro_copy: Dictionary, weather_copy: Dictionary, local_activity: Dictionary) -> void:
	var result = _erosion.step(tick, delta, world_copy, hydro_copy, weather_copy, local_activity)
	_erosion_thread_mutex.lock()
	_erosion_thread_result = result
	_erosion_thread_mutex.unlock()

func _consume_erosion_worker_result() -> Dictionary:
	if not _erosion_thread_busy:
		return {}
	if _erosion_thread != null and _erosion_thread.is_alive():
		return {}
	if _erosion_thread != null:
		_erosion_thread.wait_to_finish()
	_erosion_thread_busy = false
	_erosion_thread_mutex.lock()
	var result = _erosion_thread_result.duplicate(true)
	_erosion_thread_result = {}
	_erosion_thread_mutex.unlock()
	return result

func _stop_solar_worker() -> void:
	if _solar_thread != null and _solar_thread.is_alive():
		_solar_thread.wait_to_finish()
	_solar_thread = null
	_solar_thread_busy = false
	_solar_thread_mutex.lock()
	_solar_thread_result = {}
	_solar_thread_mutex.unlock()

func _start_weather_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _weather_thread_busy:
		return
	if _weather_thread == null:
		_weather_thread = Thread.new()
	_weather_thread_busy = true
	var callable = Callable(self, "_weather_thread_entry").bind(tick, delta, local_activity.duplicate(true))
	_weather_thread.start(callable)

func _weather_thread_entry(tick: int, delta: float, local_activity: Dictionary) -> void:
	var start_us = Time.get_ticks_usec()
	var snapshot = _weather.step(tick, delta, local_activity)
	var elapsed_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_weather_thread_mutex.lock()
	_weather_thread_result = {"snapshot": snapshot, "step_ms": elapsed_ms}
	_weather_thread_mutex.unlock()

func _consume_weather_worker_result() -> Dictionary:
	if not _weather_thread_busy:
		return {}
	if _weather_thread != null and _weather_thread.is_alive():
		return {}
	if _weather_thread != null:
		_weather_thread.wait_to_finish()
	_weather_thread_busy = false
	_weather_thread_mutex.lock()
	var result = _weather_thread_result.duplicate(true)
	_weather_thread_result = {}
	_weather_thread_mutex.unlock()
	return result

func _start_solar_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _solar_thread_busy:
		return
	var world_copy = _world_snapshot.duplicate(true)
	var weather_copy = _weather_snapshot.duplicate(true)
	if _solar_thread == null:
		_solar_thread = Thread.new()
	_solar_thread_busy = true
	var callable = Callable(self, "_solar_thread_entry").bind(tick, delta, world_copy, weather_copy, local_activity.duplicate(true))
	_solar_thread.start(callable)

func _solar_thread_entry(tick: int, delta: float, world_copy: Dictionary, weather_copy: Dictionary, local_activity: Dictionary) -> void:
	var start_us = Time.get_ticks_usec()
	var snapshot = _solar.step(tick, delta, world_copy, weather_copy, local_activity)
	var elapsed_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_solar_thread_mutex.lock()
	_solar_thread_result = {"snapshot": snapshot, "step_ms": elapsed_ms}
	_solar_thread_mutex.unlock()

func _consume_solar_worker_result() -> Dictionary:
	if not _solar_thread_busy:
		return {}
	if _solar_thread != null and _solar_thread.is_alive():
		return {}
	if _solar_thread != null:
		_solar_thread.wait_to_finish()
	_solar_thread_busy = false
	_solar_thread_mutex.lock()
	var result = _solar_thread_result.duplicate(true)
	_solar_thread_result = {}
	_solar_thread_mutex.unlock()
	return result

func _build_local_activity_field() -> Dictionary:
	var next: Dictionary = {}
	for tile_variant in _local_activity_by_tile.keys():
		var tile_id = String(tile_variant)
		var decayed = clampf(float(_local_activity_by_tile.get(tile_id, 0.0)) * 0.9, 0.0, 1.0)
		if decayed > 0.01:
			next[tile_id] = decayed
	for tile_variant in _pending_terrain_changed_tiles.keys():
		var tile_id = String(tile_variant)
		next[tile_id] = maxf(float(next.get(tile_id, 0.0)), 0.75)
	var erosion_changed: Array = _erosion_snapshot.get("changed_tiles", [])
	for tile_variant in erosion_changed:
		var tile_id = String(tile_variant)
		next[tile_id] = maxf(float(next.get(tile_id, 0.0)), 0.6)
	var geology: Dictionary = _world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		var vx = int(volcano.get("x", 0))
		var vz = int(volcano.get("y", 0))
		var radius = maxi(1, int(volcano.get("radius", 2)))
		var activity = clampf(float(volcano.get("activity", 0.5)), 0.0, 1.0)
		for dz in range(-radius - 1, radius + 2):
			for dx in range(-radius - 1, radius + 2):
				var tx = vx + dx
				var tz = vz + dz
				if tx < 0 or tz < 0 or tx >= int(_world_snapshot.get("width", 0)) or tz >= int(_world_snapshot.get("height", 0)):
					continue
				var dist = sqrt(float(dx * dx + dz * dz))
				var max_dist = float(radius) + 1.0
				if dist > max_dist:
					continue
				var falloff = clampf(1.0 - dist / max_dist, 0.0, 1.0)
				var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
				var score = clampf(activity * (0.35 + falloff * 0.65), 0.0, 1.0)
				next[tile_id] = maxf(float(next.get(tile_id, 0.0)), score)
	_local_activity_by_tile = next
	return next.duplicate(true)

func _on_hud_play_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 1
	_refresh_hud()

func _on_hud_pause_pressed() -> void:
	_is_playing = false
	_refresh_hud()

func _on_hud_fast_forward_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 4 if _ticks_per_frame == 1 else 1
	_refresh_hud()

func _on_hud_rewind_pressed() -> void:
	_is_playing = false
	_restore_to_tick(maxi(0, _sim_tick - 24))
	_refresh_hud()

func _on_hud_fork_pressed() -> void:
	_fork_index += 1
	_active_branch_id = "branch_%02d" % _fork_index
	_refresh_hud()

func _format_duration_hms(total_seconds: float) -> String:
	var whole = maxi(0, int(floor(total_seconds)))
	var hours = int(whole / 3600)
	var minutes = int((whole % 3600) / 60)
	var seconds = int(whole % 60)
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

func _sync_living_world_features(force_respawn_settlement: bool) -> void:
	var signals = {
		"environment_snapshot": _world_snapshot,
		"water_network_snapshot": _hydrology_snapshot,
		"weather_snapshot": _weather_snapshot,
		"solar_snapshot": _solar_snapshot,
	}
	if _ecology_controller != null and _ecology_controller.has_method("set_environment_signals"):
		_ecology_controller.call("set_environment_signals", signals)
	if force_respawn_settlement and _settlement_controller != null and _settlement_controller.has_method("spawn_initial_settlement"):
		var width = float(_world_snapshot.get("width", 1))
		var depth = float(_world_snapshot.get("height", 1))
		var spawn = {"chosen": {"x": width * 0.5, "y": depth * 0.5}}
		_settlement_controller.call("spawn_initial_settlement", spawn)
	if force_respawn_settlement and _villager_controller != null and _villager_controller.has_method("clear_generated"):
		_villager_controller.call("clear_generated")

func _on_hud_overlays_changed(paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	if _debug_overlay_root == null:
		return
	if _debug_overlay_root.has_method("set_visibility_flags"):
		_debug_overlay_root.call("set_visibility_flags", paths, resources, conflicts, smell, wind, temperature)
