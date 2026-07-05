@tool
class_name LAVoxelCameraRig
extends Camera3D

## RTS-style orbit camera for the voxel simulation (Black & White feel).
##
##   - Middle-mouse drag to rotate the view (orbit): horizontal = heading/yaw, vertical =
##     tilt/pitch. WASD / arrow keys pan; push the cursor to a screen edge to edge-scroll.
##   - Mouse wheel zooms in / out.
##   - Shift + middle-mouse drag grabs & pans the terrain; Q / E rotate
##     yaw and R / F tilt pitch from the keyboard. (LMB = select/grab and RMB = spawn/cast
##     are handled by VoxelWorld, so the camera leaves both those buttons free.)
##   - The cursor stays visible (only captured while actively dragging) so HUD clicks,
##     selection, and placement keep working.
##
## The rig is defined by a ground focus point plus a spherical offset (distance/yaw/pitch);
## panning moves the focus, zoom changes the distance, orbit changes yaw/pitch. The camera
## transform is rebuilt from that state every time it changes (_update_transform()).
##
## Hosts the VoxelViewer in the integration scene (VoxelWorld calls
## terrain.attach_viewer(camera)). Exposes aim_ray() for click-to-place / select and
## focus_on()/frame_vista() so the world can recenter the view without fighting the rebuild.

# --- Tunables -----------------------------------------------------------------
const MIN_DISTANCE: float = 4.0           # closest zoom (units from focus) — down close on an animal
const MAX_DISTANCE: float = 1400.0        # farthest zoom — pull way out for a whole-world view
const ZOOM_STEP: float = 1.15             # wheel multiplier per notch
const PAN_SPEED: float = 140.0            # WASD/arrow-key pan, per second, scaled by distance
const DRAG_PAN_SPEED: float = 6.0         # Shift+MMB drag pan, per pixel, scaled by distance
const ORBIT_SENSITIVITY: float = 0.0075   # MMB drag orbit, radians per pixel
const KEY_YAW_SPEED: float = 1.6          # Q/E yaw, radians per second
const EDGE_MARGIN: float = 12.0           # px from a screen edge that triggers edge-scroll
const EDGE_PAN_SPEED: float = 70.0         # edge-scroll pan, per second, scaled by distance
const PITCH_MIN: float = deg_to_rad(15.0) # shallowest downward tilt
const PITCH_MAX: float = deg_to_rad(85.0) # steepest (near top-down) tilt
const RAY_LENGTH: float = 4000.0

# Reference distance the pan speeds are tuned against; panning scales with distance so the
# world moves a consistent fraction of the screen at every zoom level.
const PAN_REFERENCE_DISTANCE: float = 100.0

# --- State --------------------------------------------------------------------
var _focus: Vector3 = Vector3.ZERO
var _distance: float = 140.0
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(55.0)
var _panning: bool = false
var _orbiting: bool = false

# Screen shake (earthquakes, big impacts). Trauma 0..1 decays; the applied offset is removed and
# re-added each frame so it never accumulates into the fly position.
const SHAKE_MAG: float = 1.8
const TRAUMA_DECAY: float = 1.1
# How strongly felt seismic energy (from the ecology's seismic field) converts to trauma per second.
# The shake now EMERGES from ground motion: any disturbance emits a seismic pulse, the rig queries the
# energy at its own position each frame and feeds it here — no event tells the camera to shake.
const SEISMIC_TRAUMA_GAIN: float = 2.0
var _trauma: float = 0.0
var _shake_applied: Vector3 = Vector3.ZERO
var _ecology: Object = null                # LAEcologyService — source of the seismic field (set by VoxelWorld)


## Add camera trauma (0..1). The low-level shake primitive; it decays on its own. Driven emergently
## by felt seismic energy (see _process), not by disaster code calling it directly.
func add_shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Wire the ecology so the rig can query seismic_energy_at() and shake in response to ground motion.
func set_ecology(ecology: Object) -> void:
	_ecology = ecology


func _ready() -> void:
	current = true
	# Fallback framing used until VoxelWorld calls frame_vista() with the real surface height:
	# a 3/4 downward vista, pulled back so we open on a landscape rather than inside a hill.
	_focus = Vector3(0.0, 20.0, 0.0)
	_distance = 140.0
	_yaw = 0.0
	_pitch = deg_to_rad(55.0)
	_update_transform()


## Frame a sweeping 3/4 vista over `center` (the spawn area, at the true surface height).
## Called once by VoxelWorld after the terrain has streamed so we never start buried in a
## hillside or staring at the ground.
func frame_vista(center: Vector3) -> void:
	_focus = center + Vector3(0.0, 8.0, 0.0)
	_distance = 34.0
	_yaw = 0.0
	_pitch = deg_to_rad(38.0)
	_update_transform()


## Recenter the camera on `point` (auto-select focus, meteor impacts, etc.) at a closer
## inspection distance. Goes through the focus state so the per-frame rebuild doesn't
## immediately overwrite a directly-poked transform.
func focus_on(point: Vector3) -> void:
	_focus = point
	_distance = clampf(40.0, MIN_DISTANCE, MAX_DISTANCE)
	_update_transform()


## Rebuild the camera transform from the focus/distance/yaw/pitch state.
func _update_transform() -> void:
	var b: Basis = Basis.from_euler(Vector3(-_pitch, _yaw, 0.0))
	global_position = _focus + b * Vector3(0.0, 0.0, _distance)
	look_at(_focus, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			# Plain MMB held + drag orbits (horizontal = yaw, vertical = pitch);
			# Shift + MMB pans. RMB is left free for spawn/cast.
			if mb.pressed:
				if Input.is_key_pressed(KEY_SHIFT):
					_set_panning(true)
				else:
					_set_orbiting(true)
			else:
				_set_panning(false)
				_set_orbiting(false)
			return
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom(1.0 / ZOOM_STEP)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(ZOOM_STEP)

	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		if _panning:
			# Drag the land under the cursor: moving the mouse right slides the world right,
			# so the focus moves opposite. Scale by distance for a consistent feel.
			var scale: float = DRAG_PAN_SPEED * _distance_pan_factor()
			_pan_ground(-mm.relative.x * scale, mm.relative.y * scale)
			_update_transform()
		elif _orbiting:
			_yaw -= mm.relative.x * ORBIT_SENSITIVITY
			_pitch = clampf(_pitch + mm.relative.y * ORBIT_SENSITIVITY, PITCH_MIN, PITCH_MAX)
			_update_transform()


func _set_panning(active: bool) -> void:
	_panning = active
	_update_mouse_capture()


func _set_orbiting(active: bool) -> void:
	_orbiting = active
	_update_mouse_capture()


## Capture the mouse only while actively dragging (pan or orbit) so a drag isn't limited by
## the window edge; otherwise keep the cursor visible for selection, placement, and edge-scroll.
func _update_mouse_capture() -> void:
	if _panning or _orbiting:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _zoom(factor: float) -> void:
	_distance = clampf(_distance * factor, MIN_DISTANCE, MAX_DISTANCE)
	_update_transform()


## Pan factor relative to the reference distance, so pan speeds scale with zoom.
func _distance_pan_factor() -> float:
	return _distance / PAN_REFERENCE_DISTANCE


## Move the focus on the horizontal ground plane in the current yaw frame.
##   `right`   moves along the camera's ground-right axis,
##   `forward` moves along the camera's ground-forward axis (away from the camera).
func _pan_ground(right: float, forward: float) -> void:
	var fwd: Vector3 = Vector3(sin(_yaw), 0.0, cos(_yaw))
	var rgt: Vector3 = Vector3(cos(_yaw), 0.0, -sin(_yaw))
	# Camera looks toward -forward (down its -Z), so "up on screen" pans the focus forward.
	_focus += rgt * right - fwd * forward


func _process(delta: float) -> void:
	# Don't drive movement in the editor (@tool) preview.
	if Engine.is_editor_hint():
		return

	# Undo last frame's shake so movement acts on the true base position.
	global_position -= _shake_applied
	_shake_applied = Vector3.ZERO

	var right: float = 0.0
	var forward: float = 0.0

	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		forward += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		forward -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		right += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		right -= 1.0

	# Edge-scroll (only when not mid-drag, so a drag off-screen doesn't also edge-pan).
	if not _panning and not _orbiting:
		var edge: Vector2 = _edge_scroll_dir()
		right += edge.x
		forward += edge.y

	var changed: bool = false
	if absf(right) > 0.001 or absf(forward) > 0.001:
		var speed: float = PAN_SPEED * _distance_pan_factor() * delta
		_pan_ground(right * speed, forward * speed)
		changed = true

	var yaw_dir: float = 0.0
	if Input.is_key_pressed(KEY_Q):
		yaw_dir += 1.0
	if Input.is_key_pressed(KEY_E):
		yaw_dir -= 1.0
	if absf(yaw_dir) > 0.001:
		_yaw += yaw_dir * KEY_YAW_SPEED * delta
		changed = true

	var pitch_dir: float = 0.0
	if Input.is_key_pressed(KEY_R):
		pitch_dir += 1.0
	if Input.is_key_pressed(KEY_F):
		pitch_dir -= 1.0
	if absf(pitch_dir) > 0.001:
		_pitch = clampf(_pitch + pitch_dir * KEY_YAW_SPEED * delta, PITCH_MIN, PITCH_MAX)
		changed = true

	if changed:
		_update_transform()

	# Respond to felt ground motion: query the seismic field at the camera's own position and top up
	# trauma in proportion to nearby seismic energy. That energy already folds in proximity (worse the
	# nearer the source) and time decay, so the shake is the camera REACTING to the ground — a meteor
	# impact, a volcano breach, an earthquake pulse all shake it emergently just by disturbing the earth.
	if _ecology != null and _ecology.has_method("seismic_energy_at"):
		var seismic: float = _ecology.seismic_energy_at(global_position)
		if seismic > 0.0:
			add_shake(seismic * SEISMIC_TRAUMA_GAIN * delta)

	# Apply decaying camera shake as a transient offset on top of the base position (set above).
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	if _trauma > 0.0:
		var s: float = _trauma * _trauma * SHAKE_MAG
		_shake_applied = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * s
		global_position += _shake_applied


## Returns a ground-plane pan direction (right, forward) per axis when the cursor is within
## EDGE_MARGIN of a screen edge; Vector2.ZERO otherwise. Magnitude folds in the edge/key
## speed ratio so edge-scroll speed is independent of the key-pan tuning.
func _edge_scroll_dir() -> Vector2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return Vector2.ZERO
	var size: Vector2 = vp.get_visible_rect().size
	var m: Vector2 = vp.get_mouse_position()
	# Ignore a cursor that has left the window (negative or past the far edge).
	if m.x < 0.0 or m.y < 0.0 or m.x > size.x or m.y > size.y:
		return Vector2.ZERO
	var dir: Vector2 = Vector2.ZERO
	if m.x <= EDGE_MARGIN:
		dir.x -= 1.0
	elif m.x >= size.x - EDGE_MARGIN:
		dir.x += 1.0
	# Screen-top edge pans forward (into the scene); screen-bottom pans back toward the camera.
	if m.y <= EDGE_MARGIN:
		dir.y += 1.0
	elif m.y >= size.y - EDGE_MARGIN:
		dir.y -= 1.0
	return dir * (EDGE_PAN_SPEED / PAN_SPEED)


## Returns a world-space ray {"origin": Vector3, "dir": Vector3}.
##   - screen_pos == Vector2(-1, -1): use the viewport center.
##   - otherwise: project the given screen position.
func aim_ray(screen_pos: Vector2 = Vector2(-1.0, -1.0)) -> Dictionary:
	var sp: Vector2 = screen_pos
	if sp.x < 0.0 and sp.y < 0.0:
		var vp: Viewport = get_viewport()
		if vp != null:
			sp = vp.get_visible_rect().size * 0.5
		else:
			sp = Vector2.ZERO

	# project_ray_* need the camera to be inside a viewport; guard for headless
	# instantiation outside a tree by falling back to the camera transform.
	if not is_inside_tree():
		return {
			"origin": global_position,
			"dir": -global_transform.basis.z,
		}

	return {
		"origin": project_ray_origin(sp),
		"dir": project_ray_normal(sp),
	}


## Representative movement speed for consumers (WeatherSystem scales rain/wind by it).
## Reports the effective distance-scaled pan speed so weather still gets a sensible number.
func get_fly_speed() -> float:
	return PAN_SPEED * _distance_pan_factor() * 60.0
