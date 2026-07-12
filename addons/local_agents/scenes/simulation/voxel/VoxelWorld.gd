extends Node3D
class_name LAVoxelWorld

# From-scratch simulation root built entirely in code on the Zylann godot_voxel GDExtension. This is a THIN
# COMPOSITION ROOT: it instantiates + wires the scene's services and hands each cross-cutting concern to a
# focused controller — sky/sun (LAVoxelSkyController), initial spawning (LAVoxelSpawnController), CLI/demo
# input (LAVoxelInputController), and debug views (LAVoxelDebugWiring). The per-frame _process keeps only
# the planet spin, the delegating ticks, and the screenshot/fps harness probe.
# (Explicit types only — project rule: no ':=' inferred typing.)

const CameraRigScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/VoxelCameraRig.gd")
const EcologyServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ecology/EcologyService.gd")
const VegetationRendererScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/mesh/VegetationRenderer.gd")
const HudScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/SpawnPaletteHud.gd")
const AudioDirectorScript: GDScript = preload("res://addons/local_agents/audio/AudioDirector.gd")
const InteractionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelInteraction.gd")
const SpawnBrushScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSpawnBrush.gd")
const DisastersScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelDisasters.gd")
const PopulationGovernorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ecology/PopulationGovernor.gd")
const WeatherScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/WeatherSystem.gd")
const OceanPlaneScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/OceanPlane.gd")
const MaterialField3DScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialField3D.gd")
const WaterParticlesScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/WaterParticles.gd")
const WaterSurfaceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialFieldRender3D.gd")
const DrainageOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/DrainageOverlay.gd")
const StreamerHostScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelStreamerHost.gd")
const ThoughtPanelScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/CreatureThoughtPanel.gd")
const EventTrackerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/events/LAEventTracker.gd")
const PlanetBodyScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/system/PlanetBody.gd")
const SphereGridScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SphereGrid.gd")
# Focused cross-cutting controllers (each owns one concern; see the class docs).
const SkyControllerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSkyController.gd")
const SpawnControllerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSpawnController.gd")
const InputControllerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelInputController.gd")
const DebugWiringScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelDebugWiring.gd")
const AudioControllerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelAudioController.gd")
const GameProgressionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/game/GameProgression.gd")
const GameHudScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/GameHud.gd")
const TimeControlScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelTimeControl.gd")
const TimelineScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelTimeline.gd")
const CampaignTutorialScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/CampaignTutorial.gd")
const SettingsApplierScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelSettingsApplier.gd")
const WorldSaveControllerScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/game/WorldSaveController.gd")

# --- SOLAR-SYSTEM-FIRST: the world is a star + planet body (see TODO). Radial is the default; flat retired. ---
# CELLULAR (Voronoi) relief: continents sit at the cell cores, valley networks run the cell borders → real
# emergent river drainage. RELIEF is the cellular amplitude; FEATURE is the cell size (continent wavelength).
# A BIGGER radius flattens the ground horizon (a moderate village fits the close view with little curvature).
# RELIEF + FEATURE + OCEAN_BIAS + the field shell (below) all scale with the radius via PLANET_SCALE, so the
# ocean fraction (~72%), continent count, and field cost (cell_count fixed — just coarser cells) are preserved.
const PLANET_RADIUS: float = 500.0
const PLANET_SCALE: float = PLANET_RADIUS / 250.0     # everything below was tuned at radius 250
const PLANET_RELIEF: float = 46.0 * PLANET_SCALE
const PLANET_FEATURE: float = 155.0 * PLANET_SCALE
# OCEAN-heavy world: sea shell at the mean radius and OCEAN_BIAS pushes the whole surface inward, so most of
# the sphere is below the sea — continents/islands emerge only at the cellular cores, with the sea for the
# rivers to drain into. Raise OCEAN_BIAS (or SEA_RADIUS) for more water; lower for more land.
const PLANET_SEA_RADIUS: float = PLANET_RADIUS
const PLANET_OCEAN_BIAS: float = -10.0 * PLANET_SCALE  # NEGATIVE = mostly LAND (rivers/lakes) with the low regions
                                                      # as the sea (smooth simplex continents are centred ~0, so a
                                                      # negative bias lifts most of the surface above sea level).
                                                      # RAISE toward + for more sea. Runtime-tunable: LA_OCEAN_BIAS=<n>.
# BASIN relief: medium-wavelength undulation carved into the flat cellular plateaus so land has CLOSED
# DEPRESSIONS (lake bowls) — the pools springs/rain/runoff collect into as standing lakes (raise for deeper
# lakes/more relief; 0 = flat plateaus that only drain to the sea).
const PLANET_BASIN_RELIEF: float = 20.0 * PLANET_SCALE
const PLANET_BASIN_SIZE: float = 130.0 * PLANET_SCALE
# RIDGES: ridged-multifractal river-valley network carved into the continents (branching valleys → long rivers).
const PLANET_RIDGE_RELIEF: float = 22.0 * PLANET_SCALE
const PLANET_RIDGE_SIZE: float = 95.0 * PLANET_SCALE
const PLANET_SPIN_RATE: float = 0.10        # rad/s axial spin (~1 rotation / 63s) — day/night sweep
const PLANET_SPIN_AXIS: Vector3 = Vector3(0.40, 0.92, 0.0)   # ~23.5° obliquity vs the orbit plane → real seasons

var _body: Node3D = null    # LAPlanetBody — the one planet (owns terrain + actors in its local frame)
var _terrain                # LAVoxelTerrainService (from _body.terrain())
var _orbits: LASystemOrbits = null   # moving-frame solar system: planet orbit + sun/insolation/seasons drive
var _moon: LAMoon = null             # kinematic moon (gravity body + visual)
var _camera: Camera3D
var _ecology: Node          # LAEcologyService
var _veg_renderer: Node3D    # LAVegetationRenderer (batched vegetation draws)
var _render_opts: Dictionary = {}   # quality-preset render flags (ssao/glow/sun_shadows/fog/ocean_transparent)
var _hud: CanvasLayer       # LASpawnPaletteHud
var _game_hud: CanvasLayer = null  # LAGameHud — gamified objective/summary overlay (H toggles it)
var _time_control: CanvasLayer = null  # LAVoxelTimeControl — pause/slow/play/fast (Space + ,/.) owning time_scale
var _actors_root: Node3D
var _interaction: Node3D = null   # LAVoxelInteraction — input, selection, the player's hand
var _brush: Node3D = null         # LAVoxelSpawnBrush — radius spawn brush + placement
var _disasters: Node = null       # LAVoxelDisasters — volcano/lightning/meteor casts
var _weather: Node = null   # LAWeatherSystem (visual rain/wind for now; being made emergent)
var _material: Node = null   # LAMaterialField — the ONE substrate: terrain-coupled water + heat/air
var _ocean: Node = null      # LAOceanPlane — the calm sea drawn as one GPU plane (CA meshes only waves)
var _water: Node = null      # LAWaterParticles — the ONE field-driven atmosphere visual (cloud/fog/rain/snow)
var _water_surface: Node = null  # LAMaterialFieldRender3D — dynamic fluid surface (springs/rivers/lakes/floods)
var _drainage: Node = null       # LADrainageOverlay — debug highlight of the drainage network


# Ocean fraction knob: how far the whole surface is pushed below sea level. LA_OCEAN_BIAS overrides the default
# (pre-scale units, like PLANET_OCEAN_BIAS) so the land/sea split can be tuned per-launch without an edit.
func _ocean_bias() -> float:
	if OS.has_environment("LA_OCEAN_BIAS"):
		return float(OS.get_environment("LA_OCEAN_BIAS")) * PLANET_SCALE
	return PLANET_OCEAN_BIAS
var _streamer_host: Node = null # LAVoxelStreamerHost — owns the streamer overlay/avatar/voice/director
var _thought_panel: CanvasLayer = null # LACreatureThoughtPanel — click-a-creature "what it's thinking" hook
var _events: Node = null     # LAEventTracker — the ONE emergent phenomenon-event source (streamer + telemetry consume it)

# --- Focused controllers (each owns one cross-cutting concern) ---
var _sky_ctrl: LAVoxelSkyController = null      # star/sun + sky-mode wiring + day/night clock
var _spawn: LAVoxelSpawnController = null       # initial ecology/actor spawning + counts + river springs
var _gen_screen: LAGeneratingPlanetScreen = null   # "Generating planet" loading overlay (hides world assembly)
var _input: LAVoxelInputController = null       # CLI-arg parsing + auto-demo firing + pause-menu host
var _debug: LAVoxelDebugWiring = null           # DebugPanel/DebugOverlay wiring + debug-view dispatch
var _progression: LAGameProgression = null      # campaign stage ladder gating camera zoom / view modes / spawns
var _settings_applier: LAVoxelSettingsApplier = null  # applies GameMode.settings → grid res / spawn counts / effects / disaster cadence

# --- Procedural audio (presentation only; reacts to events, never drives the sim) ---
var _audio: LocalAgentsAudioDirector = null
var _music_destruction: float = 0.0     # decays each frame; meteors spike it
var _mood_timer: int = 0
var _music_auto_adapt: bool = true      # when false, stop feeding sim mood so manual menu picks stick
var _audio_ctrl: Node = null            # LAVoxelAudioController — event stings + music-seed salt + UI/milestone helpers

var _frame: int = 0
# Transient landslide diagnostic (read by LAVoxelHarness.emit_smoke_summary at run end).
var _peak_slump: int = 0                    # most loose-sediment cells slumping at once
# Rolling FPS probe: averages the last N frames so a windowed --shoot run reports a stable perf number.
var _fps_accum: float = 0.0
var _fps_count: int = 0
var _gpu_ms_accum: float = 0.0    # isolated GPU render time — independent of CPU sim load
const FPS_PROBE_FRAMES: int = 150


func _ready() -> void:
	# CLI-arg parsing FIRST (its seeds feed the sky; its flags gate the offscreen window + streamer).
	_input = InputControllerScript.new()
	_input.name = "InputController"
	add_child(_input)
	_input.parse_cmdline()

	# --- Campaign progression: data-driven stage ladder that GATES existing capabilities (camera zoom
	# ceiling, view modes, spawn palette) on earned objectives. Created early so the camera's set_orbit_target
	# sees the constrained ceiling; the camera / view-controls / palette QUERY it via LAGameProgression.active().
	_progression = GameProgressionScript.new()
	_progression.name = "GameProgression"
	add_child(_progression)

	# --- Front-end settings bridge: resolves GameMode.settings (difficulty/quality/audio) into concrete sim
	# knobs. Created early + settings read NOW so the field build + initial spawn can query the grid resolution
	# and actor budget below; its live concerns (effects density + ambient-disaster cadence) are bound at the
	# end of _ready once those systems exist. All application logic lives here — the root only wires.
	_settings_applier = SettingsApplierScript.new()
	_settings_applier.name = "SettingsApplier"
	add_child(_settings_applier)
	_settings_applier.read_settings()

	# Non-interactive verification/screenshot runs (--run-frames / --shoot) shove the OS window WAY
	# off-screen the instant we start, so agent/CI runs that render on a real display path never pop a
	# visible window in front of the user. Env LA_OFFSCREEN forces it too.
	if (_input.run_frames() > 0 or _input.shoot_path() != "" or OS.has_environment("LA_OFFSCREEN")) and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_position(Vector2i(-8000, -8000))
		# Opt-in uncap (LA_UNCAP): drop vsync + the fps limit to see headroom above the monitor refresh.
		if _input.run_frames() > 0 and OS.has_environment("LA_UNCAP"):
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0

	# --- Sun + sky + day/night + the star: owned by LAVoxelSkyController (cmdline-seeded clocks). ---
	_sky_ctrl = SkyControllerScript.new()
	_sky_ctrl.name = "SkyController"
	add_child(_sky_ctrl)
	# Quality-preset render flags gate the fill-rate-heavy effects (SSAO/glow/sun-shadows/fog + ocean opacity)
	# so the DEFAULT preset is playable and only HIGH pays for the full look — see LAVoxelSettingsApplier.
	_render_opts = _settings_applier.render_opts()
	_sky_ctrl.setup(self, _input.time_of_day_seed(), _input.lunar_seed(), _render_opts)

	# --- The planet body: one world in a LOCAL frame; owns terrain + actors so they ride its transform. ---
	_body = PlanetBodyScript.new()
	_body.name = "PlanetBody"
	add_child(_body)
	_body.setup({"radius": PLANET_RADIUS, "relief": PLANET_RELIEF, "feature_size": PLANET_FEATURE,
		"basin_relief": PLANET_BASIN_RELIEF, "basin_size": PLANET_BASIN_SIZE,
		"ridge_relief": PLANET_RIDGE_RELIEF, "ridge_size": PLANET_RIDGE_SIZE,
		"sea_radius": PLANET_SEA_RADIUS, "ocean_bias": _ocean_bias(), "view_distance": 2000, "seed": 1337})
	_terrain = _body.terrain()
	# PLANETARY SKY: view from space with the sun FIXED shining star->planet; the spinning planet turns
	# under it → a stark star-lit day/night terminator sweeps the surface.
	_sky_ctrl.enter_space_mode(_body.center())

	# --- Camera + voxel viewer ---
	_camera = CameraRigScript.new()
	_camera.name = "CameraRig"
	add_child(_camera)
	_camera.current = true
	_body.attach_viewer(_camera)
	# Orbit-the-planet camera (radial up, MMB-drag orbit, scroll zoom) framing the body from space.
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(_body.center(), _body.radius())
		# Open the view over the lit hemisphere (resolved one-shot once the sun light is placed).
		if _camera.has_method("face_sun_on_start") and _sky_ctrl != null:
			_camera.face_sun_on_start(_sky_ctrl.sun())

	# --- Actors + ecology (actors live UNDER the body so they ride its frame) ---
	_actors_root = _body.actors_root
	_ecology = EcologyServiceScript.new()
	_ecology.name = "Ecology"
	add_child(_ecology)
	_ecology.setup(_terrain, _actors_root)
	# Shared GPU-instanced vegetation renderer: plants/trees draw through its batched MultiMesh (one draw per
	# type) instead of hundreds of per-node MeshInstances. Lives under actors_root so it rides the planet frame.
	_veg_renderer = VegetationRendererScript.new()
	_veg_renderer.name = "VegetationRenderer"
	_actors_root.add_child(_veg_renderer)
	_ecology.set_vegetation_renderer(_veg_renderer)
	# Let the camera query the seismic field so ground disturbances shake it emergently.
	if _camera != null and _camera.has_method("set_ecology"):
		_camera.set_ecology(_ecology)

	# --- HUD ---
	_hud = HudScript.new()
	_hud.name = "HUD"
	add_child(_hud)
	_hud.set_status("Streaming terrain...")
	# Gamified overlay (objective/progress/stage + unlock toasts + planet summary); reads progression + telemetry.
	# Kept as a ref so the interaction controller's H key can toggle it alongside the spawn palette.
	_game_hud = GameHudScript.new()
	add_child(_game_hud)

	# Player time-dilation controls (Space=pause, ,/. = slower/faster, Home=1×). Owns Engine.time_scale.
	_time_control = TimeControlScript.new()
	add_child(_time_control)
	_time_control.set_camera(_camera)

	# --- Procedural audio ---
	_audio = AudioDirectorScript.new()
	_audio.name = "AudioDirector"
	add_child(_audio)
	_audio.configure()
	# On/off + per-bus volumes are applied from the player's settings by LAVoxelAudioController.setup()
	# (created below) — audio ships ON by default, silenced only by LA_NO_AUDIO / --no-audio. The root just
	# builds the director and seeds a neutral mood.
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
	_weather.setup(_camera, _sky_ctrl.sun(), _sky_ctrl.env())

	# --- The ONE material field: the dense 3D GPU substrate. A real volume — every material (temp, water,
	# vapor/cloud/fog, lava) lives in the same GPU-resident buffers and every rule is a pass in one
	# pipeline, so fluids interact with the 3D caves. It lazily samples rock/void as the terrain streams. ---
	_material = MaterialField3DScript.new()
	_material.name = "MaterialField"
	add_child(_material)
	# CUBED-SPHERE field (Phase B): a SphereGrid shell enclosing the planet (crust + atmosphere), gathered via
	# the neighbour table with radial gravity. ~123K cells (res 32/face × depth 20 × 6). Down = inward-radial.
	var field_grid: RefCounted = SphereGridScript.new()
	# Per-face cell resolution + shell depth come from the quality setting (Low runs a smaller grid on weak
	# GPUs). Medium keeps the historical 32/face. The shell (core_radius, cell_size) SCALES with the planet
	# radius (PLANET_SCALE) so it always spans the surface band + atmosphere with the SAME cell_count — a bigger
	# planet costs the same field, just with proportionally coarser cells (at radius 250: core 170, cell 8 →
	# shell 170..330). Cells stay ~cubical because the lateral cell size also scales with radius at fixed res.
	field_grid.build(_settings_applier.grid_res_per_face(), _settings_applier.grid_depth(), 170.0 * PLANET_SCALE, 8.0 * PLANET_SCALE, _body.center())
	_material.setup_sphere(field_grid, _terrain)
	if _material.has_method("sample_solidity"):
		_material.sample_solidity()                        # fill the solid mask from the terrain SDF
	LASimReport.register(Callable(_material, "report"))   # field channel aggregates flow into SIM_REPORT
	LASimReport.register(func() -> Dictionary: return LASimReportSources.population(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.cognition(self))
	LASimReport.register(func() -> Dictionary: return LASimReportSources.disease(self))
	# The field reads the REAL sun (DirectionalLight3D) live — its energy + angle drive all heating.
	_material.set_sun(_sky_ctrl.sun())
	if _ecology.has_method("set_material_field"):
		_ecology.set_material_field(_material)
	# The ONE emergent phenomenon-event source: watches the field aggregates and emits typed events
	# (eruption/wildfire/flood/storm/lightning/impact) that the streamer + SIM_REPORT consume. Gate mirrors
	# LA_NO_STREAMER (perf A/B + headless opt-out).
	if not OS.has_environment("LA_NO_EVENT_TRACKER"):
		_events = EventTrackerScript.new()
		_events.name = "EventTracker"
		add_child(_events)
		_events.setup(self)
	# Weather relays the field's EMERGENT rain (no invented rain of its own) — wire the field to it.
	if _weather != null and _weather.has_method("set_field"):
		_weather.set_field(_material)

	# Game-feel audio: salt the music seed + fire an SFX sting per emergent phenomenon event. Thin
	# wiring over the audio director; all behavior lives in the controller (composition root = one line).
	_audio_ctrl = AudioControllerScript.new()
	_audio_ctrl.name = "AudioController"
	add_child(_audio_ctrl)
	_audio_ctrl.setup(self)

	# The calm sea: ONE GPU ocean plane at sea level. Planet: a finite spherical sea SHELL at sea_radius.
	_ocean = OceanPlaneScript.new()
	add_child(_ocean)
	if _terrain.is_planet():
		_ocean.setup_sphere(_body.center(), _body.sea_radius(), bool(_render_opts.get("ocean_transparent", true)))
	else:
		_ocean.setup(_terrain.sea_level(), _camera)

	# The field's emergent condensate, rendered as ONE GPU particle system: cloud / fog / rain / snow, the
	# phase a per-particle property classified from the field's baked cover texture.
	_water = WaterParticlesScript.new()
	add_child(_water)
	_water.setup(_material, _camera, _sky_ctrl.sun(), _body.center(), _body.sea_radius())

	# The dynamic FLUID SURFACE: springs/rivers/waterfalls/lakes/floods meshed from the field's `water` column
	# and drawn with VoxelWater.gdshader (this water was simulated but never rendered before). Near-cap + ~4.5 Hz
	# rebuild; all behavior in the module (composition root = one add_child).
	_water_surface = WaterSurfaceScript.new()
	_water_surface.name = "WaterSurface"
	add_child(_water_surface)
	_water_surface.setup(_material, _camera, _terrain, _sky_ctrl.sun(), _body.center(), _body.sea_radius())

	# The sky cycle reads the field each frame (cloud-cover dimming) + pushes the day/night colour tint to
	# the water-particle renderer.
	_sky_ctrl.bind_scene(_weather, _material, _water)

	# --- MOVING-FRAME SOLAR SYSTEM: the planet carries a heliocentric orbital STATE that drives the sun's motion
	# across the sky, the seasons (tilted spin axis vs orbit plane), and insolation (orbit distance × atmospheric
	# dust → bake / freeze / impact-winter). A moon orbits the planet (a gravity body meteors can slingshot).
	# Meteor impacts transfer momentum into the orbit → knock the planet toward the sun or out of the system. ---
	_moon = LAMoon.new()
	_moon.name = "Moon"
	add_child(_moon)
	_orbits = LASystemOrbits.new()
	_orbits.name = "SystemOrbits"
	_orbits.add_to_group("system_orbits")
	add_child(_orbits)
	_orbits.setup(_body, _sky_ctrl, _material)
	_orbits.set_moon(_moon)
	LASimReport.register(Callable(_orbits, "report"))

	# Feed the live temperature texture to the terrain shader so HOT GROUND GLOWS (meteor craters, lava,
	# wildfire fronts) — emergent incandescence, updated in place each field step.
	if _terrain.has_method("set_shader_param") and _material.has_method("heat_texture"):
		_terrain.set_shader_param("heat_tex", _material.heat_texture())
		_terrain.set_shader_param("heat_world_min", _material.heat_world_min())
		_terrain.set_shader_param("heat_world_size", _material.heat_world_size())

	# --- Debug menu (left) + world-space gizmo overlay: field views, type highlights, intended paths. ---
	_debug = DebugWiringScript.new()
	_debug.name = "DebugWiring"
	add_child(_debug)
	_debug.setup(self, _material, _terrain, _sky_ctrl, _hud, _input, _ecology)
	# Drainage-network debug highlight (where rivers should run) — a child of the planet body so it rides the
	# spin; DebugWiring owns its toggle (DEBUG panel "Rivers" + --debug-rivers). Composition root = wiring only.
	_drainage = DrainageOverlayScript.new()
	_drainage.name = "DrainageOverlay"
	_body.add_child(_drainage)
	_drainage.setup(_material)
	_debug.set_drainage(_drainage, _input.debug_rivers())

	# --- Streamer / commentator (lower-right face-cam driven by the local LLM). LAZY + default-OFF: nothing
	# is built at startup, so a fresh launch spins up NO local LLM / TTS and shows no overlay. The player
	# presses C (toggle_streamer) to build it on first use. --no-streamer / LA_NO_STREAMER disable it
	# entirely (it can't even be lazily built). See _ensure_streamer_host(). ---

	# --- Interaction / spawn brush / disasters controllers ---
	# Order: disasters first (the brush casts through it), then the brush, then interaction (routes input
	# to the brush and holds the selection ring).
	_disasters = DisastersScript.new()
	_disasters.name = "Disasters"
	add_child(_disasters)
	_disasters.setup(self, _terrain, _ecology, _actors_root, _camera, _audio)
	# Lightning is EMERGENT: the field's charge process fires a bolt where a convective updraft breaks
	# down, injecting the heat pulse + scare itself, and calls back here for the VISUAL/audio bolt only.
	if _material != null and _material.has_method("set_lightning_visual"):
		_material.set_lightning_visual(Callable(_disasters, "spawn_lightning"))
	# Population governor ("smite"): watches the animal count and, when it overflows the frame budget, seeds an
	# emergent culling flood at the densest herd — the cull emerges from the flood, no scripted deaths. Self-ticks.
	var governor: Node = PopulationGovernorScript.new()
	governor.name = "PopulationGovernor"
	add_child(governor)
	governor.setup(_ecology, _terrain, _actors_root)
	# Plate tectonics: drifting plates whose boundaries seed volcanoes/earthquakes (Ring of Fire). Self-ticks.
	var tectonics: LAPlateTectonics = LAPlateTectonics.new()
	tectonics.name = "PlateTectonics"
	add_child(tectonics)
	tectonics.setup(_terrain, _disasters)
	_brush = SpawnBrushScript.new()
	_brush.name = "SpawnBrush"
	add_child(_brush)
	_brush.setup(self, _terrain, _camera, _ecology, _hud, _audio, _actors_root, _disasters)
	_interaction = InteractionScript.new()
	_interaction.name = "Interaction"
	add_child(_interaction)
	_interaction.setup(self, _terrain, _camera, _ecology, _hud, _audio, _brush)
	_interaction.set_game_hud(_game_hud)   # H toggles the gamified overlay alongside the spawn palette
	if _hud.has_signal("spawn_selected"):
		_hud.spawn_selected.connect(_interaction.on_spawn_selected)
	# Re-root the family-tree inspector whenever the selection changes (debug reader; wired here as the two
	# controllers are built in different phases of composition).
	if _debug != null:
		_interaction.selection_changed.connect(_debug.on_selection_changed)
		_debug.set_interaction(_interaction)   # enables the debug menu's "select all thinking/queued" action
	# Click-a-creature "what it's thinking" panel — surfaces the existing per-creature cognition (its last
	# decision + the local model's rationale). Pure UI reader; subscribes to the same selection signal.
	_thought_panel = ThoughtPanelScript.new()
	_thought_panel.name = "CreatureThoughtPanel"
	add_child(_thought_panel)
	_thought_panel.setup(_interaction)

	# --- Initial spawning controller (ticked each frame until the surface has meshed). ---
	_spawn = SpawnControllerScript.new()
	_spawn.name = "SpawnController"
	add_child(_spawn)
	_spawn.setup(self, _body, _terrain, _ecology, _camera, _material, _hud, _disasters)
	_spawn.set_spawn_scale(_settings_applier.spawn_scale())   # quality actor_budget → fewer/more actors
	# "Generating planet" loading overlay — covers the world ASSEMBLING (terrain streaming, camera arc settling,
	# initial spawn) so the player never watches it build; finished + faded the moment the world is ready.
	_gen_screen = LAGeneratingPlanetScreen.new()
	_gen_screen.name = "GeneratingPlanetScreen"
	add_child(_gen_screen)

	# Wire the input controller's auto-demo hooks now that every scene ref exists.
	_input.bind(_terrain, _camera, _body, _sky_ctrl.star(), _material, _disasters, _interaction, _ecology)

	# Cinematic trailer capture (--trailer-shot=NAME): a scene-scripter drives a scripted camera + timed events
	# and auto-quits; run with Godot movie-maker (--write-movie) to record. Clean footage → hide the game UI.
	if _input.trailer_shot() != "":
		# Clean footage: hide EVERY UI overlay (HUD, gamified HUD, debug field-view panel, view-mode bar and the
		# thought panel are each their own CanvasLayer), so only the world renders.
		for child in get_children():
			if child is CanvasLayer:
				(child as CanvasLayer).visible = false
		# Cinematic PHYSICAL camera: real f-stop depth-of-field + exposure (Godot's CameraAttributesPhysical).
		# f/2.8 with a mid focus distance gives a gentle background bokeh; per-shot focus can be tuned in the
		# director. Applied only in trailer mode so gameplay exposure is untouched.
		if _camera is Camera3D:
			var cam_attr: CameraAttributesPhysical = CameraAttributesPhysical.new()
			cam_attr.exposure_aperture = 2.8
			cam_attr.frustum_focus_distance = 80.0
			cam_attr.frustum_focal_length = 40.0
			(_camera as Camera3D).attributes = cam_attr
		var director: LATrailerDirector = LATrailerDirector.new()
		director.name = "TrailerDirector"
		add_child(director)
		director.begin(self, _camera, _disasters, _input, _body, null, _input.trailer_shot())

	# Bind the settings applier's live concerns now that disasters/terrain/particles exist: pushes the effects
	# density onto the atmosphere particles and arms the difficulty-scaled ambient-disaster cadence.
	_settings_applier.bind(self, _disasters, _terrain, _water)

	# First-run campaign intro: a data-defined guided tour (reusable LATutorial system) that teaches the core
	# loop. Campaign-only + first-run + skippable + persisted — all owned by the controller; the root just wires.
	var tutorial: LACampaignTutorial = CampaignTutorialScript.new()
	tutorial.name = "CampaignTutorial"
	add_child(tutorial)
	tutorial.setup(_interaction, _hud, _game_hud, _input, _progression)

	# Save / load: resumes a menu-requested slot (deferred until the field GPU is up) and hosts the pause-menu
	# "Save game" entry. All gather/apply logic lives in LAWorldSaveController + LAWorldSaveState (this root
	# stays a composition root — one wire line).
	var save_ctrl: LAWorldSaveController = WorldSaveControllerScript.new()
	save_ctrl.name = "WorldSaveController"
	add_child(save_ctrl)
	save_ctrl.setup(self)

	# Timeline snapshot ring — smooth in-place reverse + fork (RAM ring, off in the harness unless LA_SNAPSHOTS=1).
	var timeline: LAVoxelTimeline = TimelineScript.new()
	timeline.name = "Timeline"
	add_child(timeline)
	timeline.setup(save_ctrl)
	if _time_control != null and _time_control.has_method("set_timeline"):
		_time_control.set_timeline(timeline)


func _process(delta: float) -> void:
	_frame += 1
	# Track the physics-tick cost every frame so SimReport's max = the heavy STEP-FRAME spike.
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	# Advance the orbit BEFORE the sky so the sun-shine direction + insolation are fresh when the sky reads them.
	if _orbits != null:
		_orbits.update(delta)
	_sky_ctrl.update(delta)
	# Share the sky clock with the ecology so nocturnal behavior can key off night.
	if _ecology != null and _ecology.has_method("set_time_of_day"):
		_ecology.set_time_of_day(_sky_ctrl.time_of_day())
	_update_music_mood()
	# Planet axial SPIN — the body (its terrain + actors are children) turns as ONE moving frame while the
	# camera stays in the system frame, so day/night sweeps across the surface. Starts after life is placed so
	# spawn stays deterministic. FROZEN during the seabed-volcano capstone so the world-fixed field and the
	# spinning terrain SDF stay aligned (else a long accretion would smear the cone into an arc).
	if _body != null and _spawn.is_spawned() and _terrain.is_planet() and not _input.auto_seavolcano() and not _input.manual_rotate():
		_body.rotate(PLANET_SPIN_AXIS.normalized(), PLANET_SPIN_RATE * delta)
	# Spawn the starting ecology once terrain has streamed + collided at the surface.
	_spawn.try_spawn(_input.overview(), _input.farview(), _input.auto_meteor(), _input.auto_select())
	# World is ready → fade out the "Generating planet" overlay (once).
	if _gen_screen != null and _spawn.is_spawned():
		_gen_screen.finish()
		_gen_screen = null
	_interaction.update_hand(delta)
	_interaction.update_selection_ring()
	_brush.update_brush_ring()
	_push_environment()
	if _spawn.is_spawned() and _frame % 15 == 0:
		_sample_behaviour_peaks()
	# Landslide diagnostic: track the most sediment cells slumping at once (throttled — the count is a full
	# grid scan). Always sampled so a meteor/volcano/earthquake slump is visible without --cognition-stats.
	if _spawn.is_spawned() and _frame % 10 == 0 and _material != null and _material.has_method("slump_count"):
		_peak_slump = maxi(_peak_slump, _material.slump_count())

	# Per-frame auto-demo firing (meteor/volcano/seavolcano/stamp/lightning/storm/select) — CLI-driven only.
	_input.update(_frame, _spawn.is_spawned())

	# Accumulate FPS over the final window before the screenshot for a stable perf reading.
	if _input.shoot_path() != "" and _frame > _input.shoot_frames() - FPS_PROBE_FRAMES and _frame <= _input.shoot_frames():
		_fps_accum += Engine.get_frames_per_second()
		_gpu_ms_accum += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		_fps_count += 1

	if _input.shoot_path() != "" and _frame == _input.shoot_frames():
		var avg_fps: float = _fps_accum / maxf(1.0, float(_fps_count))
		var avg_gpu: float = _gpu_ms_accum / maxf(1.0, float(_fps_count))
		print("FPS_AVG=%.1f GPU_MS=%.3f frames=%d entities=%d" % [avg_fps, avg_gpu, _fps_count, _actors_root.get_child_count()])
		capture_screenshot(_input.shoot_path())
		LAAppExit.request(self, 0)

	if _input.run_frames() > 0 and _frame % 180 == 0 and _frame < _input.run_frames():
		LAVoxelHarness.emit_population_trace(self, _frame)   # trajectory samples through a long run
	if _input.run_frames() > 0 and _frame == _input.run_frames():
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
	# report shows the PEAK each occurred at over the run (not just the final frame).
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
		"time_of_day": _sky_ctrl.time_of_day() if _sky_ctrl != null else 0.30,
		"destruction_intensity": _music_destruction,
		"threat": _music_destruction,
	})


func _on_music_auto_adapt_changed(on: bool) -> void:
	_music_auto_adapt = on
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Music auto-adapt: %s" % ("ON" if on else "off — manual control"))


# --- controller callbacks: the interaction/brush/disasters controllers forward the few bits of
# root-owned state (music mood, harness latch, debug view toggles) back through these. ---

# Spike the music's destruction mood (meteors/volcanoes/lightning). Decays each frame in _update_music_mood.
func set_destruction(intensity: float) -> void:
	_music_destruction = intensity


# The disasters controller fired the one-shot auto-meteor test; latch it (forwarded to the input controller).
func mark_auto_meteor_fired() -> void:
	if _input != null:
		_input.mark_auto_meteor_fired()


# V key (from the interaction controller): toggle the emergent scent-field debug gizmos (DebugOverlay).
func toggle_scent_view() -> void:
	if _debug != null:
		_debug.toggle_scent_view()


# T key (from the interaction controller): toggle the terrain temperature heatmap debug view.
func toggle_temp_view() -> void:
	if _debug != null:
		_debug.toggle_temp_view()


# C key (from the interaction controller): build the streamer on first use (lazy — keeps the local LLM
# + TTS entirely unloaded until the player asks for it), then hide/show it, gating its compute off/on.
func toggle_streamer() -> void:
	if not _ensure_streamer_host():
		return
	if _streamer_host.has_method("toggle_streamer"):
		_streamer_host.toggle_streamer()


# Build the streamer host the first time it is requested. Returns false when the streamer is disabled for
# this run (--no-streamer / env LA_NO_STREAMER), so a headless / perf / no-LLM run never spins one up. The
# freshly built host starts hidden + compute-gated (see VoxelStreamerHost.setup); the toggle above then
# shows it, so the building press is what turns it on.
func _ensure_streamer_host() -> bool:
	if _streamer_host != null:
		return true
	if not _input.streamer_enabled() or OS.has_environment("LA_NO_STREAMER"):
		return false
	_streamer_host = StreamerHostScript.new()
	_streamer_host.name = "StreamerHost"
	add_child(_streamer_host)
	_streamer_host.setup(self, _ecology, _material, _input.streamer_persona(), _input.streamer_avatar_flavor())
	return true


func _push_environment() -> void:
	if _weather == null:
		return
	# Feed the emergent wind field its prevailing (large-scale) input; local circulation emerges on top.
	# Scent now rides this same wind INSIDE the field — no external scent wiring needed.
	if _material != null and _material.has_method("set_wind"):
		if _input.force_wind() != 0.0:
			_material.set_wind(Vector2(_input.force_wind(), 0.0))
		else:
			var w: Vector3 = _weather.wind_vector()
			_material.set_wind(Vector2(w.x, w.z))


# Capture the current viewport to a PNG (the --shoot harness + the DebugPanel save button both call this).
func capture_screenshot(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d" % [path, img.get_width(), img.get_height()])
