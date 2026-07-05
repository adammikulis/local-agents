class_name LACreature
extends CharacterBody3D

# One flexible creature driven by a species config Dictionary. Terrain-follow via an
# injected LAVoxelTerrainService (surface_height(x,z)). Behavior is emergent: flee larger
# hunters, hunt prey (melee bite or persistence + thrown rocks), scavenge carrion, eat
# plants, panic at felt/heard events, flock/imitate same-kind neighbours, and live/die by
# an energy budget. (Explicit types only — project rule: no ':=' inferred typing.)

const GROUP_SELECTABLE: String = "selectable"
const GROUP_PLANT: String = "plant"
const GROUP_CREATURE: String = "creature"
const GROUP_ROCK: String = "rock"
const GROUP_CARRION: String = "carrion"
const PREDATOR_SIZE_RATIO: float = 1.2     # flee anything this many times my size that hunts

const CorpseScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Corpse.gd")
const ThrownRockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/ThrownRock.gd")

# --- energy / hunger / mortality (emergent: eat to live, starve or age to die) ---
var energy: float = 100.0
var max_energy: float = 100.0
var metabolism: float = 2.2
var food_value: float = 55.0
var max_age: float = 90.0
var hungry_at: float = 0.7

# --- ranged hunting (throwers can't outrun fast prey, so they throw rocks) ---
var throws: bool = false
var throw_range: float = 14.0
var _throw_cd: float = 0.0
var has_rock: bool = false
var _rock_visual: MeshInstance3D = null
var _dying: bool = false

var terrain = null                       # LAVoxelTerrainService (injected)
var config: Dictionary = {}

var species: String = "creature"
var diet: String = "herbivore"
var speed: float = 3.0
var size: float = 0.5
var color: Color = Color(0.7, 0.7, 0.7)
var can_fly: bool = false
var cruise_height: float = 12.0
var sense_radius: float = 8.0
var maturity_age: float = 15.0
var preys_on: PackedStringArray = PackedStringArray()
var flees_from: PackedStringArray = PackedStringArray()
var herd: bool = false

# --- flocking weights (defaults; overridden per-species via config) ---
var flock_cohesion: float = 0.5
var flock_alignment: float = 0.5
var flock_separation: float = 0.8
var flock_radius: float = 8.0
var flock_weight: float = 0.7

var age: float = 0.0
var state: String = "wander"

var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _repath_timer: float = 0.0
var _mesh: MeshInstance3D = null

# --- terror / fear system: sprint away from felt/heard violence, overriding all else ---
var _panic_timer: float = 0.0
var _panic_source: Vector3 = Vector3.ZERO

# Injected scent field (LAScentField) — predators follow prey scent when out of sight.
var _scent = null


func add_fear(source_pos: Vector3, intensity: float) -> void:
	if intensity <= 0.0:
		return
	_panic_source = source_pos
	_panic_timer = maxf(_panic_timer, clampf(intensity, 0.6, 7.0))


func set_scent(s) -> void:
	_scent = s


# A thrown rock struck me — I die (drop a corpse).
func on_struck() -> void:
	die("struck")


# Death leaves a physical corpse (carrion) — creatures never just vanish.
# `impulse` (e.g. from a meteor) flings the body outward.
func die(_cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying:
		return
	_dying = true
	var parent: Node = get_parent()
	if parent != null and is_inside_tree():
		var corpse: CorpseScript = CorpseScript.new()
		parent.add_child(corpse)
		corpse.setup(species, color, size, terrain)
		corpse.global_position = global_position
		if impulse.length() > 0.01 and corpse.has_method("fling"):
			# Fling after the body has a physics space (next physics tick).
			var c = corpse
			var imp: Vector3 = impulse
			get_tree().create_timer(0.06).timeout.connect(
				func(): if is_instance_valid(c): c.fling(imp))
	queue_free()


func setup(_terrain, _config: Dictionary) -> void:
	terrain = _terrain
	config = _config.duplicate(true)
	species = String(config.get("species", species))
	diet = String(config.get("diet", diet))
	speed = float(config.get("speed", speed))
	size = float(config.get("size", size))
	color = config.get("color", color)
	can_fly = bool(config.get("can_fly", can_fly))
	cruise_height = float(config.get("cruise_height", cruise_height))
	sense_radius = float(config.get("sense_radius", sense_radius))
	maturity_age = float(config.get("maturity_age", maturity_age))
	preys_on = PackedStringArray(config.get("preys_on", PackedStringArray()))
	flees_from = PackedStringArray(config.get("flees_from", PackedStringArray()))
	herd = bool(config.get("herd", herd))
	flock_cohesion = float(config.get("flock_cohesion", flock_cohesion))
	flock_alignment = float(config.get("flock_alignment", flock_alignment))
	flock_separation = float(config.get("flock_separation", flock_separation))
	flock_radius = float(config.get("flock_radius", sense_radius))
	flock_weight = float(config.get("flock_weight", flock_weight))
	max_energy = float(config.get("max_energy", 100.0))
	energy = max_energy
	metabolism = float(config.get("metabolism", metabolism))
	food_value = float(config.get("food_value", size * 90.0))
	max_age = float(config.get("max_age", maxf(maturity_age * 5.0, 60.0)))
	hungry_at = float(config.get("hungry_at", hungry_at))
	throws = bool(config.get("throws", throws))
	throw_range = float(config.get("throw_range", throw_range))
	state = "cruise" if can_fly else "wander"

	collision_layer = 2
	collision_mask = 0                    # movement is manual; picked via layer-2 query
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(_species_group(species))
	add_to_group(GROUP_CREATURE)
	_heading = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0).normalized()
	if _heading == Vector3.ZERO:
		_heading = Vector3.FORWARD


static func _species_group(sp: String) -> String:
	return "species_%s" % sp


func _build_body() -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	if can_fly:
		var cap: CapsuleMesh = CapsuleMesh.new()
		cap.radius = size * 0.5
		cap.height = maxf(size * 1.4, size)
		mesh.mesh = cap
	else:
		var body: CapsuleMesh = CapsuleMesh.new()
		body.radius = size * 0.6
		body.height = maxf(size * 2.0, size * 1.2)
		mesh.mesh = body
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	mesh.material_override = mat
	add_child(mesh)
	_mesh = mesh

	var shape: CollisionShape3D = CollisionShape3D.new()
	var cyl: CapsuleShape3D = CapsuleShape3D.new()
	cyl.radius = maxf(size * 0.6, 0.1)
	cyl.height = maxf(size * 2.0, 0.4)
	shape.shape = cyl
	add_child(shape)

	# Throwers (humans) carry a visible rock when armed.
	if throws:
		_rock_visual = MeshInstance3D.new()
		_rock_visual.mesh = LARockMesh.make(maxf(size * 0.32, 0.18), 4242, 0.45)
		_rock_visual.material_override = LARockMesh.material()
		_rock_visual.position = Vector3(size * 0.55, size * 0.7, size * 0.35)
		_rock_visual.visible = false
		add_child(_rock_visual)


func _physics_process(delta: float) -> void:
	age += delta
	_throw_cd -= delta
	# Metabolism drains energy; exertion costs more; eating refills. Starve or age = death.
	var exertion: float = 1.6 if (state == "flee" or state == "panic" or state == "chase") else 1.0
	energy -= metabolism * exertion * delta
	if energy <= 0.0:
		die("starvation")
		return
	if age >= max_age:
		die("old age")
		return
	if terrain == null:
		return

	var pos: Vector3 = global_position
	var surf: float = _surface_at(pos.x, pos.z)
	if is_nan(surf):
		return                            # unmeshed / off-terrain: skip this frame

	var desired: Vector3 = _heading
	_wander_timer -= delta
	_repath_timer -= delta
	_panic_timer -= delta

	var eff_speed: float = speed
	if _panic_timer > 0.0:
		# TERROR: sprint straight away from what was heard/felt. Overrides everything.
		state = "panic"
		var away: Vector3 = pos - _panic_source
		away.y = 0.0
		if away.length() > 0.001:
			desired = away.normalized()
		eff_speed = speed * 2.1
	else:
		# Universal, emergent: flee any nearby larger hunter first (no hardcoded pairs).
		var big_pred: Node3D = _nearest_larger_predator(pos)
		if big_pred != null:
			state = "flee"
			var away: Vector3 = pos - big_pred.global_position
			away.y = 0.0
			if away.length() > 0.001:
				desired = away.normalized()
			eff_speed = speed * 1.7
		elif can_fly:
			desired = _think_bird(pos, delta)
			state = "cruise"
		elif diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0):
			desired = _think_predator(pos, desired)
		else:
			desired = _think_prey(pos, desired)

		if big_pred == null and _wander_timer <= 0.0:
			_wander_timer = randf_range(1.2, 3.0)
			var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0) * 0.6
			desired = (desired + jitter)

	desired.y = 0.0
	if desired.length() > 0.001:
		_heading = desired.normalized()

	var step: Vector3 = _heading * eff_speed * delta
	var new_x: float = pos.x + step.x
	var new_z: float = pos.z + step.z

	var target_surf: float = _surface_at(new_x, new_z)
	if is_nan(target_surf):
		target_surf = surf
	var target_y: float = target_surf + size
	if can_fly:
		target_y = target_surf + cruise_height

	global_position = Vector3(new_x, target_y, new_z)

	if _heading.length() > 0.01:
		var look: Vector3 = global_position + _heading
		look.y = global_position.y
		if not look.is_equal_approx(global_position):
			look_at(look, Vector3.UP)


func _surface_at(x: float, z: float) -> float:
	if terrain == null or not terrain.has_method("surface_height"):
		return NAN
	return float(terrain.surface_height(x, z))


# --- prey behavior: flee predators (dominates), else wander + flock, eat plants ---
func _think_prey(pos: Vector3, fallback: Vector3) -> Vector3:
	var threat: Node3D = _nearest_of(pos, flees_from)
	if threat != null:
		state = "flee"
		var away: Vector3 = pos - threat.global_position
		away.y = 0.0
		if away.length() > 0.001:
			return away.normalized() * 1.5
	if diet != "carnivore" and _try_eat_plant(pos):
		state = "eat"
		return fallback + _flock_steer(pos, true)
	state = "wander"
	return fallback + _flock_steer(pos, true)


# --- predator behavior: scavenge, hunt prey (throw or bite), track scent, else flock ---
func _think_predator(pos: Vector3, fallback: Vector3) -> Vector3:
	# Scavenge carrion whenever not near-full (omnivores/humans eat anything they can).
	if energy < max_energy * 0.95 and _try_scavenge(pos):
		state = "eat"
		return fallback
	var prey: Node3D = _nearest_of(pos, preys_on)
	if prey != null:
		var to_prey: Vector3 = prey.global_position - pos
		to_prey.y = 0.0
		if throws:
			return _hunt_with_rock(pos, prey, to_prey, fallback)   # ranged: humans throw rocks
		if to_prey.length() <= maxf(size + 0.8, 1.0):
			_kill_and_eat(prey)
			state = "eat"
			return fallback
		state = "chase"
		if to_prey.length() > 0.001:
			return to_prey.normalized()
	else:
		var trail: Vector3 = _follow_prey_scent(pos)
		if trail != Vector3.ZERO:
			state = "track"
			return trail
	if diet == "omnivore" and _try_eat_plant(pos):
		state = "eat"
		return fallback + _flock_steer(pos, true)
	state = "wander"
	return fallback + _flock_steer(pos, true)


# Persistence hunting: the hunter can't outrun fleeing prey, so it just keeps walking
# after it. The prey sprints (burning energy fast) and eventually collapses from
# exhaustion. A rock, if grabbed on the way, ends it sooner.
func _hunt_with_rock(pos: Vector3, prey: Node3D, to_prey: Vector3, fallback: Vector3) -> Vector3:
	var dist: float = to_prey.length()
	if not has_rock:
		var rock: Node3D = _nearest_rock(pos)
		if rock != null and pos.distance_to((rock as Node3D).global_position) <= maxf(size + 1.3, 1.7):
			if rock.has_method("take"):
				rock.take()
			has_rock = true
			_set_rock_visual(true)
	if has_rock and dist <= throw_range and _throw_cd <= 0.0:
		_throw_rock_at(prey)
		state = "throw"
		return fallback
	state = "stalk"
	return to_prey.normalized() if dist > 0.001 else fallback


func _throw_rock_at(prey: Node3D) -> void:
	has_rock = false
	_set_rock_visual(false)
	_throw_cd = 2.5
	var parent: Node = get_parent()
	if parent == null:
		return
	var rock: ThrownRockScript = ThrownRockScript.new()
	parent.add_child(rock)
	if rock.has_method("setup"):
		rock.setup(terrain)
	rock.throw_at(global_position + Vector3(0, size, 0), prey, 26.0)


func _kill_and_eat(prey: Node3D) -> void:
	var gain: float = food_value
	if prey is LACreature:
		gain = (prey as LACreature).food_value
	energy = minf(max_energy, energy + gain * 0.7)
	LocalAgentsAudioDirector.emit(get_tree(), "chomp", global_position)
	if prey.has_method("die"):
		prey.die("eaten")           # leaves a carcass (leftovers for scavengers)
	elif prey.has_method("queue_free"):
		prey.queue_free()


func _try_scavenge(pos: Vector3) -> bool:
	if diet == "herbivore":
		return false
	for c in get_tree().get_nodes_in_group(GROUP_CARRION):
		if not is_instance_valid(c) or not (c is Node3D):
			continue
		if pos.distance_to((c as Node3D).global_position) <= maxf(size + 1.0, 1.4):
			if c.has_method("feed"):
				var got: float = float(c.call("feed", 30.0))
				energy = minf(max_energy, energy + got)
				return got > 0.0
	return false


func _follow_prey_scent(pos: Vector3) -> Vector3:
	if _scent == null or preys_on.is_empty():
		return Vector3.ZERO
	for sp in preys_on:
		var dir: Vector3 = _scent.scent_direction(pos, String(sp), sense_radius * 2.5)
		if dir != Vector3.ZERO:
			dir.y = 0.0
			return dir
	return Vector3.ZERO


func _nearest_rock(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = sense_radius * 2.5
	for r in get_tree().get_nodes_in_group(GROUP_ROCK):
		if not is_instance_valid(r) or not (r is Node3D):
			continue
		var d: float = pos.distance_to((r as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = r
	return best


func _set_rock_visual(on: bool) -> void:
	if _rock_visual != null and is_instance_valid(_rock_visual):
		_rock_visual.visible = on


func _think_bird(pos: Vector3, _delta: float) -> Vector3:
	return _heading + _flock_steer(pos, false)


# Unified same-kind flocking / imitation steering, shared by ALL species: cohesion
# (toward local center), alignment (match average heading — "do what others like me do"),
# and separation (avoid crowding). flatten zeroes Y for ground creatures.
func _flock_steer(pos: Vector3, flatten: bool) -> Vector3:
	if flock_weight <= 0.0:
		return Vector3.ZERO
	var mates: Array = get_tree().get_nodes_in_group(_species_group(species))
	var center: Vector3 = Vector3.ZERO
	var align: Vector3 = Vector3.ZERO
	var separation: Vector3 = Vector3.ZERO
	var n: int = 0
	var sep_dist: float = maxf(size * 4.0, 1.5)
	for m in mates:
		if m == self or not is_instance_valid(m):
			continue
		var lm: LACreature = m as LACreature
		if lm == null:
			continue
		var op: Vector3 = lm.global_position
		var d: float = pos.distance_to(op)
		if d > flock_radius or d < 0.0001:
			continue
		center += op
		align += lm._heading
		if d < sep_dist:
			separation += (pos - op) / d          # stronger the closer they are
		n += 1
	if n == 0:
		return Vector3.ZERO
	center /= float(n)
	align /= float(n)
	var cohesion: Vector3 = center - pos
	if flatten:
		cohesion.y = 0.0
		align.y = 0.0
		separation.y = 0.0
	var steer: Vector3 = Vector3.ZERO
	if cohesion.length() > 0.001:
		steer += cohesion.normalized() * flock_cohesion
	if align.length() > 0.001:
		steer += align.normalized() * flock_alignment
	if separation.length() > 0.001:
		steer += separation.normalized() * flock_separation
	return steer * flock_weight


func _try_eat_plant(pos: Vector3) -> bool:
	if energy > max_energy * 0.92:
		return false                          # sated: don't bother grazing
	for p in get_tree().get_nodes_in_group(GROUP_PLANT):
		if not is_instance_valid(p) or not (p is Node3D):
			continue
		if pos.distance_to((p as Node3D).global_position) <= maxf(size + 0.6, 0.9):
			if p.has_method("is_edible") and not p.is_edible():
				continue
			(p as Node3D).queue_free()
			energy = minf(max_energy, energy + 32.0)
			return true
	return false


# Emergent threat detection: no hardcoded predator pairs. Flee ANY nearby creature that
# HUNTS and is meaningfully LARGER than me — one rule makes rabbits flee foxes AND humans,
# foxes flee humans, and apex-sized hunters fear nothing.
func is_hunter() -> bool:
	return diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0)


func _nearest_larger_predator(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = sense_radius
	for cand in get_tree().get_nodes_in_group(GROUP_CREATURE):
		if not is_instance_valid(cand) or cand == self:
			continue
		if not cand.has_method("is_hunter") or not cand.call("is_hunter"):
			continue
		if float(cand.get("size")) < size * PREDATOR_SIZE_RATIO:
			continue
		var c3: Node3D = cand as Node3D
		var d: float = pos.distance_to(c3.global_position)
		if d < best_d:
			best_d = d
			best = c3
	return best


func _nearest_of(pos: Vector3, species_list: PackedStringArray) -> Node3D:
	var best: Node3D = null
	var best_d: float = sense_radius
	for sp in species_list:
		for cand in get_tree().get_nodes_in_group(_species_group(sp)):
			if not is_instance_valid(cand) or cand == self:
				continue
			var c3: Node3D = cand as Node3D
			if c3 == null:
				continue
			var d: float = pos.distance_to(c3.global_position)
			if d < best_d:
				best_d = d
				best = c3
	return best


func is_mature() -> bool:
	return age >= maturity_age


func get_inspector_payload() -> Dictionary:
	var maturity: String = "adult" if is_mature() else "juvenile"
	var activity: String = _describe_activity()
	var energy_pct: int = int(round(100.0 * energy / maxf(1.0, max_energy)))
	var nearby: int = get_tree().get_nodes_in_group(_species_group(species)).size() - 1
	var p: Vector3 = global_position
	var lines: Array = [
		"Species: %s (%s)" % [species, maturity],
		"Diet: %s" % diet,
		"Doing: %s" % activity,
		"Energy: %d%%  %s" % [energy_pct, _energy_bar(energy_pct)],
		"Age: %.0fs / %.0fs" % [age, max_age],
		"Speed: %.1f   Size: %.2f" % [speed, size],
		"Herd nearby: %d" % maxi(0, nearby),
		"Pos: (%.0f, %.0f, %.0f)" % [p.x, p.y, p.z],
	]
	if throws:
		lines.append("Rock in hand: %s" % ("yes" if has_rock else "no"))
	return {"title": species.capitalize(), "lines": lines}


func _describe_activity() -> String:
	match state:
		"panic": return "terrified — fleeing!"
		"flee": return "fleeing a predator"
		"chase": return "chasing prey"
		"stalk": return "stalking prey (persistence hunt)"
		"track": return "tracking scent"
		"throw": return "throwing a rock"
		"eat": return "eating"
		"cruise": return "flying with the flock"
		"wander": return "wandering with its kind"
		_: return state


func _energy_bar(pct: int) -> String:
	var filled: int = clampi(pct / 10, 0, 10)
	return "[%s%s]" % ["#".repeat(filled), "-".repeat(10 - filled)]
