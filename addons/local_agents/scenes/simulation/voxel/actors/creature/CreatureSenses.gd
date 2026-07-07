class_name LACreatureSenses
extends RefCounted

## Perception queries for LACreature, factored out of the main brain. All functions are
## static and take the creature `c` — they read its senses (sense_radius, night _sense_mult,
## size, injected _scent, preys_on) and scan the scene groups. Kept dependency-free of the
## LACreature type (dynamic access + inlined group names/constants) so there is no cyclic
## class reference. (Explicit types only — project rule: no ':=' inferred typing.)

# Mirrors LACreature.PREDATOR_SIZE_RATIO — flee hunters at least this many times my size.
const PREDATOR_SIZE_RATIO: float = 1.2

# One spatial hash shared by every creature's sense queries; lazily built and rebuilt at most once per
# physics frame per group (see LASpatialIndex). The first sense call of a frame that needs a group pays
# the rebuild; the other 276 creatures reuse it. This is what turns the old O(n²) group scans into O(n).
static var _index: LASpatialIndex = null


## The shared frame-stamped spatial index, ensured fresh for the current physics frame for `groups`.
static func _fresh_index(c, groups: Array) -> LASpatialIndex:
	if _index == null:
		_index = LASpatialIndex.new()
	_index.rebuild_if_stale(c.get_tree(), Engine.get_physics_frames(), groups)
	return _index


## Nearest live member of any species in `species_list` the creature can SEE (inside its FOV cone
## and eye range, per LAVision — so a hunter must face prey, and binocular eyes reach farther).
static func nearest_of(c, pos: Vector3, species_list) -> Node3D:
	var groups: Array = []
	for sp in species_list:
		groups.append("species_" + String(sp))
	var idx: LASpatialIndex = _fresh_index(c, groups)
	var best: Node3D = null
	var best_d: float = LAVision.effective_range(c)
	for sp in species_list:
		for cand in idx.query("species_" + String(sp), pos, best_d):
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
	for cand in _fresh_index(c, ["creature"]).query("creature", pos, best_d):
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
	for r in _fresh_index(c, ["rock"]).query("rock", pos, best_d):
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
	for cand in _fresh_index(c, ["carrion"]).query("carrion", pos, best_d):
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
	for cand in _fresh_index(c, [group]).query(group, pos, best_d):
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


## Direction UP the prey-scent gradient in the shared field, or ZERO if none (predator tracking). The old
## per-species trail collapsed into one PREY channel: a carnivore follows prey musk toward prey-dense ground
## (vision still picks the individual target). The scent rides the real wind, so this is "smell prey downwind".
static func follow_prey_scent(c, pos: Vector3) -> Vector3:
	if c._material == null or not c._material.has_method("scent_gradient") or c.preys_on.is_empty():
		return Vector3.ZERO
	var dir: Vector3 = c._material.scent_gradient(pos, LAMaterialScent3D.PREY)
	if dir != Vector3.ZERO:
		dir.y = 0.0
		return dir
	return Vector3.ZERO
