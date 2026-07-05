class_name LAFireSystem
extends Node3D

## EMERGENT wildfire. The system tracks a set of BURNING actors (trees and plants) — not a
## grid. Each burning actor obeys three simple local rules every tick, and forests catching,
## fire-breaks at rivers, and rain putting fires out all EMERGE from them, nothing is scripted:
##
##   1. SPREAD  — a burning actor rolls, on a cadence, to ignite each flammable neighbour
##                within SPREAD_RADIUS. Dense stands go up; isolated plants don't.
##   2. BURN    — it burns down over its lifetime, then is consumed (removed) and leaves ash
##                that fertilises a NEW plant on the spot (via ecology.seed_plant_at).
##   3. SCARE   — nearby creatures feel the heat and panic away (ecology.broadcast_scare).
##
## RAIN suppresses ignition and, when heavy, extinguishes active fires — so weather and the
## water field (whose wet cells simply have no flammable actors on them) both fight the fire
## for free. Built in code, no external assets. (Explicit types only — no ':=' inferred typing.)

const FLAMMABLE_GROUPS: Array = ["tree", "plant"]

const SPREAD_RADIUS: float = 7.0
const SPREAD_INTERVAL: float = 1.1          # seconds between spread attempts per fire
const SPREAD_CHANCE: float = 0.5            # per flammable neighbour, per attempt
const BURN_TIME_MIN: float = 6.0
const BURN_TIME_MAX: float = 11.0
const SCARE_INTERVAL: float = 1.3
const SCARE_RADIUS: float = 9.0

## Weather gates: above SUPPRESS_RAIN fires stop spreading; above EXTINGUISH_RAIN they die out.
const SUPPRESS_RAIN: float = 0.35
const EXTINGUISH_RAIN: float = 0.7

var _ecology = null                         # LAEcologyService (seed_plant_at, broadcast_scare)
var _weather = null                         # LAWeatherSystem (rain)

# One entry per burning actor: {node, life, max_life, spread_cd, scare_cd, fx}
var _fires: Array = []


func setup(ecology) -> void:
	_ecology = ecology


func set_weather(w) -> void:
	_weather = w


func active_fire_count() -> int:
	return _fires.size()


## True if `node` is already on fire (so we never double-ignite it).
func is_burning(node) -> bool:
	for f in _fires:
		if f["node"] == node:
			return true
	return false


## Set a flammable actor alight. No-op for non-flammable nodes or ones already burning.
func ignite(node) -> void:
	if node == null or not is_instance_valid(node) or not (node is Node3D):
		return
	if not _is_flammable(node) or is_burning(node):
		return
	var n3: Node3D = node as Node3D
	var fx: Node3D = _make_fire_fx(n3)
	n3.add_child(fx)
	_fires.append({
		"node": n3,
		"life": randf_range(BURN_TIME_MIN, BURN_TIME_MAX),
		"spread_cd": randf_range(0.3, SPREAD_INTERVAL),
		"scare_cd": randf_range(0.2, SCARE_INTERVAL),
		"fx": fx,
	})


## Ignite every flammable actor within `radius` of a world point (a meteor strike, etc).
func ignite_area(world_pos: Vector3, radius: float) -> void:
	var r2: float = radius * radius
	for group in FLAMMABLE_GROUPS:
		for a in get_tree().get_nodes_in_group(group):
			if is_instance_valid(a) and a is Node3D:
				if (a as Node3D).global_position.distance_squared_to(world_pos) <= r2:
					ignite(a)


func _is_flammable(node) -> bool:
	for group in FLAMMABLE_GROUPS:
		if node.is_in_group(group):
			return true
	return false


func _physics_process(delta: float) -> void:
	if _fires.is_empty():
		return
	var rain: float = 0.0
	if _weather != null and _weather.has_method("rain"):
		rain = _weather.rain()
	var extinguishing: bool = rain >= EXTINGUISH_RAIN
	var can_spread: bool = rain < SUPPRESS_RAIN

	var survivors: Array = []
	for f in _fires:
		var node = f["node"]
		if node == null or not is_instance_valid(node):
			continue                                    # actor already gone (eaten, meteor'd)
		# Heavy rain drains life fast; a wet fire dies without leaving healthy regrowth.
		var drain: float = delta * (4.0 if extinguishing else 1.0)
		f["life"] = float(f["life"]) - drain
		if float(f["life"]) <= 0.0:
			_consume(node as Node3D, not extinguishing)
			continue

		# SPREAD to flammable neighbours (unless rain suppresses it).
		f["spread_cd"] = float(f["spread_cd"]) - delta
		if float(f["spread_cd"]) <= 0.0:
			f["spread_cd"] = SPREAD_INTERVAL
			if can_spread:
				_spread_from((node as Node3D).global_position)

		# SCARE nearby creatures — they flee the heat.
		f["scare_cd"] = float(f["scare_cd"]) - delta
		if float(f["scare_cd"]) <= 0.0:
			f["scare_cd"] = SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare((node as Node3D).global_position, SCARE_RADIUS, 0.6)

		survivors.append(f)
	_fires = survivors


func _spread_from(origin: Vector3) -> void:
	var r2: float = SPREAD_RADIUS * SPREAD_RADIUS
	for group in FLAMMABLE_GROUPS:
		for a in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(a) or not (a is Node3D):
				continue
			var a3: Node3D = a as Node3D
			if a3.global_position.distance_squared_to(origin) > r2:
				continue
			if is_burning(a3):
				continue
			if randf() < SPREAD_CHANCE:
				ignite(a3)


# The actor is fully consumed: a tree topples as it collapses; then it's removed and (if it
# burned rather than being rained out) leaves ash that seeds a new plant on the spot.
func _consume(node: Node3D, leaves_ash: bool) -> void:
	var pos: Vector3 = node.global_position
	if node.has_method("topple"):
		node.call("topple", Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0))
	if leaves_ash and _ecology != null and _ecology.has_method("seed_plant_at"):
		_ecology.seed_plant_at(pos)
	node.queue_free()


# A flickering flame: upward orange particles plus a warm point light that will free itself
# with the actor (it's a child) or when we extinguish. Built entirely in code.
func _make_fire_fx(host: Node3D) -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "FireFX"

	var particles: GPUParticles3D = GPUParticles3D.new()
	particles.amount = 24
	particles.lifetime = 0.9
	particles.one_shot = false
	particles.emitting = true
	var flame: QuadMesh = QuadMesh.new()
	flame.size = Vector2(0.5, 0.5)
	var fmat: StandardMaterial3D = StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.5, 0.12)
	fmat.emission_energy_multiplier = 3.0
	fmat.albedo_color = Color(1.0, 0.55, 0.15, 0.9)
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flame.material = fmat
	particles.draw_pass_1 = flame
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.8
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 20.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 4.5
	pm.gravity = Vector3(0.0, 2.5, 0.0)          # flames rise
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.color = Color(1.0, 0.6, 0.2)
	particles.process_material = pm
	particles.position = Vector3(0.0, 1.2, 0.0)
	root.add_child(particles)

	var light: OmniLight3D = OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 3.0
	light.omni_range = 9.0
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)

	return root
