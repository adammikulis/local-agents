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
const AudioDirectorScript: GDScript = preload("res://addons/local_agents/audio/AudioDirector.gd")
const WeatherScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/WeatherSystem.gd")
const WaterScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/WaterFieldSystem.gd")

const INITIAL_COUNTS: Dictionary = {"plant": 70, "rabbit": 16, "fox": 3, "bird": 14, "villager": 6}
const ROCK_COUNT: int = 44
const FOREST_CLUSTERS: int = 7

var _terrain                # LAVoxelTerrainService
var _camera: Camera3D
var _ecology: Node          # LAEcologyService
var _hud: CanvasLayer       # LASpawnPaletteHud
var _actors_root: Node3D
var _selection_ring: MeshInstance3D
var _selected: Node = null
var _weather: Node = null   # LAWeatherSystem
var _water: Node = null      # LAWaterFieldSystem — CA rivers/lakes/ocean

# --- Day/night cycle. VoxelWorld owns ALL sky lighting (sun arc + energy, sky colors,
# ambient) so the cycle and weather never fight over the same properties; weather only
# supplies a rain factor that dims on top. time_of_day: 0=midnight, .25=dawn, .5=noon, .75=dusk.
var _sun: DirectionalLight3D = null
var _sky_mat: ProceduralSkyMaterial = null
var _env: Environment = null
var _time_of_day: float = 0.32              # start mid-morning
const DAY_LENGTH: float = 200.0             # seconds per full day
const SUN_ENERGY_NOON: float = 1.45
const AMBIENT_DAY: float = 0.62
const AMBIENT_NIGHT: float = 0.09           # moonlight floor so nights aren't pitch black
const SKY_TOP_DAY: Color = Color(0.36, 0.56, 0.86)
const SKY_TOP_NIGHT: Color = Color(0.02, 0.03, 0.11)
const SKY_HORIZON_DAY: Color = Color(0.72, 0.80, 0.88)
const SKY_HORIZON_NIGHT: Color = Color(0.05, 0.06, 0.15)
const SKY_HORIZON_DUSK: Color = Color(0.92, 0.48, 0.24)

# Rain depth-per-second added to the water field per unit of weather rain (0..1).
# Deliberately small: rain is a transient wetting that flows downhill to fill basins,
# NOT the main water source (that's sea-level basins + springs). Too large floods the
# whole map because uniform rain outpaces evaporation on flat ground.
const RAIN_TO_DEPTH: float = 0.03
# Persistent springs (world XZ) seeded on high ground so rivers form downhill; fed
# a little depth every frame so channels sustain instead of drying out.
var _springs: Array = []
var _springs_seeded: bool = false
const SPRING_RATE: float = 0.9              # depth per second per spring

var _armed_kind: String = ""
var _spawned_initial: bool = false
var _ready_wait_ticks: int = 0
var _scent_visible: bool = false

# --- Procedural audio (presentation only; reacts to events, never drives the sim) ---
var _audio: LocalAgentsAudioDirector = null
var _music_destruction: float = 0.0     # decays each frame; meteors spike it
var _mood_timer: int = 0

# Optional self-screenshot / smoke harness: pass `-- --shoot=<path> [--shoot-frames=N]`
var _shoot_path: String = ""
var _shoot_frames: int = 150
var _run_frames: int = 0
var _auto_meteor: bool = false
var _auto_meteor_fired: bool = false
var _auto_select: bool = false
var _auto_select_done: bool = false
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

	# --- Sun + sky ---
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP_DAY
	sky_mat.sky_horizon_color = SKY_HORIZON_DAY
	sky_mat.ground_horizon_color = Color(0.62, 0.66, 0.62)
	sky_mat.ground_bottom_color = Color(0.30, 0.34, 0.30)
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = AMBIENT_DAY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# SSAO tuned for terrain scale: the default 1m radius is invisible on kilometre-wide
	# hills, so widen it to occlude at valley/gully scale for real depth in creases and
	# under actors, with a gentle power curve so it reads as soft contact shadow, not grime.
	e.ssao_enabled = true
	e.ssao_radius = 3.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.6
	e.ssao_detail = 0.4
	e.ssao_horizon = 0.09
	e.ssao_sharpness = 0.95

	# HDR glow/bloom: only genuinely bright (>1.0) pixels bloom — incandescent lava, the
	# sun's specular glint on water, sunlit snow — so the scene gains punch without a
	# washed-out haze over everything. High threshold keeps midtone grass/rock crisp.
	e.glow_enabled = not OS.has_environment("NOGLOW")
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	e.glow_intensity = 0.85
	e.glow_strength = 1.0
	e.glow_bloom = 0.05
	e.glow_hdr_threshold = 1.05
	e.glow_hdr_scale = 2.0
	e.glow_hdr_luminance_cap = 12.0
	e.glow_normalized = false
	# Only the two mid-frequency levels are active: bloom passes are the cost driver at
	# this resolution, and these give a soft halo without paying for full-res or very-wide
	# blur taps. (Baseline: enabling all 5 levels cost ~40% fps for no extra visible gain.)
	e.set_glow_level(1, 0.0)
	e.set_glow_level(2, 0.0)
	e.set_glow_level(3, 1.0)
	e.set_glow_level(4, 0.8)
	e.set_glow_level(5, 0.0)

	# Subtle atmospheric fog: gives the vista depth, hides the terrain-LOD pop at the
	# horizon, and dissolves the ocean's hard edge into the skyline instead of ending in a
	# line. Cheap (non-volumetric). Aerial perspective tints distant geometry toward the
	# sky so far mountains recede; sky_affect stays low so the sky itself isn't washed out.
	# fog_light_color is re-tinted to the horizon color every frame in _update_day_night.
	e.fog_enabled = not OS.has_environment("NOFOG")
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = SKY_HORIZON_DAY
	e.fog_light_energy = 1.0
	e.fog_sun_scatter = 0.15
	e.fog_density = 0.0016
	e.fog_aerial_perspective = 0.55
	e.fog_sky_affect = 0.05
	e.fog_height = -40.0
	e.fog_height_density = 0.012

	env.environment = e
	add_child(env)
	_sky_mat = sky_mat
	_env = e

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -47.0, 0.0)
	sun.light_energy = SUN_ENERGY_NOON
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)
	_sun = sun

	# --- Terrain ---
	_terrain = TerrainServiceScript.new()
	# Larger world: keep all voxel data resident over a big bounded area so edits work
	# anywhere, with a long view distance for the vistas.
	_terrain.build(self, {"bounds_half_xz": 300, "view_distance": 640})

	# --- Camera + voxel viewer ---
	_camera = CameraRigScript.new()
	_camera.name = "CameraRig"
	add_child(_camera)
	_camera.current = true
	_terrain.attach_viewer(_camera)

	# --- Actors + ecology ---
	_actors_root = Node3D.new()
	_actors_root.name = "Actors"
	add_child(_actors_root)
	_ecology = EcologyServiceScript.new()
	_ecology.name = "Ecology"
	add_child(_ecology)
	_ecology.setup(_terrain, _actors_root)

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
	_audio.set_music_enabled(true)
	_audio.set_music_mood({"population": 0, "time_of_day": 0.30, "destruction_intensity": 0.0})

	# --- Weather: rain + wind. Wind advects scent; rain washes it away. ---
	_weather = WeatherScript.new()
	_weather.name = "Weather"
	add_child(_weather)
	_weather.setup(_camera, sun, e)
	# Let the wildfire system see the rain so weather can suppress/extinguish fires.
	if _ecology.has_method("fire_system"):
		var fs = _ecology.fire_system()
		if fs != null and fs.has_method("set_weather"):
			fs.set_weather(_weather)

	# --- Water: CA rivers/lakes/ocean over the terrain. Rain (from weather) and a
	# few springs feed it; it flows downhill and pools on its own. Creatures drink
	# from it and fish live in it (both query the field). ---
	_water = WaterScript.new()
	_water.name = "Water"
	add_child(_water)
	# Cover the full bounded play area; 4m cells keep the CA cheap (~150^2 grid).
	_water.setup(_terrain, 300.0, 4.0)
	if _ecology.has_method("set_water"):
		_ecology.set_water(_water)


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
		elif arg == "--auto-meteor":
			_auto_meteor = true
		elif arg == "--auto-select":
			_auto_select = true


func _process(delta: float) -> void:
	_frame += 1
	_update_day_night(delta)
	_update_music_mood()
	# Spawn the starting ecology once terrain has streamed + collided near origin.
	if not _spawned_initial and _terrain != null:
		if _terrain.is_ready_at(Vector3(0, 0, 0)):
			_ready_wait_ticks += 1
			if _ready_wait_ticks > 6:
				_ecology.spawn_initial(INITIAL_COUNTS)
				_ecology.populate_environment(ROCK_COUNT, FOREST_CLUSTERS)
				_seed_water()
				# Frame a vista at the real surface height (only when not driven by a harness cam).
				if not _auto_meteor and not _auto_select and _camera.has_method("frame_vista"):
					var oh: float = _terrain.surface_height(0.0, 0.0)
					if not is_nan(oh):
						_camera.frame_vista(Vector3(0.0, oh, 0.0))
				_spawned_initial = true
				_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")
	_update_selection_ring()
	_push_environment()
	_feed_water()

	# Auto-meteor demo/test: drop a meteor on a forest so it carves a crater, topples trees,
	# and ignites a wildfire. Works in both screenshot mode and headless run-frames mode.
	if _auto_meteor and not _auto_meteor_fired and _spawned_initial:
		var trigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if _frame == trigger:
			_fire_test_meteor()

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
			_camera.global_position = p + Vector3(6.0, 5.0, 6.0)
			_camera.look_at(p, Vector3.UP)
			_select_at(get_viewport().get_visible_rect().size * 0.5)
			var title: String = ""
			if _selected != null:
				title = String(_selected.call("get_inspector_payload").get("title", ""))
			print("SELECT_RESULT selected=", _selected != null, " ring_visible=", _selection_ring.visible, " title=", title)
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
		var n_sel: int = get_tree().get_nodes_in_group("selectable").size()
		var n_act: int = _actors_root.get_child_count()
		# Live-world diagnostics: verify the wired subsystems are actually doing something.
		var wet: int = 0
		if _water != null and _water.has_method("wet_cell_count"):
			wet = _water.wet_cell_count()
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
		for c in creatures:
			if is_instance_valid(c) and "hydration" in c and "max_hydration" in c:
				var h: int = int(round(100.0 * float(c.hydration) / maxf(1.0, float(c.max_hydration))))
				min_hyd = mini(min_hyd, h)
				if String(c.get("state")) == "drink":
					drinkers += 1
		print("SMOKE_SUMMARY={\"frames\":%d,\"spawned_initial\":%s,\"ready\":%s,\"selectable\":%d,\"actors\":%d,\"wet_cells\":%d,\"poop\":%d,\"fish\":%d,\"fires\":%d,\"min_hydration\":%d,\"drinking\":%d,\"time_of_day\":%.2f}" % [
			_frame, str(_spawned_initial).to_lower(), str(_terrain.is_ready_at(Vector3.ZERO)).to_lower(), n_sel, n_act, wet, n_poop, n_fish, n_fire, min_hyd, drinkers, _time_of_day])
		get_tree().quit(0)


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

	# Sun arc: steep overhead at noon, shallow at the horizon near dawn/dusk; sweeps E->W.
	_sun.rotation_degrees = Vector3(-(6.0 + daylight * 66.0), -47.0 + (_time_of_day - 0.5) * 90.0, 0.0)
	_sun.light_energy = SUN_ENERGY_NOON * daylight * storm
	# Warm the sunlight near the horizon (dawn/dusk glow).
	var warm: float = clampf(1.0 - elev * 2.5, 0.0, 1.0) * clampf(daylight * 6.0, 0.0, 1.0)
	_sun.light_color = Color(1.0, 1.0, 1.0).lerp(Color(1.0, 0.6, 0.32), warm * 0.8)

	# Sky colors lerp day<->night; horizon warms to dusk-orange around the transitions.
	var night: float = 1.0 - daylight
	if _sky_mat != null:
		_sky_mat.sky_top_color = SKY_TOP_DAY.lerp(SKY_TOP_NIGHT, night)
		var horizon: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		horizon = horizon.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_sky_mat.sky_horizon_color = horizon
	if _env != null:
		_env.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, daylight) * storm
		# Keep the distance fog matched to the current horizon so far terrain and the
		# ocean melt into the same color the sky shows there (warm at dusk, dark at night).
		var fog_col: Color = SKY_HORIZON_DAY.lerp(SKY_HORIZON_NIGHT, night)
		fog_col = fog_col.lerp(SKY_HORIZON_DUSK, warm * 0.7)
		_env.fog_light_color = fog_col

	# Share the clock with the ecology so nocturnal behavior can key off night.
	if _ecology != null and _ecology.has_method("set_time_of_day"):
		_ecology.set_time_of_day(_time_of_day)


# Feed the generative music a mood from live world state. Presentation only.
func _update_music_mood() -> void:
	if _audio == null:
		return
	var dt: float = get_process_delta_time()
	_music_destruction = maxf(0.0, _music_destruction - dt * 0.4)
	_mood_timer += 1
	if _mood_timer % 20 != 0:
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
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = event.position
		if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(pos):
			return
		if _armed_kind != "":
			_place_armed(pos)
		else:
			_select_at(pos)


func _on_spawn_selected(kind: String) -> void:
	_armed_kind = kind
	if kind == "":
		_hud.set_status("Select mode — click an entity to inspect it.")
	else:
		_hud.set_status("Spawn %s — click the ground to place." % kind)


func _place_armed(screen_pos: Vector2) -> void:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 2000.0)
	if not bool(hit.get("hit", false)):
		_hud.set_status("No ground under cursor — aim at the terrain.")
		return
	var point: Vector3 = hit["position"]
	if _armed_kind == "meteor":
		var meteor: MeteorScript = MeteorScript.new()
		_actors_root.add_child(meteor)
		meteor.setup(_terrain, _ecology)
		meteor.launch(point)
		_music_destruction = 1.0
		_hud.set_status("Meteor inbound!")
	else:
		_ecology.spawn(_armed_kind, point)
		if _audio != null:
			_audio.play_sfx("spawn", point)
		_hud.set_status("Spawned %s." % _armed_kind)
	_spawn_puff(point, _kind_color(_armed_kind))


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
	m.launch(impact)
	_music_destruction = 1.0
	_auto_meteor_fired = true
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
	if _weather == null or _ecology == null or not _ecology.has_method("scent_field"):
		return
	var sf = _ecology.scent_field()
	if sf == null:
		return
	if sf.has_method("set_wind"):
		sf.set_wind(_weather.wind_vector())
	if sf.has_method("set_wash"):
		sf.set_wash(_weather.rain())


# Choose the water's sea level (from origin ground) and a few high-ground springs
# so genuine basins fill as lakes and springs feed downhill rivers. One-shot.
func _seed_water() -> void:
	if _water == null or _terrain == null:
		return
	var origin_h: float = _terrain.surface_height(0.0, 0.0)
	if not is_nan(origin_h):
		# Only ground clearly below the origin becomes standing water — avoids a global flood.
		_water.sea_level = origin_h - 10.0
	# Sample a ring of candidate points; the highest few become persistent springs.
	var candidates: Array = []
	var ring: int = 8
	for i in range(ring):
		var ang: float = TAU * float(i) / float(ring)
		var r: float = 130.0
		var px: float = cos(ang) * r
		var pz: float = sin(ang) * r
		var h: float = _terrain.surface_height(px, pz)
		if not is_nan(h):
			candidates.append({"pos": Vector3(px, h, pz), "h": h})
	candidates.sort_custom(func(a, b): return float(a["h"]) > float(b["h"]))
	_springs.clear()
	for i in range(mini(3, candidates.size())):
		_springs.append(candidates[i]["pos"])
	_springs_seeded = true


# Drive the water field every frame: weather rain fills it uniformly; springs keep
# feeding so rivers sustain. Cheap — the CA itself is throttled internally.
func _feed_water() -> void:
	if _water == null:
		return
	if _weather != null and _water.has_method("add_rain"):
		_water.add_rain(_weather.rain() * RAIN_TO_DEPTH)
	if _springs_seeded and _water.has_method("add_source"):
		var dt: float = get_process_delta_time()
		for p in _springs:
			_water.add_source(p, SPRING_RATE * dt)


func _kind_color(kind: String) -> Color:
	match kind:
		"plant": return Color(0.35, 0.85, 0.3)
		"rabbit": return Color(0.92, 0.92, 0.95)
		"fox": return Color(0.95, 0.5, 0.15)
		"bird": return Color(0.3, 0.6, 0.95)
		"villager": return Color(0.75, 0.5, 0.9)
		"fish": return Color(0.55, 0.72, 0.86)
		"meteor": return Color(1.0, 0.5, 0.2)
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
