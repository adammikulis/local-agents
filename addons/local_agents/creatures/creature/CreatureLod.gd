class_name LACreatureLod
extends RefCounted


const THINK_STRIDE: int = 3                # decide every N physics frames (movement stays every-frame)
const FAR_THINK_STRIDE: int = 30           # far/off-screen discretionary thinking cap (~2 Hz)
const SLEEP_THINK_STRIDE: int = 30         # asleep/resting: no decisions to make — heaviest throttle
const MID_LOD_D2: float = 4900.0           # physics-LOD binary-tier boundary (LA_NO_PHYS_LOD only)
# Distance at which camera-relevance has fallen to 0.5 (LALodStride.relevance_from_distance).
const THINK_LOD_CHARACTERISTIC_DISTANCE: float = 90.0
const FOLLOWER_THINK_STRIDE: int = 18      # a follower re-decides rarely (~3 Hz) — it coasts on the adopted action

const FAR_LOD_D2: float = 40000.0   # binary-tier A/B baseline only (LA_NO_PHYS_LOD)
# The whole _physics_process runs on a stride derived from camera relevance (LALodStride).
const PHYS_LOD_CHARACTERISTIC_DISTANCE: float = 40.0
const PHYS_STRIDE_MAX: int = 12     # far-side creatures update at most every 12th frame
static var _phys_lod_off: bool = OS.has_environment("LA_NO_PHYS_LOD")   # A/B knob: force the binary tiers

# Camera position.
static var _cam_frame: int = -1
static var _cam_pos: Vector3 = Vector3(INF, INF, INF)

static var _ai_scale_frame: int = -1
static var _ai_tick_scale: float = 1.0


## The active camera's world position, cached for the whole population for this physics frame.
static func camera_pos(c) -> Vector3:
	var f: int = int(Engine.get_physics_frames())
	if f != _cam_frame:
		_cam_frame = f
		var vp: Viewport = c.get_viewport()
		var cam: Camera3D = vp.get_camera_3d() if vp != null else null
		_cam_pos = cam.global_position if cam != null else Vector3(INF, INF, INF)
	return _cam_pos


static func ai_tick_scale() -> float:
	var f: int = int(Engine.get_physics_frames())
	if f != _ai_scale_frame:
		_ai_scale_frame = f
		var n: float = float(Engine.get_meta("la_ai_tick_frames", THINK_STRIDE)) if Engine.has_meta("la_ai_tick_frames") else float(THINK_STRIDE)
		_ai_tick_scale = clampf(n / float(THINK_STRIDE), 0.34, 20.0)
	return _ai_tick_scale


## The LOD/distance base stride, then scaled by the AI-tick setting.
static func think_stride(c) -> int:
	return maxi(1, int(round(float(base_think_stride(c)) * ai_tick_scale())))


## How often THIS creature runs the discretionary think cascade, in physics frames.
static func base_think_stride(c) -> int:
	var state: String = String(c.state)
	if state == "sleep" or state == "roost" or state == "nesting" or state == "rest":
		return SLEEP_THINK_STRIDE
	if state == "flee" or state == "panic" or state == "chase" or state == "stalk" \
			or state == "throw" or state == "seek" or state == "drink":
		return THINK_STRIDE
	if c._leader != null and is_instance_valid(c._leader):
		return FOLLOWER_THINK_STRIDE
	var cam: Vector3 = camera_pos(c)
	if is_inf(cam.x):
		return THINK_STRIDE
	# Continuous relevance-driven ramp.
	var d: float = sqrt(c.global_position.distance_squared_to(cam))
	var relevance: float = LALodStride.relevance_from_distance(d, THINK_LOD_CHARACTERISTIC_DISTANCE)
	return LALodStride.stride_for(relevance, FAR_THINK_STRIDE, THINK_STRIDE)


static func phys_gate(c, delta: float) -> float:
	if c._force_think:
		return delta
	var cam_d2: float = c.global_position.distance_squared_to(camera_pos(c))
	if not is_finite(cam_d2):
		return delta
	c._lod_accum += delta
	var lod_stride: int
	if _phys_lod_off:
		lod_stride = 8 if cam_d2 > FAR_LOD_D2 else (4 if cam_d2 > MID_LOD_D2 else 1)   # binary tiers (A/B baseline)
	else:
		var relevance: float = LALodStride.relevance_from_distance(sqrt(cam_d2), PHYS_LOD_CHARACTERISTIC_DISTANCE)
		lod_stride = LALodStride.stride_for(relevance, PHYS_STRIDE_MAX)
	if not LALodStride.should_run(int(Engine.get_physics_frames()), c._think_phase, lod_stride):
		return -1.0
	var caught_up: float = c._lod_accum
	c._lod_accum = 0.0
	return caught_up
