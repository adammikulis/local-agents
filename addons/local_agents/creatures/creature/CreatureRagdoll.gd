class_name LACreatureRagdoll
extends RefCounted


const SETTLE_SPEED: float = 0.35          # below this lin+ang speed the shadow counts as resting
const SETTLE_HOLD: float = 0.4            # seconds it must stay slow before we call it settled
const MAX_RAGDOLL_TIME: float = 1.0       # hard cap on the tumble before we force-settle (see tick())
const SHADOW_MASK: int = 1                # collide with the terrain (static body on layer 1) only

const MICROBE_SEED: float = 0.2           # suppressed microbe load at death; blooms as the body is consumed
const DECOMP_RATE_PER_SEC: float = 0.35   # fraction of biomass the full bloom converts per second at warm+wet
const COLD_STALL_C: float = -2.0          # at/below this the bloom stalls to MUMMIFY_FLOOR (frozen preservation)
const WARM_OPT_C: float = 28.0            # at/above this warmth is optimal (rate factor 1.0)
const MUMMIFY_FLOOR: float = 0.06         # slowest warmth factor — a frozen carcass lingers ~16x longer
const DRY_MOISTURE: float = 0.6           # moisture factor for a dry-land carcass (a wet/submerged one = 1.0)
const DETRITUS_YIELD: float = 1.0         # detritus deposited into the field per unit biomass consumed
const SHRINK_FRACTION: float = 0.25       # over the final quarter of decomposition the body shrinks away
const MAX_CARCASSES: int = 80             # GENEROUS safety backstop only — decomposition self-bounds the count

# World-wide carcass registry, in creation order. Decomposition already self-bounds the count (bodies rot back
# into soil), so this is only a backstop against a pathological pileup (e.g. a mass die-off in permafrost where
# everything mummifies): if the count ever exceeds MAX_CARCASSES, the OLDEST body (front) is despawned.
static var _carcasses: Array = []


# Release the shadow: the creature is flung and physics takes over. `lethal` marks this as a death,
# so when the tumble settles the body stays and decays instead of standing back up. A near-zero
# impulse still topples the body (a small nudge) so a quiet death lies down rather than standing.
static func launch(c, impulse: Vector3, lethal: bool) -> void:
	if lethal:
		_become_carcass(c)
	# Already ragdolling (e.g. a second blast): just add the new impulse to the live shadow.
	if c._ragdoll and is_instance_valid(c._shadow):
		c._shadow.apply_central_impulse(impulse)
		return

	var parent: Node = c.get_parent()
	if parent == null or not c.is_inside_tree():
		return

	var radius: float = maxf(c.size * 0.6, 0.1)
	var height: float = maxf(c.size * 2.0, radius * 2.0)

	var shadow: RigidBody3D = RigidBody3D.new()
	shadow.name = "RagdollShadow"
	shadow.collision_layer = 0            # the creature (layer 2) stays the pickable thing, not this
	shadow.collision_mask = SHADOW_MASK   # rest on / bounce off the terrain
	shadow.gravity_scale = 1.0
	var shape: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	shape.shape = capsule
	shadow.add_child(shape)
	parent.add_child(shadow)
	shadow.global_transform = c.global_transform

	# The push. A tiny impulse still gets a topple nudge so the body lies down.
	var rng: LASimRng = LASimRng.for_domain("life")
	var push: Vector3 = impulse
	if push.length() < 0.5:
		var axis: Vector3 = Vector3(rng.randf_range(-1.0, 1.0), 0.4, rng.randf_range(-1.0, 1.0))
		push = axis.normalized() * (c.size * 2.5 + 1.5)
	shadow.apply_central_impulse(push)
	shadow.apply_torque_impulse(Vector3(
		rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)
	) * (push.length() * 0.25 + 1.0))

	c._shadow = shadow
	c._ragdoll = true
	c._settle_t = 0.0


# Called each physics frame while the shadow is driving. The visible creature copies the shadow's
# transform (model tumbles with it); when the shadow rests we either stand up or turn into a carcass.
static func tick(c, delta: float) -> void:
	if not is_instance_valid(c._shadow):
		_on_settled(c)
		return
	c.global_transform = c._shadow.global_transform
	# Total time spent tumbling (reuses _decay_age, which stays 0 until the body settles into a carcass).
	c._decay_age += delta

	var lin: float = c._shadow.linear_velocity.length()
	var ang: float = c._shadow.angular_velocity.length()
	if c._shadow.sleeping or (lin < SETTLE_SPEED and ang < SETTLE_SPEED):
		c._settle_t += delta
	else:
		c._settle_t = 0.0
	if c._settle_t >= SETTLE_HOLD or c._decay_age >= MAX_RAGDOLL_TIME:
		_on_settled(c)


# The shadow has come to rest — dismiss it and either recover (alive) or ground the carcass (dead).
static func _on_settled(c) -> void:
	var pos: Vector3 = c.global_position
	_dismiss_shadow(c)
	c._ragdoll = false
	c._settle_t = 0.0
	c._decay_age = 0.0                # reset the tumble-timer reuse: decomposition ages from a fresh 0

	if c._dead:
		# Lie where it fell: keep the tumbled orientation, just seat it on the surface. Radial planet
		# geometry: the ground point is along the body's own centre→pos radial, and we lift it out along
		# that same radial by a fraction of its size so the carcass rests on (not through) the ground.
		if c.terrain != null:
			var surf: Vector3 = c.terrain.ground_point(pos)
			if not is_nan(surf.x):
				var up_out: Vector3 = (pos - c.terrain.planet_center()).normalized()
				c.global_position = surf + up_out * (c.size * 0.35)
		c._carcass = true
		return

	# Survived the fling: snap upright (keep only yaw), reseat on the ground, resume normal life.
	if c.terrain != null:
		var surf2: Vector3 = c.terrain.ground_point(pos)
		if not is_nan(surf2.x):
			var up_out2: Vector3 = (pos - c.terrain.planet_center()).normalized()
			c.global_position = surf2 + up_out2 * c.size
	var yaw: float = c.global_rotation.y
	c.global_rotation = Vector3(0.0, yaw, 0.0)
	# A hard landing frightens the creature and rattles neighbours (same stimulus a thrown body makes).
	c.add_fear(c.global_position, 1.5)
	if c._ecology != null and c._ecology.has_method("broadcast_scare"):
		c._ecology.broadcast_scare(c.global_position, 8.0, 0.9)


static func _dismiss_shadow(c) -> void:
	if is_instance_valid(c._shadow):
		c._shadow.queue_free()
	c._shadow = null


# Turn the (still-living) creature INTO a carcass: leave the live groups so nothing hunts/flees it,
# join carrion+corpse so scavengers eat it, freeze its animation, and set its remaining meat value.
static func _become_carcass(c) -> void:
	c._dead = true
	# The body is the carcass. Draw the whole live mass OUT of the animal's own accounts as we do it, so the
	# mass exists in exactly one place and a predator that already took a bite finds correspondingly less meat.
	c._carrion = LACreatureBodyMass.draw(c, LACreatureBodyMass.body_mass(c))
	c._carrion_initial = c._carrion           # what it weighed when it died — the denominator for rot + shrink
	c._decay_age = 0.0
	c.remove_from_group(c._species_group(c.species))
	c.remove_from_group(c.GROUP_CREATURE)
	c.add_to_group(c.GROUP_CARRION)
	c.add_to_group("corpse")
	_freeze_animations(c._model_root if c._model_root != null else c._mesh)
	_register_carcass(c)


# Track this new carcass and keep the world-wide carcass count within MAX_CARCASSES. Prunes entries that
# already rotted away (freed nodes) then, while still over budget, evicts the OLDEST carcass first.
static func _register_carcass(c) -> void:
	_carcasses.append(c)
	var i: int = _carcasses.size() - 1
	while i >= 0:
		if not is_instance_valid(_carcasses[i]):
			_carcasses.remove_at(i)
		i -= 1
	while _carcasses.size() > MAX_CARCASSES:
		var oldest: Node = _carcasses.pop_front()
		_despawn_carcass(oldest)
	LASimReport.gauge("carcasses", float(_carcasses.size()))


# Drop a carcass from the registry once it has fully decomposed away (keeps the count telemetry honest).
static func _forget_carcass(c) -> void:
	_carcasses.erase(c)
	LASimReport.gauge("carcasses", float(_carcasses.size()))   # telemetry: live carcass count (bounded by the cap)


static func _despawn_carcass(c) -> void:
	if not is_instance_valid(c):
		return
	if c._carrion > 0.0 and c._material != null and c._material.has_method("deposit_detritus"):
		c._material.deposit_detritus(c.global_position, c._carrion)
	c._carrion = 0.0
	_dismiss_shadow(c)
	c.queue_free()


static func decay_tick(c, delta: float) -> void:
	c._decay_age += delta
	var initial: float = maxf(float(c._carrion_initial), 0.0001)
	if c._carrion <= 0.0:
		_forget_carcass(c)
		c.queue_free()
		return
	var consumed_frac: float = clampf(1.0 - c._carrion / initial, 0.0, 1.0)
	# Autocatalytic microbe bloom: a suppressed seed at death that grows toward full as the body is converted.
	var microbes: float = MICROBE_SEED + consumed_frac * (1.0 - MICROBE_SEED)
	var consumed: float = minf(initial * DECOMP_RATE_PER_SEC * microbes * _decomp_env(c) * delta, c._carrion)
	if consumed > 0.0:
		c._carrion -= consumed
		if c._material != null and c._material.has_method("deposit_detritus"):
			c._material.deposit_detritus(c.global_position, consumed * DETRITUS_YIELD)

	_update_rot(c)
	# Shrink away over the final stretch of decomposition so it visibly wastes to nothing before removal.
	if consumed_frac >= 1.0 - SHRINK_FRACTION:
		var t: float = clampf((consumed_frac - (1.0 - SHRINK_FRACTION)) / SHRINK_FRACTION, 0.0, 1.0)
		c.scale = Vector3.ONE * clampf(1.0 - t, 0.05, 1.0)
	# Biomass fully returned to soil: the carcass is gone. This is what SELF-BOUNDS the carcass count.
	if c._carrion <= 0.0:
		_forget_carcass(c)
		c.queue_free()


static func _decomp_env(c) -> float:
	if c._material == null:
		return DRY_MOISTURE
	var pos: Vector3 = c.global_position
	var warmth: float = 1.0
	if c._material.has_method("temp_at"):
		var t_c: float = c._material.temp_at(pos)          # cheap cell read; the primary spatial driver
		warmth = clampf((t_c - COLD_STALL_C) / (WARM_OPT_C - COLD_STALL_C), MUMMIFY_FLOOR, 1.0)
	var moisture: float = DRY_MOISTURE
	if c._material.has_method("snow_depth_at") and c._material.snow_depth_at(pos) > 0.01:
		moisture *= 0.5                        # frozen under snow: driest + coldest ⇒ slowest (permafrost)
	return warmth * moisture


# A shared translucent overlay on every mesh of the body: fades a green rot tint in as decomposition starts,
# then lerps that green toward black as the biomass is consumed. Driven by how much biomass is GONE (not a
# clock), so a fast warm rot blackens quickly and a mummifying cold one stays fresh-looking for a long time.
static func _update_rot(c) -> void:
	if c._rot_overlay == null:
		c._rot_overlay = StandardMaterial3D.new()
		c._rot_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		c._rot_overlay.roughness = 1.0
		c._rot_overlay.metallic = 0.0
		c._rot_overlay.albedo_color = Color(0.13, 0.32, 0.05, 0.0)
		_apply_overlay(c._model_root if c._model_root != null else c._mesh, c._rot_overlay)
	var initial: float = maxf(float(c._carrion_initial), 0.0001)
	var pt: float = clampf(1.0 - c._carrion / initial, 0.0, 1.0) if initial > 0.0 else 1.0
	var green: Color = Color(0.13, 0.32, 0.05)
	var black: Color = Color(0.02, 0.02, 0.02)
	var col: Color = green.lerp(black, clampf((pt - 0.35) / 0.65, 0.0, 1.0))
	col.a = clampf(pt / 0.3, 0.0, 0.92)
	c._rot_overlay.albedo_color = col


static func _apply_overlay(node, mat: StandardMaterial3D) -> void:
	if node == null:
		return
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_overlay = mat
	for child in node.get_children():
		_apply_overlay(child, mat)


static func _freeze_animations(node) -> void:
	if node == null:
		return
	if node is AnimationPlayer:
		(node as AnimationPlayer).stop()
	for child in node.get_children():
		_freeze_animations(child)


# A scavenger takes a bite; returns the energy actually removed (clamped to what remains). When the
# carcass is used up it shrinks to gone next frame by jumping decay to the shrink phase.
static func feed(c, amount: float) -> float:
	if c._carrion <= 0.0:
		return 0.0
	var taken: float = clampf(amount, 0.0, c._carrion)
	c._carrion -= taken
	if c._carrion < 0.0:
		c._carrion = 0.0
	# When a scavenger strips the last of the meat the next decay_tick sees _carrion <= 0 and frees the body.
	return taken


# Unified food model: a carcass is MEAT — fresh at first, then "decayed" (worth less) once decomposition has
# converted more than 40% of the biomass.
static func food_profile(c) -> Dictionary:
	var initial: float = maxf(float(c._carrion_initial), 0.0001)
	var consumed_frac: float = clampf(1.0 - c._carrion / initial, 0.0, 1.0) if initial > 0.0 else 1.0
	var st: String = "decayed" if consumed_frac > 0.4 else "dead"
	return {"type": "meat", "state": st, "value": c._carrion}


static func inspector_payload(c) -> Dictionary:
	return {
		"title": "Carcass",
		"lines": [
			"Dead %s" % c.species,
			"Decaying...",
			"Carrion: %.0f left" % c._carrion,
		],
	}
