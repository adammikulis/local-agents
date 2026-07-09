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
var _force_wind: float = 0.0            # --wind=<x>: force a constant eastward wind (verification)
var _cognition_stats: bool = false      # --cognition-stats: print fast/slow brain + genetics metrics
var _auto_meteor: bool = false
var _overview: bool = false             # --overview: frame a wide whole-island vista (screenshot aid)
var _farview: bool = false              # --farview: pull the vista out to max zoom (ocean-coverage test)
var _rain_force: bool = false           # --rain: force the rain visual on (verification aid)
var _debug_demo: bool = false
var _wind_view: bool = false            # --wind-view: enable ONLY the emergent wind-arrow overlay
var _auto_volcano: bool = false
var _auto_volcano_fired: bool = false
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
var _auto_spin: bool = false     # FREE-mode "planet rotates in front of you" option
var _geosync: bool = false       # GEOSYNC: camera rides the planet's rotating frame, locked over one region
var _solar_view: bool = false    # PLANET orbit ↔ SOLAR-SYSTEM overview (planet + visible sun)
var _view_controls = null                # the on-screen [Planet|Solar] · [Free|Geosync] · [Auto-spin] cluster (LAVoxelViewControls)
var _fast: int = 1                       # --fast=N: sim steps per render frame (1 = realtime)
var _face_sun: bool = false              # --face-sun: aim the camera at the star before the screenshot (sun-visibility proof)
var _face_sun_done: bool = false
var _menu_shot: bool = false             # --menu-shot: show the pause menu overlay before the screenshot (menu proof)
var _menu_shot_done: bool = false
var _start_geosync: bool = false         # --geosync: start in geosync rotation mode (verification aid)
var _start_solar: bool = false           # --solar-view: start in the solar-system overview (verification aid)
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
		elif arg.begins_with("--fast="):
			_fast = int(arg.substr("--fast=".length()))
		elif arg == "--face-sun":
			_face_sun = true
		elif arg == "--menu-shot":
			_menu_shot = true
		elif arg == "--geosync":
			_start_geosync = true
		elif arg == "--solar-view":
			_start_solar = true
	# Apply the fast-forward multiplier through the pause menu's single setter (shared with the in-menu speed
	# buttons). Clamped there; N=1 leaves the engine clock untouched.
	if _pause_menu != null:
		_pause_menu.set_time_scale(_fast)


## Esc opens the pause menu (pausing the sim); G toggles geosync, P toggles the solar-system view, K toggles
## the free-mode auto-spin. While the menu is OPEN the tree is paused so this controller stops receiving input
## and the menu itself owns Esc-to-close.
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
	elif kc == KEY_P:
		toggle_solar_view()
		get_viewport().set_input_as_handled()
	elif kc == KEY_K:
		toggle_auto_spin()
		get_viewport().set_input_as_handled()


# --- Camera-mode system (rotation modes + planet/solar view) ------------------
# Spin runs (VoxelWorld gate) when EITHER the auto-spin option OR geosync is on; default = neither = manual drag.
func manual_rotate() -> bool: return not (_auto_spin or _geosync)
func auto_spin_on() -> bool: return _auto_spin
func geosync_on() -> bool: return _geosync
func solar_view_on() -> bool: return _solar_view


func set_auto_spin(on: bool) -> void:
	_auto_spin = on
	_refresh_view_controls()


func toggle_auto_spin() -> void:
	set_auto_spin(not _auto_spin)


## GEOSYNC: attach the camera to the planet's rotating frame (locked over one region). Enabling also turns the
## planet spin on (via manual_rotate()) so the lock is visible, and coming back to solar/free is lossless.
func set_geosync(on: bool) -> void:
	_geosync = on
	if on:
		_auto_spin = true            # a geosynchronous lock only reads as such against a spinning planet
		if _solar_view:
			set_solar_view(false)    # geosync is a close-region mode; leave the pulled-back overview
	if _camera != null and _camera.has_method("set_geosync"):
		_camera.set_geosync(on)
	_refresh_view_controls()


func toggle_geosync() -> void:
	set_geosync(not _geosync)


## PLANET ↔ SOLAR-SYSTEM view. Solar = a pulled-back manual framing that shows the planet AND the sun in one
## shot; planet = the default close orbit. Needs the star + body refs (wired in bind()).
func set_solar_view(on: bool) -> void:
	_solar_view = on
	if _camera == null:
		return
	if on:
		if _geosync:
			set_geosync(false)       # the overview is a fixed-frame shot, not a region ride
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


func _refresh_view_controls() -> void:
	if _view_controls != null:
		_view_controls.call("refresh", _solar_view, _geosync, _auto_spin)


## Wire the scene refs the auto-demo hooks act on (called from the world once the scene is composed).
func bind(terrain, camera: Camera3D, body: Node3D, star: Node3D, material: Node, disasters: Node, interaction: Node3D) -> void:
	_terrain = terrain
	_camera = camera
	_body = body
	_star = star
	_material = material
	_disasters = disasters
	_interaction = interaction
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

	# Auto-volcano demo/test: raise a volcano near origin that ERUPTS IMMEDIATELY (force_erupt), frame
	# the camera on it, and fire it ~560 frames (~5s) before the screenshot.
	if _auto_volcano and not _auto_volcano_fired and spawned:
		var vtrigger: int = 350 if _shoot_path != "" else maxi(_run_frames - 600, 60)
		if frame >= vtrigger:
			var oh: float = _terrain.surface_height(20.0, 20.0)
			if not is_nan(oh):
				var vc: Node = _disasters.spawn_volcano(Vector3(20.0, oh, 20.0))
				if vc != null and vc.has_method("force_erupt"):
					vc.force_erupt()
				if _camera != null and _camera.has_method("frame_vista"):
					_camera.frame_vista(Vector3(20.0, oh, 20.0))
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
	if (_start_geosync or _start_solar) and not _start_mode_applied and spawned:
		var mtrigger: int = (_shoot_frames - 50) if _shoot_path != "" else 100
		if frame >= mtrigger:
			if _start_geosync:
				set_geosync(true)
			if _start_solar:
				set_solar_view(true)
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

	# Auto-select demo: aim at the nearest creature and run the real selection path.
	if _auto_select and not _auto_select_done and spawned and frame == _shoot_frames - 40:
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


# --- Flag accessors (read by the world composition root) ---------------------
func streamer_enabled() -> bool: return _streamer_enabled
func streamer_persona() -> String: return _streamer_persona
func streamer_avatar_flavor() -> String: return _streamer_avatar_flavor
func time_of_day_seed() -> float: return _time_of_day
func lunar_seed() -> float: return _lunar_phase
func shoot_path() -> String: return _shoot_path
func shoot_frames() -> int: return _shoot_frames
func run_frames() -> int: return _run_frames
func force_wind() -> float: return _force_wind
func overview() -> bool: return _overview
func farview() -> bool: return _farview
func auto_meteor() -> bool: return _auto_meteor
func auto_select() -> bool: return _auto_select
func auto_seavolcano() -> bool: return _auto_seavolcano
func debug_demo() -> bool: return _debug_demo
func wind_view() -> bool: return _wind_view
func fast_multiplier() -> int: return _fast
