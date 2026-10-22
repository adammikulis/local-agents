class_name LACreatureRagdoll
extends RefCounted


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


## No body kept, as a fresh process holds it.
static func forget() -> void:
	_carcasses.clear()


# The creature is flung: a free body under the field's own gravity that stops on the field's own ground,
# the same wherever the viewer is. `impulse` is the velocity change it is given, m/s. `lethal` marks a
# death, so the body stays and decays where it lands. A near-zero push still topples it.
static func launch(c, impulse: Vector3, lethal: bool) -> void:
	if lethal:
		_become_carcass(c)
	var parent: Node = c.get_parent()
	if parent == null or not c.is_inside_tree():
		return
	var pos: Vector3 = c.global_position
	var up: Vector3 = c.terrain.up_at(pos) if c.terrain != null else Vector3.UP
	var vel: Vector3 = impulse
	if c._ragdoll and c._fall_id >= 0:
		var st: Dictionary = LABallistics.state(c._fall_id)
		vel += Vector3(st.get("velocity", Vector3.ZERO))
		LABallistics.release(c._fall_id)
		c._fall_id = -1
	var rng: LASimRng = LASimRng.for_domain("life")
	if vel.length() < 0.5:
		var t1: Vector3 = up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		var t2: Vector3 = up.cross(t1)
		var axis: Vector3 = t1 * rng.randf_range(-1.0, 1.0) + up * 0.4 + t2 * rng.randf_range(-1.0, 1.0)
		vel = axis.normalized() * (c.size * 2.5 + 1.5)
	c._fall_push = vel
	c._ragdoll = true
	if LABallistics.rock_at(pos):
		_on_settled(c)
		return
	c._fall_id = LABallistics.drop(pos, vel, LACreatureRespiration.body_mass(c), maxf(c.size * 0.6, 0.1))


# The free body carries the creature until the field's ground stops it.
static func tick(c, delta: float) -> void:
	var st: Dictionary = LABallistics.state(c._fall_id) if c._fall_id >= 0 else {}
	if st.is_empty():
		_on_settled(c)
		return
	c.global_position = st["position"]
	c._decay_age += delta
	if bool(st["landed"]):
		_on_settled(c)


# Landed: either recover (alive) or ground the carcass (dead), seated on the body's surface.
static func _on_settled(c) -> void:
	var pos: Vector3 = c.global_position
	_release_fall(c)
	c._ragdoll = false
	c._decay_age = 0.0                # reset the tumble-timer reuse: decomposition ages from a fresh 0

	if c._dead:
		# Lie on the side the push toppled it towards, seated on the surface along its own radial.
		if c.terrain != null:
			var surf: Vector3 = c.terrain.ground_point(pos)
			if not is_nan(surf.x):
				var up_out: Vector3 = (pos - c.terrain.planet_center()).normalized()
				c.global_position = surf + up_out * (c.size * 0.35)
				var tip: Vector3 = up_out.cross(Vector3(c._fall_push))
				if tip.length() > 1.0e-4:
					c.global_transform.basis = Basis(tip.normalized(), PI * 0.5) * c.global_transform.basis
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
	c.add_fear(c.global_position, 1.5)


static func _release_fall(c) -> void:
	if c._fall_id >= 0:
		LABallistics.release(c._fall_id)
	c._fall_id = -1


# Turn the (still-living) creature INTO a carcass: leave the live groups so nothing hunts/flees it,
# join carrion+corpse so scavengers eat it, freeze its animation, and set its remaining meat value.
static func _become_carcass(c) -> void:
	c._dead = true
	# The body is the carcass. Draw the whole live mass OUT of the animal's own accounts as we do it, so the
	# mass exists in exactly one place and a predator that already took a bite finds correspondingly less meat.
	c._carrion = LACreatureBodyMass.draw(c, LACreatureBodyMass.body_carbon(c))
	c._carrion_initial = c._carrion           # what it weighed when it died — the denominator for rot + shrink
	c._decay_age = 0.0
	c.remove_from_group(c._species_group(c.species))
	c.remove_from_group(c.GROUP_CREATURE)
	c.add_to_group(c.GROUP_CARRION)
	c.add_to_group("corpse")
	LAGroupIndex.shared().joined(c)
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
	_release_fall(c)
	c.queue_free()


static func decay_tick(c, delta: float) -> void:
	c._decay_age += delta
	LACreatureRespiration.exchange_heat(c, c.global_position, delta, LACreatureRespiration.body_mass(c),
		LACreatureRespiration.exchange_area(c))
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
	# The microbes work at the carcass's own temperature, which follows the medium it lies in.
	var t_c: float = float(c.body_temp)
	var warmth: float = clampf((t_c - COLD_STALL_C) / (WARM_OPT_C - COLD_STALL_C), MUMMIFY_FLOOR, 1.0)
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
# taken the fraction of biomass below.
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
