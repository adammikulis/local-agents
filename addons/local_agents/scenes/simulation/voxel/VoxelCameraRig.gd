@tool
class_name LAVoxelCameraRig
extends Camera3D

## Free-look fly camera for the voxel simulation.
##
##   - Hold RMB to mouse-look (mouse is only captured while RMB is held, so HUD
##     clicks keep working the rest of the time).
##   - WASD to move on the view plane, Shift = up / faster, Ctrl = down.
##   - Mouse wheel adjusts fly speed.
##   - No Ctrl-to-orbit requirement; this is a plain fly cam.
##
## Hosts the VoxelViewer in the integration scene (VoxelWorld calls
## terrain.attach_viewer(camera)). Exposes aim_ray() for click-to-place / select.

# --- Tunables -----------------------------------------------------------------
const MOUSE_SENSITIVITY: float = 0.0032
const MIN_SPEED: float = 4.0
const MAX_SPEED: float = 400.0
const SPEED_STEP: float = 1.15            # wheel multiplier per notch
const FAST_MULTIPLIER: float = 3.0        # Shift while moving
const PITCH_LIMIT: float = deg_to_rad(89.0)
const RAY_LENGTH: float = 4000.0

# --- State --------------------------------------------------------------------
var _fly_speed: float = 40.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false

# Screen shake (earthquakes, big impacts). Trauma 0..1 decays; the applied offset is removed and
# re-added each frame so it never accumulates into the fly position.
const SHAKE_MAG: float = 1.8
const TRAUMA_DECAY: float = 1.1
var _trauma: float = 0.0
var _shake_applied: Vector3 = Vector3.ZERO


## Add camera trauma (0..1). Earthquakes/impacts call this; it decays on its own.
func add_shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func _ready() -> void:
	current = true
	# Fallback framing used until VoxelWorld calls frame_vista() with the real surface height:
	# high and pulled back so we open on a vista, not the inside of a hill.
	global_position = Vector3(0.0, 70.0, 120.0)
	look_at(Vector3(0.0, 20.0, 0.0), Vector3.UP)
	_sync_angles_from_basis()


## Frame a sweeping 3/4 vista over `center` (the spawn area, at the true surface height).
## Called once by VoxelWorld after the terrain has streamed so we never start buried in a
## hillside or staring at the ground. Angles are re-synced so mouse-look continues smoothly.
func frame_vista(center: Vector3) -> void:
	global_position = center + Vector3(46.0, 66.0, 116.0)
	look_at(center + Vector3(0.0, 8.0, 0.0), Vector3.UP)
	_sync_angles_from_basis()


func _sync_angles_from_basis() -> void:
	var e: Vector3 = global_transform.basis.get_euler()
	_pitch = clampf(e.x, -PITCH_LIMIT, PITCH_LIMIT)
	_yaw = e.y


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_set_looking(mb.pressed)
			return
		if mb.pressed and _looking:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_fly_speed = clampf(_fly_speed * SPEED_STEP, MIN_SPEED, MAX_SPEED)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_fly_speed = clampf(_fly_speed / SPEED_STEP, MIN_SPEED, MAX_SPEED)

	elif event is InputEventMouseMotion and _looking:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= mm.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - mm.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		_apply_look()


func _set_looking(active: bool) -> void:
	_looking = active
	# Only capture the mouse while actively looking, so HUD stays clickable.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if active else Input.MOUSE_MODE_VISIBLE
	if active:
		_sync_angles_from_basis()


func _apply_look() -> void:
	var b: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	global_transform.basis = b


func _process(delta: float) -> void:
	# Don't drive movement in the editor (@tool) preview.
	if Engine.is_editor_hint():
		return

	# Undo last frame's shake so movement acts on the true base position.
	global_position -= _shake_applied
	_shake_applied = Vector3.ZERO

	var dir: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_SHIFT):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir += Vector3.DOWN

	if dir.length() > 0.001:
		dir = dir.normalized()
		var speed: float = _fly_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= FAST_MULTIPLIER
		global_position += dir * speed * delta

	# Apply decaying shake as a transient offset on top of the base position.
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	if _trauma > 0.0:
		var s: float = _trauma * _trauma * SHAKE_MAG
		_shake_applied = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * s
		global_position += _shake_applied


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


func get_fly_speed() -> float:
	return _fly_speed
