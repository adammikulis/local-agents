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
# Flyers turn GRADUALLY (max radians/sec) so flocks wheel and vultures circle wide instead of
# snapping direction every frame — the fix for frantic, too-fast circling.
const BIRD_TURN_RATE: float = 1.5

const CorpseScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Corpse.gd")
const ThrownRockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/ThrownRock.gd")
const PoopScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Poop.gd")

# --- energy / hunger / mortality (emergent: eat to live, starve or age to die) ---
var energy: float = 100.0
var max_energy: float = 100.0
var metabolism: float = 2.2

# --- health / HP (emergent damage: blasts & lightning deal graded, deterministic damage;
# 0 HP = death). Bigger creatures carry more HP; set from `size` at spawn. ---
var health: float = 100.0
var max_health: float = 100.0
var food_value: float = 55.0
var max_age: float = 90.0
var hungry_at: float = 0.7

# --- thirst (emergent: drink from the water field or die of dehydration) ---
# hydration mirrors energy: full at max, drains at thirst_rate, drinking refills, 0 = death.
var hydration: float = 100.0
var max_hydration: float = 100.0
var thirst_rate: float = 1.0
const DRINK_RATE: float = 45.0             # hydration/sec restored while drinking
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives

# --- temperature comfort (emergent: read the shared field's temp at my feet) ---
# Between COOL_COMFORT and WARM_COMFORT costs nothing. Beyond, heat parches (raising effective
# thirst → the existing seek-water drive relocates herds to water / away from fire) and cold drains
# energy; past the lethal bounds it kills. A wildfire, lava, a hot day, or a cold snap all act
# through this one rule — no per-disaster code.
# Real Celsius: comfortable roughly 8–28°C.
const WARM_COMFORT: float = 28.0
const COOL_COMFORT: float = 8.0
const HEAT_THIRST_FACTOR: float = 0.15     # extra thirst/sec per °C above WARM_COMFORT
const HEAT_ENERGY_FACTOR: float = 0.08     # extra energy/sec burned per °C above WARM_COMFORT
const COLD_ENERGY_FACTOR: float = 0.15     # energy/sec burned per °C below COOL_COMFORT
const LETHAL_HEAT: float = 50.0           # °C at/above which it dies of heatstroke (no flame)
const COMBUST_TEMP: float = 200.0         # °C — organic tissue catches FIRE (in a wildfire/lava)
const LETHAL_COLD: float = -18.0          # °C at/below which it freezes
const DROWN_DEPTH: float = 2.5             # water depth a non-flyer drowns in
const DROWN_DRAIN: float = 40.0           # energy/sec lost while submerged

var _material = null                          # LAMaterialField (temp_at / depth_at / is_water_at)
var _water_dir_cache: Vector3 = Vector3.ZERO
var _water_search_cd: float = 0.0

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
var nocturnal: bool = false
# Perception scale for the night: recomputed each frame from the shared day/night clock.
# Nocturnal species see FARTHER after dark; diurnal species see LESS — so nights favour
# night hunters. Emergent, driven by one config flag, not hardcoded predator/prey cases.
var _sense_mult: float = 1.0

# --- flocking weights (defaults; overridden per-species via config) ---
var flock_cohesion: float = 0.5
var flock_alignment: float = 0.5
var flock_separation: float = 0.8
var flock_radius: float = 8.0
var flock_weight: float = 0.7

var age: float = 0.0
var state: String = "wander"

# --- the player's "hand" (Black & White): picked up, carried, then dropped or thrown ---
# While _held, _physics_process is suspended so VoxelWorld drives global_position directly.
# While _thrown, the body flies ballistically (velocity + gravity) until it lands.
var _held: bool = false
var _thrown: bool = false
var _thrown_velocity: Vector3 = Vector3.ZERO
const THROW_GRAVITY: float = 26.0            # ballistic fall while thrown

var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _repath_timer: float = 0.0
var _mesh: MeshInstance3D = null

# --- display model (glTF via LAModelVisual) when the species has one; else the capsule above.
# Animation is driven visually in _process from actual per-frame displacement. ---
var _model_root: Node3D = null
var _model_anim: AnimationPlayer = null
var _model_anims: Dictionary = {}
var _model_run_speed: float = 999.0
var _vis_prev_pos: Vector3 = Vector3.ZERO
var _vis_t: float = 0.0

# --- terror / fear system: sprint away from felt/heard violence, overriding all else ---
var _panic_timer: float = 0.0
var _panic_source: Vector3 = Vector3.ZERO

# Injected scent field (LAScentField) — predators follow prey scent when out of sight.
var _scent = null
# Injected ecology service — used to register droppings so dung can seed plants.
var _ecology = null

# Digestion: every so often a fed creature leaves droppings (a strong scent marker
# that predators track prey by, and that occasionally fertilizes a new plant).
var _poop_cd: float = 0.0

# --- perception genes: sight is a FOV cone (LAVision), hearing is omnidirectional ---
# eye_fov = full cone width in degrees. Wide (prey, ~300) = panoramic but shallow; narrow
# (predator, ~100) = must aim, but binocular depth buys longer range. Heritable + evolvable.
var eye_fov: float = 220.0
var hearing_range: float = 12.0            # calls carry this far, in every direction, even at night
var _call_cd: float = 0.0

# --- cognition (fast/slow) + genetics ---
# family_id groups kin: offspring inherit a parent's id, so relatives learn from each other more
# strongly than unrelated herd-mates (social/cultural transmission of behaviour).
var family_id: int = 0
var _genome = null                         # LAGenome (heritable traits + baked instinct priors)
var _cognition = null                      # LACognition (per-creature learned policy + slow-brain hook)
var _migrate_dir: Vector3 = Vector3.ZERO   # steady heading chosen when the 'migrate' action fires

# --- flight / scavenging / public information ("watch the vultures") ---
var _target_altitude: float = 12.0         # per-frame desired flight height above ground (flyers descend to feed/circle)
var _cue_pos: Vector3 = Vector3.ZERO       # a heard/smelt carrion cue to investigate
var _cue_cd: float = 0.0                    # seconds the current cue stays salient
var _pursued_cue: String = ""              # the LEARNED cue key currently being investigated
var _pursued_cd: float = 0.0               # window to credit that cue if food follows (else it decays)

# --- nesting / shelter (birds nest, mammals burrow/den; offspring inherit the site) ---
var nests: bool = false
var nest_habitat: String = ""                    # "tree" | "ground" | "water" (default derived from can_fly)
var has_nest: bool = false
var nest_pos: Vector3 = Vector3(INF, INF, INF)   # sentinel = no nest yet
var _nest_node = null                            # LANest (the placed home site)


func add_fear(source_pos: Vector3, intensity: float) -> void:
	if intensity <= 0.0:
		return
	_panic_source = source_pos
	_panic_timer = maxf(_panic_timer, clampf(intensity, 0.6, 7.0))


# --- the player's hand: pick up, carry, drop, or throw a creature ---
# The picking-up: suspend the AI/terrain-snap so the hand (VoxelWorld) can position us freely.
func hold_begin() -> void:
	_held = true
	_thrown = false
	_thrown_velocity = Vector3.ZERO
	_panic_timer = 0.0                        # in the hand it stops panicking


# A gentle set-down: resume normal life wherever we were dropped.
func hold_end() -> void:
	_held = false


# Released with a fling: fly ballistically (gravity) until we land on the surface.
func throw(velocity: Vector3) -> void:
	_held = false
	_thrown = true
	_thrown_velocity = velocity


func is_held() -> bool:
	return _held or _thrown


## Current steering heading (unit-ish world vector the creature is moving along) — read by the debug
## overlay to draw its intended path. Zero while held/thrown (no self-directed motion).
func debug_heading() -> Vector3:
	if _held or _thrown:
		return Vector3.ZERO
	return _heading


func set_scent(s) -> void:
	_scent = s


func set_ecology(e) -> void:
	_ecology = e


func set_material_field(w) -> void:
	_material = w


# Organic matter combusts — bursts into flame (not incandescent glow) and dies burned. The flame is
# detached at the spot so it lingers as the body drops, rather than freeing with the creature.
func _combust() -> void:
	if _dying:
		return
	var parent: Node = get_parent()
	if parent != null:
		var flame: Node3D = LAFlameFX.make()
		parent.add_child(flame)
		flame.global_position = global_position
		var timer: SceneTreeTimer = get_tree().create_timer(2.5)
		timer.timeout.connect(func(): if is_instance_valid(flame): flame.queue_free())
	die("burned", Vector3(0.0, 2.0, 0.0))


# A thrown rock struck me — I die (drop a corpse).
func on_struck() -> void:
	die("struck")


# Take deterministic HP damage from a blast/lightning/etc. Death happens only when HP hits 0,
# and the killing blow's impulse flings the corpse. No randomness in the kill path.
func take_damage(amount: float, cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying or amount <= 0.0:
		return
	health -= amount
	if health <= 0.0:
		die(cause, impulse)


# Death leaves a physical corpse (carrion) — creatures never just vanish.
# `impulse` (e.g. from a meteor) flings the body outward.
func die(_cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying:
		return
	_dying = true
	# A death cry: nearby animals hear it and startle (predators may later home in on it).
	if _ecology != null and _ecology.has_method("broadcast_call"):
		_ecology.broadcast_call(global_position, species, "distress", self)
	var parent: Node = get_parent()
	if parent != null and is_inside_tree():
		var corpse: CorpseScript = CorpseScript.new()
		parent.add_child(corpse)
		corpse.setup(species, color, size, terrain)
		if corpse.has_method("set_scent"):
			corpse.set_scent(_scent)          # the carcass advertises itself as carrion scent
		corpse.global_position = global_position
		if impulse.length() > 0.01 and corpse.has_method("fling"):
			# Fling after the body has a physics space (next physics tick).
			var c = corpse
			var imp: Vector3 = impulse
			get_tree().create_timer(0.06).timeout.connect(
				func(): if is_instance_valid(c): c.fling(imp))
	queue_free()


# Leave a dropping at `ground_pos`: a strong species-scent marker that predators
# emergently track prey by, and that (via the ecology) may fertilize a new plant.
func _drop_poop(ground_pos: Vector3) -> void:
	var parent: Node = get_parent()
	if parent == null or not is_inside_tree():
		return
	var poop: LAPoop = PoopScript.new()
	parent.add_child(poop)
	poop.global_position = ground_pos
	poop.setup(terrain, _scent, species)
	if _ecology != null and _ecology.has_method("register_poop"):
		_ecology.register_poop(poop)


func setup(_terrain, _config: Dictionary, _genome_arg = null) -> void:
	terrain = _terrain
	# Genome drives the config: an offspring/evolved creature is passed a genome and we express it;
	# otherwise we build an ancestral genome from the species template so EVERY creature has
	# heritable genes (and per-individual variation once bred).
	if _genome_arg != null:
		_genome = _genome_arg
		config = _genome.express()
	else:
		config = _config.duplicate(true)
		_genome = LAGenome.from_config(config)
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
	nocturnal = bool(config.get("nocturnal", nocturnal))
	flock_cohesion = float(config.get("flock_cohesion", flock_cohesion))
	flock_alignment = float(config.get("flock_alignment", flock_alignment))
	flock_separation = float(config.get("flock_separation", flock_separation))
	flock_radius = float(config.get("flock_radius", sense_radius))
	flock_weight = float(config.get("flock_weight", flock_weight))
	max_energy = float(config.get("max_energy", 100.0))
	energy = max_energy
	# HP scales with body size: a bigger animal endures more before a blast kills it.
	max_health = float(config.get("max_health", 30.0 + size * 120.0))
	health = max_health
	metabolism = float(config.get("metabolism", metabolism))
	max_hydration = float(config.get("max_hydration", 100.0))
	hydration = max_hydration
	thirst_rate = float(config.get("thirst_rate", thirst_rate))
	food_value = float(config.get("food_value", size * 90.0))
	max_age = float(config.get("max_age", maxf(maturity_age * 5.0, 60.0)))
	hungry_at = float(config.get("hungry_at", hungry_at))
	throws = bool(config.get("throws", throws))
	throw_range = float(config.get("throw_range", throw_range))
	# Perception genes (with sensible per-body defaults) + kin id for social learning.
	eye_fov = float(config.get("eye_fov", eye_fov))
	hearing_range = float(config.get("hearing_range", sense_radius * 1.5))
	family_id = int(config.get("family_id", get_instance_id()))
	# Nesting is general and config-driven: ANY species that actually nests/shelters sets nests:true
	# (birds roost in trees, mammals/snakes burrow or den) — no per-species branch here.
	nests = bool(config.get("nests", nests))
	nest_habitat = String(config.get("nest_habitat", "tree" if can_fly else "ground"))
	_target_altitude = cruise_height
	state = "cruise" if can_fly else "wander"
	_poop_cd = randf_range(20.0, 45.0)
	_call_cd = randf_range(0.0, 2.0)

	collision_layer = 2
	collision_mask = 0                    # movement is manual; picked via layer-2 query
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(_species_group(species))
	add_to_group(GROUP_CREATURE)
	_heading = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0).normalized()
	if _heading == Vector3.ZERO:
		_heading = Vector3.FORWARD

	# The fast/slow brain: born with the genome's baked instinct priors; learns the rest by living
	# and by watching kin. The shared slow-brain scheduler is injected separately (set_cognition_scheduler).
	_cognition = LACognition.new()
	_cognition.seed_from_genome(_genome)


# The shared System-2 scheduler (FunctionGemma budget/queue), injected by the ecology after setup.
func set_cognition_scheduler(s) -> void:
	if _cognition != null:
		_cognition.set_scheduler(s)


func get_cognition():
	return _cognition


func get_genome():
	return _genome


func get_family_id() -> int:
	return family_id


static func _species_group(sp: String) -> String:
	return "species_%s" % sp


func _build_body() -> void:
	# Prefer a display model for this species (LAActorModels); fall back to the primitive capsule.
	_build_model()
	if _model_root == null:
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


# Try to build a display model for this species. Sets _model_root/_model_anim on success,
# leaves them null (caller builds the capsule) if the species has no model or it fails to load.
func _build_model() -> void:
	var def: Dictionary = LAActorModels.get_def(species)
	var model_path: String = String(config.get("model", def.get("path", "")))
	if model_path.is_empty():
		return
	var target_h: float = maxf(size * 2.0, size * 1.2) * float(config.get("model_scale", 1.0))
	var yaw: float = float(config.get("model_yaw", def.get("yaw", 0.0)))
	var model: Node3D = LAModelVisual.build(model_path, target_h, "center", yaw, LAActorModels.tint(species))
	if model == null:
		return
	add_child(model)
	_model_root = model
	_model_anim = LAModelVisual.find_anim(model)
	_model_anims = def.get("anims", {})
	_model_run_speed = float(def.get("run", 999.0))
	_vis_prev_pos = global_position


# Visual-only animation: play idle/move/run (or bob a rigless model) from actual displacement.
# Kept out of _physics_process so it never perturbs movement/AI, only presentation.
func _process(delta: float) -> void:
	if _model_root == null:
		return
	_vis_t += delta
	var p: Vector3 = global_position
	var sp: float = 0.0
	if delta > 0.0001:
		sp = (p - _vis_prev_pos).length() / delta
	_vis_prev_pos = p
	LAModelVisual.animate(_model_root, _model_anim, _model_anims, sp, _model_run_speed, _vis_t, delta)


func _physics_process(delta: float) -> void:
	# In the player's hand: VoxelWorld sets our position each frame; skip AI + terrain-snap.
	if _held:
		return
	# Mid-throw: fly ballistically until we hit the surface, then resume normal life.
	if _thrown:
		_integrate_thrown(delta)
		return
	age += delta
	_throw_cd -= delta
	# Night perception: nocturnal species gain range after dark, diurnal ones lose it.
	_sense_mult = 1.0
	if _ecology != null and _ecology.has_method("is_night") and _ecology.is_night():
		_sense_mult = 1.4 if nocturnal else 0.7
	# Metabolism drains energy; exertion costs more, sleeping costs less; eating refills.
	var exertion: float = 1.0
	if state == "flee" or state == "panic" or state == "chase":
		exertion = 1.6
	elif state == "sleep" or state == "rest" or state == "roost":
		exertion = 0.5                        # sleeping/resting conserves energy — why animals do it
	energy -= metabolism * exertion * delta
	if energy <= 0.0:
		die("starvation")
		return
	# Thirst drains steadily; dehydration kills like starvation. Drinking (below) refills it.
	hydration -= thirst_rate * delta
	if hydration <= 0.0:
		die("thirst")
		return
	if age >= max_age:
		die("old age")
		return
	if terrain == null:
		return

	var pos: Vector3 = global_position

	# TEMPERATURE COMFORT + DROWNING (emergent, from the shared field at my feet).
	if _material != null:
		var t: float = _material.temp_at(pos.x, pos.z)
		# Flesh doesn't glow like hot metal — it COMBUSTS. In fire/lava heat the creature bursts into
		# flame and dies burned (organic matter ignites; inorganic ground glows via the shader instead).
		if t >= COMBUST_TEMP:
			_combust()
			return
		if t > WARM_COMFORT:
			var over: float = t - WARM_COMFORT
			hydration -= over * HEAT_THIRST_FACTOR * delta   # heat parches → seek water (existing drive)
			energy -= over * HEAT_ENERGY_FACTOR * delta
			if t >= LETHAL_HEAT:
				die("heatstroke")
				return
		elif t < COOL_COMFORT:
			energy -= (COOL_COMFORT - t) * COLD_ENERGY_FACTOR * delta
			if t <= LETHAL_COLD:
				die("frozen")
				return
		if not can_fly and _material.depth_at(pos.x, pos.z) >= DROWN_DEPTH:
			energy -= DROWN_DRAIN * delta
			if energy <= 0.0:
				die("drowned")
				return

	var surf: float = _surface_at(pos.x, pos.z)
	if is_nan(surf):
		return                            # unmeshed / off-terrain: skip this frame

	# Digestion: a fed creature periodically leaves droppings on the ground below it.
	_poop_cd -= delta
	if _poop_cd <= 0.0:
		_poop_cd = randf_range(24.0, 48.0)
		if energy > max_energy * 0.35:
			_drop_poop(Vector3(pos.x, surf, pos.z))

	var desired: Vector3 = _heading
	_wander_timer -= delta
	_repath_timer -= delta
	_panic_timer -= delta
	_call_cd -= delta
	_cue_cd -= delta
	# A cue I chased that led to no food weakens that association (so only reliable signs stick).
	if _pursued_cd > 0.0:
		_pursued_cd -= delta
		if _pursued_cd <= 0.0 and _pursued_cue != "":
			if _cognition != null:
				_cognition.reinforce_cue(_pursued_cue, -0.3)
			_pursued_cue = ""
	# Flyers default to cruise altitude each frame; foraging/circling/roosting lowers it.
	_target_altitude = cruise_height
	# Social learning: copy confident habits from visible same-species kin/herd-mates (throttled).
	if _cognition != null:
		_cognition.observe(self, delta)

	var eff_speed: float = speed
	if _panic_timer > 0.0:
		# TERROR: sprint straight away from what was heard/felt. Overrides everything.
		state = "panic"
		var away: Vector3 = pos - _panic_source
		away.y = 0.0
		if away.length() > 0.001:
			desired = away.normalized()
		eff_speed = speed * 2.1
		_emit_call("alarm")                          # screech so unseeing herd-mates also bolt
	else:
		# Universal, emergent: flee any nearby larger hunter first (no hardcoded pairs).
		var big_pred: Node3D = LACreatureSenses.nearest_larger_predator(self, pos)
		if big_pred != null:
			state = "flee"
			var away: Vector3 = pos - big_pred.global_position
			away.y = 0.0
			if away.length() > 0.001:
				desired = away.normalized()
			eff_speed = speed * 1.7
			_emit_call("alarm")                      # sentinel call flushes the whole warren
		else:
			# Thirst competes with hunger: once parched, seeking/drinking water interrupts
			# normal behavior (but never overrides fleeing a predator, handled above).
			var thirst_action: String = _handle_thirst(pos, delta)
			if thirst_action == "drink":
				eff_speed = 0.0                      # stand at the water's edge and drink
				state = "drink"
			elif thirst_action == "seek":
				desired = _water_dir_cache
				state = "seek"
			elif diet == "scavenger":
				desired = _think_scavenger(pos, delta)   # vultures: soar, follow carrion, circle, feed
			elif can_fly:
				desired = _think_bird(pos, delta)         # sets its own state; may land to feed/drink
			elif diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0):
				desired = _think_predator(pos, desired)
			else:
				desired = _think_prey(pos, desired)

		# Nesting/roosting drive (ANY nesting species, config-driven): head home to roost at night
		# or to breed, establishing the site the first time. Offspring inherit it (philopatry).
		if nests and LACreatureNesting.should_seek_nest(self):
			desired = _handle_nesting(pos, desired)
			if state == "sleep":
				eff_speed = speed * 0.05          # barely stir while sleeping at the nest

		# COGNITION (fast/slow): the cascade above is the innate default policy. In a discretionary
		# situation (no predator forcing a flee) let THIS individual's learned/observed/slow-brain
		# policy substitute a better action. An empty policy changes nothing — so day-0 behaviour is
		# identical to before (regression-safe); learning only ever adds overrides.
		if big_pred == null and _cognition != null and state != "roost" and state != "nesting":
			var sig: Dictionary = LASituationSignature.compute(self)
			var innate_action: String = _state_to_action(state)
			var chosen: String = _cognition.decide(self, innate_action, sig, delta)
			if chosen != innate_action:
				var mv: Dictionary = _execute_action(chosen, pos, delta)
				if mv.has("heading"):
					desired = mv["heading"]
				state = String(mv.get("state", state))
				eff_speed = float(mv.get("speed", eff_speed))

		if big_pred == null and _wander_timer <= 0.0:
			_wander_timer = randf_range(1.2, 3.0)
			var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0) * 0.6
			desired = (desired + jitter)

	desired.y = 0.0
	if desired.length() > 0.001:
		var want: Vector3 = desired.normalized()
		if can_fly:
			# Rotate the heading toward the target by a capped angle so flight banks smoothly.
			_heading = _turn_toward(_heading, want, BIRD_TURN_RATE * delta)
		else:
			_heading = want

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


# Rotate `from` toward `to` about the up axis by at most `max_angle` radians (both flattened).
func _turn_toward(from: Vector3, to: Vector3, max_angle: float) -> Vector3:
	var a: Vector3 = from
	a.y = 0.0
	var b: Vector3 = to
	b.y = 0.0
	if a.length() < 0.001:
		return to
	a = a.normalized()
	if b.length() < 0.001:
		return a
	b = b.normalized()
	var ang: float = a.signed_angle_to(b, Vector3.UP)
	var clamped: float = clampf(ang, -max_angle, max_angle)
	return a.rotated(Vector3.UP, clamped)


func _surface_at(x: float, z: float) -> float:
	if terrain == null or not terrain.has_method("surface_height"):
		return NAN
	return float(terrain.surface_height(x, z))


# Ballistic flight while thrown: integrate velocity + gravity, land on the surface, then
# resume normal life. A hard landing frightens the creature and rattles its neighbours —
# a thrown body is just another impact stimulus (emergent, no throw-specific reaction code).
func _integrate_thrown(delta: float) -> void:
	_thrown_velocity.y -= THROW_GRAVITY * delta
	var next: Vector3 = global_position + _thrown_velocity * delta
	var surf: float = _surface_at(next.x, next.z)
	if is_nan(surf):
		surf = global_position.y - size
	var floor_y: float = surf + size
	if next.y <= floor_y:
		next.y = floor_y
		var impact_speed: float = _thrown_velocity.length()
		_thrown = false
		_thrown_velocity = Vector3.ZERO
		global_position = next
		if impact_speed > 8.0:
			add_fear(global_position, clampf(impact_speed * 0.12, 0.6, 4.0))
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(global_position, 8.0, clampf(impact_speed * 0.05, 0.3, 1.5))
		return
	global_position = next


# --- prey behavior: flee predators (dominates), else wander + flock, eat plants ---
func _think_prey(pos: Vector3, fallback: Vector3) -> Vector3:
	var threat: Node3D = LACreatureSenses.nearest_of(self, pos, flees_from)
	if threat != null:
		state = "flee"
		var away: Vector3 = pos - threat.global_position
		away.y = 0.0
		if away.length() > 0.001:
			return away.normalized() * 1.5
	if diet != "carnivore" and _try_eat_plant(pos):
		state = "eat"
		return fallback + LACreatureFlocking.steer(self, pos, true)
	state = "wander"
	return fallback + LACreatureFlocking.steer(self, pos, true)


# --- predator behavior: scavenge, hunt prey (throw or bite), track scent, else flock ---
func _think_predator(pos: Vector3, fallback: Vector3) -> Vector3:
	# Scavenge carrion whenever not near-full (omnivores/humans eat anything they can).
	if energy < max_energy * 0.95 and _try_scavenge(pos):
		state = "eat"
		return fallback
	# Public information ("watch the vultures"), fully EMERGENT: other animals are cues to resources,
	# and experience — not code — decides which cues are worth following. If a perceived cue has a
	# high learned worth (or curiosity picks an unknown one), go investigate it.
	if energy < max_energy * 0.85:
		var cue: Dictionary = _best_learned_cue(pos)
		if not cue.is_empty():
			_pursued_cue = String(cue["key"])
			_pursued_cd = 8.0
			state = "investigate"
			return cue["dir"]
	var prey: Node3D = LACreatureSenses.nearest_of(self, pos, preys_on)
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
		# Public information ("watch the vultures"): a hungry ground scavenger heads toward the
		# strongest carrion cue — circling vultures (sight), carrion scent (smell), or a carrion call
		# (sound). A weak innate pull; the cognition layer reinforces it into a learned, inherited habit.
		if energy < max_energy * 0.7:
			var cue: Vector3 = _carrion_cue(pos)
			if cue != Vector3.ZERO:
				state = "investigate"
				return cue
		var trail: Vector3 = LACreatureSenses.follow_prey_scent(self, pos)
		if trail != Vector3.ZERO:
			state = "track"
			return trail
	if diet == "omnivore" and _try_eat_plant(pos):
		state = "eat"
		return fallback + LACreatureFlocking.steer(self, pos, true)
	state = "wander"
	return fallback + LACreatureFlocking.steer(self, pos, true)


# Persistence hunting: the hunter can't outrun fleeing prey, so it just keeps walking
# after it. The prey sprints (burning energy fast) and eventually collapses from
# exhaustion. A rock, if grabbed on the way, ends it sooner.
func _hunt_with_rock(pos: Vector3, prey: Node3D, to_prey: Vector3, fallback: Vector3) -> Vector3:
	var dist: float = to_prey.length()
	if not has_rock:
		var rock: Node3D = LACreatureSenses.nearest_rock(self, pos)
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
		rock.setup(terrain, _material)
	rock.throw_at(global_position + Vector3(0, size, 0), prey, 26.0)


func _kill_and_eat(prey: Node3D) -> void:
	var gain: float = food_value
	if prey is LACreature:
		gain = (prey as LACreature).food_value
	energy = minf(max_energy, energy + gain * 0.7)
	LocalAgentsAudioDirector.emit(get_tree(), "chomp", global_position)
	_emit_call("forage")                     # a kill call: kin nearby learn to hunt this situation
	_reinforce_cue_success()
	if prey.has_method("die"):
		prey.die("eaten")           # leaves a carcass (leftovers for scavengers)
	elif prey.has_method("queue_free"):
		prey.queue_free()


# Scavenging is just eating meat-type food off the ground — same unified path as grazing.
func _try_scavenge(pos: Vector3) -> bool:
	return _try_eat_food(pos)


# UNIFIED EATING: scan nearby food (anything exposing food_profile — plants, carcasses, …) and eat
# the best item my diet will forage. Herbivores take carbs, carnivores/scavengers take meat,
# omnivores both; energy gained scales with the food's STATE (a rotten carcass is worth half, cooked
# more). One rule for every diet and every food source — living prey is the one thing not eaten here
# (it must be hunted first, which turns it into a carcass = dead meat).
func _try_eat_food(pos: Vector3) -> bool:
	if energy > max_energy * 0.92:
		return false                              # sated
	var best: Node3D = null
	var best_val: float = 0.0
	var reach: float = maxf(size + 1.0, 1.4)
	for grp in [GROUP_PLANT, GROUP_CARRION]:
		for f in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(f) or not (f is Node3D):
				continue
			if not f.has_method("food_profile"):
				continue
			if pos.distance_to((f as Node3D).global_position) > reach:
				continue
			if f.has_method("is_edible") and not f.is_edible():
				continue
			var prof: Dictionary = f.food_profile()
			if not LAFood.can_forage(diet, prof):
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
	energy = minf(max_energy, energy + gained)
	_emit_call("forage")
	_reinforce_cue_success()
	return true


func _set_rock_visual(on: bool) -> void:
	if _rock_visual != null and is_instance_valid(_rock_visual):
		_rock_visual.visible = on


func _think_bird(pos: Vector3, delta: float) -> Vector3:
	# A hungry/thirsty bird drops out of the flock, LANDS, and forages/drinks (flyers can now descend).
	if LACreatureBird.wants_to_land(self):
		_target_altitude = maxf(size, 1.0)
		var thirst: String = _handle_thirst(pos, delta)
		if thirst == "drink":
			state = "drink"
			return _heading
		if thirst == "seek":
			state = "seek"
			return _water_dir_cache
		state = "eat" if _try_eat_plant(pos) else "wander"
		return _heading + LACreatureFlocking.steer(self, pos, true)
	# Otherwise soar with the flock, wheeling and bobbing on thermals.
	_target_altitude = maxf(cruise_height + sin(age * 0.4) * 3.0, 1.5)
	state = "cruise"
	return _heading + LACreatureBird.steer(self, pos)


# Vulture behaviour: soar high scanning for death; follow the "carrion" scent (or a seen carcass);
# spiral DOWN and circle over the kill (the visible signal others read); feed; call to advertise it.
func _think_scavenger(pos: Vector3, _delta: float) -> Vector3:
	var carcass: Node3D = LACreatureSenses.nearest_visible_carrion(self, pos)
	var to_flat: Vector3 = Vector3.ZERO
	if carcass != null:
		to_flat = Vector3(carcass.global_position.x - pos.x, 0.0, carcass.global_position.z - pos.z)
	elif _scent != null and _scent.has_method("scent_direction"):
		var d: Vector3 = _scent.scent_direction(pos, "carrion", sense_radius * 4.0)
		if d != Vector3.ZERO:
			to_flat = Vector3(d.x, 0.0, d.z)
	if to_flat != Vector3.ZERO:
		var dist: float = to_flat.length()
		if carcass != null and dist < 7.0:
			# Over the carcass: spiral down and feed — the visible "vultures circling".
			state = "circle"
			_target_altitude = maxf(size + 1.0, 2.0)
			_emit_call("carrion")                        # announce the kill (draws ground scavengers)
			if dist < maxf(size + 1.4, 1.8):
				_try_scavenge(pos)
			var tangent: Vector3 = Vector3(-to_flat.z, 0.0, to_flat.x).normalized()
			return to_flat.normalized() * 0.4 + tangent * 0.7
		state = "soar"
		_target_altitude = maxf(cruise_height * 0.5, 3.0)   # glide down toward the find
		return to_flat.normalized() + LACreatureBird.steer(self, pos) * 0.3
	# Nothing dead in sight or on the wind: soar high on thermals with the kettle.
	state = "soar"
	_target_altitude = maxf(cruise_height + sin(age * 0.4) * 3.0, 2.0)
	return _heading + LACreatureBird.steer(self, pos)


# EMERGENT public information. Look at the other animals I can perceive; each is a possible cue to a
# resource, keyed generically by its "species:state" (nothing names vultures or circling). Head for
# the cue my experience rates highest — and, when nothing is proven, occasionally investigate an
# UNKNOWN cue out of curiosity so associations can be discovered in the first place. Flying animals
# are perceptible far off against the open sky, which is exactly why a wheeling flock reads at range.
func _best_learned_cue(pos: Vector3) -> Dictionary:
	if _cognition == null:
		return {}
	var best_key: String = ""
	var best_val: float = 0.3                    # only exploit a cue once it's proven worthwhile
	var best_dir: Vector3 = Vector3.ZERO
	var unknown_key: String = ""
	var unknown_dir: Vector3 = Vector3.ZERO
	for m in get_tree().get_nodes_in_group(GROUP_CREATURE):
		if not is_instance_valid(m) or m == self or not (m is Node3D):
			continue
		var mpos: Vector3 = (m as Node3D).global_position
		var flying: bool = bool(m.get("can_fly"))
		var reach: float = (sense_radius * 4.0) if flying else LAVision.effective_range(self)
		if pos.distance_to(mpos) > reach:
			continue
		if not flying and not LAVision.can_see(self, mpos):
			continue
		var dir: Vector3 = Vector3(mpos.x - pos.x, 0.0, mpos.z - pos.z)
		if dir.length() < 0.001:
			continue
		var key: String = "%s:%s" % [String(m.get("species")), String(m.get("state"))]
		var val: float = _cognition.cue_value(key)
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


# Learn from a meal in two ways: credit the cue I was deliberately chasing, AND — Pavlovian —
# associate whatever signs happen to be present with the food. Signs that RELIABLY accompany food
# (scavengers circling overhead, animals feeding) accrue value across many meals; incidental noise
# washes out. This is how "circling vultures mean a carcass" is DISCOVERED, never coded.
func _reinforce_cue_success() -> void:
	if _cognition == null:
		return
	if _pursued_cue != "" and _pursued_cd > 0.0:
		_cognition.reinforce_cue(_pursued_cue, 1.0)
	_pursued_cue = ""
	_pursued_cd = 0.0
	var pos: Vector3 = global_position
	for m in get_tree().get_nodes_in_group(GROUP_CREATURE):
		if not is_instance_valid(m) or m == self or not (m is Node3D):
			continue
		var mpos: Vector3 = (m as Node3D).global_position
		var flying: bool = bool(m.get("can_fly"))
		var reach: float = (sense_radius * 4.0) if flying else LAVision.effective_range(self)
		if pos.distance_to(mpos) > reach:
			continue
		if not flying and not LAVision.can_see(self, mpos):
			continue
		_cognition.reinforce_cue("%s:%s" % [String(m.get("species")), String(m.get("state"))], 0.6)


# The strongest carrion CUE for a ground scavenger, over three channels — this is "watch the
# vultures": circling flyers (sight), carrion scent (smell), or a heard carrion call (sound).
func _carrion_cue(pos: Vector3) -> Vector3:
	var flyer: Node3D = LACreatureSenses.nearest_visible_in_state(self, pos, GROUP_CREATURE, ["circle"])
	if flyer != null:
		var d: Vector3 = Vector3(flyer.global_position.x - pos.x, 0.0, flyer.global_position.z - pos.z)
		if d.length() > 0.001:
			return d.normalized()
	if _scent != null and _scent.has_method("scent_direction"):
		var s: Vector3 = _scent.scent_direction(pos, "carrion", sense_radius * 3.0)
		if s != Vector3.ZERO:
			return Vector3(s.x, 0.0, s.z).normalized()
	if _cue_cd > 0.0:
		var c: Vector3 = Vector3(_cue_pos.x - pos.x, 0.0, _cue_pos.z - pos.z)
		if c.length() > 0.001:
			return c.normalized()
	return Vector3.ZERO


# Off-hours: diurnal animals rest at night, nocturnal ones by day — from the one `nocturnal` flag +
# the shared clock, no per-species sleep schedule.
func _rest_period() -> bool:
	if _ecology == null or not _ecology.has_method("is_night"):
		return false
	return _ecology.is_night() != nocturnal


# Home drive: establish a nest the first time, then head to it — to SLEEP through the rest period,
# or to breed. Returns the desired heading; sets state (roost/nesting/sleep). Site + shelter are
# config-driven (birds nest in trees, mammals/snakes burrow, aquatic species nest in water).
func _handle_nesting(pos: Vector3, fallback: Vector3) -> Vector3:
	if not has_nest:
		_establish_nest(pos)
	if not has_nest:
		return fallback
	if LACreatureNesting.at_nest(self, pos):
		_nest_touch()
		state = "sleep" if _rest_period() else "nesting"
		if can_fly:
			_target_altitude = maxf(size + 0.5, 1.0)      # settle onto the nest/roost
		return Vector3.ZERO                                 # stay put
	state = "roost" if _rest_period() else "nesting"
	var nh: Vector3 = LACreatureNesting.steer_to_nest(self, pos)
	return nh if nh != Vector3.ZERO else fallback


func _establish_nest(pos: Vector3) -> void:
	var site: Vector3 = LACreatureNesting.choose_site(self, pos)
	if is_inf(site.x):
		return
	nest_pos = site
	has_nest = true
	if _ecology != null and _ecology.has_method("spawn_nest"):
		var n = _ecology.spawn_nest(site, species, family_id, can_fly)
		if n != null:
			_nest_node = n


func _nest_touch() -> void:
	if _nest_node != null and is_instance_valid(_nest_node) and _nest_node.has_method("touch"):
		_nest_node.touch()


# Thirst drive. Returns "" (not thirsty enough / no water known), "drink" (standing at
# water — refill in place) or "seek" (head toward the nearest water via _water_dir_cache).
# Emergent watering holes: nothing scripts where animals gather — they simply walk to the
# nearest wet cell of the shared water field, so they cluster wherever water actually pools.
func _handle_thirst(pos: Vector3, delta: float) -> String:
	if _material == null or not _material.has_method("is_water_at"):
		return ""
	if hydration >= max_hydration * THIRSTY_FRACTION:
		return ""
	if _material.is_water_at(pos.x, pos.z):
		hydration = minf(max_hydration, hydration + DRINK_RATE * delta)
		return "drink"
	_water_search_cd -= delta
	if _water_search_cd <= 0.0:
		_water_search_cd = 0.5
		_water_dir_cache = _find_water_dir(pos)
	if _water_dir_cache != Vector3.ZERO:
		return "seek"
	return ""


# Probe rings of increasing radius for the nearest wet cell and return a flat unit
# heading toward it, or ZERO if no water is within reach. Cheap: index-math queries.
func _find_water_dir(pos: Vector3) -> Vector3:
	if _material == null or not _material.has_method("is_water_at"):
		return Vector3.ZERO
	var radii: Array = [sense_radius, sense_radius * 2.0, sense_radius * 3.5]
	var dirs: int = 12
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var px: float = pos.x + cos(ang) * float(r)
			var pz: float = pos.z + sin(ang) * float(r)
			if _material.is_water_at(px, pz):
				var d: Vector3 = Vector3(px - pos.x, 0.0, pz - pos.z)
				if d.length() > 0.001:
					return d.normalized()
	return Vector3.ZERO


# Grazing is just eating carbs-type food off the ground — same unified path as scavenging.
func _try_eat_plant(pos: Vector3) -> bool:
	return _try_eat_food(pos)


# --- cognition action vocabulary bridge -------------------------------------
# Map the innate cascade's descriptive `state` to a canonical action name (LAActionRegistry) so the
# fast policy, social learning, and the LLM all speak the same vocabulary.
func _state_to_action(s: String) -> String:
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
		"eat":
			return "graze" if diet == "herbivore" else "scavenge"
		"rest", "sleep", "roost", "nesting":
			return "rest"
		"migrate":
			return "migrate"
		_:
			return "wander"


# Execute a chosen action name → {heading, state, speed}. This is the name→behaviour dispatch the
# fast policy and slow brain drive; it reuses the same primitives as the innate cascade.
func _execute_action(action: String, pos: Vector3, delta: float) -> Dictionary:
	match action:
		"graze":
			_try_eat_plant(pos)
			return {"heading": _heading + LACreatureFlocking.steer(self, pos, true), "state": "eat", "speed": speed}
		"scavenge":
			_try_scavenge(pos)
			return {"heading": _heading + LACreatureFlocking.steer(self, pos, true), "state": "eat", "speed": speed}
		"investigate":
			var cue: Vector3 = _carrion_cue(pos)
			if cue != Vector3.ZERO:
				return {"heading": cue, "state": "investigate", "speed": speed}
			return {"heading": _heading, "state": "wander", "speed": speed}
		"hunt", "throw_rock":
			var h: Vector3 = _think_predator(pos, _heading)   # sets `state` (chase/stalk/throw/…)
			return {"heading": h, "state": state, "speed": speed}
		"flock":
			return {"heading": _heading + LACreatureFlocking.steer(self, pos, not can_fly), "state": "flock", "speed": speed}
		"drink":
			if _material != null and _material.has_method("is_water_at") and _material.is_water_at(pos.x, pos.z):
				hydration = minf(max_hydration, hydration + DRINK_RATE * delta)
				return {"heading": _heading, "state": "drink", "speed": 0.0}
			return _execute_action("seek_water", pos, delta)
		"seek_water":
			var wd: Vector3 = _find_water_dir(pos)
			if wd != Vector3.ZERO:
				return {"heading": wd, "state": "seek", "speed": speed}
			return {"heading": _heading, "state": "wander", "speed": speed}
		"rest":
			return {"heading": _heading, "state": "rest", "speed": speed * 0.12}
		"migrate":
			if _migrate_dir == Vector3.ZERO:
				var cards: Array = [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]
				_migrate_dir = cards[randi() % cards.size()]
			return {"heading": _migrate_dir, "state": "migrate", "speed": speed}
		"wander":
			return {"heading": _heading, "state": "wander", "speed": speed}
	return {"heading": _heading, "state": state, "speed": speed}


func _forage_action() -> String:
	if diet == "herbivore":
		return "graze"
	return "hunt" if preys_on.size() > 0 else "graze"


# Emit an animal call others can hear (omnidirectional). The ecology relays it; each listener gates
# on its own hearing_range. Throttled so a panicking animal doesn't scream every frame.
func _emit_call(call_type: String) -> void:
	if _ecology == null or not _ecology.has_method("broadcast_call"):
		return
	if _call_cd > 0.0:
		return
	_call_cd = 1.5 if call_type == "alarm" else 4.0
	_ecology.broadcast_call(global_position, species, call_type, self)


# Hear a call from `caller` (already range-checked by the broadcaster against my hearing_range).
# Alarm/distress feed the fear reflex even with no line of sight; a same-species forage call teaches
# me to forage in my current situation, kin weighted over strangers — sound-based social learning.
func hear_call(source_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	match call_type:
		"alarm":
			add_fear(source_pos, 1.2)
		"distress":
			add_fear(source_pos, 0.8)
		"forage":
			if from_species == species and _cognition != null:
				var kin: bool = caller != null and caller.has_method("get_family_id") and caller.get_family_id() == family_id
				var rel: float = 1.0 if kin else 0.35
				_cognition.learn_from_sound(self, _forage_action(), rel)
		"carrion":
			# A scavenger announced a carcass: any non-herbivore remembers it as a cue to investigate,
			# so it can converge on the kill even without seeing the vultures (sound past line of sight).
			if diet != "herbivore":
				_cue_pos = source_pos
				_cue_cd = 12.0


# Emergent threat detection: no hardcoded predator pairs. Flee ANY nearby creature that
# HUNTS and is meaningfully LARGER than me — one rule makes rabbits flee foxes AND humans,
# foxes flee humans, and apex-sized hunters fear nothing.
func is_hunter() -> bool:
	return diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0)


func is_mature() -> bool:
	return age >= maturity_age


# Inspector presentation lives in LACreatureInspector; this stays as the group-facing hook.
func get_inspector_payload() -> Dictionary:
	return LACreatureInspector.payload(self)
