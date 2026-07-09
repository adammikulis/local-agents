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
const WaterParticlesScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/WaterParticles.gd")
const DebugPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugPanel.gd")
const DebugOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DebugOverlay.gd")
const SkyCycleScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSkyCycle.gd")
const StreamerHostScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelStreamerHost.gd")
const StarScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/Star.gd")
const PlanetBodyScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/PlanetBody.gd")
const SphereGridScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")

# --- SOLAR-SYSTEM-FIRST: the world is a star + planet body (see TODO). Radial is the default; flat retired. ---
const PLANET_RADIUS: float = 250.0
const PLANET_RELIEF: float = 16.0
const PLANET_FEATURE: float = 78.0
# Sea sits INSIDE the relief band (surface radius spans ~radius±relief) so low ground floods and high
# ground stays dry — a real coastline. Just below the mean radius → a bit more land than sea.
const PLANET_SEA_RADIUS: float = 248.0
const STAR_POSITION: Vector3 = Vector3(900.0, 320.0, 620.0)
const PLANET_SPIN_RATE: float = 0.10        # rad/s axial spin (~1 rotation / 63s) — day/night sweep
const PLANET_SPIN_AXIS: Vector3 = Vector3(0.15, 1.0, 0.0)   # slightly tilted (obliquity); normalized at use

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6, "vulture": 5}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7

var _star: Node3D = null    # LAStar — positioned light + gravity + solar driver
var _body: Node3D = null    # LAPlanetBody — the one planet (owns terrain + actors in its local frame)
var _terrain                # LAVoxelTerrainService (from _body.terrain())
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
var _water: Node = null      # LAWaterParticles — the ONE field-driven atmosphere visual (cloud/fog/rain/snow)

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
# Transient emergent behaviours (circling/leaders/followers/…) are sampled into SimReport gauges, which track
# their running max, so the report shows the PEAK each reached — not just the final-frame value.
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
# --auto-seavolcano: the CAPSTONE. Seed a volcano on the SEABED and let its sustained lava supply build a new
# ISLAND emergently (eruption -> underwater quench -> solidify -> SDF growth -> breach). Prints SEAVOLCANO={...}
# proof (vent surface radius vs sea radius, rock_cells, mineral_total) periodically so a long run shows the rise.
var _auto_seavolcano: bool = false
var _auto_seavolcano_fired: bool = false
var _seavolcano: Node = null
var _seavolcano_vent: Vector3 = Vector3.ZERO
var _auto_lightning: bool = false
var _auto_lightning_fired: bool = false
var _auto_meteor_fired: bool = false
var _auto_select: bool = false
var _auto_select_done: bool = false
var _auto_tornado: bool = false
var _auto_thunderstorm: bool = false
var _auto_hurricane: bool = false
var _auto_storm_fired: bool = false
# --stamp-test: Rock Stage C proof. Deposit rock into a VOID cell just above the surface and confirm the
# rock_fill 0.5-crossing physically GROWS terrain (is_solid flips false->true at the stamp point). Prints
# STAMP_TEST={...} once the grow fires. Temporary verification hook, not gameplay.
var _stamp_test: bool = false
var _stamp_test_deposited: bool = false
var _stamp_test_reported: bool = false
var _stamp_test_target: Vector3 = Vector3.ZERO
var _stamp_test_deposit_frame: int = 0
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
		# Opt-in uncap (LA_UNCAP): drop vsync + the fps limit to see headroom above the monitor refresh.
		# NOT on by default — on macOS Metal an uncapped spin actually contends and reports LOWER than the
		# normal vsync-paced rate, so the vsync-paced number (below the refresh) is the honest playable figure.
		if _run_frames > 0 and OS.has_environment("LA_UNCAP"):
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0

	# --- Sun + sky + day/night: owned by LAVoxelSkyCycle. It builds the sky shader material, the
	# WorldEnvironment (tonemap/SSAO/glow/fog/ambient), the sun (PSSM cascade-blend shadows) and the
	# moon, and runs the day/night clock each frame. The cmdline-seeded clocks are threaded in here. ---
	_sky = SkyCycleScript.new()
	_sky.name = "SkyCycle"
	add_child(_sky)
	_sky.setup(self, _time_of_day, _lunar_phase)

	# --- The star (positioned light + gravity + solar driver) ---
	_star = StarScript.new()
	_star.name = "Star"
	add_child(_star)
	_star.setup({"position": STAR_POSITION, "energy": 1.4})
	# The sky cycle owns the visual sun for now; the star supplies position/gravity/solar math. Hide its own
	# light so they don't double up (wiring the sky's sun to follow the star = the sky/solar fan-out unit).
	if _star.light() != null:
		_star.light().visible = false

	# --- The planet body: one world in a LOCAL frame; owns terrain + actors so they ride its transform.
	# (Native SDF sphere via build_planet. Whole body resident so off-camera edits apply anywhere.) ---
	_body = PlanetBodyScript.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({"radius": PLANET_RADIUS, "relief": PLANET_RELIEF, "feature_size": PLANET_FEATURE,
		"sea_radius": PLANET_SEA_RADIUS, "view_distance": 2000, "seed": 1337})
	_terrain = _body.terrain()
	# PLANETARY SKY: view from space (dark starfield + low ambient) with the sun FIXED shining star->planet;
	# the spinning planet turns under it → a stark star-lit day/night terminator sweeps the surface.
	if _sky.has_method("set_space_mode"):
		_sky.set_space_mode((_body.center() - _star.global_position).normalized())

	# --- Camera + voxel viewer ---
	_camera = CameraRigScript.new()
	_camera.name = "CameraRig"
	add_child(_camera)
	_camera.current = true
	_body.attach_viewer(_camera)
	# Orbit-the-planet camera (radial up, MMB-drag orbit, scroll zoom) framing the body from space.
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(_body.center(), _body.radius())

	# --- Actors + ecology (actors live UNDER the body so they ride its frame) ---
	_actors_root = _body.actors_root
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
	# CUBED-SPHERE field (Phase B): a SphereGrid shell enclosing the planet (crust + atmosphere), gathered via
	# the neighbour table with radial gravity. ~123K cells (res 32/face × depth 20 × 6). Down = inward-radial.
	var sea3d: float = _body.sea_radius()
	var field_grid: RefCounted = SphereGridScript.new()
	field_grid.build(32, 20, 170.0, 8.0, _body.center())   # core_radius 170, cell 8 → shell 170..330
	_material.setup_sphere(field_grid, _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()                        # fill the solid mask from the terrain SDF
	LASimReport.register(Callable(_material, "report"))   # field channel aggregates flow into SIM_REPORT
	LASimReport.register(func() -> Dictionary: return LASimReportSources.population(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.cognition(self))
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
	# Planet: a finite spherical sea SHELL at sea_radius. Flat: the camera-following horizontal plane.
	if _terrain.is_planet():
		_ocean.setup_sphere(_body.center(), _body.sea_radius())
	else:
		_ocean.setup(_terrain.sea_level(), _camera)

	# The field's emergent condensate, rendered as ONE GPU particle system: cloud / fog / rain / snow, the
	# phase a per-particle property classified from the field's baked cover texture (sampled per particle by
	# normalize(pos - center)). This is the FIRST real planet atmosphere visual — it dissolves the dead flat
	# CloudLayer sheets + the RainLayer box, emits through the atmosphere shell, and drifts slowly on the sky.
	_water = WaterParticlesScript.new()
	add_child(_water)
	_water.setup(_material, _camera, _sky.sun(), _body.center(), _body.sea_radius())

	# The sky cycle reads the field each frame (cloud-cover dimming) + pushes the day/night colour tint to
	# the water-particle renderer. Order-independent — the cycle only touches them from its per-frame update().
	_sky.bind_scene(_weather, _material, _water)

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
		elif arg == "--auto-seavolcano":
			_auto_seavolcano = true
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
		elif arg == "--stamp-test":
			_stamp_test = true


func _process(delta: float) -> void:
	_frame += 1
	# Track the physics-tick cost every frame so SimReport's max = the heavy STEP-FRAME spike (compare to
	# field_ms: physics_ms − field_ms is the non-field "other" we're hunting).
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_sky.update(delta)
	# Share the sky clock with the ecology so nocturnal behavior can key off night (kept out of the
	# sky controller so the cycle stays decoupled from ecology).
	if _ecology != null and _ecology.has_method("set_time_of_day"):
		_ecology.set_time_of_day(_sky.time_of_day())
	_update_music_mood()
	# Planet axial SPIN — the body (its terrain + actors are children) turns as ONE moving frame while the
	# camera stays in the system frame, so day/night sweeps across the surface. Starts after life is placed so
	# spawn stays deterministic. THE moving-frame validation: everything on the body must ride it.
	# FROZEN during the seabed-volcano capstone: the MaterialField grid is world-fixed, so a long accretion under
	# a spinning terrain would SMEAR the growing cone into an arc (the field's rock_fill and the terrain SDF drift
	# apart as the body turns). Freezing the spin for the --auto-seavolcano demo keeps the field and terrain aligned
	# so the island piles at exactly ONE spot. (Contract-sanctioned option; costs only the day/night sweep.)
	if _body != null and _spawned_initial and _terrain.is_planet() and not _auto_seavolcano:
		_body.rotate(PLANET_SPIN_AXIS.normalized(), PLANET_SPIN_RATE * delta)
	# Spawn the starting ecology once terrain has streamed + collided at the surface.
	if not _spawned_initial and _body != null:
		# Gate on the surface being meshed. On a planet, "ready" = the top-of-planet patch has collided.
		var ready_probe: Vector3 = _body.center() + Vector3.UP * (_body.radius() + 30.0)
		if _body.is_ready_at(ready_probe):
			_ready_wait_ticks += 1
			if _ready_wait_ticks > 6:
				LASimReport.reset()
				if _terrain.is_planet():
					# Radial world: ecology places life ON the sphere (surface_point spawn), fish in the sea
					# shell; the orbit camera frames the body. Still-flat steps (caves, flat sea seeding,
					# scripted volcano) are skipped pending their radial versions (Phase B field / Phase C).
					_ecology.spawn_initial(INITIAL_COUNTS)
					_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
					if _ecology.has_method("stock_initial_aquatic"):
						_ecology.stock_initial_aquatic()
					if _camera.has_method("set_orbit_target"):
						_camera.set_orbit_target(_body.center(), _body.radius())
					# Magma CORE: pin the planet's centre hot → radial geothermal gradient. Interim seed on the
					# box grid; Phase B's cubed-sphere field makes this the innermost radial layers natively.
					if _material.has_method("add_magma_source"):
						_material.add_magma_source(_body.center(), 1300.0, 0.6)
				else:
					if _terrain.has_method("carve_caves"):
						_terrain.carve_caves(1337)
					_ecology.spawn_initial(INITIAL_COUNTS)
					_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
					_seed_water()
					if _ecology.has_method("stock_initial_aquatic"):
						_ecology.stock_initial_aquatic()
					_disasters.spawn_default_volcano()
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
	if _spawned_initial and _frame % 15 == 0:
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

	# CAPSTONE — auto-seavolcano: seed a SEABED vent EARLY so the sustained supply has a long window to build a
	# new island underwater and breach the surface. Frame the camera on the SEA SURFACE above the vent so the
	# before/after shots show open sea becoming land. The island is 100% emergent (quench+solidify+SDF growth).
	if _auto_seavolcano and not _auto_seavolcano_fired and _spawned_initial and _frame >= 120:
		var sun_dir: Vector3 = (_star.global_position - _body.center()).normalized() if _star != null else Vector3.UP
		var sv: Array = _disasters.spawn_sea_volcano(sun_dir)
		_seavolcano = sv[0]
		_seavolcano_vent = sv[1]
		if _seavolcano != null and _camera != null:
			# A lit close-up: sit on the sunward side, above the sea surface over the vent, looking down at where the
			# island emerges. Orbit-mode _process won't override a manual transform, so this framing holds.
			var vdir: Vector3 = (_seavolcano_vent - _body.center()).normalized()
			var sea_pt: Vector3 = _body.center() + vdir * (_terrain.sea_radius() + 2.0)
			var cam_pos: Vector3 = sea_pt + sun_dir * 46.0 + vdir * 30.0
			_camera.global_position = cam_pos
			_camera.look_at(sea_pt, vdir)
		_auto_seavolcano_fired = true
		var floor_r: float = (_seavolcano_vent - _body.center()).length() if _seavolcano != null else 0.0
		print("SEAVOLCANO_SEED={vent:%v, floor_r:%.1f, sea_r:%.1f}" % [_seavolcano_vent, floor_r, _terrain.sea_radius()])
	# Periodic island-growth proof: the vent column's surface radius rising toward/above sea_radius IS the
	# emergent island. Cheap (one raycast + the running supply ledger).
	if _auto_seavolcano and _seavolcano != null and _frame % 150 == 0:
		var vd: Vector3 = (_seavolcano.global_position - _body.center()).normalized()
		var vr: float = _terrain.surface_radius(vd)
		var sea_r2: float = _terrain.sea_radius()
		print("SEAVOLCANO={frame:%d, vent_r:%.2f, sea_r:%.2f, above_sea:%s, supplied:%.0f}" % [
			_frame, (vr if not is_nan(vr) else -1.0), sea_r2,
			str((not is_nan(vr)) and vr > sea_r2), _seavolcano.total_supplied])

	# Rock Stage C proof: deposit rock into a VOID cell ~3 units above the top surface, then confirm the
	# rock_fill 0.5-crossing GROWS terrain (is_solid flips false->true at the stamp point, captured
	# same-frame inside the stamp so the planet's spin can't move the rock away from the query).
	if _stamp_test and _spawned_initial and _material != null:
		if not _stamp_test_deposited and _frame >= 90:
			var sp: Vector3 = _terrain.surface_point(Vector3.UP)
			if not is_nan(sp.x) and _material.get("_stamp") != null:
				_stamp_test_target = sp + (sp - _body.center()).normalized() * 3.0
				_material._stamp.debug_deposit(_stamp_test_target, 1.0)
				_stamp_test_deposited = true
				_stamp_test_deposit_frame = _frame
				print("STAMP_TEST_DEPOSIT={pos:%v, before_solid:%s}" % [_stamp_test_target, str(_terrain.is_solid(_stamp_test_target))])
		elif _stamp_test_deposited and not _stamp_test_reported:
			var st = _material._stamp
			var grew: bool = st != null and st.grows > 0
			# Report the MOMENT the grow fires (captures the same-frame is_solid before/after proof), or a
			# failure marker if none fired within ~250 frames of the deposit.
			if grew or _frame > _stamp_test_deposit_frame + 250:
				print("STAMP_TEST={grew:%s, at_frame:%d, grows:%d, shrinks:%d, before_solid:%s, after_solid:%s, live_is_solid:%s, scan_ms:%.3f}" % [
					str(grew), _frame, (st.grows if st != null else 0), (st.shrinks if st != null else 0),
					str(st.last_grow_before_solid if st != null else false),
					str(st.last_grow_after_solid if st != null else false),
					str(_terrain.is_solid(st.last_grow_pos) if (st != null and grew) else false),
					(st.last_scan_ms if st != null else 0.0)])
				_stamp_test_reported = true

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
	var lead: int = 0
	var foll: int = 0
	var max_depth: int = 0   # deepest leader chain this sample (walk _leader pointers, cap 8 hops)
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
		if bool(c.get("herd")):
			if bool(c.get("_is_leader")):
				lead += 1
			else:
				foll += 1
		var ldr: Variant = c.get("_leader")
		if is_instance_valid(ldr) or bool(c.get("_is_leader")):
			var depth: int = 0
			var node: Variant = c
			while depth < 8:
				var up: Variant = node.get("_leader")
				if not is_instance_valid(up):
					break
				depth += 1
				node = up
			max_depth = maxi(max_depth, depth)
	# Feed these transient emergent behaviours into SimReport as gauges — it tracks their running max, so the
	# report shows the PEAK each occurred at over the run (not just the final frame). Replaces the _peak_* vars.
	LASimReport.gauge("circling", circ)
	LASimReport.gauge("investigating", invs)
	LASimReport.gauge("sleeping", slp)
	LASimReport.gauge("leaders", lead)
	LASimReport.gauge("followers", foll)
	LASimReport.gauge("hierarchy_depth", max_depth)


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
