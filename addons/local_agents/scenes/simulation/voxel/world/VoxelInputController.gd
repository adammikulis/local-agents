class_name LAVoxelInputController
extends Node

const PauseMenuScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelPauseMenu.gd")
const ViewControlsScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/world/VoxelViewControls.gd")

## LAVoxelInputController — owns the CLI-arg parsing + all the harness/demo flag state, the per-frame
## auto-demo firing (meteor/volcano/seavolcano/stamp-test/lightning/storm/select), and is the host point
## for an in-game pause (Esc) menu. Factored out of LAVoxelWorld so the "input / Esc menu" concern is one
## file. parse_cmdline() runs first (its seeds feed the sky), then bind() wires the scene refs the demo
## hooks fire through, then update() is ticked each frame. (Explicit types only — no ':=' inferred typing.)

# --- Scene refs the demo hooks fire through (wired via bind()) ---
var _terrain = null
var _camera: Camera3D = null
var _body: Node3D = null
var _star: Node3D = null
var _material: Node = null
var _disasters: Node = null
var _interaction: Node3D = null
var _ecology: Node = null

# --- Streamer seeds (read by the world when it builds the streamer host) ---
var _streamer_enabled: bool = true        # --no-streamer (or env LA_NO_STREAMER) skips the local-LLM overlay
var _streamer_persona: String = "hype"
var _streamer_avatar_flavor: String = "male"

# --- Sky clock seeds (parsed here; the world threads them into the sky controller) ---
var _time_of_day: float = 0.30
var _lunar_phase: float = 0.15

# Optional self-screenshot / smoke harness: pass `-- --shoot=<path> [--shoot-frames=N]`
var _shoot_path: String = ""
var _shoot_frames: int = 150
var _run_frames: int = 0
var _smoke: bool = false                # --smoke: boot the MINIMAL (Potato/Low) config for fast parse+run checks
var _force_wind: float = 0.0            # --wind=<x>: force a constant eastward wind (verification)
var _cognition_stats: bool = false      # --cognition-stats: print fast/slow brain + genetics metrics
var _auto_meteor: bool = false
var _auto_barrage: bool = false          # --auto-barrage: rain a volley of large meteors (deep carve / fracture test)
var _auto_barrage_fired: bool = false
var _overview: bool = false             # --overview: frame a wide whole-island vista (screenshot aid)
var _farview: bool = false              # --farview: pull the vista out to max zoom (ocean-coverage test)
var _rain_force: bool = false           # --rain: force the rain visual on (verification aid)
var _debug_demo: bool = false
var _wind_view: bool = false            # --wind-view: enable ONLY the emergent wind-arrow overlay
var _debug_field: String = ""           # --debug-field=<channel>: pre-enable a substrate heatmap (biomass/lava/…)
var _debug_behaviors: String = ""       # --debug-behaviors[=a,b]: pre-enable behavior-state highlights (default foraging+hunting)
# --- local-LLM slow-brain control/verification flags ---
var _llm_highlight: bool = false        # --llm-highlight: pre-enable the thinking/queued tints + report live counts
var _llm_off: String = ""               # --llm-off[=all|species]: mid-run, disable the slow brain for a group (fallback proof)
var _llm_off_applied: bool = false
var _llm_off_calls_before: int = 0
var _llm_select: bool = false           # --llm-select: late in the run, select all thinking/queued creatures (predicate proof)
var _llm_select_done: bool = false
var _llm_report_frame: int = 0          # throttles the periodic LLM_HIGHLIGHT count print
var _auto_volcano: bool = false
var _auto_volcano_fired: bool = false
var _auto_seavolcano: bool = false
var _auto_seavolcano_fired: bool = false
var _seavolcano: Node = null
var _seavolcano_vent: Vector3 = Vector3.ZERO
var _auto_lightning: bool = false
var _auto_lightning_fired: bool = false
var _auto_earthquake: bool = false
var _auto_earthquake_fired: bool = false
var _auto_meteor_fired: bool = false
var _auto_select: bool = false
var _auto_select_done: bool = false
var _frame_hut: bool = false             # --frame-hut: close 3/4 shot of a villager hut with a villager beside it (scale-check aid)
var _frame_hut_done: bool = false
var _debug_family: bool = false          # --debug-family: force a real birth + select a kin, open the family-tree inspector
var _debug_family_seeded: bool = false
var _debug_family_selected: bool = false
var _debug_family_root: Node = null
var _cam_creature_done: bool = false    # latch: framed a behavior-tinted creature for the debug screenshot
var _auto_tornado: bool = false
var _auto_thunderstorm: bool = false
var _auto_hurricane: bool = false
var _auto_storm_fired: bool = false
var _stamp_test: bool = false
var _stamp_test_deposited: bool = false
var _stamp_test_reported: bool = false
var _stamp_test_target: Vector3 = Vector3.ZERO
var _stamp_test_deposit_frame: int = 0

# --- Esc pause menu (this controller is its documented host point) ---
var _pause_menu: LAVoxelPauseMenu = null

# --- Camera / view control state (this controller owns the camera-mode system) ---
# Default = drag-to-rotate only: auto-spin OFF and geosync OFF, so the world only turns when the player drags
# (playtest feedback #3). VoxelWorld gates its spin line on manual_rotate(); the planet spins when EITHER the
# auto-spin option is on OR geosync is active (geosync needs the spin to be meaningful).
var _auto_spin: bool = false     # ORBIT-mode "planet rotates in front of you" option
var _geosync: bool = false       # GEOSYNC: camera rides the planet's rotating frame, locked over one region
var _fly: bool = false           # FLY: planet-aware free-flight drone (WASD + hold-drag look + radial up/down)
var _solar_view: bool = false    # PLANET orbit ↔ SOLAR-SYSTEM overview (planet + visible sun)
var _view_controls = null                # the on-screen [Planet|Solar] · [Free|Geosync] · [Auto-spin] cluster (LAVoxelViewControls)
var _fast: int = 1                       # --fast=N: sim steps per render frame (1 = realtime)
var _trailer_shot: String = ""           # --trailer-shot=NAME: LATrailerDirector drives a scripted capture
var _face_sun: bool = false              # --face-sun: aim the camera at the star before the screenshot (sun-visibility proof)
var _face_sun_done: bool = false
var _water_cam: bool = false             # --water-cam: hover just above the sea looking across it (fluid-render proof)
var _water_cam_done: bool = false
var _menu_shot: bool = false             # --menu-shot: show the pause menu overlay before the screenshot (menu proof)
var _menu_shot_done: bool = false
var _help_shot: bool = false             # --help-shot: open the pause "Controls & help" overlay before the screenshot
var _help_shot_done: bool = false
var _start_geosync: bool = false         # --geosync: start in geosync rotation mode (verification aid)
var _start_solar: bool = false           # --solar-view: start in the solar-system overview (verification aid)
var _start_fly: bool = false             # --fly: start in fly mode down near the surface (verification aid)
var _start_mode_applied: bool = false


func parse_cmdline() -> void:
	# Build the Esc pause menu up front so it exists before any input arrives.
	_pause_menu = PauseMenuScript.new()
	_pause_menu.name = "PauseMenu"
	add_child(_pause_menu)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = int(arg.substr("--shoot-frames=".length()))
		elif arg.begins_with("--run-frames="):
			_run_frames = int(arg.substr("--run-frames=".length()))
		elif arg.begins_with("--trailer-shot="):
			# Cinematic capture: LATrailerDirector drives a scripted shot; run with --write-movie to record it.
			_trailer_shot = arg.substr("--trailer-shot=".length())
			_streamer_enabled = false
		elif arg == "--smoke":
			# Fast minimal-config boot: streamer off here + an Engine meta the settings applier reads to force the
			# Potato/Low presets (smallest grid, fewest actors, effects/FX off). One flag, two readers, no wiring.
			_smoke = true
			_streamer_enabled = false
			Engine.set_meta("la_smoke", true)
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
		elif arg.begins_with("--debug-field="):
			_debug_field = arg.substr("--debug-field=".length())
		elif arg == "--debug-behaviors":
			_debug_behaviors = "foraging,hunting"
		elif arg.begins_with("--debug-behaviors="):
			_debug_behaviors = arg.substr("--debug-behaviors=".length())
		elif arg == "--llm-highlight":
			# Pre-enable the thinking/queued tints via the shared behavior-highlight path (VoxelDebugWiring
			# reads _debug_behaviors on setup), and report live consult counts each ~150 frames.
			_llm_highlight = true
			_debug_behaviors = "llm_thinking,llm_queued"
		elif arg == "--llm-off":
			_llm_off = "all"
		elif arg.begins_with("--llm-off="):
			_llm_off = arg.substr("--llm-off=".length())
		elif arg == "--llm-select":
			_llm_select = true
		elif arg == "--auto-meteor":
			_auto_meteor = true
		elif arg == "--auto-barrage":
			_auto_barrage = true
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
		elif arg == "--auto-earthquake":
			_auto_earthquake = true
		elif arg == "--auto-select":
			_auto_select = true
		elif arg == "--frame-hut":
			_frame_hut = true
		elif arg == "--debug-family" or arg == "--debug-family=1":
			_debug_family = true
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
		elif arg.begins_with("--fast="):
			_fast = int(arg.substr("--fast=".length()))
		elif arg == "--face-sun":
			_face_sun = true
		elif arg == "--water-cam":
			_water_cam = true
		elif arg == "--menu-shot":
			_menu_shot = true
		elif arg == "--help-shot":
			_help_shot = true
		elif arg == "--geosync":
			_start_geosync = true
		elif arg == "--solar-view":
			_start_solar = true
		elif arg == "--fly":
			_start_fly = true
		elif arg == "--campaign":
			GameMode.start_campaign()      # force campaign gating for a verification run (menu sets this normally)
		elif arg == "--sandbox":
			GameMode.start_sandbox()       # force sandbox (everything unlocked) for a verification run
	# Apply the fast-forward multiplier through the pause menu's single setter (shared with the in-menu speed
	# buttons). Clamped there; N=1 leaves the engine clock untouched.
	if _pause_menu != null:
		_pause_menu.set_time_scale(_fast)


## Esc opens the pause menu (pausing the sim); G toggles geosync, F toggles fly, P toggles the solar-system
## view, K toggles the orbit-mode auto-spin. While the menu is OPEN the tree is paused so this controller stops
## receiving input and the menu itself owns Esc-to-close.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var kc: int = (event as InputEventKey).keycode
	if kc == KEY_ESCAPE and _pause_menu != null and not _pause_menu.is_open():
		_pause_menu.open()
		get_viewport().set_input_as_handled()
	elif kc == KEY_G:
		toggle_geosync()
		get_viewport().set_input_as_handled()
	elif kc == KEY_F:
		toggle_fly()
		get_viewport().set_input_as_handled()
	elif kc == KEY_P:
		toggle_solar_view()
		get_viewport().set_input_as_handled()
	elif kc == KEY_K:
		toggle_auto_spin()
		get_viewport().set_input_as_handled()


# --- Camera-mode system (rotation modes [Orbit | Geosync | Fly] + planet/solar view) -------------------------
# Spin runs (VoxelWorld gate) when EITHER the auto-spin option OR geosync is on; default = neither = manual drag.
func manual_rotate() -> bool: return not (_auto_spin or _geosync)
func auto_spin_on() -> bool: return _auto_spin
func geosync_on() -> bool: return _geosync
func fly_on() -> bool: return _fly
func solar_view_on() -> bool: return _solar_view


func set_auto_spin(on: bool) -> void:
	_auto_spin = on
	_refresh_view_controls()


func toggle_auto_spin() -> void:
	set_auto_spin(not _auto_spin)


## Plain ORBIT rotation mode: clear geosync + fly and let the camera resume its default orbit.
func set_orbit_mode() -> void:
	if _fly:
		set_fly(false)
	if _geosync:
		set_geosync(false)
	_refresh_view_controls()


## GEOSYNC: attach the camera to the planet's rotating frame (locked over one region). Enabling also turns the
## planet spin on (via manual_rotate()) so the lock is visible, and coming back to solar/orbit is lossless.
func set_geosync(on: bool) -> void:
	# Gated capability: geosync is earned mid-campaign (sandbox / no progression = always available).
	if on and not LAGameProgression.cap_unlocked("view_geosync"):
		_refresh_view_controls()
		return
	_geosync = on
	if on:
		_fly = false
		_auto_spin = true            # a geosynchronous lock only reads as such against a spinning planet
		if _solar_view:
			set_solar_view(false)    # geosync is a close-region mode; leave the pulled-back overview
	if _camera != null and _camera.has_method("set_geosync"):
		_camera.set_geosync(on)
	_refresh_view_controls()


func toggle_geosync() -> void:
	set_geosync(not _geosync)


## FLY / DRONE free-flight: WASD + hold-drag look + radial lift/descend + Shift boost. Mutually exclusive with
## geosync and the solar overview.
func set_fly(on: bool) -> void:
	_fly = on
	if on:
		_geosync = false
		if _solar_view:
			set_solar_view(false)
	if _camera != null and _camera.has_method("set_fly"):
		_camera.set_fly(on)
	_refresh_view_controls()


func toggle_fly() -> void:
	set_fly(not _fly)


## PLANET ↔ SOLAR-SYSTEM view. Solar = a pulled-back manual framing that shows the planet AND the sun in one
## shot; planet = the default close orbit. Needs the star + body refs (wired in bind()).
func set_solar_view(on: bool) -> void:
	# Gated capability: the solar-system overview is the campaign CAPSTONE (sandbox / no progression = available).
	if on and not LAGameProgression.cap_unlocked("view_solar"):
		_refresh_view_controls()
		return
	_solar_view = on
	if _camera == null:
		return
	if on:
		if _geosync:
			set_geosync(false)       # the overview is a fixed-frame shot, not a region ride
		if _fly:
			set_fly(false)
		_apply_solar_view()
	elif _camera.has_method("set_planet_view"):
		_camera.set_planet_view()
	_refresh_view_controls()


func toggle_solar_view() -> void:
	set_solar_view(not _solar_view)


## Compute a pulled-back pose that frames the planet and the star together, then hand it to the camera.
func _apply_solar_view() -> void:
	if _star == null or _body == null or not _camera.has_method("set_solar_view"):
		return
	var center: Vector3 = _body.center()
	var star_pos: Vector3 = _star.global_position
	var sun_dir: Vector3 = (star_pos - center).normalized()
	var perp: Vector3 = sun_dir.cross(Vector3.UP)
	if perp.length() < 0.01:
		perp = Vector3.RIGHT
	perp = perp.normalized()
	var span: float = center.distance_to(star_pos)
	# Sit back off to one side of the planet↔sun axis (+ slightly up) far enough that BOTH the planet and the
	# sun fall inside the frustum, looking at the midpoint between them.
	var midpoint: Vector3 = center.lerp(star_pos, 0.5)
	var pos: Vector3 = midpoint + perp * (span * 1.0) + Vector3.UP * (span * 0.2)
	_camera.set_solar_view(pos, midpoint, pos.distance_to(center))


## Position the drone low over the surface, looking across the terrain (creatures/trees in view). Verification
## framing for --fly; also a sensible default place to drop into flight.
func _apply_fly_view() -> void:
	if _camera == null or not _camera.has_method("place_fly") or _body == null or _terrain == null:
		set_fly(true)
		return
	set_fly(true)
	var center: Vector3 = _body.center()
	var sp: Vector3 = _terrain.surface_point(Vector3.UP) if _terrain.has_method("surface_point") else (center + Vector3.UP * 200.0)
	if is_nan(sp.x):
		return
	var radial: Vector3 = (sp - center).normalized()
	var radius: float = _body.radius() if _body.has_method("radius") else sp.distance_to(center)
	var tangent: Vector3 = radial.cross(Vector3.UP)
	if tangent.length() < 0.01:
		tangent = radial.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	# Sit a little above the surface and back along the tangent, looking forward + slightly down at the ground.
	var pos: Vector3 = sp + radial * (radius * 0.05) - tangent * (radius * 0.10)
	var look_target: Vector3 = sp + tangent * (radius * 0.12) - radial * (radius * 0.02)
	_camera.place_fly(pos, look_target)


func _refresh_view_controls() -> void:
	if _view_controls != null:
		_view_controls.call("refresh", _solar_view, _geosync, _fly, _auto_spin)


## Wire the scene refs the auto-demo hooks act on (called from the world once the scene is composed).
func bind(terrain, camera: Camera3D, body: Node3D, star: Node3D, material: Node, disasters: Node, interaction: Node3D, ecology: Node) -> void:
	_terrain = terrain
	_camera = camera
	_body = body
	_star = star
	_material = material
	_disasters = disasters
	_interaction = interaction
	_ecology = ecology
	# Wire the planet body so the camera's GEOSYNC mode can read its rotating frame (keeps VoxelWorld untouched).
	if _camera != null and _camera.has_method("set_geosync_body"):
		_camera.set_geosync_body(_body)
	# Build the on-screen view-controls cluster: [Planet | Solar System] · [Free | Geosync] · [Auto-spin].
	_view_controls = ViewControlsScript.new()
	_view_controls.name = "ViewControls"
	add_child(_view_controls)
	_view_controls.call("setup", self)
	_refresh_view_controls()


# The disasters controller fired the one-shot auto-meteor test; latch it so update() won't refire.
func mark_auto_meteor_fired() -> void:
	_auto_meteor_fired = true


## Per-frame auto-demo firing. `frame` is the world's frame counter; `spawned` gates every hook on the
## ecology being placed. Pure harness/CLI behaviour — no-op unless a --auto-* / --stamp-test flag is set.
func update(frame: int, spawned: bool) -> void:
	# Auto-meteor demo/test: drop a meteor on a forest so it carves a crater, topples trees, ignites fire.
	if _auto_meteor and not _auto_meteor_fired and spawned:
		var trigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if frame == trigger:
			_disasters.fire_test_meteor()

	# Auto-barrage demo/test: rain a volley of large meteors to dig deep (expose crust->mantle->magma) + fracture.
	if _auto_barrage and not _auto_barrage_fired and spawned:
		var btrigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if frame >= btrigger and _disasters != null and _disasters.has_method("fire_barrage"):
			_disasters.fire_barrage()
			_auto_barrage_fired = true

	# Auto-volcano demo/test: raise a volcano near origin that ERUPTS IMMEDIATELY (force_erupt), frame
	# the camera on it, and fire it ~560 frames (~5s) before the screenshot.
	if _auto_volcano and not _auto_volcano_fired and spawned:
		var vtrigger: int = 350 if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if frame >= vtrigger:
			var vsite: Vector3 = _terrain.surface_point(Vector3(0.2, 1.0, 0.2).normalized()) if _terrain.has_method("surface_point") else Vector3(NAN, NAN, NAN)
			if not is_nan(vsite.x):
				var vc: Node = _disasters.spawn_volcano(vsite)
				if vc != null and vc.has_method("force_erupt"):
					vc.force_erupt()
				if _camera != null and _camera.has_method("frame_vista"):
					_camera.frame_vista(vsite)
				_auto_volcano_fired = true

	# CAPSTONE — auto-seavolcano: seed a SEABED vent EARLY so the sustained supply has a long window to build a
	# new island underwater and breach the surface. Frame the camera on the SEA SURFACE above the vent.
	if _auto_seavolcano and not _auto_seavolcano_fired and spawned and frame >= 120:
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
	if _auto_seavolcano and _seavolcano != null and frame % 150 == 0:
		var vd: Vector3 = (_seavolcano.global_position - _body.center()).normalized()
		var vr: float = _terrain.surface_radius(vd)
		var sea_r2: float = _terrain.sea_radius()
		print("SEAVOLCANO={frame:%d, vent_r:%.2f, sea_r:%.2f, above_sea:%s, supplied:%.0f}" % [
			frame, (vr if not is_nan(vr) else -1.0), sea_r2,
			str((not is_nan(vr)) and vr > sea_r2), _seavolcano.total_supplied])

	# Rock Stage C proof: deposit rock into a VOID cell ~3 units above the top surface, then confirm the
	# rock_fill 0.5-crossing GROWS terrain (is_solid flips false->true at the stamp point).
	if _stamp_test and spawned and _material != null:
		if not _stamp_test_deposited and frame >= 90:
			var sp: Vector3 = _terrain.surface_point(Vector3.UP)
			if not is_nan(sp.x) and _material.get("_stamp") != null:
				_stamp_test_target = sp + (sp - _body.center()).normalized() * 3.0
				_material._stamp.debug_deposit(_stamp_test_target, 1.0)
				_stamp_test_deposited = true
				_stamp_test_deposit_frame = frame
				print("STAMP_TEST_DEPOSIT={pos:%v, before_solid:%s}" % [_stamp_test_target, str(_terrain.is_solid(_stamp_test_target))])
		elif _stamp_test_deposited and not _stamp_test_reported:
			var st = _material._stamp
			var grew: bool = st != null and st.grows > 0
			# Report the MOMENT the grow fires, or a failure marker if none fired within ~250 frames.
			if grew or frame > _stamp_test_deposit_frame + 250:
				print("STAMP_TEST={grew:%s, at_frame:%d, grows:%d, shrinks:%d, before_solid:%s, after_solid:%s, live_is_solid:%s, scan_ms:%.3f}" % [
					str(grew), frame, (st.grows if st != null else 0), (st.shrinks if st != null else 0),
					str(st.last_grow_before_solid if st != null else false),
					str(st.last_grow_after_solid if st != null else false),
					str(_terrain.is_solid(st.last_grow_pos) if (st != null and grew) else false),
					(st.last_scan_ms if st != null else 0.0)])
				_stamp_test_reported = true

	# Auto-lightning demo/test: strike the nearest tree so a wildfire emerges from the bolt's heat.
	if _auto_lightning and not _auto_lightning_fired and spawned:
		var ltrigger: int = (_shoot_frames - 240) if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if frame >= ltrigger:
			_disasters.fire_test_lightning()
			_auto_lightning_fired = true

	# Auto-earthquake demo/test: release ONE stress wave near origin, LATE in the run so the propagating
	# seismic wave is still crossing at the final SIM_REPORT snapshot (shock_cells > 0). The wave itself
	# shakes the camera and panics wildlife — no per-pulse scatter. Spawn kept method-local here.
	if _auto_earthquake and not _auto_earthquake_fired and spawned and _terrain != null and _body != null:
		var qtrigger: int = (_shoot_frames - 120) if _shoot_path != "" else maxi(_run_frames - 45, 45)
		if frame >= qtrigger:
			_auto_earthquake_fired = true
			var qsite: Vector3 = _terrain.surface_point(Vector3.UP) if _terrain.has_method("surface_point") else Vector3(NAN, NAN, NAN)
			var epicentre: Vector3 = qsite if not is_nan(qsite.x) else (_body.center() + Vector3.UP * (_body.radius() if _body.has_method("radius") else 200.0))
			var quake_script: GDScript = load("res://addons/local_agents/scenes/simulation/voxel/actors/Earthquake.gd")
			var quake: Node3D = quake_script.new()
			_body.add_child(quake)
			quake.global_position = epicentre
			quake.setup(_terrain, _ecology)
			quake.rupture(epicentre)
			print("AUTO_EARTHQUAKE={frame:%d, epicentre:%v}" % [frame, epicentre])

	# Auto-storm demos/tests: touch down a tornado / seed a thunderstorm / spin up a hurricane.
	if (_auto_tornado or _auto_thunderstorm or _auto_hurricane) and not _auto_storm_fired and spawned:
		var strigger: int = (_shoot_frames - 200) if _shoot_path != "" else maxi(_run_frames - 400, 40)
		if frame >= strigger:
			_auto_storm_fired = true
			var kind: String = "hurricane" if _auto_hurricane else ("thunderstorm" if _auto_thunderstorm else "tornado")
			var focus: Vector3 = _disasters.fire_auto_storm(kind)
			if _camera != null and _camera.has_method("frame_vista"):
				_camera.frame_vista(focus)

	# Verification-aid CLI (--geosync / --solar-view): apply the start camera mode AFTER the ecology spawn has
	# framed the camera, so the mode framing holds (otherwise spawn's vista overrides it).
	if (_start_geosync or _start_solar or _start_fly) and not _start_mode_applied and spawned:
		var mtrigger: int = (_shoot_frames - 50) if _shoot_path != "" else 100
		if frame >= mtrigger:
			if _start_geosync:
				set_geosync(true)
			if _start_solar:
				set_solar_view(true)
			if _start_fly:
				_apply_fly_view()
			_start_mode_applied = true

	# --face-sun: just before the screenshot, place the camera at the planet's limb looking straight at the
	# star so the glowing sun body is in frame (visible-sun verification). Orbit-mode _process holds a manual
	# transform, so this framing sticks.
	if _face_sun and not _face_sun_done and _shoot_path != "" and _camera != null and _star != null and _body != null:
		if frame >= _shoot_frames - 60:
			var center: Vector3 = _body.center()
			var star_pos: Vector3 = _star.global_position
			var sun_dir: Vector3 = (star_pos - center).normalized()
			var perp: Vector3 = sun_dir.cross(Vector3.UP)
			if perp.length() < 0.01:
				perp = Vector3.RIGHT
			perp = perp.normalized()
			var radius: float = _body.radius() if _body.has_method("radius") else 150.0
			_camera.global_position = center + perp * (radius * 1.4) + Vector3.UP * (radius * 0.4) + sun_dir * (radius * 0.6)
			_camera.look_at(star_pos, Vector3.UP)
			_face_sun_done = true

	# --water-cam: hover the camera just above sea level looking ACROSS the water toward a nearby shore, so the
	# dynamic fluid surface (waves/foam/salinity) fills the frame — the close-up render proof I otherwise can't
	# frame. Sits inside FAR_ALT so the dynamic surface (not the far sphere) draws.
	if _water_cam and not _water_cam_done and _shoot_path != "" and _camera != null and _body != null:
		if frame >= _shoot_frames - 60:
			var wc_center: Vector3 = _body.center()
			var sea_r: float = _body.sea_radius() if _body.has_method("sea_radius") else 500.0
			var wdir: Vector3 = Vector3(0.42, 0.36, 0.83).normalized()      # a fixed spot over open sea
			var wtan: Vector3 = wdir.cross(Vector3.UP).normalized()
			_camera.global_position = wc_center + wdir * (sea_r + 18.0)     # ~18 units above the sea surface
			var look_dir: Vector3 = (wdir + wtan * 0.9).normalized()        # across the water, toward the horizon
			_camera.look_at(wc_center + look_dir * (sea_r + 2.0), wdir)     # up = local radial
			_water_cam_done = true

	# --menu-shot: show the pause menu OVERLAY (without pausing, so the capture loop keeps ticking) just before
	# the screenshot, and self-test that open() would pause the tree — the menu proof.
	if _menu_shot and not _menu_shot_done and _shoot_path != "" and _pause_menu != null:
		if frame >= _shoot_frames - 6:
			get_tree().paused = true
			var pause_ok: bool = get_tree().paused
			get_tree().paused = false
			print("MENU_PAUSE_SELFTEST paused_toggles=", pause_ok)
			_pause_menu.open(false)
			_menu_shot_done = true

	# --help-shot: open the pause menu's "Controls & help" overlay (without pausing, so the capture loop keeps
	# ticking) just before the screenshot, and confirm the entry resolves — the in-sim controls-reference proof.
	if _help_shot and not _help_shot_done and _shoot_path != "" and _pause_menu != null:
		if frame >= _shoot_frames - 6:
			_pause_menu.open(false)
			var overlay: Control = _pause_menu.open_controls_help()
			print("PAUSE_HELP_OK resolved=", overlay != null and is_instance_valid(overlay))
			_help_shot_done = true

	# Auto-select demo: frame a real creature close-up and run the REAL selection path so the
	# thought-inspector panel populates. We select the node DIRECTLY (select_node) rather than a
	# center-screen raycast, so it's deterministic at any camera scale (orbit framing can't make the
	# ray miss). Prefers an actively-behaving creature so the shot shows a live decision.
	if _auto_select and not _auto_select_done and spawned and frame == _shoot_frames - 40:
		var pick: Node3D = _pick_showcase_creature()
		if pick != null:
			_frame_camera_on(pick.global_position)
			_interaction.select_node(pick)
			var sel: Node = _interaction.selected()
			var title: String = ""
			if sel != null:
				title = String(sel.call("get_inspector_payload").get("title", ""))
			print("SELECT_RESULT selected=", sel != null, " ring_visible=", _interaction.selection_ring_visible(), " title=", title)
		_auto_select_done = true

	# Behavior-tint debug screenshot: swoop the camera down onto a creature that is actually in a tinted
	# state (foraging/hunting/…), so the green/red highlight fills the frame instead of being a sub-pixel
	# speck at whole-planet framing. In orbit mode _process leaves a manual transform in place (no per-frame
	# rebuild), so this framing holds for the capture.
	if _debug_behaviors != "" and _shoot_path != "" and not _cam_creature_done and spawned and frame == _shoot_frames - 6:
		_cam_creature_done = true
		_frame_tinted_creature()

	# --frame-hut: swing the camera onto a villager hut with a villager stood beside it, so a
	# reviewer can read the dwelling's scale against a ~1.8 m human. Set just before the capture.
	if _frame_hut and _shoot_path != "" and not _frame_hut_done and spawned and frame == _shoot_frames - 6:
		_frame_hut_done = true
		_frame_villager_hut()

	# --debug-family: force a REAL family through the ecology (two founders breed; one child dies) so the
	# kinship graph holds >=2 generations + a mate bond + a dead kin, then select a parent so the family-tree
	# inspector (opened by VoxelDebugWiring) draws a deterministic tree for the screenshot. All reads/edits go
	# through the real reproduction + death paths — the panel itself only reads the graph.
	if _debug_family and spawned and _ecology != null:
		if not _debug_family_seeded and frame >= 40:
			if _ecology.has_method("debug_seed_family"):
				_debug_family_root = _ecology.debug_seed_family()
			_debug_family_seeded = true
		if _debug_family_seeded and not _debug_family_selected:
			var ftrigger: int = (_shoot_frames - 40) if _shoot_path != "" else maxi(_run_frames - 40, 60)
			if frame >= ftrigger:
				_debug_family_selected = true
				if _debug_family_root != null and is_instance_valid(_debug_family_root) and _interaction != null:
					if _interaction.has_method("select_node"):
						_interaction.select_node(_debug_family_root)
					if _camera != null and _camera.has_method("focus_on"):
						_camera.focus_on((_debug_family_root as Node3D).global_position)

	# Local-LLM slow-brain control/verification hooks (--llm-highlight / --llm-off / --llm-select).
	_tick_llm(frame, spawned)


# Local-LLM slow-brain harness hooks. Non-interactive proofs of the player controls, all through the real
# paths (no fabricated state): report who is consulting the model live, disable a group mid-run and show the
# slow-brain calls plateau (clean fallback), and select the whole thinking/queued set via the predicate.
func _tick_llm(frame: int, spawned: bool) -> void:
	if not spawned:
		return
	var sched = _ecology.cognition_scheduler() if (_ecology != null and _ecology.has_method("cognition_scheduler")) else null

	# --llm-highlight: periodic live count of who is thinking/queued (the tints are enabled via _debug_behaviors).
	if _llm_highlight and sched != null and frame - _llm_report_frame >= 150:
		_llm_report_frame = frame
		var think_n: int = LALLMControl.count(get_tree(), "thinking", sched)
		var queue_n: int = LALLMControl.count(get_tree(), "queued", sched)
		print("LLM_HIGHLIGHT={frame:%d, thinking:%d, queued:%d, slow_brain_calls:%d}" % [
			frame, think_n, queue_n, (sched.total_calls() if sched.has_method("total_calls") else 0)])

	# --llm-off: let escalations run, snapshot the slow-brain call count, disable the group, then print the
	# after count near the end — a disabled group makes ZERO new slow-brain calls (clean fast-path fallback).
	if _llm_off != "" and sched != null:
		var off_trigger: int = (_shoot_frames - 200) if _shoot_path != "" else maxi(_run_frames / 2, 100)
		var species: String = "" if _llm_off == "all" else _llm_off
		if not _llm_off_applied and frame >= off_trigger:
			_llm_off_applied = true
			_llm_off_calls_before = sched.total_calls() if sched.has_method("total_calls") else 0
			var changed: int = LALLMControl.set_group(get_tree(), species, false)
			print("LLM_OFF_APPLIED={scope:%s, disabled:%d, slow_brain_calls_before:%d, frame:%d}" % [
				_llm_off, changed, _llm_off_calls_before, frame])
		elif _llm_off_applied:
			# Keep the group disabled: creatures BORN after the disable spawn with the config default (on), so
			# re-apply periodically to prove a sustained "group off" truly halts new slow-brain calls.
			if frame % 30 == 0:
				LALLMControl.set_group(get_tree(), species, false)
			var end_frame: int = (_shoot_frames - 4) if _shoot_path != "" else maxi(_run_frames - 2, off_trigger + 2)
			if frame == end_frame:
				var after: int = sched.total_calls() if sched.has_method("total_calls") else 0
				print("LLM_OFF_AFTER={slow_brain_calls_after:%d, delta_after_disable:%d, frame:%d}" % [
					after, after - _llm_off_calls_before, frame])

	# --llm-select: late in the run, select every creature thinking/queued through the real predicate path.
	if _llm_select and not _llm_select_done and _interaction != null and sched != null:
		var sel_trigger: int = (_shoot_frames - 30) if _shoot_path != "" else maxi(_run_frames - 30, 60)
		if frame >= sel_trigger:
			_llm_select_done = true
			var pred: Callable = func(c) -> bool: return LALLMControl.matches(c, "any", sched)
			if _interaction.has_method("select_by_predicate"):
				var n: int = _interaction.select_by_predicate(pred)
				print("LLM_SELECT_TEST={count:%d, selected:%s}" % [n, str(_interaction.selected() != null)])


# Position the camera close to a behavior-tinted creature (prefer one whose state maps to an enabled
# category — foraging/hunting — else the nearest creature) and look down at it from just above the surface.
func _frame_tinted_creature() -> void:
	if _camera == null or _terrain == null:
		return
	var pick: Node3D = _pick_showcase_creature()
	if pick == null:
		return
	_frame_camera_on(pick.global_position)


# Pick a creature worth showcasing in a demo/screenshot: prefer one actively behaving (eating, hunting,
# fleeing, drinking…) so a live decision is on screen, else the first creature there is.
func _pick_showcase_creature() -> Node3D:
	const ACTIVE_STATES: Array = ["eat", "chase", "stalk", "track", "throw", "flee", "panic", "drink", "seek"]
	# When the LLM highlight is active, prefer a creature actually consulting/queued on the slow brain so the
	# thinking/queued tint fills the frame (else fall through to the ordinary active-behavior showcase).
	if _llm_highlight and _ecology != null and _ecology.has_method("cognition_scheduler"):
		var sched = _ecology.cognition_scheduler()
		if sched != null:
			for a in get_tree().get_nodes_in_group("creature"):
				if a is Node3D and LALLMControl.matches(a, "any", sched):
					return a
	var pick: Node3D = null            # first foraging (green) creature, preferred for the demo shot
	var pick2: Node3D = null           # any other actively-tinted creature (hunting/fleeing/…)
	var fallback: Node3D = null
	for a in get_tree().get_nodes_in_group("creature"):
		if not (a is Node3D):
			continue
		if fallback == null:
			fallback = a
		var st: String = String(a.get("state"))
		if st == "eat" and pick == null:
			pick = a
		elif ACTIVE_STATES.has(st) and pick2 == null:
			pick2 = a
	if pick == null:
		pick = pick2
	if pick == null:
		pick = fallback
	return pick


# Place the camera a few metres off the surface above `p`, looking at it (surface-relative up so the
# framing holds on any face of the planet).
func _frame_camera_on(p: Vector3) -> void:
	if _camera == null:
		return
	var center: Vector3 = _terrain.planet_center() if _terrain != null and _terrain.has_method("planet_center") else Vector3.ZERO
	var up: Vector3 = (p - center).normalized()
	if up.length() < 0.001:
		up = Vector3.UP
	var tangent: Vector3 = up.cross(Vector3.RIGHT)
	if tangent.length() < 0.001:
		tangent = up.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	_camera.global_position = p + up * 6.0 + tangent * 6.0
	_camera.look_at(p, up)


# Frame a close 3/4 view of a ground villager hut, with the nearest villager stood right beside it,
# so the dwelling's scale is legible against a ~1.8 m human. A screenshot-only verification aid.
func _frame_villager_hut() -> void:
	if _camera == null or _terrain == null:
		return
	var hut: Node3D = null
	for n in get_tree().get_nodes_in_group("nest"):
		if n is Node3D and String(n.get("species")) == "villager" and not bool(n.get("in_tree")):
			hut = n
			break
	if hut == null:
		return
	var p: Vector3 = hut.global_position
	var center: Vector3 = _terrain.planet_center() if _terrain.has_method("planet_center") else Vector3.ZERO
	var up: Vector3 = (p - center).normalized()
	if up.length() < 0.001:
		up = Vector3.UP
	var tangent: Vector3 = up.cross(Vector3.RIGHT)
	if tangent.length() < 0.001:
		tangent = up.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	var side: Vector3 = up.cross(tangent).normalized()
	# Stand the nearest villager right beside the hut so a human is guaranteed in frame at true scale.
	var vill: Node3D = null
	var best: float = INF
	for a in get_tree().get_nodes_in_group("creature"):
		if a is Node3D and String(a.get("species")) == "villager":
			var d: float = (p - (a as Node3D).global_position).length()
			if d < best:
				best = d
				vill = a
	if vill != null:
		vill.global_position = p + tangent * 1.9
	var focus: Vector3 = p + up * 1.2 + tangent * 0.9
	_camera.global_position = p + up * 2.2 + tangent * 3.2 + side * 3.6
	_camera.look_at(focus, up)


# --- Flag accessors (read by the world composition root) ---------------------
func streamer_enabled() -> bool: return _streamer_enabled
func streamer_persona() -> String: return _streamer_persona
func streamer_avatar_flavor() -> String: return _streamer_avatar_flavor
func time_of_day_seed() -> float: return _time_of_day
func lunar_seed() -> float: return _lunar_phase
func shoot_path() -> String: return _shoot_path
func shoot_frames() -> int: return _shoot_frames
func run_frames() -> int: return _run_frames
func smoke() -> bool: return _smoke
func force_wind() -> float: return _force_wind
func overview() -> bool: return _overview
func farview() -> bool: return _farview
func auto_meteor() -> bool: return _auto_meteor
func trailer_shot() -> String: return _trailer_shot

# Live fast-forward multiplier (sim steps per rendered frame) — forwards to the pause menu's clamped setter, the
# same one the in-menu speed buttons and the --fast cmdline use. Lets the trailer director time-lapse mid-shot.
func set_time_scale(n: int) -> void:
	_fast = maxi(1, n)
	if _pause_menu != null and _pause_menu.has_method("set_time_scale"):
		_pause_menu.set_time_scale(_fast)
func auto_select() -> bool: return _auto_select
func debug_family() -> bool: return _debug_family
func auto_seavolcano() -> bool: return _auto_seavolcano
func debug_demo() -> bool: return _debug_demo
func wind_view() -> bool: return _wind_view
func debug_field() -> String: return _debug_field
func debug_behaviors() -> String: return _debug_behaviors
func fast_multiplier() -> int: return _fast
