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
const SimulationStateResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SimulationStateResource.gd")
const SimulationScenarioResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/scenarios/SimulationScenarioResource.gd")
const FlowFieldInstancedShader = preload("res://addons/local_agents/scenes/simulation/shaders/FlowFieldInstanced.gdshader")
const LavaSurfaceShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelLavaSurface.gdshader")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")
const SettlementControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/SettlementController.gd")
const VillagerControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/VillagerController.gd")
const CultureControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/CultureController.gd")
const EcologyControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/EcologyController.gd")
const WorldSessionControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/WorldSessionController.gd")
const SimulationLoopControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/SimulationLoopController.gd")
const EnvironmentSystemsControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/EnvironmentSystemsController.gd")
const GeologyControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/GeologyController.gd")
const InteractionControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/InteractionController.gd")
const HudControllerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/HudController.gd")
const TickSchedulerScript = preload("res://addons/local_agents/scenes/simulation/app/controllers/EnvironmentTickScheduler.gd")
const TerrainRendererAdapterScript = preload("res://addons/local_agents/scenes/simulation/app/renderers/TerrainRendererAdapter.gd")
const WaterRendererAdapterScript = preload("res://addons/local_agents/scenes/simulation/app/renderers/WaterRendererAdapter.gd")
const FeatureMarkerRendererScript = preload("res://addons/local_agents/scenes/simulation/app/renderers/FeatureMarkerRenderer.gd")
const OverlayRendererAdapterScript = preload("res://addons/local_agents/scenes/simulation/app/renderers/OverlayRendererAdapter.gd")
const WaterRenderControllerScript = preload("res://addons/local_agents/scenes/simulation/app/render/WaterRenderController.gd")
const CloudRenderControllerScript = preload("res://addons/local_agents/scenes/simulation/app/render/CloudRenderController.gd")
const LightingFxControllerScript = preload("res://addons/local_agents/scenes/simulation/app/render/LightingFxController.gd")
const TerrainQualityControllerScript = preload("res://addons/local_agents/scenes/simulation/app/render/TerrainQualityController.gd")
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
@onready var _ui_canvas: CanvasLayer = $CanvasLayer
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
@export var startup_scenario: Resource

var _session_controller = WorldSessionControllerScript.new()
var _simulation_loop_controller = SimulationLoopControllerScript.new()
var _environment_systems_controller = EnvironmentSystemsControllerScript.new()
var _interaction_controller = InteractionControllerScript.new()
var _geology_controller = GeologyControllerScript.new()
var _hud_controller = HudControllerScript.new()
var _tick_scheduler = TickSchedulerScript.new()
var _terrain_renderer = TerrainRendererAdapterScript.new()
var _water_renderer = WaterRendererAdapterScript.new()
var _feature_marker_renderer = FeatureMarkerRendererScript.new()
var _overlay_renderer = OverlayRendererAdapterScript.new()
var _water_render_controller = WaterRenderControllerScript.new()
var _cloud_render_controller = CloudRenderControllerScript.new()
var _lighting_fx_controller = LightingFxControllerScript.new()
var _terrain_quality_controller = TerrainQualityControllerScript.new()
var _state: LocalAgentsSimulationStateResource = SimulationStateResourceScript.new()

var _world_generator = _environment_systems_controller.world_generator
var _hydrology = _environment_systems_controller.hydrology_system
var _weather = _environment_systems_controller.weather_system
var _erosion = _environment_systems_controller.erosion_system
var _solar = _environment_systems_controller.solar_system
var _camera_controller = _interaction_controller.camera_controller
var _feature_query = _interaction_controller.feature_query
var _volcanic = _geology_controller
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
var _debug_column_visible: bool = true
var _debug_compact_mode: bool = false
var _debug_column_panel: PanelContainer
var _debug_column_body: VBoxContainer
var _debug_column_toggle: Button
var _debug_compact_toggle: Button
var _manual_vent_place_mode: bool = false
var _manual_eruption_active: bool = false
var _manual_selected_vent_tile_id: String = ""
var _manual_place_vent_button: Button
var _manual_erupt_button: Button
var _manual_vent_status_label: Label
var _feature_inspect_label: Label
var _selected_feature: Dictionary = {}
var _feature_select_marker: MeshInstance3D
var _rts_bottom_panel: PanelContainer
var _rts_tabs: TabContainer


func _on_water_shader_control_changed(_value: float) -> void:
	_apply_water_shader_controls()

func _on_lightning_strike_pressed() -> void:
	_lighting_fx_controller.on_lightning_strike_pressed(self)

func _on_terrain_chunk_size_changed(v: float) -> void:
	_terrain_quality_controller.on_terrain_chunk_size_changed(self, v)

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
	_cloud_render_controller.apply_cloud_and_debug_quality(self)

func _apply_ocean_quality_preset() -> void:
	_water_render_controller.apply_ocean_quality_preset(self)

func _apply_sim_backend_mode() -> void:
	_terrain_quality_controller.apply_sim_backend_mode(self)

func _apply_dynamic_quality(delta: float) -> void:
	_terrain_quality_controller.apply_dynamic_quality(self, delta)

func _apply_environment_toggles() -> void:
	_lighting_fx_controller.apply_environment_toggles(self)

func _apply_water_shader_controls() -> void:
	_water_render_controller.apply_water_shader_controls(self)

func _apply_tide_shader_controls(force: bool = false) -> void:
	_water_render_controller.apply_tide_shader_controls(self, force)

func _build_tide_shader_params() -> Dictionary:
	return _water_render_controller.build_tide_shader_params(self)


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
	_interaction_controller.camera_controller.frame_world(world)

func _initialize_camera_orbit() -> void:
	_interaction_controller.camera_controller.initialize_orbit()

func _rebuild_orbit_state_from_camera() -> void:
	pass

func _apply_camera_transform() -> void:
	pass

func _update_camera_keyboard(delta: float) -> void:
	_interaction_controller.process_camera(delta)


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
	_lighting_fx_controller.apply_demo_fog(self)
