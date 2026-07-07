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

const DECAY_LIFETIME: float = 70.0        # seconds a carcass lasts before it is gone
const SHRINK_DURATION: float = 4.0        # final seconds spent shrinking away to nothing
const NUTRITION_PER_SIZE: float = 40.0    # carrion food value per unit of body size
const DETRITUS_PER_SEC: float = 0.35      # dead matter a rotting carcass sheds into the field's decomposer channel
const SETTLE_SPEED: float = 0.35          # below this lin+ang speed the shadow counts as resting
const SETTLE_HOLD: float = 0.4            # seconds it must stay slow before we call it settled
const SHADOW_MASK: int = 1                # collide with the terrain (static body on layer 1) only


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

	var lin: float = c._shadow.linear_velocity.length()
	var ang: float = c._shadow.angular_velocity.length()
	if c._shadow.sleeping or (lin < SETTLE_SPEED and ang < SETTLE_SPEED):
		c._settle_t += delta
	else:
		c._settle_t = 0.0
	if c._settle_t >= SETTLE_HOLD:
		_on_settled(c)


# The shadow has come to rest — dismiss it and either recover (alive) or ground the carcass (dead).
static func _on_settled(c) -> void:
	var pos: Vector3 = c.global_position
	_dismiss_shadow(c)
	c._ragdoll = false
	c._settle_t = 0.0

	if c._dead:
		# Lie where it fell: keep the tumbled orientation, just seat it on the surface.
		var surf: float = c._surface_at(pos.x, pos.z)
		if not is_nan(surf):
			c.global_position = Vector3(pos.x, surf + c.size * 0.35, pos.z)
		c._carcass = true
		return

	# Survived the fling: snap upright (keep only yaw), reseat on the ground, resume normal life.
	var surf2: float = c._surface_at(pos.x, pos.z)
	if not is_nan(surf2):
		c.global_position = Vector3(pos.x, surf2 + c.size, pos.z)
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


# Decay in place: age the body, wash it green->black, then shrink and vanish. The carcass advertises FOOD
# scent emergently — LAMaterialScent3D scans the "carrion" group each step and lays FOOD from `_carrion`,
# so scavengers home in on it (no explicit deposit here, and it rides the wind + washes in rain for free).
static func decay_tick(c, delta: float) -> void:
	c._decay_age += delta
	_update_rot(c)
	# DEATH→SOIL: a rotting carcass literally becomes soil — it sheds dead matter into the field's decomposer
	# channel, where fungus grows on it and rots it back into CO₂ + soil fertility (LAMaterialFungus3D). Scaled
	# by remaining meat so a fresh, meaty carcass feeds the ground more than a picked-clean one. Emergent, general.
	if c._material != null and c._material.has_method("deposit_detritus") and c._carrion > 0.0:
		c._material.deposit_detritus(c.global_position, DETRITUS_PER_SEC * delta)

	if c._decay_age >= DECAY_LIFETIME:
		c.queue_free()
		return
	# Waste away over the final seconds so it visibly shrinks to nothing before removal.
	var shrink_start: float = DECAY_LIFETIME - SHRINK_DURATION
	if c._decay_age >= shrink_start:
		var t: float = clampf((c._decay_age - shrink_start) / SHRINK_DURATION, 0.0, 1.0)
		c.scale = Vector3.ONE * clampf(1.0 - t, 0.05, 1.0)


# A shared translucent overlay on every mesh of the body: fades a green rot tint in over the first
# stretch of decay, then lerps that green toward black as the carcass rots down.
static func _update_rot(c) -> void:
	if c._rot_overlay == null:
		c._rot_overlay = StandardMaterial3D.new()
		c._rot_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		c._rot_overlay.roughness = 1.0
		c._rot_overlay.metallic = 0.0
		c._rot_overlay.albedo_color = Color(0.13, 0.32, 0.05, 0.0)
		_apply_overlay(c._model_root if c._model_root != null else c._mesh, c._rot_overlay)
	var pt: float = clampf(c._decay_age / DECAY_LIFETIME, 0.0, 1.0)
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
	if c._carrion <= 0.0:
		c._carrion = 0.0
		c._decay_age = maxf(c._decay_age, DECAY_LIFETIME - SHRINK_DURATION)
	return taken


# Unified food model: a carcass is MEAT — fresh at first, then "decayed" (worth less) as it rots.
static func food_profile(c) -> Dictionary:
	var st: String = "decayed" if c._decay_age > DECAY_LIFETIME * 0.4 else "dead"
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
