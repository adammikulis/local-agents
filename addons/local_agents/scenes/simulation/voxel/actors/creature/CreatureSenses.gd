class_name LACreatureSenses
extends RefCounted

## Perception queries for LACreature, factored out of the main brain. All functions are
## static and take the creature `c` — they read its senses (sense_radius, night _sense_mult,
## size, injected _scent, preys_on) and scan the scene groups. Kept dependency-free of the
## LACreature type (dynamic access + inlined group names/constants) so there is no cyclic
## class reference. (Explicit types only — project rule: no ':=' inferred typing.)

# Mirrors LACreature.PREDATOR_SIZE_RATIO — flee hunters at least this many times my size.
const PREDATOR_SIZE_RATIO: float = 1.2


## Nearest live member of any species in `species_list` the creature can SEE (inside its FOV cone
## and eye range, per LAVision — so a hunter must face prey, and binocular eyes reach farther).
static func nearest_of(c, pos: Vector3, species_list) -> Node3D:
	var best: Node3D = null
	var best_d: float = LAVision.effective_range(c)
	for sp in species_list:
		for cand in c.get_tree().get_nodes_in_group("species_" + String(sp)):
			if not is_instance_valid(cand) or cand == c:
				continue
			var c3: Node3D = cand as Node3D
			if c3 == null:
				continue
			if not LAVision.can_see(c, c3.global_position):
				continue
			var d: float = pos.distance_to(c3.global_position)
			if d < best_d:
				best_d = d
				best = c3
	return best


## Emergent threat detection: nearest VISIBLE creature that HUNTS and is meaningfully LARGER than me.
## Panoramic prey spot threats from almost any angle; a predator can be ambushed from its blind spot.
static func nearest_larger_predator(c, pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = LAVision.effective_range(c)
	for cand in c.get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(cand) or cand == c:
			continue
		if not cand.has_method("is_hunter") or not cand.call("is_hunter"):
			continue
		if float(cand.get("size")) < c.size * PREDATOR_SIZE_RATIO:
			continue
		var c3: Node3D = cand as Node3D
		if not LAVision.can_see(c, c3.global_position):
			continue
		var d: float = pos.distance_to(c3.global_position)
		if d < best_d:
			best_d = d
			best = c3
	return best


## Nearest ground rock (for throwers that grab one to hurl at prey).
static func nearest_rock(c, pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = c.sense_radius * 2.5
	for r in c.get_tree().get_nodes_in_group("rock"):
		if not is_instance_valid(r) or not (r is Node3D):
			continue
		var d: float = pos.distance_to((r as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = r
	return best


## Nearest carcass (group "carrion") the creature can SEE (FOV cone). Used by aerial scavengers to
## spot a kill and by ground scavengers reading the scene directly.
static func nearest_visible_carrion(c, pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = LAVision.effective_range(c) * 1.5   # carcasses are large, spotted a bit farther
	for cand in c.get_tree().get_nodes_in_group("carrion"):
		if not is_instance_valid(cand) or not (cand is Node3D):
			continue
		var c3: Node3D = cand as Node3D
		if not LAVision.can_see(c, c3.global_position):
			continue
		var d: float = pos.distance_to(c3.global_position)
		if d < best_d:
			best_d = d
			best = c3
	return best


## Nearest VISIBLE creature (in `group`) whose `state` is one of `states`. This is how a ground
## scavenger reads a circling/soaring vulture as a pointer to a carcass — public information, general.
static func nearest_visible_in_state(c, pos: Vector3, group: String, states) -> Node3D:
	var best: Node3D = null
	var best_d: float = LAVision.effective_range(c) * 1.5
	for cand in c.get_tree().get_nodes_in_group(group):
		if not is_instance_valid(cand) or cand == c or not (cand is Node3D):
			continue
		if not states.has(String(cand.get("state"))):
			continue
		var c3: Node3D = cand as Node3D
		if not LAVision.can_see(c, c3.global_position):
			continue
		var d: float = pos.distance_to(c3.global_position)
		if d < best_d:
			best_d = d
			best = c3
	return best


## Direction along the strongest prey scent trail, or ZERO if none (predator tracking).
static func follow_prey_scent(c, pos: Vector3) -> Vector3:
	if c._scent == null or c.preys_on.is_empty():
		return Vector3.ZERO
	for sp in c.preys_on:
		var dir: Vector3 = c._scent.scent_direction(pos, String(sp), c.sense_radius * 2.5)
		if dir != Vector3.ZERO:
			dir.y = 0.0
			return dir
	return Vector3.ZERO
