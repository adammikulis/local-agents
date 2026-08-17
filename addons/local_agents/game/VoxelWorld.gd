extends Node3D
class_name LAVoxelWorld


const InputControllerScript: GDScript = preload("res://addons/local_agents/game/world/VoxelInputController.gd")
const SimulationScene: PackedScene = preload("res://addons/local_agents/game/Simulation.tscn")
const RenderLayerScene: PackedScene = preload("res://addons/local_agents/game/RenderLayer.tscn")
const UiLayerScene: PackedScene = preload("res://addons/local_agents/game/UiLayer.tscn")
const StreamerHostScript: GDScript = preload("res://addons/local_agents/sim/streamer/StreamerHost.gd")

# THE BODY THIS WORLD IS SEEDED WITH. Every length below is METRES, because the grid is metres.
const PLANET_RADIUS: float = 2.4397e6
const PLANET_RELIEF: float = 9.4e3                # peak-to-trough continental relief; LA_RELIEF overrides
const PLANET_FEATURE: float = 5.2e4               # continental wavelength
# OCEAN-heavy world: sea shell at the mean radius.
const PLANET_SEA_RADIUS: float = PLANET_RADIUS
const PLANET_OCEAN_BIAS: float = 1.0e3
# BASIN relief.
const PLANET_BASIN_RELIEF: float = 4.0e3
const PLANET_BASIN_SIZE: float = 4.4e4
# RIDGES: ridged-multifractal mountain layer.
const PLANET_RIDGE_RELIEF: float = 1.35e3               # LA_RIDGE overrides
const PLANET_RIDGE_SIZE: float = 3.2e4
const PLANET_RIDGE_OCTAVES: int = 2
const PLANET_DETAIL_RELIEF: float = 3.4e2               # fine surface grain (LA_DETAIL overrides)
# CAVES: emergent fractal spaghetti tunnels carved into the SDF underground. LA_CAVES=0 disables.
const PLANET_CAVE_SIZE: float = 2.0e4                    # tunnel wavelength, metres
const PLANET_CAVE_THRESHOLD: float = 0.09                # near-zero band => tunnel fatness (scale-free)
const PLANET_CAVE_STRENGTH: float = 40.0                 # void-SDF wall sharpness (0 disables)
const PLANET_CAVE_DEPTH_FADE: float = 4.7e3

const FPS_PROBE_FRAMES: int = 150

var _input: LAVoxelInputController = null
var _sim: LASimulation = null
var _render: LARenderLayer = null
var _ui: LAUiLayer = null
var _streamer_host: Node = null

# Forwarded sim/presentation refs.
var _material: Node = null
var _ecology: Node = null
var _body: Node3D = null
var _actors_root: Node3D = null
var _spawn: LAVoxelSpawnController = null
var _sky_ctrl: LAVoxelSkyController = null
var _progression: LAGameProgression = null
var _camera: Camera3D = null
var _hud: CanvasLayer = null
var _audio: LAAudioDirector = null
var _debug: LAVoxelDebugWiring = null
var _interaction: Node3D = null

var _frame: int = 0                         # SIM STEPS since the world was sealed; the run length is counted on it
var _render_frame: int = 0                  # render frames since _ready; the clock --perf-frames and --shoot use
var _music_destruction: float = 0.0         # decays each frame; meteors spike it
var _mood_timer: int = 0
var _music_auto_adapt: bool = true
# Rolling perf probe (--perf-frames): averages the trailing window so a reading is stable.
var _fps_accum: float = 0.0
var _fps_count: int = 0
var _gpu_ms_accum: float = 0.0
var _cpu_render_ms_accum: float = 0.0
var _proc_ms_accum: float = 0.0
var _phys_ms_accum: float = 0.0
var _frame_dt_accum: float = 0.0


# Terrain-roughness live knobs (pre-scale units, per-launch, no edit).
func _ocean_bias() -> float:
	if OS.has_environment("LA_OCEAN_BIAS"):
		return float(OS.get_environment("LA_OCEAN_BIAS"))
	return PLANET_OCEAN_BIAS

func _relief() -> float:
	return float(OS.get_environment("LA_RELIEF")) if OS.has_environment("LA_RELIEF") else PLANET_RELIEF

func _ridge_relief() -> float:
	return float(OS.get_environment("LA_RIDGE")) if OS.has_environment("LA_RIDGE") else PLANET_RIDGE_RELIEF

func _detail_relief() -> float:
	return float(OS.get_environment("LA_DETAIL")) if OS.has_environment("LA_DETAIL") else PLANET_DETAIL_RELIEF

func _caves_enabled() -> bool:
	if OS.has_environment("LA_CAVES"):
		return OS.get_environment("LA_CAVES") != "0"
	return true


func _planet_opts() -> Dictionary:
	return {"radius": PLANET_RADIUS, "relief": _relief(), "feature_size": PLANET_FEATURE,
		"basin_relief": PLANET_BASIN_RELIEF, "basin_size": PLANET_BASIN_SIZE,
		"ridge_relief": _ridge_relief(), "ridge_size": PLANET_RIDGE_SIZE,
		"ridge_octaves": PLANET_RIDGE_OCTAVES, "detail_relief": _detail_relief(),
		"caves_enabled": _caves_enabled(), "cave_size": PLANET_CAVE_SIZE,
		"cave_threshold": PLANET_CAVE_THRESHOLD, "cave_strength": PLANET_CAVE_STRENGTH,
		"cave_depth_fade": PLANET_CAVE_DEPTH_FADE, "sea_radius": PLANET_SEA_RADIUS,
		"ocean_bias": _ocean_bias(), "view_distance": 2000, "seed": 1337}


func _ready() -> void:
	# CLI-arg parsing FIRST: its flags decide whether a presentation layer is built at all.
	_input = InputControllerScript.new()
	_input.name = "InputController"
	add_child(_input)
	_input.parse_cmdline()
	_apply_window_mode()

	_sim = SimulationScene.instantiate()
	add_child(_sim)
	_sim.build({"planet": _planet_opts()})
	_sim.set_probe_flags(_input.overview(), _input.farview(), _input.auto_meteor(), _input.auto_select())
	_sim.loop().stepped.connect(_on_sim_step)
	_material = _sim.material_field()
	_ecology = _sim.ecology()
	_body = _sim.body()
	_actors_root = _sim.actors_root()
	_spawn = _sim.spawn_controller()

	if _input.render() or _input.ui():
		_render = RenderLayerScene.instantiate()
		add_child(_render)
		_render.build(self, _sim, _input)
		_camera = _render.camera()
		_sky_ctrl = _render.sky_controller()

	if _input.ui():
		_ui = UiLayerScene.instantiate()
		add_child(_ui)
		_ui.build(self, _sim, _render, _input)
		_hud = _ui.hud()
		_audio = _ui.audio()
		_debug = _ui.debug_wiring()
		_interaction = _ui.interaction()
		_progression = _ui.progression()

	# Wire the input controller's auto-demo hooks now that every scene ref exists.
	_input.bind(_sim.terrain(), _camera, _body, _sim.star(), _material, _sim.meteor_impacts(), _interaction, _ecology)
	_begin_trailer_shot()


func _apply_window_mode() -> void:
	var offscreen: bool = _input.run_frames() > 0 or _input.perf_frames() > 0 \
		or _input.shoot_path() != "" or OS.has_environment("LA_OFFSCREEN")
	if not offscreen or DisplayServer.get_name() == "headless":
		return
	# A screenshot run still has to draw, so it defocuses without minimizing.
	LAQuietWindow.apply(_input.shoot_path() == "")
	print(LAQuietWindow.state_line())
	# The perf bench ALWAYS uncaps.
	if _input.perf_frames() > 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	elif _input.run_frames() > 0 and OS.has_environment("LA_UNCAP"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0


# Cinematic trailer capture (--trailer-shot=NAME).
func _begin_trailer_shot() -> void:
	if _input.trailer_shot() == "" or _render == null:
		return
	# Clean footage: hide EVERY UI overlay (each is its own CanvasLayer), so only the world renders.
	for child in (_ui.get_children() if _ui != null else []):
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
	if _camera is Camera3D:
		# Real f-stop depth-of-field + exposure; applied only in trailer mode so gameplay exposure is untouched.
		var cam_attr: CameraAttributesPhysical = CameraAttributesPhysical.new()
		cam_attr.exposure_aperture = 2.8
		cam_attr.frustum_focus_distance = 80.0
		cam_attr.frustum_focal_length = 40.0
		(_camera as Camera3D).attributes = cam_attr
	var director: LATrailerDirector = LATrailerDirector.new()
	director.name = "TrailerDirector"
	add_child(director)
	director.begin(self, _camera, _sim.meteor_impacts(), _input, _body, null, _input.trailer_shot())


# The harness hooks, on the SIMULATION's clock. `_frame` is the step count, never a frame count.
func _on_sim_step(step: int) -> void:
	_frame = step
	# Sample the night gauges PERIODICALLY, not once at report time.
	if _sim.is_spawned() and _frame % 15 == 0:
		LAVoxelHarness.sample_night(self)
		_sample_behaviour_peaks()
	# Auto-demo firing on the SIMULATION clock.
	_input.update_sim(_frame, _sim.is_spawned())
	# Trajectory samples through a long run.
	if _input.run_frames() > 0 and _frame % 180 == 0 and _frame < _input.run_frames():
		LAVoxelHarness.emit_population_trace(self, _frame)


func _process(delta: float) -> void:
	_render_frame += 1
	# Track the physics-tick cost every frame so SimReport's max = the heavy STEP-FRAME spike.
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	if _render != null:
		_render.step(delta)
	if _ui != null:
		_ui.step(delta)
	_update_music_mood()
	# The --shoot half of the same schedule, on the RENDER clock.
	_input.update_render(_render_frame, _sim.is_spawned())
	_perf_probe(delta)


func _perf_probe(delta: float) -> void:
	var pf: int = _input.perf_frames()
	if pf <= 0:
		return
	var window: int = mini(FPS_PROBE_FRAMES, maxi(30, pf / 2))
	if _render_frame > pf - window and _render_frame <= pf:
		var vp_rid: RID = get_viewport().get_viewport_rid()
		# The _process delta IS the frame period.
		_frame_dt_accum += delta
		_fps_accum += Engine.get_frames_per_second()
		_gpu_ms_accum += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		_cpu_render_ms_accum += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
		_proc_ms_accum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_phys_ms_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_fps_count += 1
	if _render_frame != pf:
		return
	var n: float = maxf(1.0, float(_fps_count))
	var frame_ms: float = (_frame_dt_accum / n) * 1000.0
	print("PERF={\"fps\":%.1f,\"frame_ms\":%.2f,\"gpu_ms\":%.2f,\"cpu_render_ms\":%.2f,\"process_ms\":%.2f,\"physics_ms\":%.2f,\"draw_calls\":%d,\"prims_M\":%.2f,\"actors\":%d,\"creatures\":%d,\"nodes\":%d,\"window\":%d}" % [
		1000.0 / maxf(frame_ms, 0.001), frame_ms,
		_gpu_ms_accum / n, _cpu_render_ms_accum / n, _proc_ms_accum / n, _phys_ms_accum / n,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1.0e6,
		_actors_root.get_child_count(),
		get_tree().get_nodes_in_group("creature").size(),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		_fps_count])
	LAAppExit.request(self, 0)


## The LocalAgentDemoHarness contract.
func demo_report() -> Dictionary:
	var report: Dictionary = LAVoxelHarness.build_report(self)
	report["ui_nodes"] = _count_ui_nodes(get_tree().root)
	return report


func _count_ui_nodes(node: Node) -> int:
	var n: int = 0
	if node is Control or node is CanvasLayer:
		n += 1
	for child in node.get_children():
		n += _count_ui_nodes(child)
	return n


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
	# SimReport tracks each gauge's running max, so the report shows the PEAK over the run.
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
	_audio.set_music_mood({
		"population": get_tree().get_nodes_in_group("creature").size(),
		"time_of_day": _sky_ctrl.time_of_day() if _sky_ctrl != null else 0.30,
		"destruction_intensity": _music_destruction,
		"threat": _music_destruction,
	})


func _on_music_auto_adapt_changed(on: bool) -> void:
	_music_auto_adapt = on
	if _hud != null and _hud.has_method("set_status"):
		_hud.set_status("Music auto-adapt: %s" % ("on" if on else "off, manual control"))


# --- controller callbacks.

# Spike the music's destruction mood (meteors/volcanoes/lightning). Decays each frame in _update_music_mood.
func set_destruction(intensity: float) -> void:
	_music_destruction = intensity


# The impact controller fired the one-shot auto-meteor test; latch it.
func mark_auto_meteor_fired() -> void:
	if _input != null:
		_input.mark_auto_meteor_fired()


# V key: toggle the emergent scent-field debug gizmos.
func toggle_scent_view() -> void:
	if _debug != null:
		_debug.toggle_scent_view()


# T key: toggle the terrain temperature heatmap debug view.
func toggle_temp_view() -> void:
	if _debug != null:
		_debug.toggle_temp_view()


# C key: build the streamer on first use.
func toggle_streamer() -> void:
	if not _ensure_streamer_host():
		return
	if _streamer_host.has_method("toggle_streamer"):
		_streamer_host.toggle_streamer()


# Returns false when the streamer is disabled for this run (--no-streamer / LA_NO_STREAMER).
func _ensure_streamer_host() -> bool:
	if _streamer_host != null:
		return true
	if not _input.streamer_enabled() or OS.has_environment("LA_NO_STREAMER"):
		return false
	_streamer_host = StreamerHostScript.new()
	_streamer_host.name = "StreamerHost"
	add_child(_streamer_host)
	var llm: Node = _sim.llm_service()
	var streamer_client = llm.client() if llm != null and llm.is_available() else null
	_streamer_host.setup(self, _ecology, _material, _input.streamer_persona(), _input.streamer_avatar_flavor(), streamer_client)
	return true


# Capture the current viewport to a PNG (the --shoot harness + the DebugPanel save button both call this).
func capture_screenshot(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d" % [path, img.get_width(), img.get_height()])
