class_name LACreatureRagdoll
extends RefCounted

## The creature's "physics shadow" (HL2-style) + its become-a-carcass-in-place death.
##
## A living LACreature is a kinematic CharacterBody3D driven by AI. This module lets a real
## RigidBody3D — a single capsule, the SHADOW — occasionally OVERRIDE that: on any impulse
## (meteor blast, explosion, a lethal blow) the shadow is released, tumbles under real physics,
## and the visible creature simply reads the shadow's transform each frame (its model rides along,
## never swapped, never reparented). When the shadow settles:
##   * alive  -> the creature stands back up and resumes its AI (a survivable fling);
##   * dead   -> the creature STAYS as a carcass where it fell and rots green->black in place.
##
## So there is no separate corpse node and no model hand-off: the creature IS the carcass. It just
## changes groups (leaves its species/creature groups, joins carrion/corpse) and starts decaying.
## Static + dependency-free of concrete types (explicit types only — no ':=').

const NUTRITION_PER_SIZE: float = 40.0    # carcass biomass (and carrion food value) per unit of body size
const SETTLE_SPEED: float = 0.35          # below this lin+ang speed the shadow counts as resting
const SETTLE_HOLD: float = 0.4            # seconds it must stay slow before we call it settled
const MAX_RAGDOLL_TIME: float = 1.0       # hard cap on the tumble before we force-settle (see tick())
const SHADOW_MASK: int = 1                # collide with the terrain (static body on layer 1) only

# --- Emergent decomposition (no timer) --------------------------------------------------------------
# A carcass is just a lump of organic BIOMASS (c._carrion). While the animal lived, its own gut microbes were
# held in check; death ends that suppression and they OVERGROW, consuming the body from within. The microbe
# bloom is autocatalytic — the more biomass already converted, the bigger it gets — so we read it straight off
# how much biomass is already gone (MICROBE_SEED = the suppressed load that blooms), with NO scalar stored on
# the living creature (that + digestion benefit + soil bacteria is a separate creature-side follow-up). The
# bloom RATE is gated by the field's local warmth × moisture, so warm+wet rots fast and cold+dry near-stalls →
# permafrost mummification emerges for free. What the microbes consume is handed to the substrate's existing
# decomposer loop as detritus (deposit_detritus → fungus/decompose → soil fertility + CO₂). The carcass is
# freed once its biomass is fully returned to soil, so the count SELF-BOUNDS (no despawn timer).
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
	var push: Vector3 = impulse
	if push.length() < 0.5:
		var axis: Vector3 = Vector3(randf_range(-1.0, 1.0), 0.4, randf_range(-1.0, 1.0))
		push = axis.normalized() * (c.size * 2.5 + 1.5)
	shadow.apply_central_impulse(push)
	shadow.apply_torque_impulse(Vector3(
		randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)
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
	# Settle when the tumble rests OR after MAX_RAGDOLL_TIME. The hard cap is essential on a planet: the shadow
	# falls under world-down (-Y) gravity, not the radial "down", so it never actually comes to rest on the
	# spherical surface — without the cap every dead body would ragdoll forever as an ACTIVE RigidBody3D, and
	# they pile up until physics (and fps) collapse. The cap dismisses the expensive shadow promptly and
	# re-seats the body radially (via ground_point) as a static, decomposing carcass.
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
	c._carrion = maxf(c.size, 0.05) * NUTRITION_PER_SIZE
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


# Force a capped-out carcass to vanish now: drop any lingering physics shadow and free the body node.
static func _despawn_carcass(c) -> void:
	if not is_instance_valid(c):
		return
	_dismiss_shadow(c)
	c.queue_free()


# Decompose in place: the microbe bloom (gated by field warmth+moisture) eats the carcass biomass and hands
# it to the substrate's decomposer loop; the body washes green->black + shrinks in step with how much biomass
# is gone, then vanishes once fully returned to soil. The carcass also advertises FOOD scent emergently —
# LAMaterialScent3D scans the "carrion" group each step and lays FOOD from `_carrion`, so scavengers home in
# on it (rides the wind + washes in rain for free), and any diet=scavenger creature can bite via feed().
static func decay_tick(c, delta: float) -> void:
	c._decay_age += delta
	var initial: float = maxf(c.size, 0.05) * NUTRITION_PER_SIZE
	if initial <= 0.0:
		_forget_carcass(c)
		c.queue_free()
		return
	var consumed_frac: float = clampf(1.0 - c._carrion / initial, 0.0, 1.0)
	# Autocatalytic microbe bloom: a suppressed seed at death that grows toward full as the body is converted.
	var microbes: float = MICROBE_SEED + consumed_frac * (1.0 - MICROBE_SEED)
	# DEATH→SOIL: the bloom eats biomass at a warmth×moisture-gated rate and hands the consumed matter to the
	# field's existing detritus→fungus/decompose→CO₂+fertility loop (deposit_detritus). Warm+wet = rapid
	# putrefaction; cold+dry = near-stall (mummification). Scavenger bites (feed) reduce _carrion too and so
	# compose in — an eaten carcass both shrinks and decomposes faster (more converted ⇒ bigger bloom).
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


# The local decomposition rate factor: warmth × moisture, read from the field at the carcass cell. Warmth
# (the field TEMPERATURE, a cheap cell read) is the primary spatial driver: warm ground → rapid rot; a frozen
# peak → ~MUMMIFY_FLOOR (a carcass lingers — permafrost preservation, emergent, no per-biome branch). Moisture
# is coarse for now (dry land, halved further under snow) — a fuller soil-wetness read is a field-side follow-up.
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
	var initial: float = maxf(c.size, 0.05) * NUTRITION_PER_SIZE
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


# --- carcass food contract (the creature forwards these once it is a carcass) --------------------

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
	var initial: float = maxf(c.size, 0.05) * NUTRITION_PER_SIZE
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
