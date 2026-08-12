class_name LACreatureAnim
extends RefCounted


const ANIM_LOD_CHARACTERISTIC_DISTANCE: float = 45.0
const ANIM_STRIDE_MAX: int = 8      # farthest creatures update every 8th frame (~7 Hz) — imperceptible at range
static var _anim_lod_off: bool = OS.has_environment("LA_NO_ANIM_LOD")

const COLLISION_LOD_D2: float = 62500.0
static var _collision_lod_off: bool = OS.has_environment("LA_NO_COLLISION_LOD")   # A/B knob: force collision always on


## The whole per-render-frame visual tick. Called from LocalAgentCreature._process after its own cheap
## early-outs (editor hint / ablation / no model / ragdoll or carcass, where the shadow and decay own the
## transform and must not be fought by idle/run animation).
static func tick(c, delta: float) -> void:
	var p: Vector3 = c.global_position
	c._anim_accum += delta
	var cam_d2: float = p.distance_squared_to(LACreatureLod.camera_pos(c))
	# COLLISION-LOD: drop the pick shape from the physics broadphase when far (not clickable at range), so the
	# engine stops updating its AABB every frame as the creature walks. Reuses the camera distance computed here.
	if c._collision_shape != null and not _collision_lod_off:
		var want_col: bool = not is_finite(cam_d2) or cam_d2 < COLLISION_LOD_D2
		if want_col != c._collision_on:
			c._collision_on = want_col
			c._collision_shape.disabled = not want_col
	var stride: int = 1
	if is_finite(cam_d2) and not _anim_lod_off:
		var relevance: float = LALodStride.relevance_from_distance(sqrt(cam_d2), ANIM_LOD_CHARACTERISTIC_DISTANCE)
		stride = LALodStride.stride_for(relevance, ANIM_STRIDE_MAX)
	c._anim_stride = stride
	if c._anim_phase < 0:
		c._anim_phase = int(c.get_instance_id())
	if not LALodStride.should_run(int(Engine.get_physics_frames()), c._anim_phase, stride):
		return                            # not this creature's animation frame — hold the last pose
	var adt: float = c._anim_accum
	c._anim_accum = 0.0
	c._vis_t += adt
	var sp: float = 0.0
	if adt > 0.0001:
		sp = (p - c._vis_prev_pos).length() / adt
	c._vis_prev_pos = p
	LAModelVisual.animate(c._model_root, c._model_anim, c._model_anims, sp, c._model_run_speed, c._vis_t, adt)
	if c._model_anim != null:
		c._model_anim.advance(adt)        # MANUAL mode: step the mixer by the accumulated real time
