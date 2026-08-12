class_name LACreatureSenses
extends RefCounted


const PREDATOR_SIZE_RATIO: float = 1.2

# One spatial hash shared by every creature's sense queries.
static var _index: LASpatialIndex = null


## The shared frame-stamped spatial index, ensured fresh for the current physics frame for `groups`.
static func _fresh_index(c, groups: Array) -> LASpatialIndex:
	if _index == null:
		_index = LASpatialIndex.new()
	_index.rebuild_if_stale(c.get_tree(), Engine.get_physics_frames(), groups)
	return _index


## Every live creature within `radius` of `c` (itself excluded).
static func creatures_within(c, radius: float) -> Array:
	var out: Array = []
	for cand in _fresh_index(c, ["creature"]).query("creature", c.global_position, radius):
		if is_instance_valid(cand) and cand != c:
			out.append(cand)
	return out


## Nearest live member of any species in `species_list` inside the creature's FOV cone and eye range.
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


static func nearest_plant(c, pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = c.sense_radius * 2.5
	for p in _fresh_index(c, ["plant"]).query("plant", pos, best_d):
		if not is_instance_valid(p) or not (p is Node3D):
			continue
		if p.has_method("is_edible") and not p.call("is_edible"):
			continue
		var d: float = pos.distance_to((p as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = p
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


## Nearest carcass (group "carrion") the creature can SEE (FOV cone).
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


## Nearest VISIBLE creature (in `group`) whose `state` is one of `states`.
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


## Direction UP the CO₂ gradient, or ZERO if the air is uniform (predator tracking).
static func follow_prey_scent(c, pos: Vector3) -> Vector3:
	if c._material == null or not c._material.has_method("airborne_gradient") or c.preys_on.is_empty():
		return Vector3.ZERO
	var dir: Vector3 = c._material.airborne_gradient("co2", pos)
	if dir != Vector3.ZERO:
		dir.y = 0.0
		return dir
	return Vector3.ZERO
