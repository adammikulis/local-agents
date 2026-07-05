extends Node3D
class_name LAVoxelWorld

# From-scratch simulation root built entirely in code on the Zylann godot_voxel GDExtension.
# Owns: terrain service, fly camera + voxel viewer, sun + sky, actors root, ecology service,
# HUD, weather, and procedural audio. Wires the spawn palette -> click-to-place, and
# left-click -> select/inspect. (Explicit types only — project rule: no ':=' inferred typing.)

const TerrainServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/terrain/VoxelTerrainService.gd")
const CameraRigScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/VoxelCameraRig.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ecology/EcologyService.gd")
const HudScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/SpawnPaletteHud.gd")
const MeteorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Meteor.gd")
const VolcanoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Volcano.gd")
const LightningScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/LightningStrike.gd")
const EarthquakeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Earthquake.gd")
const FloodScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Flood.gd")
const AudioDirectorScript: GDScript = preload("res://addons/local_agents/audio/AudioDirector.gd")
const WeatherScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/WeatherSystem.gd")
const MaterialFieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField.gd")
const OceanPlaneScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/OceanPlane.gd")
const MaterialField3DScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const CloudLayerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/CloudLayer.gd")
const DebugPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugPanel.gd")
const DebugOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugOverlay.gd")

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6, "vulture": 5}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7

var _terrain                # LAVoxelTerrainService
var _camera: Camera3D
var _ecology: Node          # LAEcologyService
var _hud: CanvasLayer       # LASpawnPaletteHud
var _debug_panel: CanvasLayer   # LADebugPanel (left-docked debug menu)
var _debug_overlay: Node3D      # LADebugOverlay (world-space highlight/path/wind gizmos)
var _actors_root: Node3D
var _selection_ring: MeshInstance3D
var _selected: Node = null
var _weather: Node = null   # LAWeatherSystem (visual rain/wind for now; being made emergent)
var _material: Node = null   # LAMaterialField — the ONE substrate: terrain-coupled water + heat/air
var _ocean: Node = null      # LAOceanPlane — the calm sea drawn as one GPU plane (CA meshes only waves)
var _clouds: Node = null     # LACloudLayer rendering the field's cloud density (aloft)
var _fog: Node = null        # LACloudLayer rendering the field's fog density (ground-hugging)

# --- Day/night cycle. VoxelWorld owns ALL sky lighting (sun arc + energy, sky colors,
# ambient) so the cycle and weather never fight over the same properties; weather only
# supplies a rain factor that dims on top. time_of_day: 0=midnight, .25=dawn, .5=noon, .75=dusk.
var _sun: DirectionalLight3D = null
var _moon: DirectionalLight3D = null         # cool moonlight; energy tracks the lunar phase
var _sky_shader_mat: ShaderMaterial = null   # VoxelSky.gdshader: stars + phase-shaded moon disc
var _env: Environment = null
var _time_of_day: float = 0.30              # start just after dawn (dawn = .25) so the sun is already
                                            # up and climbing — the world reads as a lit morning
# Lunar cycle: an independent clock (survives day wraps). Starts at a waxing crescent so the
# very first night already has some moonlight rather than a black new moon.
var _lunar_phase: float = 0.15              # 0=new, 0.25=first quarter, 0.5=full, 0.75=last quarter
const DAY_LENGTH: float = 200.0             # seconds per full day
const LUNAR_DAYS: float = 8.0               # in-game days per full new->full->new cycle
const SUN_ENERGY_NOON: float = 1.45
const AMBIENT_DAY: float = 0.62
const AMBIENT_NIGHT: float = 0.09           # dark floor; the moon lifts brightness on lit nights
const MOON_ENERGY_FULL: float = 0.32        # directional moonlight at full moon (navigable)
const MOON_AMBIENT: float = 0.14            # extra ambient fill at a full-moon night
const MOON_COLOR: Color = Color(0.55, 0.66, 0.95)
const SKY_TOP_DAY: Color = Color(0.36, 0.56, 0.86)
const SKY_TOP_NIGHT: Color = Color(0.02, 0.03, 0.11)
# Pale, near-white horizon so the surround reads cloudlike; the ground band and haze are
# matched to this every frame (see _update_day_night) so there is no false horizon line.
const SKY_HORIZON_DAY: Color = Color(0.86, 0.90, 0.94)
const SKY_HORIZON_NIGHT: Color = Color(0.05, 0.06, 0.15)
const SKY_HORIZON_DUSK: Color = Color(0.92, 0.48, 0.24)
const GROUND_HORIZON_DAY: Color = Color(0.62, 0.66, 0.62)
const GROUND_HORIZON_NIGHT: Color = Color(0.04, 0.05, 0.10)
const GROUND_BOTTOM_DAY: Color = Color(0.30, 0.34, 0.30)
const GROUND_BOTTOM_NIGHT: Color = Color(0.02, 0.02, 0.05)

# Persistent springs (world XZ) seeded on high ground so rivers form downhill; fed
# a little depth every frame so channels sustain instead of drying out.
var _springs: Array = []
var _springs_seeded: bool = false
const SPRING_RATE: float = 0.9              # depth per second per spring

var _armed_kind: String = ""

# --- the player's hand (LMB): click a creature to select, hold to pick it up, release to
# drop or throw it. RMB spawns/casts the armed kind onto the terrain. ---
var _grab_candidate: Node = null             # creature under the cursor at LMB-press
var _held_creature: Node = null              # creature currently carried
var _grabbing: bool = false                  # committed to a carry (moved / held past threshold)
var _grab_press_pos: Vector2 = Vector2.ZERO
var _grab_press_msec: int = 0
var _hold_point: Vector3 = Vector3.ZERO      # world point the hand holds at
var _hold_velocity: Vector3 = Vector3.ZERO   # smoothed hand velocity → throw impulse
const GRAB_MOVE_THRESHOLD: float = 6.0       # px of motion that turns a click into a carry
const GRAB_HOLD_MSEC: int = 220              # or this long held still commits to a carry
const HOLD_LIFT: float = 3.0                 # height above the ground the hand carries at
const THROW_MIN_SPEED: float = 4.0           # below this a release is a gentle drop, not a throw
const THROW_MAX_SPEED: float = 40.0          # clamp on horizontal throw speed
const THROW_ARC: float = 0.4                 # upward velocity as a fraction of throw speed

# --- radius brush: RMB (click or drag) applies the armed kind across a disk, so one gesture
# paints a grove of trees, a herd of rabbits, or a spreading flood. Hold Ctrl + scroll to
# resize. A ground ring shows the footprint. Works for any armed kind (no per-kind branch). ---
var _brush_radius: float = 5.0
var _painting: bool = false
var _paint_last_world: Vector3 = Vector3(INF, INF, INF)
var _brush_ring: MeshInstance3D = null
const BRUSH_MIN: float = 1.0
const BRUSH_MAX: float = 28.0
const BRUSH_STEP: float = 1.5

var _spawned_initial: bool = false
var _ready_wait_ticks: int = 0
var _scent_visible: bool = false
var _temp_debug_visible: bool = false      # T toggles the terrain temperature heatmap debug view

# --- Procedural audio (presentation only; reacts to events, never drives the sim) ---
var _audio: LocalAgentsAudioDirector = null
var _music_destruction: float = 0.0     # decays each frame; meteors spike it
var _mood_timer: int = 0
var _music_auto_adapt: bool = true      # when false, stop feeding sim mood so manual menu picks stick

# Optional self-screenshot / smoke harness: pass `-- --shoot=<path> [--shoot-frames=N]`
var _shoot_path: String = ""
var _shoot_frames: int = 150
var _run_frames: int = 0
var _force_wind: float = 0.0            # --wind=<x>: force a constant eastward wind (verification)
var _cognition_stats: bool = false      # --cognition-stats: print fast/slow brain + genetics metrics
# Cumulative behaviour peaks over a --cognition-stats run (transient states are easy to miss in a
# single end-of-run snapshot, so we track the max seen for the emergent behaviours we care about).
var _peak_circling: int = 0
var _peak_investigating: int = 0
var _peak_sleeping: int = 0
var _auto_meteor: bool = false
var _overview: bool = false             # --overview: frame a wide whole-island vista (screenshot aid)
var _farview: bool = false              # --farview: pull the vista out to max zoom (ocean-coverage test)
var _field3d_enabled: bool = false      # --field3d: run the dense 3D MaterialField live (water pools in caves)
var _field3d: Node = null
var _debug_demo: bool = false
var _user_shot_counter: int = 0        # numbers the screenshots the DebugPanel's save button writes
var _auto_volcano: bool = false
var _auto_volcano_fired: bool = false
var _auto_lightning: bool = false
var _auto_lightning_fired: bool = false
var _storm_bolt_cd: float = 0.0
var _auto_meteor_fired: bool = false
var _auto_select: bool = false
var _auto_select_done: bool = false
var _frame: int = 0


func _ready() -> void:
	_parse_cmdline()

	# --- Sun + sky ---
	# Custom sky shader (stars + phase-shaded moon) replaces ProceduralSkyMaterial; the day
	# gradient is driven from the same uniforms each frame so daytime looks unchanged. The sun
	# and moon lights below become LIGHT0 / LIGHT1 in the shader, which draws their discs.
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var sky_mat: ShaderMaterial = ShaderMaterial.new()
	sky_mat.shader = load("res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelSky.gdshader")
	sky_mat.set_shader_parameter("sky_top_color", SKY_TOP_DAY)
	sky_mat.set_shader_parameter("sky_horizon_color", SKY_HORIZON_DAY)
	sky_mat.set_shader_parameter("ground_horizon_color", Color(0.62, 0.66, 0.62))
	sky_mat.set_shader_parameter("ground_bottom_color", Color(0.30, 0.34, 0.30))
	sky_mat.set_shader_parameter("night", 0.0)
	sky_mat.set_shader_parameter("star_intensity", 1.0)
	sky_mat.set_shader_parameter("moon_phase", _lunar_phase)
	sky_mat.set_shader_parameter("moon_color", Color(0.85, 0.90, 1.0))
	sky_mat.set_shader_parameter("moon_energy", 1.0)
	sky_mat.set_shader_parameter("sun_color", Color(1.0, 1.0, 1.0))
	sky_mat.set_shader_parameter("sun_energy", SUN_ENERGY_NOON)
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = AMBIENT_DAY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	# Subtle horizon-tinted aerial haze so distant terrain and the world's edge fade into the
	# light surround (the "inside a cloud" look). Re-tinted to the live horizon each frame.
	e.fog_enabled = true
	e.fog_light_color = SKY_HORIZON_DAY
	e.fog_density = 0.00035
	e.fog_aerial_perspective = 0.28
	e.fog_sky_affect = 0.05
	env.environment = e
	add_child(env)
	_sky_shader_mat = sky_mat
	_env = e

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -47.0, 0.0)
	sun.light_energy = SUN_ENERGY_NOON
	sun.shadow_enabled = true
	# Shadows are a per-frame render cost that scales with range; 250 covers the play area around the
	# camera without shadow-mapping all the way to the horizon (a big saving over the whole voxel view).
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)
	_sun = sun

	# Moon: added after the sun so it is LIGHT1 in the sky shader. Cool light, energy driven
	# per-frame from the lunar phase (0 at new moon), so bright nights are navigable. It does NOT cast
	# shadows — a second full shadow pass is expensive and a soft fill light's shadows are imperceptible.
	var moon: DirectionalLight3D = DirectionalLight3D.new()
	moon.light_color = MOON_COLOR
	moon.light_energy = 0.0
	moon.shadow_enabled = false
	add_child(moon)
	_moon = moon

	# --- Terrain ---
	_terrain = TerrainServiceScript.new()
	# Larger world: keep all voxel data resident over a big bounded area so edits work
	# anywhere, with a long view distance for the vistas.
	# view_distance must exceed the camera's MAX_DISTANCE (1400) so the island stays meshed when the
	# player zooms all the way out — otherwise the land unloads past ~640 units and only the ocean plane
	# is left (the "ocean doesn't line up with the land at full zoom" report). The world is only 600
	# wide, so this just keeps the whole island+seabed resident at LOD; distant terrain stays coarse.
	_terrain.build(self, {"bounds_half_xz": 300, "view_distance": 1700})

	# --- Camera + voxel viewer ---
	_camera = CameraRigScript.new()
	_camera.name = "CameraRig"
	add_child(_camera)
	_camera.current = true
	_terrain.attach_viewer(_camera)
	# Bound the pan to the island + its ocean ring (a little inside the 300-unit world edge) so the
	# player can roam the coast and open water but never fly off past the horizon into empty void.
	if _camera.has_method("set_pan_limit"):
		_camera.set_pan_limit(275.0)

	# --- Actors + ecology ---
	_actors_root = Node3D.new()
	_actors_root.name = "Actors"
	add_child(_actors_root)
	_ecology = EcologyServiceScript.new()
	_ecology.name = "Ecology"
	add_child(_ecology)
	_ecology.setup(_terrain, _actors_root)
	# Let the camera query the seismic field so ground disturbances shake it emergently (no event
	# tells the camera to shake — see LAEcologyService.seismic_energy_at / VoxelCameraRig._process).
	if _camera != null and _camera.has_method("set_ecology"):
		_camera.set_ecology(_ecology)

	# --- Selection highlight ring ---
	_selection_ring = _make_selection_ring()
	_selection_ring.visible = false
	add_child(_selection_ring)

	# --- HUD ---
	_hud = HudScript.new()
	_hud.name = "HUD"
	add_child(_hud)
	if _hud.has_signal("spawn_selected"):
		_hud.spawn_selected.connect(_on_spawn_selected)
	_hud.set_status("Streaming terrain...")

	# --- Procedural audio ---
	_audio = AudioDirectorScript.new()
	_audio.name = "AudioDirector"
	add_child(_audio)
	_audio.configure()
	# Music is MUTED by default (the player can enable it from the audio menu); SFX stay on.
	_audio.set_music_enabled(false)
	_audio.set_music_mood({"population": 0, "time_of_day": 0.30, "destruction_intensity": 0.0})
	# Wire the HUD audio menu to the live director + listen for the auto-adapt toggle.
	if _hud != null and _hud.has_method("set_audio_director"):
		_hud.set_audio_director(_audio)
	if _hud != null and _hud.has_signal("music_auto_adapt_changed"):
		_hud.music_auto_adapt_changed.connect(_on_music_auto_adapt_changed)

	# --- Weather: rain + wind. Wind advects scent; rain washes it away. ---
	_weather = WeatherScript.new()
	_weather.name = "Weather"
	add_child(_weather)
	_weather.setup(_camera, sun, e)

	# --- Unified material/heat field: the ONE substrate for all matter + energy. WATER is a material
	# here (CA rivers/lakes/ocean — creatures drink, fish live in it), temperature drives fire/phase
	# changes, and disasters inject heat/material. Replaces the old standalone water field — every
	# water query (depth_at/is_water_at/splash/...) resolves here now.
	# 4m cells keep the CA cheap (~150^2 grid). ---
	_material = MaterialFieldScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# Grid resolution is the dominant sim cost (the CA loops every cell each step). With the field's hot
	# loops now on the GPU (heat/atmosphere/liquid kernels) we can afford a finer grid: 5-unit cells give
	# ~14.6k cells across the 600-unit world (finer water/lava than the old 6-unit / 10.2k) while windowed
	# GPU stays > 60fps even under a volcano (4-unit / 22.8k dipped to ~54fps under lava-mesh load).
	_material.setup(_terrain, 300.0, 5.0)
	# The field reads the REAL sun (DirectionalLight3D) live — its energy + angle drive all heating.
	# Wind/pressure/rain are NOT injected; they emerge from the field's own physics.
	_material.set_sun(_sun)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)

	# The calm sea: ONE GPU ocean plane at sea level, following the camera to the horizon. The water
	# itself is still unified CA (it evaporates, quenches lava, a meteor splashes it); this plane just
	# draws the flat bulk cheaply, while the CA surface mesh renders only waves/surges that deviate.
	_ocean = OceanPlaneScript.new()
	add_child(_ocean)
	_ocean.setup(_terrain.sea_level() if _terrain.has_method("sea_level") else 0.0, _camera)

	# Render the field's emergent condensate: a cloud sheet aloft + a ground-hugging fog sheet, both
	# sampling the field's own density grids so they show exactly what the water cycle grew.
	_clouds = CloudLayerScript.new()
	_clouds.name = "CloudLayer"
	add_child(_clouds)
	_clouds.setup(_material, false)
	_fog = CloudLayerScript.new()
	_fog.name = "FogLayer"
	add_child(_fog)
	_fog.setup(_material, true)

	# Feed the live temperature texture to the terrain shader so HOT GROUND GLOWS (meteor craters,
	# lava, wildfire fronts) — emergent incandescence, updated in place each field step.
	if _terrain.has_method("set_shader_param") and _material.has_method("heat_texture"):
		_terrain.set_shader_param("heat_tex", _material.heat_texture())
		_terrain.set_shader_param("heat_world_min", _material.heat_world_min())
		_terrain.set_shader_param("heat_world_size", _material.heat_world_size())

	# Debug menu (left) + its world-space gizmo overlay: field views, type highlights, intended paths.
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	add_child(_debug_overlay)
	_debug_overlay.setup(_material)
	_debug_panel = DebugPanelScript.new()
	_debug_panel.name = "DebugPanel"
	add_child(_debug_panel)
	_debug_panel.view_toggled.connect(_on_debug_view)
	_debug_panel.highlight_toggled.connect(_on_debug_highlight)
	_debug_panel.paths_toggled.connect(_on_debug_paths)
	_debug_panel.perf_toggled.connect(_on_debug_perf)
	_debug_panel.screenshot_requested.connect(_on_debug_screenshot)
	if _debug_demo:
		# Verification aid: pre-enable a spread of gizmos so a screenshot shows them working.
		_debug_overlay.set_wind(true)
		_debug_overlay.set_paths(true)
		_debug_overlay.set_highlight("species_bird", true)
		_debug_overlay.set_highlight("species_fox", true)
		_debug_overlay.set_highlight("nest", true)


# --- Debug menu handlers -----------------------------------------------------

func _on_debug_view(view: String, on: bool) -> void:
	match view:
		"temp":
			_temp_debug_visible = on
			if _terrain != null and _terrain.has_method("set_shader_param"):
				_terrain.set_shader_param("heat_debug", 1.0 if on else 0.0)
		"wind":
			if _debug_overlay != null:
				_debug_overlay.set_wind(on)
		"scent":
			_scent_visible = on
			var sf = _ecology.scent_field() if _ecology != null and _ecology.has_method("scent_field") else null
			if sf != null and sf.has_method("set_scent_visible"):
				sf.set_scent_visible(on)


func _on_debug_highlight(group: String, on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_highlight(group, on)


func _on_debug_paths(on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_paths(on)


func _on_debug_perf(key: String, on: bool) -> void:
	match key:
		"shadows":
			if _sun != null:
				_sun.shadow_enabled = on
		"ssao":
			if _env != null:
				_env.ssao_enabled = on


# Save-screenshot button (DebugPanel): capture the current viewport to a numbered PNG in the project
# folder and report the absolute path so it's easy to find.
func _on_debug_screenshot() -> void:
	_user_shot_counter += 1
	var path: String = ProjectSettings.globalize_path("res://volcano_shot_%d.png" % _user_shot_counter)
	_capture_screenshot(path)
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Saved screenshot → %s" % path)


func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = int(arg.substr("--shoot-frames=".length()))
		elif arg.begins_with("--run-frames="):
			_run_frames = int(arg.substr("--run-frames=".length()))
		elif arg.begins_with("--time="):
			_time_of_day = clampf(float(arg.substr("--time=".length())), 0.0, 1.0)
		elif arg.begins_with("--lunar="):
			_lunar_phase = clampf(float(arg.substr("--lunar=".length())), 0.0, 1.0)
		elif arg.begins_with("--wind="):
			_force_wind = float(arg.substr("--wind=".length()))
		elif arg == "--debug-demo":
			_debug_demo = true
		elif arg == "--auto-meteor":
			_auto_meteor = true
		elif arg == "--auto-volcano":
			_auto_volcano = true
		elif arg == "--auto-lightning":
			_auto_lightning = true
		elif arg == "--auto-select":
			_auto_select = true
		elif arg == "--overview":
			_overview = true
		elif arg == "--farview":
			_overview = true
			_farview = true
		elif arg == "--field3d":
			_field3d_enabled = true
		elif arg == "--cognition-stats":
			_cognition_stats = true


func _process(delta: float) -> void:
	_frame += 1
	_update_day_night(delta)
	_update_music_mood()
	# Spawn the starting ecology once terrain has streamed + collided near origin.
	if not _spawned_initial and _terrain != null:
		if _terrain.is_ready_at(Vector3(0, 0, 0)):
			_ready_wait_ticks += 1
			if _ready_wait_ticks > 6:
				# Carve real 3D caves into the island BEFORE seeding water, so the terrain is genuinely 3D
				# (tunnels/caverns fluids can pour into) and the sea/springs settle around the reshaped rock.
				if _terrain.has_method("carve_caves"):
					_terrain.carve_caves(1337)
				_ecology.spawn_initial(INITIAL_COUNTS)
				_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
				_seed_water()
				# After the sea level is locked (_seed_water), seed initial ocean + lake life so the
				# water reads alive from the start; _tick_aquatic keeps every species topped up after.
				if _ecology.has_method("stock_initial_aquatic"):
					_ecology.stock_initial_aquatic()
				if _field3d_enabled:
					_build_field3d()
				_spawn_default_volcano()
				# Frame a vista at the real surface height (only when not driven by a harness cam).
				if _overview and _camera.has_method("frame_overview"):
					var ohv: float = _terrain.surface_height(0.0, 0.0)
					_camera.frame_overview(Vector3(0.0, (ohv if not is_nan(ohv) else 20.0), 0.0), 1250.0 if _farview else 360.0)
				elif not _auto_meteor and not _auto_select and _camera.has_method("frame_vista"):
					var oh: float = _terrain.surface_height(0.0, 0.0)
					if not is_nan(oh):
						_camera.frame_vista(Vector3(0.0, oh, 0.0))
				_spawned_initial = true
				_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")
	_update_hand(delta)
	_update_selection_ring()
	_update_brush_ring()
	_push_environment()
	_feed_water()
	if _cognition_stats and _spawned_initial and _frame % 15 == 0:
		_sample_behaviour_peaks()

	# Auto-meteor demo/test: drop a meteor on a forest so it carves a crater, topples trees,
	# and ignites a wildfire. Works in both screenshot mode and headless run-frames mode.
	if _auto_meteor and not _auto_meteor_fired and _spawned_initial:
		var trigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame == trigger:
			_fire_test_meteor()

	# Auto-volcano demo/test: raise a volcano near origin that ERUPTS IMMEDIATELY (force_erupt), frame
	# the camera on it, and fire it ~560 frames (~5s) before the screenshot so the shot studies a flow
	# that has been erupting for about five seconds (lava spread + some of it cooled).
	if _auto_volcano and not _auto_volcano_fired and _spawned_initial:
		# Erupt at a FIXED early frame so the eruption's age at the screenshot = _shoot_frames - 350;
		# pick _shoot_frames to study the flow at any age (e.g. ~5s vs ~10s in).
		var vtrigger: int = 350 if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame >= vtrigger:
			var oh: float = _terrain.surface_height(20.0, 20.0)
			if not is_nan(oh):
				var vc: Node = _spawn_volcano(Vector3(20.0, oh, 20.0))
				if vc != null and vc.has_method("force_erupt"):
					vc.force_erupt()
				if _camera != null and _camera.has_method("frame_vista"):
					_camera.frame_vista(Vector3(20.0, oh, 20.0))
				_auto_volcano_fired = true

	# Thunderstorms produce lightning — emergent occurrence keyed off heavy rain.
	if _spawned_initial and _weather != null and _weather.has_method("rain"):
		_storm_bolt_cd -= delta
		if _weather.rain() > 0.6 and _storm_bolt_cd <= 0.0:
			_storm_bolt_cd = randf_range(2.5, 7.0)
			_strike_random_lightning()

	# Auto-lightning demo/test: strike the nearest tree so a wildfire emerges from the bolt's heat.
	if _auto_lightning and not _auto_lightning_fired and _spawned_initial:
		var ltrigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame >= ltrigger:
			_fire_test_lightning()
			_auto_lightning_fired = true

	# Auto-select demo: aim at the nearest creature and run the real selection path.
	if _auto_select and not _auto_select_done and _spawned_initial and _frame == _shoot_frames - 40:
		var nearest: Node3D = null
		var best: float = INF
		for a in get_tree().get_nodes_in_group("selectable"):
			if a is Node3D:
				var d: float = (_camera.global_position - (a as Node3D).global_position).length()
				if d < best:
					best = d
					nearest = a
		if nearest != null:
			var p: Vector3 = nearest.global_position
			if _camera.has_method("focus_on"):
				_camera.focus_on(p)
			else:
				_camera.global_position = p + Vector3(6.0, 5.0, 6.0)
				_camera.look_at(p, Vector3.UP)
			_select_at(get_viewport().get_visible_rect().size * 0.5)
			var title: String = ""
			if _selected != null:
				title = String(_selected.call("get_inspector_payload").get("title", ""))
			print("SELECT_RESULT selected=", _selected != null, " ring_visible=", _selection_ring.visible, " title=", title)
		_auto_select_done = true

	if _shoot_path != "" and _frame == _shoot_frames:
		_capture_screenshot(_shoot_path)
		get_tree().quit(0)

	if _run_frames > 0 and _frame == _run_frames:
		var n_sel: int = get_tree().get_nodes_in_group("selectable").size()
		var n_act: int = _actors_root.get_child_count()
		# Live-world diagnostics: verify the wired subsystems are actually doing something.
		var wet: int = 0
		if _material != null and _material.has_method("wet_cell_count"):
			wet = _material.wet_cell_count()
		var heat_peak: float = 0.0
		var heat_cells: int = 0
		var lava_cells: int = 0
		if _material != null and _material.has_method("peak_heat"):
			heat_peak = _material.peak_heat()
			heat_cells = _material.hot_cell_count()
			if _material.has_method("lava_peak"):
				lava_cells = _material.lava_peak()
		var cloud_cells: int = 0
		var cloud_cover: float = 0.0
		var fog_cover: float = 0.0
		if _material != null and _material.has_method("cloud_cell_count"):
			cloud_cells = _material.cloud_cell_count()
			cloud_cover = _material.avg_cloud_cover()
			fog_cover = _material.avg_fog_cover()
		var wind_mag: float = 0.0
		if _material != null and _material.has_method("wind"):
			wind_mag = _material.wind().length()
		var n_poop: int = get_tree().get_nodes_in_group("poop").size()
		var n_fish: int = get_tree().get_nodes_in_group("species_fish").size()
		var n_fire: int = 0
		if _ecology != null and _ecology.has_method("fire_system"):
			var fsys = _ecology.fire_system()
			if fsys != null and fsys.has_method("active_fire_count"):
				n_fire = fsys.active_fire_count()
		var creatures: Array = get_tree().get_nodes_in_group("creature")
		var min_hyd: int = 100
		var drinkers: int = 0
		var circling: int = 0        # vultures over a carcass (or soaring): the visible signal
		var investigating: int = 0   # ground scavengers reading a carrion cue ("watch the vultures")
		var sleeping: int = 0        # animals resting at their nest during their off-hours
		for c in creatures:
			if is_instance_valid(c) and "hydration" in c and "max_hydration" in c:
				var h: int = int(round(100.0 * float(c.hydration) / maxf(1.0, float(c.max_hydration))))
				min_hyd = mini(min_hyd, h)
				var st: String = String(c.get("state"))
				if st == "drink":
					drinkers += 1
				elif st == "circle" or st == "soar":
					circling += 1
				elif st == "investigate":
					investigating += 1
				elif st == "sleep" or st == "roost":
					sleeping += 1
		var n_nest: int = get_tree().get_nodes_in_group("nest").size()
		# Cognition/genetics aggregates: prove the fast/slow brain + evolution are actually running.
		var habits: int = 0
		var asked: int = 0
		var learned_socially: int = 0
		var max_gen: int = 0
		var minds: int = 0
		var cues_learned: int = 0
		for c in creatures:
			if not is_instance_valid(c) or not c.has_method("get_cognition"):
				continue
			var cog = c.get_cognition()
			if cog == null:
				continue
			minds += 1
			habits += cog.policy_size()
			asked += cog.escalations
			learned_socially += cog.lessons
			for cv in cog.cue_values.values():
				if float(cv) >= 0.6:
					cues_learned += 1
			if c.has_method("get_genome") and c.get_genome() != null:
				max_gen = maxi(max_gen, int(c.get_genome().generation))
		var sched_calls: int = 0
		if _ecology != null and _ecology.has_method("cognition_scheduler"):
			var sc = _ecology.cognition_scheduler()
			if sc != null and sc.has_method("total_calls"):
				sched_calls = sc.total_calls()
		print("SMOKE_SUMMARY={\"frames\":%d,\"spawned_initial\":%s,\"ready\":%s,\"selectable\":%d,\"actors\":%d,\"wet_cells\":%d,\"heat_peak\":%.2f,\"heat_cells\":%d,\"lava_cells\":%d,\"cloud_cells\":%d,\"cloud_cover\":%.3f,\"fog_cover\":%.3f,\"wind\":%.2f,\"poop\":%d,\"fish\":%d,\"fires\":%d,\"min_hydration\":%d,\"drinking\":%d,\"time_of_day\":%.2f,\"minds\":%d,\"habits\":%d,\"escalations\":%d,\"social_lessons\":%d,\"max_generation\":%d,\"slow_brain_calls\":%d,\"nests\":%d,\"circling\":%d,\"investigating\":%d,\"sleeping\":%d,\"cues_learned\":%d}" % [
			_frame, str(_spawned_initial).to_lower(), str(_terrain.is_ready_at(Vector3.ZERO)).to_lower(), n_sel, n_act, wet, heat_peak, heat_cells, lava_cells, cloud_cells, cloud_cover, fog_cover, wind_mag, n_poop, n_fish, n_fire, min_hyd, drinkers, _time_of_day, minds, habits, asked, learned_socially, max_gen, sched_calls, n_nest, circling, investigating, sleeping, cues_learned])
		if _cognition_stats:
			var avg_habits: float = (float(habits) / float(minds)) if minds > 0 else 0.0
			print("COGNITION_SUMMARY minds=%d avg_habits=%.2f escalations=%d social_lessons=%d max_generation=%d slow_brain_calls=%d nests=%d circling=%d investigating=%d sleeping=%d cues_learned=%d" % [
				minds, avg_habits, asked, learned_socially, max_gen, sched_calls, n_nest, circling, investigating, sleeping, cues_learned])
			print("BEHAVIOUR_PEAKS peak_circling=%d peak_investigating=%d peak_sleeping=%d cues_learned=%d" % [
				_peak_circling, _peak_investigating, _peak_sleeping, cues_learned])
		get_tree().quit(0)


# Sample transient emergent behaviours so a run can prove they occurred (not just at the final frame).
func _sample_behaviour_peaks() -> void:
	var circ: int = 0
	var invs: int = 0
	var slp: int = 0
	for c in get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(c):
			continue
		var st: String = String(c.get("state"))
		if st == "circle" or st == "soar":
			circ += 1
		elif st == "investigate":
			invs += 1
		elif st == "sleep" or st == "roost":
			slp += 1
	_peak_circling = maxi(_peak_circling, circ)
	_peak_investigating = maxi(_peak_investigating, invs)
	_peak_sleeping = maxi(_peak_sleeping, slp)


# Advance the clock and drive all sky lighting from it, dimmed by weather rain.
# Emergent day arc: sun elevation is a sine of the time of day; everything (light
# energy, warm horizon at dawn/dusk, ambient floor at night) follows from that one value.
func _update_day_night(delta: float) -> void:
	if _sun == null:
		return
	_time_of_day = fposmod(_time_of_day + delta / DAY_LENGTH, 1.0)
	# Sun elevation: -1 (midnight) .. +1 (noon), zero at dawn (.25) and dusk (.75).
	var elev: float = sin((_time_of_day - 0.25) * TAU)
	var daylight: float = clampf(elev, 0.0, 1.0)
	# Storm factor from weather dims the sun/ambient on top of the day cycle.
	var rain: float = 0.0
	if _weather != null and _weather.has_method("rain"):
		rain = _weather.rain()
	var storm: float = 1.0 - rain * 0.68
	# Overcast skies (the field's own emergent cloud cover) dim the sun + ambient on top of rain.
	var cloud_cover: float = 0.0
	if _material != null and _material.has_method("avg_cloud_cover"):
		cloud_cover = _material.avg_cloud_cover()
	storm *= 1.0 - clampf(cloud_cover * 1.5, 0.0, 0.6)

	# Sun arc: steep overhead at noon, shallow at the horizon near dawn/dusk; sweeps E->W.
	_sun.rotation_degrees = Vector3(-(6.0 + daylight * 66.0), -47.0 + (_time_of_day - 0.5) * 90.0, 0.0)
	_sun.light_energy = SUN_ENERGY_NOON * daylight * storm
	# Warm the sunlight near the horizon (dawn/dusk glow).
	var warm: float = clampf(1.0 - elev * 2.5, 0.0, 1.0) * clampf(daylight * 6.0, 0.0, 1.0)
	_sun.light_color = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.6, 0.32), warm * 0.8)

	# Lunar cycle: advance the phase on its own slow clock; illuminated fraction is a cosine
	# of the phase (0 at new, 1 at full). The moon arcs opposite the sun (up through the night).
	_lunar_phase = fposmod(_lunar_phase + delta / (DAY_LENGTH * LUNAR_DAYS), 1.0)
	var moon_illum: float = (1.0 - cos(_lunar_phase * TAU)) * 0.5
	var moonup: float = clampf(-elev, 0.0, 1.0)
	if _moon != null:
		_moon.rotation_degrees = Vector3(-(6.0 + moonup * 66.0), 133.0 + (_time_of_day - 0.5) * 90.0, 0.0)
		_moon.light_energy = MOON_ENERGY_FULL * moon_illum * moonup * storm

	# Sky colors lerp day<->night; horizon warms to dusk-orange around the transitions.
	var night: float = 1.0 - daylight
	if _sky_shader_mat != null:
		_sky_shader_mat.set_shader_parameter("sky_top_color", SKY_TOP_DAY.lerp(SKY_TOP_NIGHT, night))
		var horizon: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		horizon = horizon.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_sky_shader_mat.set_shader_parameter("sky_horizon_color", horizon)
		# Darken the ground band at night too, else the static ground horizon reads as a bright
		# pale strip against the dark night sky.
		_sky_shader_mat.set_shader_parameter("ground_horizon_color", GROUND_HORIZON_DAY.lerp(GROUND_HORIZON_NIGHT, night))
		_sky_shader_mat.set_shader_parameter("ground_bottom_color", GROUND_BOTTOM_DAY.lerp(GROUND_BOTTOM_NIGHT, night))
		_sky_shader_mat.set_shader_parameter("night", night)
		_sky_shader_mat.set_shader_parameter("moon_phase", _lunar_phase)
		# Sun/moon directions drive the discs directly (basis.z of a DirectionalLight3D points
		# back toward the light, i.e. where it sits in the sky).
		_sky_shader_mat.set_shader_parameter("sun_dir", _sun.global_transform.basis.z)
		_sky_shader_mat.set_shader_parameter("sun_energy", _sun.light_energy)
		_sky_shader_mat.set_shader_parameter("sun_color", _sun.light_color)
		if _moon != null:
			_sky_shader_mat.set_shader_parameter("moon_dir", _moon.global_transform.basis.z)
	if _env != null:
		# Dark night floor, lifted softly on bright-moon nights so full moons are navigable.
		_env.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, daylight) * storm \
			+ moon_illum * night * MOON_AMBIENT * storm

	# Tint the field's cloud/fog sheets with the sky: white by day, dusk-orange near sunset, dark at
	# night (unshaded sheets, so the tint is what makes them read against the time of day).
	var cloud_tint: Color = Color(1.0, 1.0, 1.0).lerp(Color(0.10, 0.12, 0.18), night)
	cloud_tint = cloud_tint.lerp(Color(1.0, 0.55, 0.30), warm * 0.6)
	if _clouds != null:
		_clouds.set_tint(cloud_tint)
	if _fog != null:
		_fog.set_tint(cloud_tint)

	# Share the clock with the ecology so nocturnal behavior can key off night.
	if _ecology != null and _ecology.has_method("set_time_of_day"):
		_ecology.set_time_of_day(_time_of_day)
	# NOTE: the material field is NOT fed rain/daylight here — it reads the sun node directly and
	# derives its own heating/weather. This day/night code only owns the sky + sun transform/energy.


# Feed the generative music a mood from live world state. Presentation only.
func _update_music_mood() -> void:
	if _audio == null:
		return
	var dt: float = get_process_delta_time()
	_music_destruction = maxf(0.0, _music_destruction - dt * 0.4)
	_mood_timer += 1
	if _mood_timer % 20 != 0:
		return
	# Manual override: when auto-adapt is off, stop pushing mood so menu picks persist.
	if not _music_auto_adapt:
		return
	var population: int = get_tree().get_nodes_in_group("creature").size()
	_audio.set_music_mood({
		"population": population,
		"time_of_day": _time_of_day,
		"destruction_intensity": _music_destruction,
		"threat": _music_destruction,
	})


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_scent_visible = not _scent_visible
		var sf = _ecology.scent_field() if _ecology != null and _ecology.has_method("scent_field") else null
		if sf != null and sf.has_method("set_scent_visible"):
			sf.set_scent_visible(_scent_visible)
		_hud.set_status("Scent view: %s" % ("ON" if _scent_visible else "off"))
		return
	# Debug view: T paints the terrain by temperature (heatmap). More field views (wind, pressure)
	# hang off the same toggle set as those systems come online.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_temp_debug_visible = not _temp_debug_visible
		if _terrain != null and _terrain.has_method("set_shader_param"):
			_terrain.set_shader_param("heat_debug", 1.0 if _temp_debug_visible else 0.0)
		_hud.set_status("Temperature view: %s" % ("ON" if _temp_debug_visible else "off"))
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		if _hud != null and _hud.has_method("toggle_audio_menu"):
			_hud.toggle_audio_menu()
		return
	# Palette / selection hotkeys: Esc -> Select, 1-7 arm Life, Shift+1-5 arm Disasters,
	# Tab / Shift+Tab cycle the selection through on-screen entities.
	if event is InputEventKey and event.pressed and not event.echo:
		var key_ev: InputEventKey = event as InputEventKey
		if key_ev.keycode == KEY_ESCAPE:
			if _hud != null and _hud.has_method("arm_kind"):
				_hud.arm_kind("")
			return
		if key_ev.keycode == KEY_TAB:
			_cycle_selection(-1 if key_ev.shift_pressed else 1)
			return
		if key_ev.keycode >= KEY_1 and key_ev.keycode <= KEY_9:
			_arm_hotkey(key_ev.keycode - KEY_1, key_ev.shift_pressed)
			return
	# While painting, drag the brush across the terrain to keep applying the armed kind.
	if event is InputEventMouseMotion and _painting and _armed_kind != "":
		_paint_drag((event as InputEventMouseMotion).position)
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		var mpos: Vector2 = mb.position
		# Ctrl + wheel resizes the brush (only when a kind is armed, so plain wheel still zooms).
		if _armed_kind != "" and mb.pressed and mb.ctrl_pressed \
				and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var d: float = BRUSH_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -BRUSH_STEP
			_brush_radius = clampf(_brush_radius + d, BRUSH_MIN, BRUSH_MAX)
			_hud.set_status("Brush radius: %.0f m" % _brush_radius)
			return
		# RMB: paint / cast the armed kind onto the terrain (Black & White right-hand miracle).
		# Press starts a paint stroke (drag keeps painting); release ends it.
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(mpos):
					return
				if _armed_kind != "":
					_painting = true
					_paint_last_world = Vector3(INF, INF, INF)
					_place_armed(mpos)
			else:
				_painting = false
			return
		# LMB: double-click frames the entity; single press begins a click-or-grab; release
		# resolves it (select vs drop/throw).
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					_frame_focus_at(mpos)
					return
				_on_lmb_press(mpos)
			else:
				_on_lmb_release(mpos)


func _on_spawn_selected(kind: String) -> void:
	_armed_kind = kind
	if kind == "":
		_hud.set_status("Select mode — left-click a creature to inspect, hold to pick it up.")
	else:
		_hud.set_status("Cast %s — right-click the ground to place." % kind)


# Number-key arming: `index` is the 0-based digit (1 key -> 0). Shift picks the Disasters
# cluster, otherwise Life. Routes through the HUD so the palette buttons stay in sync.
func _arm_hotkey(index: int, shifted: bool) -> void:
	if _hud == null or not _hud.has_method("arm_kind"):
		return
	var kinds: PackedStringArray = LASpawnPaletteHud.DISASTER_KINDS if shifted else LASpawnPaletteHud.LIFE_KINDS
	if index < 0 or index >= kinds.size():
		return
	_hud.arm_kind(kinds[index])


# Tab / Shift+Tab: walk the selection through on-screen selectables (nearest camera-first) and
# focus the camera on each, so a busy world can be inspected without hunting for click targets.
func _cycle_selection(dir: int) -> void:
	var nodes: Array = []
	for n in get_tree().get_nodes_in_group("selectable"):
		if n is Node3D and is_instance_valid(n) and (n as Node).has_method("get_inspector_payload"):
			nodes.append(n)
	if nodes.is_empty():
		_set_selected(null)
		return
	var origin: Vector3 = _camera.global_position
	nodes.sort_custom(func(a, b):
		return origin.distance_squared_to((a as Node3D).global_position) \
			< origin.distance_squared_to((b as Node3D).global_position))
	var idx: int = nodes.find(_selected)
	if idx < 0:
		idx = 0 if dir >= 0 else nodes.size() - 1
	else:
		idx = (idx + dir) % nodes.size()
		if idx < 0:
			idx += nodes.size()
	var target: Node = nodes[idx]
	_set_selected(target)
	if _camera.has_method("focus_on"):
		_camera.focus_on((target as Node3D).global_position)


# Double-click: select the entity under the cursor (if any) and frame the camera on it.
func _frame_focus_at(screen_pos: Vector2) -> void:
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(screen_pos):
		return
	_select_at(screen_pos)
	if _selected is Node3D and _camera.has_method("focus_on"):
		_camera.focus_on((_selected as Node3D).global_position)


# --- the player's hand -------------------------------------------------------
# LMB press: remember what's under the cursor. A quick click selects; holding/dragging
# commits to a carry (see _update_hand).
func _on_lmb_press(pos: Vector2) -> void:
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(pos):
		return
	_grab_candidate = _creature_at(pos)
	_grab_press_pos = pos
	_grab_press_msec = Time.get_ticks_msec()
	_grabbing = false


# LMB release: a carry drops or throws (by hand speed); a plain click selects.
func _on_lmb_release(pos: Vector2) -> void:
	if _grabbing and _held_creature != null and is_instance_valid(_held_creature):
		var flat: Vector3 = Vector3(_hold_velocity.x, 0.0, _hold_velocity.z)
		var fspeed: float = flat.length()
		if fspeed > THROW_MIN_SPEED:
			fspeed = minf(fspeed, THROW_MAX_SPEED)
			var throw_vel: Vector3 = flat.normalized() * fspeed
			throw_vel.y = fspeed * THROW_ARC       # arc upward with throw strength
			_held_creature.call("throw", throw_vel)
			_hud.set_status("Threw the %s!" % _creature_species(_held_creature))
		else:
			_held_creature.call("hold_end")        # gentle set-down
			_hud.set_status("Set the %s down." % _creature_species(_held_creature))
	elif _grab_candidate != null and is_instance_valid(_grab_candidate):
		_set_selected(_grab_candidate)             # a click — just inspect it
	else:
		_select_at(pos)                            # empty ground — select/deselect via ray
	_grab_candidate = null
	_held_creature = null
	_grabbing = false


# Called every frame from _process: commit a pending press to a carry, then keep the held
# creature under the cursor and estimate hand velocity for throwing.
func _update_hand(delta: float) -> void:
	if _grab_candidate == null and _held_creature == null:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var mpos: Vector2 = vp.get_mouse_position()

	if not _grabbing and _grab_candidate != null:
		if not is_instance_valid(_grab_candidate):
			_grab_candidate = null
			return
		var moved: float = mpos.distance_to(_grab_press_pos)
		var held_ms: int = Time.get_ticks_msec() - _grab_press_msec
		if moved >= GRAB_MOVE_THRESHOLD or held_ms >= GRAB_HOLD_MSEC:
			_begin_carry(_grab_candidate)

	if _grabbing and _held_creature != null:
		if not is_instance_valid(_held_creature):
			_held_creature = null
			_grabbing = false
			return
		var target: Vector3 = _hand_world_point(mpos)
		if is_finite(target.x):
			if delta > 0.0001:
				var inst_vel: Vector3 = (target - _hold_point) / delta
				_hold_velocity = _hold_velocity.lerp(inst_vel, 0.5)
			_hold_point = target
			(_held_creature as Node3D).global_position = target


func _begin_carry(creature: Node) -> void:
	_grabbing = true
	_held_creature = creature
	creature.call("hold_begin")
	_hold_point = (creature as Node3D).global_position
	_hold_velocity = Vector3.ZERO
	_set_selected(creature)
	if _audio != null:
		_audio.play_sfx("ui_click")


# World point the hand carries at: the terrain surface under the cursor, lifted a little so
# the creature hovers above the ground where you point. Returns INF if the cursor misses terrain.
func _hand_world_point(screen_pos: Vector2) -> Vector3:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 2000.0)
	if not bool(hit.get("hit", false)):
		return Vector3(INF, INF, INF)
	return (hit["position"] as Vector3) + Vector3(0.0, HOLD_LIFT, 0.0)


# Physics-ray pick that resolves to a living creature (group "creature" with the hand API),
# or null if the cursor isn't over one.
func _creature_at(screen_pos: Vector2) -> Node:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["dir"] * 2000.0)
	q.collision_mask = 0xFFFFFFFF
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return null
	return _resolve_creature(r.get("collider", null))


func _resolve_creature(collider) -> Node:
	var n = collider
	while n != null and n is Node:
		if (n as Node).is_in_group("creature") and (n as Node).has_method("hold_begin"):
			return n
		n = (n as Node).get_parent()
	return null


func _creature_species(creature: Node) -> String:
	if creature != null and "species" in creature:
		return String(creature.get("species"))
	return "creature"


func _on_music_auto_adapt_changed(on: bool) -> void:
	_music_auto_adapt = on
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Music auto-adapt: %s" % ("ON" if on else "off — manual control"))


# RMB entry point: resolve the terrain point under the cursor and paint the armed kind there.
func _place_armed(screen_pos: Vector2) -> void:
	var point: Vector3 = _terrain_point(screen_pos)
	if not is_finite(point.x):
		_hud.set_status("No ground under cursor — aim at the terrain.")
		return
	_paint_brush(point)


# The terrain surface point under a screen position, or an INF vector if the cursor misses terrain.
func _terrain_point(screen_pos: Vector2) -> Vector3:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 2000.0)
	if not bool(hit.get("hit", false)):
		return Vector3(INF, INF, INF)
	return hit["position"]


# Apply the armed kind across the brush disk: one placement at the centre for a pinpoint brush,
# else a size-scaled scatter of placements. General over all kinds — trees, herds, floods alike.
func _paint_brush(center: Vector3) -> void:
	if _brush_radius <= BRUSH_MIN + 0.01:
		_apply_at(center)
	else:
		var n: int = clampi(int(round(_brush_radius * 0.6)), 1, 12)
		for i in n:
			_apply_at(_scatter_point(center))
	if _audio != null:
		_audio.play_sfx("spawn", center)
	_spawn_puff(center, _kind_color(_armed_kind))
	_paint_last_world = center


# A random point in the brush disk around `center`, re-snapped to the terrain surface (falls back
# to the centre height when the offset lands off the meshed area).
func _scatter_point(center: Vector3) -> Vector3:
	var ang: float = randf() * TAU
	var rad: float = sqrt(randf()) * _brush_radius
	var p: Vector3 = center + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	if _terrain != null and _terrain.has_method("surface_height"):
		var y: float = float(_terrain.surface_height(p.x, p.z))
		if not is_nan(y):
			p.y = y
	return p


# The single-point action for the armed kind (no puff/audio — the brush handles those once).
func _apply_at(point: Vector3) -> void:
	if _armed_kind == "meteor":
		var meteor: MeteorScript = MeteorScript.new()
		_actors_root.add_child(meteor)
		meteor.setup(_terrain, _ecology)
		# Launch from over the user's head, streaking toward the clicked point.
		meteor.launch(point, _camera.global_position)
		_music_destruction = 1.0
		_hud.set_status("Meteor inbound!")
	elif _armed_kind == "volcano":
		_spawn_volcano(point)
		_music_destruction = 1.0
		_hud.set_status("A volcano rises — stand back!")
	elif _armed_kind == "lightning":
		_spawn_lightning(point)
		_music_destruction = 0.7
		_hud.set_status("A bolt strikes!")
	elif _armed_kind == "earthquake":
		var quake: Node = EarthquakeScript.new()
		_actors_root.add_child(quake)
		quake.setup(_terrain, _ecology)
		quake.rupture(point)
		_music_destruction = 1.0
		_hud.set_status("The ground heaves!")
	elif _armed_kind == "flood":
		var flood: Node = FloodScript.new()
		_actors_root.add_child(flood)
		flood.setup(_terrain, _ecology)
		# Tie the surge footprint to the spawn brush so a flood only covers where the player aimed.
		flood.surge(point, _brush_radius)
		_hud.set_status("Flood surge!")
	else:
		_ecology.spawn(_armed_kind, point)
		_hud.set_status("Spawned %s." % _armed_kind)


# Continue a paint stroke as the cursor drags: re-paint once the brush has moved far enough that
# strokes don't stack on the same spot (spacing scales with radius).
func _paint_drag(screen_pos: Vector2) -> void:
	var point: Vector3 = _terrain_point(screen_pos)
	if not is_finite(point.x):
		return
	if is_finite(_paint_last_world.x):
		var spacing: float = maxf(_brush_radius * 0.6, 1.5)
		if _paint_last_world.distance_to(point) < spacing:
			return
	_paint_brush(point)


# A flat ground ring showing the brush footprint, following the cursor whenever a kind is armed.
func _update_brush_ring() -> void:
	if _armed_kind == "" or _camera == null or _terrain == null:
		if _brush_ring != null:
			_brush_ring.visible = false
		return
	_ensure_brush_ring()
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var mpos: Vector2 = vp.get_mouse_position()
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(mpos):
		_brush_ring.visible = false
		return
	var p: Vector3 = _terrain_point(mpos)
	if not is_finite(p.x):
		_brush_ring.visible = false
		return
	_brush_ring.visible = true
	_brush_ring.global_position = p + Vector3(0.0, 0.15, 0.0)
	_brush_ring.scale = Vector3(_brush_radius, 1.0, _brush_radius)
	var mat: StandardMaterial3D = _brush_ring.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = _kind_color(_armed_kind)


func _ensure_brush_ring() -> void:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		return
	var ring: MeshInstance3D = MeshInstance3D.new()
	ring.name = "BrushRing"
	var torus: TorusMesh = TorusMesh.new()   # lies flat in the XZ plane; scaled to the radius
	torus.inner_radius = 0.95
	torus.outer_radius = 1.0
	torus.rings = 48
	ring.mesh = torus
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.9, 0.9, 0.9, 0.75)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	add_child(ring)
	_brush_ring = ring


# The world always has one active volcano — placed on the highest of several sampled points so it's a
# proper mountain landmark, well away from the origin spawn.
func _spawn_default_volcano() -> void:
	var best_h: float = -INF
	var best: Vector3 = Vector3(150.0, 0.0, 150.0)
	var ring: int = 12
	for i in range(ring):
		var ang: float = TAU * float(i) / float(ring)
		var r: float = 160.0
		var px: float = cos(ang) * r
		var pz: float = sin(ang) * r
		var h: float = _terrain.surface_height(px, pz)
		if not is_nan(h) and h > best_h:
			best_h = h
			best = Vector3(px, h, pz)
	if best_h > -INF:
		_spawn_volcano(best)


func _spawn_volcano(point: Vector3) -> Node:
	var v: Node = VolcanoScript.new()
	_actors_root.add_child(v)
	v.setup(_terrain, _ecology)
	v.erupt_at(point)
	return v


func _spawn_lightning(point: Vector3) -> void:
	var b: Node = LightningScript.new()
	_actors_root.add_child(b)
	b.setup(_terrain, _ecology)
	b.strike(point)
	if _audio != null:
		_audio.play_sfx("thunder", point)


# A bolt at a random point in the play area (thunderstorm occurrence).
func _strike_random_lightning() -> void:
	var ang: float = randf() * TAU
	var r: float = randf() * 250.0
	var px: float = cos(ang) * r
	var pz: float = sin(ang) * r
	var h: float = _terrain.surface_height(px, pz)
	if not is_nan(h):
		_spawn_lightning(Vector3(px, h, pz))


# Strike the nearest tree (test: confirm fire emerges from the bolt's heat).
func _fire_test_lightning() -> void:
	var best: float = INF
	var impact: Vector3 = Vector3.ZERO
	var found: bool = false
	for t in get_tree().get_nodes_in_group("tree"):
		if t is Node3D:
			var d: float = (_camera.global_position - (t as Node3D).global_position).length()
			if d < best:
				best = d
				impact = (t as Node3D).global_position
				found = true
	if found:
		_spawn_lightning(impact)


func _select_at(screen_pos: Vector2) -> void:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(ray["origin"], ray["origin"] + ray["dir"] * 2000.0)
	q.collision_mask = 0xFFFFFFFF
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		_set_selected(null)
		return
	var node: Node = _resolve_selectable(r.get("collider", null))
	_set_selected(node)


func _resolve_selectable(collider) -> Node:
	var n = collider
	while n != null and n is Node:
		if (n as Node).is_in_group("selectable") and (n as Node).has_method("get_inspector_payload"):
			return n
		n = (n as Node).get_parent()
	return null


func _set_selected(node: Node) -> void:
	_selected = node
	if node == null:
		_hud.clear_inspector()
		_selection_ring.visible = false
		return
	_hud.show_inspector(node.call("get_inspector_payload"))
	_selection_ring.visible = true
	if _audio != null:
		_audio.play_sfx("ui_click")


# Launch a test meteor at the nearest tree (so it hits vegetation and can start a fire),
# falling back to the point under the camera's aim if there are no trees.
func _fire_test_meteor() -> void:
	var impact: Vector3 = Vector3.ZERO
	var found: bool = false
	var best: float = INF
	for t in get_tree().get_nodes_in_group("tree"):
		if t is Node3D:
			var d: float = (_camera.global_position - (t as Node3D).global_position).length()
			if d < best:
				best = d
				impact = (t as Node3D).global_position
				found = true
	if not found:
		var ray: Dictionary = _camera.aim_ray()
		var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 3000.0)
		if not bool(hit.get("hit", false)):
			return
		impact = hit["position"]
	var m: MeteorScript = MeteorScript.new()
	_actors_root.add_child(m)
	m.setup(_terrain, _ecology)
	m.launch(impact, _camera.global_position)
	_music_destruction = 1.0
	_auto_meteor_fired = true
	if _camera.has_method("focus_on"):
		_camera.focus_on(impact)
	else:
		_camera.global_position = impact + Vector3(26.0, 30.0, 26.0)
		_camera.look_at(impact, Vector3.UP)


func _update_selection_ring() -> void:
	if _selected == null or not is_instance_valid(_selected):
		_selection_ring.visible = false
		_selected = null
		return
	if _selected is Node3D:
		var p: Vector3 = (_selected as Node3D).global_position
		_selection_ring.global_position = p + Vector3(0, 0.1, 0)
		if _selected.has_method("get_inspector_payload"):
			_hud.show_inspector(_selected.call("get_inspector_payload"))


func _push_environment() -> void:
	if _weather == null:
		return
	# Drift the field's vapor/clouds downwind with the live weather wind (XZ).
	if _material != null and _material.has_method("set_wind"):
		if _force_wind != 0.0:
			_material.set_wind(Vector2(_force_wind, 0.0))
		else:
			var w: Vector3 = _weather.wind_vector()
			_material.set_wind(Vector2(w.x, w.z))
	if _ecology == null or not _ecology.has_method("scent_field"):
		return
	var sf = _ecology.scent_field()
	if sf == null:
		return
	if sf.has_method("set_wind"):
		sf.set_wind(_weather.wind_vector())
	if sf.has_method("set_wash"):
		sf.set_wash(_weather.rain())


# Build the dense 3D MaterialField (behind --field3d): sample rock/void from the terrain SDF, seed the
# sea, feed the same springs, and start it. It renders its own 3D water surface (sea + cavern pools) on
# top of the 2.5D field — an A/B proving ground on the road to replacing the 2.5D substrate.
func _build_field3d() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	_field3d = MaterialField3DScript.new()
	_field3d.name = "MaterialField3D"
	add_child(_field3d)
	var sea: float = _terrain.sea_level() if _terrain.has_method("sea_level") else 0.0
	# 8-unit cells over the island's Y span (seabed to above the spring heads) keeps it ~130k cells.
	_field3d.setup(_terrain, 300.0, 8.0, -80.0, 90.0, sea)
	_field3d.sample_solidity()
	_field3d.seed_sea()
	for p in _springs:
		_field3d.add_source(p, 0.8)          # modest headwaters — streams/ponds, not a flooded interior
	_field3d.activate()
	_hud.set_status("3D water field active — water pools in caves.")


# Lock the sea level to the island's true ocean surface, sync the terrain shader's beach/snow bands to
# it, and pick a few high interior peaks as persistent springs so rivers run downhill to the coast and
# drain into the ocean (continuous water). One-shot.
func _seed_water() -> void:
	if _material == null or _terrain == null:
		return
	# The terrain was shaped around a fixed sea level; use it directly (not origin ground, which is now
	# the island's high centre) so the whole sub-sea seabed reads as ocean.
	var sea: float = _terrain.sea_level() if _terrain.has_method("sea_level") else 0.0
	_material.sea_level = sea
	if _terrain.has_method("set_shader_param"):
		_terrain.set_shader_param("sea_level", sea)
		# Snow only lightly caps the very highest hilltops (the isle tops out ~78 above a sea of ~6), so
		# the island reads green with rocky slopes rather than a snowfield.
		_terrain.set_shader_param("snow_height", sea + 66.0)
	# Sample interior rings and take the highest points as spring heads (headwaters up on the island so
	# streams flow the full length down to the sea). Must be clearly above the sea to feed real rivers.
	var candidates: Array = []
	var rings: Array = [50.0, 95.0, 140.0]
	var per: int = 8
	for ri in range(rings.size()):
		var r: float = float(rings[ri])
		for i in range(per):
			var ang: float = TAU * float(i) / float(per) + float(ri) * 0.7   # stagger rings
			var px: float = cos(ang) * r
			var pz: float = sin(ang) * r
			var h: float = _terrain.surface_height(px, pz)
			if not is_nan(h) and h > sea + 25.0:
				candidates.append({"pos": Vector3(px, h, pz), "h": h})
	candidates.sort_custom(func(a, b): return float(a["h"]) > float(b["h"]))
	_springs.clear()
	for i in range(mini(4, candidates.size())):
		_springs.append(candidates[i]["pos"])
	_springs_seeded = true


# Feed the WATER material from persistent SPRINGS only (real groundwater sources on high ground so
# rivers sustain downhill). Rain is NOT injected here anymore — precipitation emerges from the
# field's own vapor/condensation cycle. Cheap — the CA is throttled internally.
func _feed_water() -> void:
	if _material == null:
		return
	if _springs_seeded and _material.has_method("add_source"):
		var dt: float = get_process_delta_time()
		for p in _springs:
			_material.add_source(p, SPRING_RATE * dt)


func _kind_color(kind: String) -> Color:
	match kind:
		"plant": return Color(0.35, 0.85, 0.3)
		"tree": return Color(0.2, 0.6, 0.25)
		"rabbit": return Color(0.92, 0.92, 0.95)
		"fox": return Color(0.95, 0.5, 0.15)
		"bird": return Color(0.3, 0.6, 0.95)
		"villager": return Color(0.75, 0.5, 0.9)
		"fish": return Color(0.55, 0.72, 0.86)
		"meteor": return Color(1.0, 0.5, 0.2)
		"volcano": return Color(0.95, 0.42, 0.12)
		"lightning": return Color(0.82, 0.88, 1.0)
		"earthquake": return Color(0.55, 0.40, 0.28)
		"flood": return Color(0.30, 0.55, 0.90)
		_: return Color(0.8, 0.9, 0.6)


# Brief upward sparkle at a spawn point — instant "it worked" feedback.
func _spawn_puff(pos: Vector3, tint: Color) -> void:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 28
	p.lifetime = 1.1
	p.explosiveness = 0.85
	p.global_position = pos + Vector3(0, 0.4, 0)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)
	var qmat: StandardMaterial3D = StandardMaterial3D.new()
	qmat.albedo_color = tint
	qmat.emission_enabled = true
	qmat.emission = tint
	qmat.emission_energy_multiplier = 3.0
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = qmat
	p.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.6
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 2.5
	pm.initial_velocity_max = 5.0
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.color = tint
	p.process_material = pm
	add_child(p)
	var t: SceneTreeTimer = get_tree().create_timer(1.6)
	t.timeout.connect(func(): if is_instance_valid(p): p.queue_free())


func _make_selection_ring() -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.2
	mi.mesh = torus
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.92, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.1)
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	return mi


func _capture_screenshot(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d" % [path, img.get_width(), img.get_height()])
