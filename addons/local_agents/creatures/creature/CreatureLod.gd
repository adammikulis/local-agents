class_name LACreatureLod
extends RefCounted

## Decision + physics-rate LEVEL OF DETAIL for LocalAgentCreature ("do less by relevance"), factored out of
## the main brain so the cadence policy lives in one owner file.
##
## Two related throttles live here:
##   * think stride — how often the creature runs the DISCRETIONARY cognition cascade. Sleep is cheapest,
##     followers coast on an adopted action, time-critical states (flee/hunt/drink) stay at the full near
##     rate at any distance, and everything else grades smoothly with camera relevance (LALodStride).
##   * physics-rate gate — how often the whole _physics_process body runs at all, with an accumulated
##     catch-up dt so metabolism/aging/movement distance stay correct however sparse the update (a far
##     creature simply advances several frames of motion at once, invisible at range).
##
## Every-frame work (metabolism, thirst, temperature, ageing, death, movement) is unaffected in substance:
## the catch-up dt keeps its integrated result the same. This spreads cost automatically — a fraction of
## the population is always asleep (diurnal by night / nocturnal by day, staggered) and most animals are
## off-screen.
##
## The shared camera position and the global AI-tick multiplier are cached ONCE PER PHYSICS FRAME here and
## reused by the whole population (one get_camera_3d() / one Engine meta read per frame, not one per
## creature). Static + dynamic field access on the passed creature, like the other Creature* modules.
## (Explicit types only — project rule: no ':=' inferred typing.)

const THINK_STRIDE: int = 3                # decide every N physics frames (movement stays every-frame)
const FAR_THINK_STRIDE: int = 30           # far/off-screen discretionary thinking cap (~2 Hz)
const SLEEP_THINK_STRIDE: int = 30         # asleep/resting: no decisions to make — heaviest throttle
const MID_LOD_D2: float = 4900.0           # physics-LOD's legacy A/B tier boundary (LA_NO_PHYS_LOD only)
# The distance at which camera-relevance has fallen to 0.5 (LALodStride.relevance_from_distance): stride
# grows smoothly from THINK_STRIDE (the floor even up close — decisions never need 60 Hz resolution) up
# to FAR_THINK_STRIDE, with no cutoff anywhere. One number, no separate rate+cap pair to keep in sync.
const THINK_LOD_CHARACTERISTIC_DISTANCE: float = 90.0
# A `herd` creature that is NOT the local top-ranked same-species individual becomes a FOLLOWER: it ADOPTS
# its leader's decision (the canonical action) and coasts on it, so it skips the whole expensive think_* +
# cognition assessment and ticks slowly. Only the few local leaders pay the heavy "what to do" cost.
# Reflexes (flee/thirst) + all pathing stay per-individual.
const FOLLOWER_THINK_STRIDE: int = 18      # a follower re-decides rarely (~3 Hz) — it coasts on the adopted action

const FAR_LOD_D2: float = 40000.0   # legacy binary-tier A/B baseline only (LA_NO_PHYS_LOD)
# PHYSICS-RATE LOD: the whole _physics_process (movement + physiology + think) runs on a stride derived
# from camera relevance (LALodStride) — near-view creatures update near every frame (smooth motion), the
# far-side population a couple times a second, smoothly in between with no cutoff. Same principle + shape
# as the animation-framerate LOD (LACreatureAnim).
const PHYS_LOD_CHARACTERISTIC_DISTANCE: float = 40.0
const PHYS_STRIDE_MAX: int = 12     # far-side creatures update at most every 12th frame
static var _phys_lod_off: bool = OS.has_environment("LA_NO_PHYS_LOD")   # A/B knob: force the old binary tiers

# Camera position, fetched once per physics frame and shared by every creature (a single
# get_camera_3d() lookup, not one per creature). INF when there is no active camera.
static var _cam_frame: int = -1
static var _cam_pos: Vector3 = Vector3(INF, INF, INF)

# Global AI-tick multiplier resolved from the Sim/AI setting `la_ai_tick_frames` (published by
# LAVoxelSettingsApplier as an Engine metadata global). Baseline is THINK_STRIDE (3) — the Medium default
# (3) leaves every stride unchanged; a higher setting stretches all strides so the population re-decides
# less often (cheaper CPU), a lower one tightens them. Cached once per physics frame (ONE meta read shared
# by the whole population, mirroring camera_pos) and clamped so creatures never freeze (min stride 1
# enforced at the call site) nor thrash. Re-read live each frame, so a mid-game settings re-apply takes
# effect immediately (LAVoxelSettingsApplier.publish_globals rewrites the meta on GameMode.settings_applied).
static var _ai_scale_frame: int = -1
static var _ai_tick_scale: float = 1.0


## The active camera's world position, cached for the whole population for this physics frame.
## Vector3(INF, INF, INF) when there is no camera (callers treat that as "relevance undefined").
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


## How often THIS creature runs the discretionary think cascade, in physics frames. Sleep is cheapest,
## then distance-graded for idle/discretionary states; time-critical states (fleeing, hunting, drinking)
## stay at the full near rate at any distance so an off-screen chase or a drink never stalls.
static func base_think_stride(c) -> int:
	var state: String = String(c.state)
	if state == "sleep" or state == "roost" or state == "nesting" or state == "rest":
		return SLEEP_THINK_STRIDE
	if state == "flee" or state == "panic" or state == "chase" or state == "stalk" \
			or state == "throw" or state == "seek" or state == "drink":
		return THINK_STRIDE
	# A follower (anyone with a valid leader — herd member, squad grunt, or a parent-following juvenile)
	# coasts on its adopted action and re-decides rarely; its leader pays the heavy "what to do" cost.
	# Time-critical states above already opted out, so a fleeing/drinking follower is never throttled.
	if c._leader != null and is_instance_valid(c._leader):
		return FOLLOWER_THINK_STRIDE
	var cam: Vector3 = camera_pos(c)
	if is_inf(cam.x):
		return THINK_STRIDE
	# Continuous relevance-driven ramp (replaces the old NEAR/MID/FAR jump-tier ladder) — no distance
	# branch anywhere: stride grows smoothly from THINK_STRIDE, capped at FAR_THINK_STRIDE.
	var d: float = sqrt(c.global_position.distance_squared_to(cam))
	var relevance: float = LALodStride.relevance_from_distance(d, THINK_LOD_CHARACTERISTIC_DISTANCE)
	return LALodStride.stride_for(relevance, FAR_THINK_STRIDE, THINK_STRIDE)


## Compute-bubble LOD gate for the whole _physics_process body. Returns the dt this frame's update should
## integrate (the ACCUMULATED catch-up delta when the creature is running on a stride), or -1.0 when this
## is not the creature's update frame and the caller must return immediately. An acute event (_force_think
## from a scare/damage) always runs live; with no camera the relevance is undefined so we run at full rate.
static func phys_gate(c, delta: float) -> float:
	if c._force_think:
		return delta
	var cam_d2: float = c.global_position.distance_squared_to(camera_pos(c))
	if not is_finite(cam_d2):
		return delta
	c._lod_accum += delta
	var lod_stride: int
	if _phys_lod_off:
		lod_stride = 8 if cam_d2 > FAR_LOD_D2 else (4 if cam_d2 > MID_LOD_D2 else 1)   # legacy binary tiers (A/B baseline)
	else:
		var relevance: float = LALodStride.relevance_from_distance(sqrt(cam_d2), PHYS_LOD_CHARACTERISTIC_DISTANCE)
		lod_stride = LALodStride.stride_for(relevance, PHYS_STRIDE_MAX)
	if not LALodStride.should_run(int(Engine.get_physics_frames()), c._think_phase, lod_stride):
		return -1.0
	var caught_up: float = c._lod_accum
	c._lod_accum = 0.0
	return caught_up
