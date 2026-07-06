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
const AudioDirectorScript: GDScript = preload("res://addons/local_agents/audio/AudioDirector.gd")
const InteractionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelInteraction.gd")
const SpawnBrushScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSpawnBrush.gd")
const DisastersScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelDisasters.gd")
const WeatherScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/WeatherSystem.gd")
const OceanPlaneScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/OceanPlane.gd")
const MaterialField3DScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const CloudLayerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/CloudLayer.gd")
const RainLayerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/RainLayer.gd")
const DebugPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugPanel.gd")
const DebugOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugOverlay.gd")
const StreamerOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerOverlay.gd")
const StreamerAvatarScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerAvatar.gd")
const StreamerVoiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerVoice.gd")
const StreamerDirectorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerDirector.gd")
const EnergyGraphScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/SceneEnergyGraph.gd")

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6, "vulture": 5}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7

var _terrain                # LAVoxelTerrainService
var _camera: Camera3D
var _ecology: Node          # LAEcologyService
var _hud: CanvasLayer       # LASpawnPaletteHud
var _debug_panel: CanvasLayer   # LADebugPanel (left-docked debug menu)
var _debug_overlay: Node3D      # LADebugOverlay (world-space highlight/path/wind gizmos)
var _streamer_overlay: CanvasLayer  # LAStreamerOverlay (lower-right face-cam + caption + toggle)
var _streamer_director: Node        # LAStreamerDirector (LLM commentary brain)
var _streamer_avatar: Node          # LAStreamerAvatar (live SubViewport portrait)
var _streamer_voice: Node           # LAStreamerVoice (Piper TTS)
var _energy_graph: Control          # LASceneEnergyGraph (live total-energy overlay + intensity source)
var _streamer_persona: String = "hype"   # default personality; override with --streamer-persona=<id>
var _streamer_avatar_flavor: String = "male"   # "male" | "female"; override with --streamer-avatar=
var _actors_root: Node3D
var _interaction: Node3D = null   # LAVoxelInteraction — input, selection, the player's hand
var _brush: Node3D = null         # LAVoxelSpawnBrush — radius spawn brush + placement
var _disasters: Node = null       # LAVoxelDisasters — volcano/lightning/meteor casts
var _weather: Node = null   # LAWeatherSystem (visual rain/wind for now; being made emergent)
var _material: Node = null   # LAMaterialField — the ONE substrate: terrain-coupled water + heat/air
var _ocean: Node = null      # LAOceanPlane — the calm sea drawn as one GPU plane (CA meshes only waves)
var _clouds: Node = null     # LACloudLayer rendering the field's cloud density (aloft)
var _fog: Node = null        # LACloudLayer rendering the field's fog density (ground-hugging)
var _rain: Node = null       # LARainLayer — GPU rain particles where the field precipitates (emergent)

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
var _rain_force: bool = false           # --rain: force the rain visual on (verification aid)
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

	# --- HUD ---
	_hud = HudScript.new()
	_hud.name = "HUD"
	add_child(_hud)
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

	# --- The ONE material field: the dense 3D GPU substrate. A real volume — every material (temp, water,
	# vapor/cloud/fog, lava) lives in the same GPU-resident buffers and every rule is a pass in one
	# pipeline, so fluids interact with the 3D caves (water pools in caverns, lava drains into tubes,
	# plumes rise shafts). It lazily samples rock/void as the terrain streams and self-activates. This
	# REPLACES the retired 2.5D field wholesale. ---
	_material = MaterialField3DScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# 8-unit cells over the island's Y span (~130k cells); the whole heat+water+atmosphere+lava step runs
	# on the GPU (resident SSBOs, one readback/frame). Headless falls back to the CPU oracle.
	var sea3d: float = _terrain.sea_level() if _terrain.has_method("sea_level") else 0.0
	_material.setup(_terrain, 300.0, 8.0, -80.0, 90.0, sea3d)
	# The field reads the REAL sun (DirectionalLight3D) live — its energy + angle drive all heating.
	# Wind/pressure/rain are NOT injected; they emerge from the field's own physics.
	_material.set_sun(_sun)
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)
	# Weather relays the field's EMERGENT rain (no invented rain of its own) — wire the field to it.
	if _weather != null and _weather.has_method("set_field"):
		_weather.set_field(_material)

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

	# Rain VISUAL — GPU streak particles that fall only where the field's clouds are dense enough to
	# precipitate (emergent from the vapor→cloud→rain cycle, gated by cloud density at the camera).
	_rain = RainLayerScript.new()
	add_child(_rain)
	_rain.setup(_material, _camera)
	if _rain_force and _rain.has_method("set_force"):
		_rain.set_force(true)

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

	_setup_streamer()

	# --- Interaction / spawn brush / disasters controllers ---
	# The root stays a thin composition + harness root; these own input, placement, and disaster casts.
	# Order: disasters first (the brush casts through it), then the brush, then interaction (routes input
	# to the brush and holds the selection ring). Interaction defines _unhandled_input so Godot routes
	# input straight to it.
	_disasters = DisastersScript.new()
	_disasters.name = "Disasters"
	add_child(_disasters)
	_disasters.setup(self, _terrain, _ecology, _actors_root, _camera, _audio)
	_brush = SpawnBrushScript.new()
	_brush.name = "SpawnBrush"
	add_child(_brush)
	_brush.setup(self, _terrain, _camera, _ecology, _hud, _audio, _actors_root, _disasters)
	_interaction = InteractionScript.new()
	_interaction.name = "Interaction"
	add_child(_interaction)
	_interaction.setup(self, _terrain, _camera, _ecology, _hud, _audio, _brush)
	if _hud.has_signal("spawn_selected"):
		_hud.spawn_selected.connect(_interaction.on_spawn_selected)


# --- Streamer / commentator (lower-right face-cam driven by the local LLM) ----

func _setup_streamer() -> void:
	# Overlay first (a CanvasLayer), then the live avatar parented under it so its SubViewport draws.
	_streamer_overlay = StreamerOverlayScript.new()
	_streamer_overlay.name = "StreamerOverlay"
	add_child(_streamer_overlay)

	_streamer_avatar = StreamerAvatarScript.new()
	_streamer_avatar.name = "StreamerAvatar"
	_streamer_overlay.add_child(_streamer_avatar)
	_streamer_avatar.setup(_streamer_avatar_flavor)
	_streamer_overlay.bind_avatar(_streamer_avatar)

	_streamer_voice = StreamerVoiceScript.new()
	_streamer_voice.name = "StreamerVoice"
	add_child(_streamer_voice)
	_streamer_voice.setup({"gender": _streamer_avatar_flavor})

	_streamer_director = StreamerDirectorScript.new()
	_streamer_director.name = "StreamerDirector"
	add_child(_streamer_director)
	_streamer_director.setup(self, {"voice": _streamer_voice, "persona": _streamer_persona})

	# Live scene-energy graph (kinetic + seismic + thermal) shown top-right — the intensity signal the
	# director reacts to, made visible. The director reads its current total so quips fire on real energy.
	_energy_graph = EnergyGraphScript.new()
	_streamer_overlay.add_child(_energy_graph)
	_energy_graph.setup(self, _ecology, _material)
	if _streamer_director.has_method("set_energy_source"):
		_streamer_director.set_energy_source(_energy_graph)

	# Wire the loop: director -> caption + speech; UI toggle/persona -> director; speech -> avatar mouth.
	_streamer_director.line_ready.connect(_on_streamer_line)
	_streamer_director.status_changed.connect(_streamer_overlay.set_status)
	_streamer_overlay.enabled_toggled.connect(_on_streamer_enabled)
	_streamer_overlay.persona_selected.connect(_streamer_director.set_persona)
	_streamer_voice.speaking_started.connect(_on_streamer_speaking_started)
	_streamer_voice.speaking_finished.connect(_on_streamer_speaking_finished)
	_streamer_overlay.avatar_selected.connect(_on_streamer_avatar_selected)
	_streamer_overlay.set_default_persona(_streamer_persona)
	_streamer_overlay.set_default_avatar(_streamer_avatar_flavor)


# Swap the streamer between male/female: rebuild the avatar body + switch the TTS voice live.
func _on_streamer_avatar_selected(flavor: String) -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_flavor"):
		_streamer_avatar.set_flavor(flavor)
	if _streamer_voice != null and _streamer_voice.has_method("set_gender"):
		_streamer_voice.set_gender(flavor)


func _on_streamer_line(text: String) -> void:
	if _streamer_overlay != null:
		_streamer_overlay.show_line(text)
	if _streamer_voice != null:
		_streamer_voice.speak(text)
	print("STREAMER_LINE=%s" % text)


func _on_streamer_enabled(on: bool) -> void:
	if _streamer_director != null:
		_streamer_director.set_enabled(on)
	if _streamer_voice != null:
		_streamer_voice.set_enabled(on)


func _on_streamer_speaking_started(_text: String) -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_talking"):
		_streamer_avatar.set_talking(true)


func _on_streamer_speaking_finished() -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_talking"):
		_streamer_avatar.set_talking(false)


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
		elif arg.begins_with("--streamer-persona="):
			_streamer_persona = arg.substr("--streamer-persona=".length())
		elif arg.begins_with("--streamer-avatar="):
			_streamer_avatar_flavor = arg.substr("--streamer-avatar=".length())
		elif arg == "--auto-lightning":
			_auto_lightning = true
		elif arg == "--auto-select":
			_auto_select = true
		elif arg == "--overview":
			_overview = true
		elif arg == "--farview":
			_overview = true
			_farview = true
		elif arg == "--rain":
			_rain_force = true
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
				_disasters.spawn_default_volcano()
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
	_interaction.update_hand(delta)
	_interaction.update_selection_ring()
	_brush.update_brush_ring()
	_push_environment()
	_feed_water()
	if _cognition_stats and _spawned_initial and _frame % 15 == 0:
		_sample_behaviour_peaks()

	# Auto-meteor demo/test: drop a meteor on a forest so it carves a crater, topples trees,
	# and ignites a wildfire. Works in both screenshot mode and headless run-frames mode.
	if _auto_meteor and not _auto_meteor_fired and _spawned_initial:
		var trigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame == trigger:
			_disasters.fire_test_meteor()

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
				var vc: Node = _disasters.spawn_volcano(Vector3(20.0, oh, 20.0))
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
			_disasters.strike_random_lightning()

	# Auto-lightning demo/test: strike the nearest tree so a wildfire emerges from the bolt's heat.
	if _auto_lightning and not _auto_lightning_fired and _spawned_initial:
		var ltrigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame >= ltrigger:
			_disasters.fire_test_lightning()
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
			_interaction.select_at(get_viewport().get_visible_rect().size * 0.5)
			var sel: Node = _interaction.selected()
			var title: String = ""
			if sel != null:
				title = String(sel.call("get_inspector_payload").get("title", ""))
			print("SELECT_RESULT selected=", sel != null, " ring_visible=", _interaction.selection_ring_visible(), " title=", title)
		_auto_select_done = true

	if _shoot_path != "" and _frame == _shoot_frames:
		_capture_screenshot(_shoot_path)
		get_tree().quit(0)

	if _run_frames > 0 and _frame == _run_frames:
		LAVoxelHarness.emit_smoke_summary(self)


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


func _on_music_auto_adapt_changed(on: bool) -> void:
	_music_auto_adapt = on
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Music auto-adapt: %s" % ("ON" if on else "off — manual control"))


# --- controller callbacks: the interaction/brush/disasters controllers forward the few bits of
# root-owned state (music mood, harness flags, debug view toggles) back through these. ---

# Spike the music's destruction mood (meteors/volcanoes/lightning). Decays each frame in _update_music_mood.
func set_destruction(intensity: float) -> void:
	_music_destruction = intensity


# The disasters controller fired the one-shot auto-meteor test; latch it so _process won't refire.
func mark_auto_meteor_fired() -> void:
	_auto_meteor_fired = true


# V key (from the interaction controller): toggle the scent field's debug view.
func toggle_scent_view() -> void:
	_scent_visible = not _scent_visible
	var sf = _ecology.scent_field() if _ecology != null and _ecology.has_method("scent_field") else null
	if sf != null and sf.has_method("set_scent_visible"):
		sf.set_scent_visible(_scent_visible)
	_hud.set_status("Scent view: %s" % ("ON" if _scent_visible else "off"))


# T key (from the interaction controller): toggle the terrain temperature heatmap debug view.
func toggle_temp_view() -> void:
	_temp_debug_visible = not _temp_debug_visible
	if _terrain != null and _terrain.has_method("set_shader_param"):
		_terrain.set_shader_param("heat_debug", 1.0 if _temp_debug_visible else 0.0)
	_hud.set_status("Temperature view: %s" % ("ON" if _temp_debug_visible else "off"))


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


# Sync the terrain shader's beach/snow bands to the island's sea level and register a few high interior
# peaks as PERSISTENT springs on the field (the 3D field injects them itself each step) so rivers run
# downhill to the coast and drain into the ocean (continuous water). One-shot.
func _seed_water() -> void:
	if _material == null or _terrain == null:
		return
	# The terrain was shaped around a fixed sea level (the field already has it from setup); sync the shader.
	var sea: float = _terrain.sea_level() if _terrain.has_method("sea_level") else 0.0
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
	# Register each spring ONCE as a persistent source; the 3D field injects it internally every step
	# (modest headwaters — streams/ponds, not a flooded interior).
	if _material.has_method("add_source"):
		for p in _springs:
			_material.add_source(p, 0.8)
	_springs_seeded = true


# Springs are registered ONCE with the 3D field (see _seed_water) and injected internally each step, so
# there is nothing to feed per-frame. Kept as a no-op for the _process call site.
func _feed_water() -> void:
	pass


func _capture_screenshot(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d" % [path, img.get_width(), img.get_height()])
