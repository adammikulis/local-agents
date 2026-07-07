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
const SkyCycleScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSkyCycle.gd")
const StreamerHostScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelStreamerHost.gd")

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6, "vulture": 5}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7

var _terrain                # LAVoxelTerrainService
var _camera: Camera3D
var _ecology: Node          # LAEcologyService
var _hud: CanvasLayer       # LASpawnPaletteHud
var _debug_panel: CanvasLayer   # LADebugPanel (left-docked debug menu)
var _debug_overlay: Node3D      # LADebugOverlay (world-space highlight/path/wind gizmos)
var _sky: Node = null           # LAVoxelSkyCycle — owns ALL sky/sun/moon/environment + day/night clock
var _streamer_host: Node = null # LAVoxelStreamerHost — owns the streamer overlay/avatar/voice/director
var _streamer_enabled: bool = true        # --no-streamer (or env LA_NO_STREAMER) skips the local-LLM overlay
var _streamer_persona: String = "hype"   # cmdline seed for the streamer; override with --streamer-persona=<id>
var _streamer_avatar_flavor: String = "male"   # cmdline seed: "male" | "female"; override with --streamer-avatar=
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

# --- Day/night cycle owned by LAVoxelSkyCycle (see _sky). VoxelWorld only seeds the clocks from the
# command line; the sky controller owns ALL sky lighting so the cycle and weather never fight over the
# same properties. time_of_day: 0=midnight, .25=dawn, .5=noon, .75=dusk.
var _time_of_day: float = 0.30              # cmdline seed only (override with --time=); the live clock lives in _sky
var _lunar_phase: float = 0.15              # cmdline seed only (override with --lunar=); 0=new .5=full

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
var _peak_slump: int = 0                    # most loose-sediment cells slumping at once (landslide diagnostic)
var _auto_meteor: bool = false
var _overview: bool = false             # --overview: frame a wide whole-island vista (screenshot aid)
var _farview: bool = false              # --farview: pull the vista out to max zoom (ocean-coverage test)
var _rain_force: bool = false           # --rain: force the rain visual on (verification aid)
var _debug_demo: bool = false
var _wind_view: bool = false            # --wind-view: enable ONLY the emergent wind-arrow overlay (funneling/fronts)
var _user_shot_counter: int = 0        # numbers the screenshots the DebugPanel's save button writes
var _auto_volcano: bool = false
var _auto_volcano_fired: bool = false
var _auto_lightning: bool = false
var _auto_lightning_fired: bool = false
var _auto_meteor_fired: bool = false
var _auto_select: bool = false
var _auto_select_done: bool = false
var _auto_tornado: bool = false
var _auto_thunderstorm: bool = false
var _auto_hurricane: bool = false
var _auto_storm_fired: bool = false
var _frame: int = 0
# Rolling FPS probe: averages the last N frames so a windowed --shoot run reports a
# stable perf number instead of the noisy single-frame counter (which swings with sim
# growth). Printed as FPS_AVG= alongside SHOT_SAVED.
var _fps_accum: float = 0.0
var _fps_count: int = 0
var _gpu_ms_accum: float = 0.0    # isolated GPU render time — independent of CPU sim load
const FPS_PROBE_FRAMES: int = 150


func _ready() -> void:
	_parse_cmdline()

	# Non-interactive verification/screenshot runs (--run-frames / --shoot) shove the OS window WAY
	# off-screen the instant we start, so agent/CI runs that render on a real display path never pop a
	# visible window in front of the user (rendering + --shoot capture still work off-screen on macOS).
	# Real interactive play (neither flag) is untouched. Env LA_OFFSCREEN forces it too.
	if (_run_frames > 0 or _shoot_path != "" or OS.has_environment("LA_OFFSCREEN")) and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_position(Vector2i(-8000, -8000))

	# --- Sun + sky + day/night: owned by LAVoxelSkyCycle. It builds the sky shader material, the
	# WorldEnvironment (tonemap/SSAO/glow/fog/ambient), the sun (PSSM cascade-blend shadows) and the
	# moon, and runs the day/night clock each frame. The cmdline-seeded clocks are threaded in here. ---
	_sky = SkyCycleScript.new()
	_sky.name = "SkyCycle"
	add_child(_sky)
	_sky.setup(self, _time_of_day, _lunar_phase)

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
	# ALL audio starts OFF: every aspect (Music/SFX/Voice/UI) is muted at its bus, and their director
	# synthesis flags are off, so nothing plays or is generated. The player unmutes / sets levels per
	# aspect in the audio-menu mixer. Master stays live as the global row (unmute one aspect to hear it).
	_audio.set_enabled(true)
	_audio.set_music_enabled(false)
	_audio.set_sfx_enabled(false)
	for muted_bus in ["Music", "Sfx", "Voice", "Ui"]:
		var mbi: int = AudioServer.get_bus_index(muted_bus)
		if mbi >= 0:
			AudioServer.set_bus_mute(mbi, true)
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
	_weather.setup(_camera, _sky.sun(), _sky.env())

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
	_material.set_sun(_sky.sun())
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

	# The sky cycle reads these each frame (rain/cloud dimming + cloud/fog sheet tinting); bind them now
	# that they exist. Order-independent — the cycle only touches them from its per-frame update().
	_sky.bind_scene(_weather, _material, _clouds, _fog)

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
	elif _wind_view:
		# Wind-field verification: ONLY the emergent wind-arrow overlay (clean shot of funneling/fronts).
		_debug_overlay.set_wind(true)

	# --- Streamer / commentator (lower-right face-cam driven by the local LLM) ---
	# Skipped with --no-streamer (or env LA_NO_STREAMER) so a run doesn't spin up the local LLM /
	# TTS — faster startup + lighter frame for perf testing and headless/CI.
	if _streamer_enabled and not OS.has_environment("LA_NO_STREAMER"):
		_streamer_host = StreamerHostScript.new()
		_streamer_host.name = "StreamerHost"
		add_child(_streamer_host)
		_streamer_host.setup(self, _ecology, _material, _streamer_persona, _streamer_avatar_flavor)

	# --- Interaction / spawn brush / disasters controllers ---
	# The root stays a thin composition + harness root; these own input, placement, and disaster casts.
	# Order: disasters first (the brush casts through it), then the brush, then interaction (routes input
	# to the brush and holds the selection ring). Interaction defines _unhandled_input so Godot routes
	# input straight to it.
	_disasters = DisastersScript.new()
	_disasters.name = "Disasters"
	add_child(_disasters)
	_disasters.setup(self, _terrain, _ecology, _actors_root, _camera, _audio)
	# Lightning is now EMERGENT: the field's charge process fires a bolt where a convective updraft breaks
	# down, injecting the heat pulse + scare itself, and calls back here for the VISUAL/audio bolt only.
	if _material != null and _material.has_method("set_lightning_visual"):
		_material.set_lightning_visual(Callable(_disasters, "spawn_lightning"))
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
			if _debug_overlay != null:
				_debug_overlay.set_scent(on)


func _on_debug_highlight(group: String, on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_highlight(group, on)


func _on_debug_paths(on: bool) -> void:
	if _debug_overlay != null:
		_debug_overlay.set_paths(on)


func _on_debug_perf(key: String, on: bool) -> void:
	match key:
		"shadows":
			if _sky != null:
				_sky.set_shadows(on)
		"ssao":
			if _sky != null:
				_sky.set_ssao(on)


# Save-screenshot button (DebugPanel): capture the current viewport to a numbered PNG in the project
# folder and report the absolute path so it's easy to find.
func _on_debug_screenshot() -> void:
	_user_shot_counter += 1
	var path: String = ProjectSettings.globalize_path("res://volcano_shot_%d.png" % _user_shot_counter)
	_capture_screenshot(path)
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Saved screenshot → %s" % path)


	# Anti-aliasing: the low-poly terrain/actors have hard silhouettes that crawl and
	# alias badly. MSAA 2x cleans the geometry edges. The scene is CPU-bound (see the
	# perf-probe notes) so this GPU-side smoothing is effectively free here.
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.msaa_3d = Viewport.MSAA_2X

	# Enable per-viewport GPU render-time measurement so the perf probe can report the
	# rendering cost isolated from the (highly variable) CPU sim load.
	if _shoot_path != "":
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


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
		elif arg == "--wind-view":
			_wind_view = true
		elif arg == "--auto-meteor":
			_auto_meteor = true
		elif arg == "--auto-volcano":
			_auto_volcano = true
		elif arg == "--no-streamer":
			_streamer_enabled = false
		elif arg.begins_with("--streamer-persona="):
			_streamer_persona = arg.substr("--streamer-persona=".length())
		elif arg.begins_with("--streamer-avatar="):
			_streamer_avatar_flavor = arg.substr("--streamer-avatar=".length())
		elif arg == "--auto-lightning":
			_auto_lightning = true
		elif arg == "--auto-select":
			_auto_select = true
		elif arg == "--auto-tornado":
			_auto_tornado = true
		elif arg == "--auto-thunderstorm":
			_auto_thunderstorm = true
		elif arg == "--auto-hurricane":
			_auto_hurricane = true
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
	_sky.update(delta)
	# Share the sky clock with the ecology so nocturnal behavior can key off night (kept out of the
	# sky controller so the cycle stays decoupled from ecology).
	if _ecology != null and _ecology.has_method("set_time_of_day"):
		_ecology.set_time_of_day(_sky.time_of_day())
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
	# Landslide diagnostic: track the most sediment cells slumping at once (throttled — the count is a full
	# grid scan). Always sampled so a meteor/volcano/earthquake slump is visible without --cognition-stats.
	if _spawned_initial and _frame % 10 == 0 and _material != null and _material.has_method("slump_count"):
		_peak_slump = maxi(_peak_slump, _material.slump_count())

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

	# Lightning is no longer keyed off a rain probe — it EMERGES from the field's charge process (charge
	# builds in convective updrafts and breaks down to a bolt), which fires the visual via set_lightning_visual().

	# Auto-lightning demo/test: strike the nearest tree so a wildfire emerges from the bolt's heat.
	if _auto_lightning and not _auto_lightning_fired and _spawned_initial:
		var ltrigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame >= ltrigger:
			_disasters.fire_test_lightning()
			_auto_lightning_fired = true

	# Auto-storm demos/tests: touch down a tornado / seed a thunderstorm / spin up a hurricane so the
	# harness can confirm each storm's emergent behaviour. Fired once, a bit before the summary/shot.
	if (_auto_tornado or _auto_thunderstorm or _auto_hurricane) and not _auto_storm_fired and _spawned_initial:
		var strigger: int = (_shoot_frames - 200) if _shoot_path != "" else maxi(_run_frames - 400, 40)
		if _frame >= strigger:
			_auto_storm_fired = true
			var kind: String = "hurricane" if _auto_hurricane else ("thunderstorm" if _auto_thunderstorm else "tornado")
			var focus: Vector3 = _disasters.fire_auto_storm(kind)
			if _camera != null and _camera.has_method("frame_vista"):
				_camera.frame_vista(focus)

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

	# Accumulate FPS over the final window before the screenshot for a stable perf reading.
	if _shoot_path != "" and _frame > _shoot_frames - FPS_PROBE_FRAMES and _frame <= _shoot_frames:
		_fps_accum += Engine.get_frames_per_second()
		_gpu_ms_accum += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		_fps_count += 1

	if _shoot_path != "" and _frame == _shoot_frames:
		var avg_fps: float = _fps_accum / maxf(1.0, float(_fps_count))
		var avg_gpu: float = _gpu_ms_accum / maxf(1.0, float(_fps_count))
		print("FPS_AVG=%.1f GPU_MS=%.3f frames=%d entities=%d" % [avg_fps, avg_gpu, _fps_count, _actors_root.get_child_count()])
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
		"time_of_day": _sky.time_of_day() if _sky != null else _time_of_day,
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


# V key (from the interaction controller): toggle the emergent scent-field debug gizmos (DebugOverlay).
func toggle_scent_view() -> void:
	_scent_visible = not _scent_visible
	if _debug_overlay != null:
		_debug_overlay.set_scent(_scent_visible)
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
	# Feed the emergent wind field its prevailing (large-scale) input; local circulation emerges on top.
	# Scent now rides this same wind INSIDE the field (LAMaterialScent3D advects on _vel_*) — no external
	# scent wiring needed; it washes in rain via the field's precipitation() for free.
	if _material != null and _material.has_method("set_wind"):
		if _force_wind != 0.0:
			_material.set_wind(Vector2(_force_wind, 0.0))
		else:
			var w: Vector3 = _weather.wind_vector()
			_material.set_wind(Vector2(w.x, w.z))


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
