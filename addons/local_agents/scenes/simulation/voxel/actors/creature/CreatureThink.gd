class_name LACreatureThink
extends RefCounted

## Diet-driven decision routines for LACreature (prey / predator / bird / scavenger), plus the cognition
## action-vocabulary bridge, factored out of the main brain. Each entry point returns a desired heading
## and sets the creature's `state`; unified eating, ranged hunting, "watch the vultures" public-information
## cues, and the innate→action dispatch all live here. Static + dynamic access on the passed creature (no
## cyclic class reference). (Explicit types only — project rule: no ':=' inferred typing.)

const DRINK_RATE: float = 45.0             # hydration/sec restored while drinking (mirrors LACreature.DRINK_RATE)
const COMPANION_FOLLOW_DIST: float = 4.0   # a "follow" companion closes to this range, then heels/holds

const ThrownRockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/ThrownRock.gd")


# --- prey behavior: flee predators (dominates), else forage (seek + eat plants), else wander + flock ---
static func think_prey(c, pos: Vector3, fallback: Vector3) -> Vector3:
	var threat: Node3D = LACreatureSenses.nearest_of(c, pos, c.flees_from)
	if threat != null:
		c.state = "flee"
		var away: Vector3 = pos - threat.global_position
		away.y = 0.0
		if away.length() > 0.001:
			return away.normalized() * 1.5
	if c.diet != "carnivore":
		return forage_graze(c, pos, fallback)
	c.state = "wander"
	return fallback + LACreatureFlocking.steer(c, pos, true)


# DIRECTED GRAZING for a plant-eater. Eat a plant within reach; else — if hungry — steer toward the nearest
# SENSED edible plant (the exact "locate the food and move to it" rule a predator uses to chase prey), which the
# tangent-projection in Creature turns into surface movement; else wander + flock. Before this, a herbivore only
# ate what it randomly bumped into (reach ~1.5 u) and so starved to extinction amid abundant, growing plants —
# now it walks to the pasture. Emergent (no per-species code): one seek-and-eat drive, gated by the hunger signal.
static func forage_graze(c, pos: Vector3, fallback: Vector3) -> Vector3:
	if _try_eat_plant(c, pos):
		c.state = "eat"
		return fallback + LACreatureFlocking.steer(c, pos, true)
	if LACreatureDigestion.hunger(c) > 0.12:
		var food: Node3D = LACreatureSenses.nearest_plant(c, pos)
		if food != null:
			var to_food: Vector3 = (food as Node3D).global_position - pos
			if to_food.length() > 0.001:
				c.state = "forage"
				return to_food.normalized()
	c.state = "wander"
	return fallback + LACreatureFlocking.steer(c, pos, true)


# --- predator behavior: scavenge, hunt prey (throw or bite), track scent, else flock ---
static func think_predator(c, pos: Vector3, fallback: Vector3) -> Vector3:
	# Scavenge carrion whenever not near-full (omnivores/humans eat anything they can).
	if c.energy < c.max_energy * 0.95 and _try_scavenge(c, pos):
		c.state = "eat"
		return fallback
	# Public information ("watch the vultures"), fully EMERGENT: other animals are cues to resources,
	# and experience — not code — decides which cues are worth following. If a perceived cue has a
	# high learned worth (or curiosity picks an unknown one), go investigate it.
	if c.energy < c.max_energy * 0.85:
		var cue: Dictionary = _best_learned_cue(c, pos)
		if not cue.is_empty():
			c._pursued_cue = String(cue["key"])
			c._pursued_cd = 8.0
			c.state = "investigate"
			return cue["dir"]
	var prey: Node3D = LACreatureSenses.nearest_of(c, pos, c.preys_on)
	if prey != null:
		var to_prey: Vector3 = prey.global_position - pos
		to_prey.y = 0.0
		if c.throws:
			return _hunt_with_rock(c, pos, prey, to_prey, fallback)   # ranged: humans throw rocks
		if to_prey.length() <= maxf(c.size + 0.8, 1.0):
			_kill_and_eat(c, prey)
			c.state = "eat"
			return fallback
		c.state = "chase"
		if to_prey.length() > 0.001:
			return to_prey.normalized()
	else:
		# Public information ("watch the vultures"): a hungry ground scavenger heads toward the
		# strongest carrion cue — circling vultures (sight), carrion scent (smell), or a carrion call
		# (sound). A weak innate pull; the cognition layer reinforces it into a learned, inherited habit.
		if c.energy < c.max_energy * 0.7:
			var cue: Vector3 = _carrion_cue(c, pos)
			if cue != Vector3.ZERO:
				c.state = "investigate"
				return cue
		var trail: Vector3 = LACreatureSenses.follow_prey_scent(c, pos)
		if trail != Vector3.ZERO:
			c.state = "track"
			return trail
	if c.diet == "omnivore" and _try_eat_plant(c, pos):
		c.state = "eat"
		return fallback + LACreatureFlocking.steer(c, pos, true)
	c.state = "wander"
	return fallback + LACreatureFlocking.steer(c, pos, true)


# Persistence hunting: the hunter can't outrun fleeing prey, so it just keeps walking after it. The prey
# sprints (burning energy fast) and eventually collapses from exhaustion. A rock, if grabbed on the way,
# ends it sooner.
static func _hunt_with_rock(c, pos: Vector3, prey: Node3D, to_prey: Vector3, fallback: Vector3) -> Vector3:
	var dist: float = to_prey.length()
	if not c.has_rock:
		var rock: Node3D = LACreatureSenses.nearest_rock(c, pos)
		if rock != null and pos.distance_to((rock as Node3D).global_position) <= maxf(c.size + 1.3, 1.7):
			if rock.has_method("take"):
				rock.take()
			c.has_rock = true
			_set_rock_visual(c, true)
	if c.has_rock and dist <= c.throw_range and c._throw_cd <= 0.0:
		_throw_rock_at(c, prey)
		c.state = "throw"
		return fallback
	c.state = "stalk"
	return to_prey.normalized() if dist > 0.001 else fallback


static func _throw_rock_at(c, prey: Node3D) -> void:
	c.has_rock = false
	_set_rock_visual(c, false)
	c._throw_cd = 2.5
	var parent: Node = c.get_parent()
	if parent == null:
		return
	var rock: ThrownRockScript = ThrownRockScript.new()
	parent.add_child(rock)
	if rock.has_method("setup"):
		rock.setup(c.terrain, c._material)
	rock.throw_at(c.global_position + Vector3(0, c.size, 0), prey, 26.0)


static func _kill_and_eat(c, prey: Node3D) -> void:
	var gain: float = c.food_value
	if prey != null and "food_value" in prey:
		gain = float(prey.food_value)
	# The kill fills the GUT (biomass), not energy directly — energy now rises only as it digests (over seconds).
	var meat: float = gain * 0.7
	var prey_profile: Dictionary = prey.food_profile() if prey != null and prey.has_method("food_profile") else {}
	LACreatureDigestion.ingest(c, meat, prey_profile)
	LocalAgentsAudioDirector.emit(c.get_tree(), "chomp", c.global_position)
	c._emit_call("forage")                     # a kill call: kin nearby learn to hunt this situation
	_reinforce_cue_success(c)
	# TASTE learning: a fresh kill's taste cue, reinforced by how much the meal is worth (chemical affinity).
	if not prey_profile.is_empty():
		LACreatureChemSense.on_eat(c, prey_profile, meat)
	if prey.has_method("die"):
		prey.die("eaten")           # leaves a carcass (leftovers for scavengers)
	elif prey.has_method("queue_free"):
		prey.queue_free()


# Scavenging is just eating meat-type food off the ground — same unified path as grazing.
static func _try_scavenge(c, pos: Vector3) -> bool:
	return _try_eat_food(c, pos)


# UNIFIED EATING: scan nearby food (anything exposing food_profile — plants, carcasses, …) and eat the
# best item my diet will forage. Herbivores take carbs, carnivores/scavengers take meat, omnivores both;
# energy gained scales with the food's STATE (a rotten carcass is worth half, cooked more). One rule for
# every diet and every food source — living prey is the one thing not eaten here (it must be hunted first,
# which turns it into a carcass = dead meat).
static func _try_eat_food(c, pos: Vector3) -> bool:
	# Sated when energy is high OR the gut is already packed with a meal being digested — a starving-but-full
	# creature stops foraging and lets its gut work (energy climbs as it digests) instead of over-eating.
	if c.energy > c.max_energy * 0.92 or LACreatureDigestion.gut_fill(c) > 0.9:
		return false
	var best: Node3D = null
	var best_val: float = 0.0
	var reach: float = maxf(c.size + 1.0, 1.4)
	for grp in ["plant", "carrion"]:
		for f in c.get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(f) or not (f is Node3D):
				continue
			if not f.has_method("food_profile"):
				continue
			if pos.distance_to((f as Node3D).global_position) > reach:
				continue
			if f.has_method("is_edible") and not f.is_edible():
				continue
			var prof: Dictionary = f.food_profile()
			if not LAFood.can_forage(c.diet, prof):
				continue
			# TASTE AVERSION: refuse a food this creature has LEARNED tastes bad (a poison it has been sickened
			# by, or absorbed as a fear from kin) unless it is desperate enough to gamble — the affinity system
			# now steers foraging, so a herbivore skips the toxic plant it learned and grazes the wholesome ones.
			if LACreatureChemSense.avoids_food(c, prof):
				continue
			var v: float = LAFood.value(prof)
			if v > best_val:
				best_val = v
				best = f
	if best == null:
		return false
	var profile: Dictionary = best.food_profile()
	var gained: float = 0.0
	if best.has_method("feed"):
		gained = float(best.call("feed", 30.0)) * LAFood.state_mult(profile)   # a bite of a carcass
	else:
		gained = LAFood.value(profile)                                          # a whole plant
		(best as Node3D).queue_free()
	if gained <= 0.0:
		return false
	# The bite fills the GUT (biomass) instead of crediting energy directly — energy rises only as it digests.
	LACreatureDigestion.ingest(c, gained, profile)
	# TOXIC bite: a poisonous plant still fed the gut, but it also HARMS. Route the poison through the ordinary
	# damage path so the HP loss flows into cognition's aversive valence + learned-lethal veto exactly like any
	# other harm — the creature learns to shun this plant. Survivable by design (see LACreatureChemSense consts).
	var toxin: float = LACreatureChemSense.toxin_damage(c, profile)
	if toxin > 0.0:
		c.take_damage(toxin, "toxin")
	c._emit_call("forage")
	_reinforce_cue_success(c)
	# TASTE learning: reinforce the food's taste cue by how much this bite fed me (chemical affinity).
	LACreatureChemSense.on_eat(c, profile, gained)
	return true


static func _set_rock_visual(c, on: bool) -> void:
	if c._rock_visual != null and is_instance_valid(c._rock_visual):
		c._rock_visual.visible = on


static func think_bird(c, pos: Vector3, delta: float) -> Vector3:
	# A hungry/thirsty bird drops out of the flock, LANDS, and forages/drinks (flyers can now descend).
	if LACreatureBird.wants_to_land(c):
		c._target_altitude = maxf(c.size, 1.0)
		var thirst: String = LACreatureThirst.handle_thirst(c, pos, delta)
		if thirst == "drink":
			c.state = "drink"
			return c._heading
		if thirst == "seek":
			c.state = "seek"
			return c._water_dir_cache
		c.state = "eat" if _try_eat_plant(c, pos) else "wander"
		return c._heading + LACreatureFlocking.steer(c, pos, true)
	# Otherwise soar with the flock, wheeling and bobbing on thermals.
	c._target_altitude = maxf(c.cruise_height + sin(c.age * 0.4) * 3.0, 1.5)
	c.state = "cruise"
	return c._heading + LACreatureBird.steer(c, pos)


# Vulture behaviour: soar high scanning for death; follow the "carrion" scent (or a seen carcass); spiral
# DOWN and circle over the kill (the visible signal others read); feed; call to advertise it.
static func think_scavenger(c, pos: Vector3, _delta: float) -> Vector3:
	var carcass: Node3D = LACreatureSenses.nearest_visible_carrion(c, pos)
	var to_flat: Vector3 = Vector3.ZERO
	if carcass != null:
		to_flat = Vector3(carcass.global_position.x - pos.x, 0.0, carcass.global_position.z - pos.z)
	elif c._material != null and c._material.has_method("scent_gradient"):
		var d: Vector3 = c._material.scent_gradient(pos, LAMaterialField3D.SCENT_FOOD)
		if d != Vector3.ZERO:
			to_flat = Vector3(d.x, 0.0, d.z)
	if to_flat != Vector3.ZERO:
		var dist: float = to_flat.length()
		if carcass != null and dist < 7.0:
			# Over the carcass: spiral down and feed — the visible "vultures circling".
			c.state = "circle"
			c._target_altitude = maxf(c.size + 1.0, 2.0)
			c._emit_call("carrion")                        # announce the kill (draws ground scavengers)
			if dist < maxf(c.size + 1.4, 1.8):
				_try_scavenge(c, pos)
			var tangent: Vector3 = Vector3(-to_flat.z, 0.0, to_flat.x).normalized()
			return to_flat.normalized() * 0.4 + tangent * 0.7
		c.state = "soar"
		c._target_altitude = maxf(c.cruise_height * 0.5, 3.0)   # glide down toward the find
		return to_flat.normalized() + LACreatureBird.steer(c, pos) * 0.3
	# Nothing dead in sight or on the wind: soar high on thermals with the kettle.
	c.state = "soar"
	c._target_altitude = maxf(c.cruise_height + sin(c.age * 0.4) * 3.0, 2.0)
	return c._heading + LACreatureBird.steer(c, pos)


# EMERGENT public information. Look at the other animals I can perceive; each is a possible cue to a
# resource, keyed generically by its "species:state" (nothing names vultures or circling). Head for the
# cue my experience rates highest — and, when nothing is proven, occasionally investigate an UNKNOWN cue
# out of curiosity so associations can be discovered in the first place. Flying animals are perceptible
# far off against the open sky, which is exactly why a wheeling flock reads at range.
static func _best_learned_cue(c, pos: Vector3) -> Dictionary:
	if c._cognition == null:
		return {}
	var best_key: String = ""
	var best_val: float = 0.3                    # only exploit a cue once it's proven worthwhile
	var best_dir: Vector3 = Vector3.ZERO
	var unknown_key: String = ""
	var unknown_dir: Vector3 = Vector3.ZERO
	for m in c.get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(m) or m == c or not (m is Node3D):
			continue
		var mpos: Vector3 = (m as Node3D).global_position
		var flying: bool = bool(m.get("can_fly"))
		var reach: float = (c.sense_radius * 4.0) if flying else LAVision.effective_range(c)
		if pos.distance_to(mpos) > reach:
			continue
		if not flying and not LAVision.can_see(c, mpos):
			continue
		var dir: Vector3 = Vector3(mpos.x - pos.x, 0.0, mpos.z - pos.z)
		if dir.length() < 0.001:
			continue
		var key: String = "%s:%s" % [String(m.get("species")), String(m.get("state"))]
		var val: float = c._cognition.cue_value(key)
		if val > best_val:
			best_val = val
			best_key = key
			best_dir = dir.normalized()
		elif val <= 0.05 and unknown_key == "":
			unknown_key = key
			unknown_dir = dir.normalized()
	if best_key != "":
		return {"key": best_key, "dir": best_dir}
	if unknown_key != "" and randf() < 0.03:     # curiosity: try an unproven cue to learn from it
		return {"key": unknown_key, "dir": unknown_dir}
	return {}


# Learn from a meal in two ways: credit the cue I was deliberately chasing, AND — Pavlovian — associate
# whatever signs happen to be present with the food. Signs that RELIABLY accompany food (scavengers
# circling overhead, animals feeding) accrue value across many meals; incidental noise washes out. This is
# how "circling vultures mean a carcass" is DISCOVERED, never coded.
static func _reinforce_cue_success(c) -> void:
	if c._cognition == null:
		return
	if c._pursued_cue != "" and c._pursued_cd > 0.0:
		c._cognition.reinforce_cue(c._pursued_cue, 1.0)
	c._pursued_cue = ""
	c._pursued_cd = 0.0
	var pos: Vector3 = c.global_position
	for m in c.get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(m) or m == c or not (m is Node3D):
			continue
		var mpos: Vector3 = (m as Node3D).global_position
		var flying: bool = bool(m.get("can_fly"))
		var reach: float = (c.sense_radius * 4.0) if flying else LAVision.effective_range(c)
		if pos.distance_to(mpos) > reach:
			continue
		if not flying and not LAVision.can_see(c, mpos):
			continue
		c._cognition.reinforce_cue("%s:%s" % [String(m.get("species")), String(m.get("state"))], 0.6)


# The strongest carrion CUE for a ground scavenger, over three channels — this is "watch the vultures":
# circling flyers (sight), carrion scent (smell), or a heard carrion call (sound).
static func _carrion_cue(c, pos: Vector3) -> Vector3:
	var flyer: Node3D = LACreatureSenses.nearest_visible_in_state(c, pos, "creature", ["circle"])
	if flyer != null:
		var d: Vector3 = Vector3(flyer.global_position.x - pos.x, 0.0, flyer.global_position.z - pos.z)
		if d.length() > 0.001:
			return d.normalized()
	if c._material != null and c._material.has_method("scent_gradient"):
		var s: Vector3 = c._material.scent_gradient(pos, LAMaterialField3D.SCENT_FOOD)
		if s != Vector3.ZERO:
			return Vector3(s.x, 0.0, s.z).normalized()
	if c._cue_cd > 0.0:
		var cc: Vector3 = Vector3(c._cue_pos.x - pos.x, 0.0, c._cue_pos.z - pos.z)
		if cc.length() > 0.001:
			return cc.normalized()
	return Vector3.ZERO


# Grazing is just eating carbs-type food off the ground — same unified path as scavenging.
static func _try_eat_plant(c, pos: Vector3) -> bool:
	return _try_eat_food(c, pos)


# --- cognition action vocabulary bridge -------------------------------------
# Map the innate cascade's descriptive `state` to a canonical action name (LAActionRegistry) so the fast
# policy, social learning, and the LLM all speak the same vocabulary.
static func state_to_action(c, s: String) -> String:
	match s:
		"flee", "panic":
			return "flee"
		"chase", "stalk", "track":
			return "hunt"
		"throw":
			return "throw_rock"
		"drink":
			return "drink"
		"seek":
			return "seek_water"
		"cruise":
			return "flock"
		"circle", "soar":
			return "scavenge"
		"investigate":
			return "investigate"
		"eat", "forage":
			return "graze" if c.diet == "herbivore" else "scavenge"
		"rest", "sleep", "roost", "nesting":
			return "rest"
		"migrate":
			return "migrate"
		_:
			return "wander"


# Clamp a leader's action to one a FOLLOWER `f` can meaningfully perform before it adopts it. Followers are
# same-species as their leader (so diets normally match), but this guards mixed/edge configs: a non-hunter
# handed "hunt"/"throw_rock" forages instead, and a herbivore handed "scavenge" grazes. execute_action also
# degrades gracefully (a herbivore sent to hunt finds no prey → wanders), so this is belt-and-suspenders.
static func _adoptable_action(action: String, f) -> String:
	match action:
		"hunt", "throw_rock":
			if f.diet == "carnivore" or (f.diet == "omnivore" and f.preys_on.size() > 0):
				return action
			return "graze" if f.diet == "herbivore" else "scavenge"
		"scavenge":
			return "graze" if f.diet == "herbivore" else action
		_:
			return action


# Execute a chosen action name → {heading, state, speed}. This is the name→behaviour dispatch the fast
# policy and slow brain drive; it reuses the same primitives as the innate cascade.
static func execute_action(c, action: String, pos: Vector3, delta: float) -> Dictionary:
	match action:
		"graze":
			# Directed grazing (seek + eat), so a herbivore driven here by its policy/leader walks to the pasture
			# instead of only eating what it bumps into. forage_graze sets c.state ("eat"/"forage"/"wander").
			var gh: Vector3 = forage_graze(c, pos, c._heading)
			return {"heading": gh, "state": c.state, "speed": c.speed}
		"scavenge":
			_try_scavenge(c, pos)
			return {"heading": c._heading + LACreatureFlocking.steer(c, pos, true), "state": "eat", "speed": c.speed}
		"investigate":
			var cue: Vector3 = _carrion_cue(c, pos)
			if cue != Vector3.ZERO:
				return {"heading": cue, "state": "investigate", "speed": c.speed}
			return {"heading": c._heading, "state": "wander", "speed": c.speed}
		"hunt", "throw_rock":
			var h: Vector3 = think_predator(c, pos, c._heading)   # sets `state` (chase/stalk/throw/…)
			return {"heading": h, "state": c.state, "speed": c.speed}
		"flock":
			return {"heading": c._heading + LACreatureFlocking.steer(c, pos, not c.can_fly), "state": "flock", "speed": c.speed}
		"drink":
			if c._material != null and c._material.has_method("is_water_at") and c._material.is_water_at(pos):
				c.hydration = minf(c.max_hydration, c.hydration + DRINK_RATE * delta)
				return {"heading": c._heading, "state": "drink", "speed": 0.0}
			return execute_action(c, "seek_water", pos, delta)
		"seek_water":
			var wd: Vector3 = LACreatureThirst.find_water_dir(c, pos)
			if wd != Vector3.ZERO:
				return {"heading": wd, "state": "seek", "speed": c.speed}
			return {"heading": c._heading, "state": "wander", "speed": c.speed}
		"rest":
			return {"heading": c._heading, "state": "rest", "speed": c.speed * 0.12}
		"migrate":
			if c._migrate_dir == Vector3.ZERO:
				var cards: Array = [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]
				c._migrate_dir = cards[randi() % cards.size()]
			return {"heading": c._migrate_dir, "state": "migrate", "speed": c.speed}
		"flee":
			# A follower that ADOPTED its leader's flee (Creature._physics_process) must actually move — this
			# used to fall through to the no-op default and keep wandering toward the danger. Sprint away from
			# the nearest larger predator if one is sensed, else reverse the current heading.
			var away: Vector3 = -c._heading
			var pred = LACreatureSenses.nearest_larger_predator(c, pos)
			if pred != null and is_instance_valid(pred) and (pos - pred.global_position).length() > 0.001:
				away = pos - pred.global_position
			if away.length() < 0.001:
				away = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0)
			return {"heading": away.normalized(), "state": "flee", "speed": c.speed * 1.5}
		"wander":
			return {"heading": c._heading, "state": "wander", "speed": c.speed}
		"come":
			# COMPANION "come": a bonded creature walks to the player's hand beacon (LACreatureBond.target) and
			# stops on arrival. No bond target yet → hold in place rather than wander off.
			if c.bond == null or not c.bond.has_target():
				return {"heading": c._heading, "state": "come", "speed": 0.0}
			var to_hand: Vector3 = c.bond.target() - pos
			if to_hand.length() <= maxf(c.size + 1.4, 1.8):
				return {"heading": c._heading, "state": "come", "speed": 0.0}   # arrived at the hand
			return {"heading": to_hand.normalized(), "state": "come", "speed": c.speed * 1.2}
		"follow":
			# COMPANION "follow": trail the player, closing to a comfortable distance then holding (so a bonded
			# pack heels alongside the player rather than piling onto the exact point).
			if c.bond == null or not c.bond.has_target():
				return {"heading": c._heading, "state": "follow", "speed": 0.0}
			var to_p: Vector3 = c.bond.target() - pos
			if to_p.length() <= COMPANION_FOLLOW_DIST:
				return {"heading": c._heading, "state": "follow", "speed": 0.0}
			return {"heading": to_p.normalized(), "state": "follow", "speed": c.speed}
		"stay":
			# COMPANION "stay": stand your ground where commanded (keeps facing, no travel).
			return {"heading": c._heading, "state": "stay", "speed": 0.0}
	return {"heading": c._heading, "state": c.state, "speed": c.speed}
