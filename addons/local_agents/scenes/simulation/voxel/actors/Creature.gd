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
const GROUND_TURN_RATE: float = 6.0        # ground creatures turn briskly-but-smoothly toward their decided
                                           # heading each frame, so throttled decisions don't read as jerky pops
const THINK_STRIDE: int = 3                 # decide every N physics frames (movement stays every-frame)

const ThrownRockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/ThrownRock.gd")

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
# How strongly this species clings to an incumbent local leader (emergent hysteresis). A challenger must
# out-rank the current leader by MORE than this margin to take over. 0 = pure meritocracy (always follow the
# local top — animals); high = sticky dynasties that survive a slump (humans). One number, no per-species code.
var leader_loyalty: float = 0.0
# Emergent leadership SHAPE for this species (one knob, increasing structure):
#   "flat"    — one local leader per cluster; everyone else follows it directly (the base model).
#   "family"  — juveniles follow their nearest family adult (parent/elder); adults flat-follow the pack leader.
#   "command" — family-following PLUS a multi-level rank tree among adults (grunt→lieutenant→huntmaster).
# "family"/"command" both parent-follow, so parent-following is just a mode of hierarchy, not a separate flag.
var hierarchy: String = "flat"
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
# A THROW is just a fling: it releases the same physics shadow (below), so a thrown creature tumbles
# under real physics and stands back up on landing — one mechanism, no separate ballistic path.
var _held: bool = false

# Physics shadow (HL2-style): while _ragdoll, a RigidBody3D SHADOW drives the body (fling/topple),
# and the visible creature reads its transform each frame. On settle it either stands up (alive) or
# becomes a _carcass — the SAME node, no separate corpse, no model swap — and rots green->black.
var _ragdoll: bool = false
var _carcass: bool = false
var _dead: bool = false
var _shadow: RigidBody3D = null
var _settle_t: float = 0.0
var _decay_age: float = 0.0
var _carrion: float = 0.0                     # remaining meat value once a carcass
var _rot_overlay: StandardMaterial3D = null   # shared green->black decay tint on the model

var _heading: Vector3 = Vector3.FORWARD
var _target_heading: Vector3 = Vector3.FORWARD   # decided heading; _heading eases toward it each frame
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

# --- decision throttling: think every THINK_STRIDE frames (instance-staggered), move every frame ---
var _eff_speed: float = 0.0                 # decided speed, carried between think-frames
var _think_phase: int = -1                  # per-instance stagger offset (lazily set on first tick)
var _force_think: bool = false              # acute event (scare/damage) → re-decide next frame

# --- emergent local leadership (LACreatureLeadership) ---
# A `herd` creature is either the local top-ranked same-species individual (a LEADER: _leader==null,
# _is_leader==true, runs the full think cascade) or a FOLLOWER (_leader set → adopts the leader's decision
# and coasts). Election is throttled by _leader_elect_cd. Non-herd creatures are always their own leader.
var _leader: Node3D = null
var _is_leader: bool = true
var _leader_elect_cd: int = 0

# Injected ecology service — broadcast calls, spawns.
var _ecology = null

# Digestion + marking: a fed creature periodically drops FECES (soil fertility + a food/musk cue) and, more
# often, URINE (territorial musk). Both deposit into the shared scent/fertility field (LAMaterialScent3D)
# via _material — predators track prey by their dung, and dung fertilizes the soil so plants regrow.
var _poop_cd: float = 0.0
var _urine_cd: float = 0.0

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
	_force_think = true                       # acute terror: bolt NEXT frame, don't wait for the stride


# --- the player's hand: pick up, carry, drop, or throw a creature ---
# The picking-up: suspend the AI/terrain-snap so the hand (VoxelWorld) can position us freely.
func hold_begin() -> void:
	_held = true
	_panic_timer = 0.0                        # in the hand it stops panicking


# A gentle set-down: resume normal life wherever we were dropped.
func hold_end() -> void:
	_held = false


# Released with a fling: hand the release velocity to the physics shadow as an impulse — the body
# tumbles under real physics and (surviving) gets back up on landing. Same path as any other fling.
func throw(velocity: Vector3) -> void:
	_held = false
	fling(velocity)


func is_held() -> bool:
	return _held or _ragdoll


## Current steering heading (unit-ish world vector the creature is moving along) — read by the debug
## overlay to draw its intended path. Zero while held/ragdolling (no self-directed motion).
func debug_heading() -> Vector3:
	if _held or _ragdoll or _carcass:
		return Vector3.ZERO
	return _heading


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


# Take deterministic HP damage from a blast/lightning/etc. Death happens only when HP hits 0.
# A surviving creature hit by a real impulse is FLUNG (physics shadow) and gets back up; the
# killing blow's impulse flings the body that then stays as a carcass. No randomness in the path.
func take_damage(amount: float, cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying or amount <= 0.0:
		return
	_force_think = true                       # being hurt forces an immediate re-decision (flee/react)
	health -= amount
	# A wound bleeds: a burst of BLOOD scent into the field draws opportunists to hurt prey (emergent).
	if _material != null and _material.has_method("deposit_blood"):
		_material.deposit_blood(global_position, clampf(amount * 0.04, 0.2, 3.0))
	if health <= 0.0:
		die(cause, impulse)
	elif impulse.length() > 3.0:
		fling(impulse)


# Shove the LIVING creature with a physics impulse: the shadow takes over, it tumbles, then stands
# back up. This is the same mechanism death uses — flinging is decoupled from dying.
func fling(impulse: Vector3) -> void:
	if _dying or _held:
		return
	LACreatureRagdoll.launch(self, impulse, false)


# Death: the creature does NOT vanish or spawn a corpse — it becomes a carcass IN PLACE. Its physics
# shadow is released so the body falls/tumbles (an `impulse`, e.g. a meteor, flings it), and once it
# settles it stays where it fell and rots (green->black) before finally shrinking away. Same node,
# same model, throughout.
func die(_cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying:
		return
	_dying = true
	# A death cry: nearby animals hear it and startle (predators may later home in on it).
	if _ecology != null and _ecology.has_method("broadcast_call"):
		_ecology.broadcast_call(global_position, species, "distress", self)
	LACreatureRagdoll.launch(self, impulse, true)


# Deposit waste at `ground_pos` into the shared scent/fertility field: feces enriches the soil (plants
# regrow on dung — emergent) and carries a food + musk cue predators track prey by; urine is territorial
# musk. No node is spawned — the deposit is a few cells in LAMaterialScent3D that diffuse + wash away.
func _deposit_waste(ground_pos: Vector3, kind: String) -> void:
	if _material != null and _material.has_method("deposit_waste"):
		_material.deposit_waste(ground_pos, self, kind)


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
	leader_loyalty = float(config.get("leader_loyalty", leader_loyalty))
	hierarchy = String(config.get("hierarchy", hierarchy))
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
	LACreatureBody.build_body(self)
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


# Visual-only animation: play idle/move/run (or bob a rigless model) from actual displacement.
# Kept out of _physics_process so it never perturbs movement/AI, only presentation.
func _process(delta: float) -> void:
	if _model_root == null:
		return
	if _ragdoll or _carcass:
		return                            # the shadow/decay owns the transform; don't drive idle/run anim
	_vis_t += delta
	var p: Vector3 = global_position
	var sp: float = 0.0
	if delta > 0.0001:
		sp = (p - _vis_prev_pos).length() / delta
	_vis_prev_pos = p
	LAModelVisual.animate(_model_root, _model_anim, _model_anims, sp, _model_run_speed, _vis_t, delta)


# --- decision LOD (distance + sleep) ------------------------------------------------------------
# The full cognition cascade is the creature's only non-trivial per-frame cost. Every-frame work
# (metabolism, thirst, temperature, ageing, death, movement) stays every-frame so distant creatures
# still live/die/glide correctly; only the DISCRETIONARY think cascade is throttled by how visible
# and how idle the creature is. This spreads the cost automatically: a fraction of the population is
# always asleep (diurnal by night / nocturnal by day, staggered), and most animals are off-screen.
const MID_THINK_STRIDE: int = 10           # mid-distance discretionary thinking (~6 Hz)
const FAR_THINK_STRIDE: int = 30           # far/off-screen discretionary thinking (~2 Hz)
const SLEEP_THINK_STRIDE: int = 30         # asleep/resting: no decisions to make — heaviest throttle
const NEAR_LOD_D2: float = 900.0           # <30 m from camera → full THINK_STRIDE rate
const MID_LOD_D2: float = 4900.0           # <70 m → MID rate; beyond → FAR rate

# --- Emergent local leadership (LACreatureLeadership). A `herd` creature that is NOT the local top-ranked
# same-species individual becomes a FOLLOWER: it ADOPTS its leader's decision (the canonical action) and
# coasts on it, so it skips the whole expensive think_* + cognition assessment and ticks slowly. Only the
# few local leaders pay the heavy "what to do" cost. Reflexes (flee/thirst) + all pathing stay per-individual.
const FOLLOWER_THINK_STRIDE: int = 18      # a follower re-decides rarely (~3 Hz) — it coasts on the adopted action
const LEADER_ELECT_STRIDE: int = 45        # re-run the (cheap, throttled) local-leader election ~every 0.75 s
const LEADER_RADIUS_MULT: float = 1.5      # leadership neighbourhood = flock_radius × this
# A/B / verification kill-switch: LA_NO_LEADERSHIP=1 makes every creature its own leader (no delegation),
# i.e. the pre-leadership behaviour, for on/off population + perf comparison. Read once (env is process-wide).
static var _leadership_off: int = -1
static func _leadership_disabled() -> bool:
	if _leadership_off < 0:
		_leadership_off = 1 if OS.get_environment("LA_NO_LEADERSHIP") == "1" else 0
	return _leadership_off == 1

# Camera position, fetched once per physics frame and shared by every creature (a single
# get_camera_3d() lookup, not one per creature). INF when there is no active camera.
static var _cam_frame: int = -1
static var _cam_pos: Vector3 = Vector3(INF, INF, INF)


func _camera_pos() -> Vector3:
	var f: int = int(Engine.get_physics_frames())
	if f != _cam_frame:
		_cam_frame = f
		var vp: Viewport = get_viewport()
		var cam: Camera3D = vp.get_camera_3d() if vp != null else null
		_cam_pos = cam.global_position if cam != null else Vector3(INF, INF, INF)
	return _cam_pos


# How often THIS creature runs the discretionary think cascade, in physics frames. Sleep is cheapest,
# then distance-graded for idle/discretionary states; time-critical states (fleeing, hunting, drinking)
# stay at the full near rate at any distance so an off-screen chase or a drink never stalls.
func _think_stride() -> int:
	if state == "sleep" or state == "roost" or state == "nesting" or state == "rest":
		return SLEEP_THINK_STRIDE
	if state == "flee" or state == "panic" or state == "chase" or state == "stalk" \
			or state == "throw" or state == "seek" or state == "drink":
		return THINK_STRIDE
	# A follower (anyone with a valid leader — herd member, squad grunt, or a parent-following juvenile)
	# coasts on its adopted action and re-decides rarely; its leader pays the heavy "what to do" cost.
	# Time-critical states above already opted out, so a fleeing/drinking follower is never throttled.
	if _leader != null and is_instance_valid(_leader):
		return FOLLOWER_THINK_STRIDE
	var cam: Vector3 = _camera_pos()
	if is_inf(cam.x):
		return THINK_STRIDE
	var d2: float = global_position.distance_squared_to(cam)
	if d2 < NEAR_LOD_D2:
		return THINK_STRIDE
	if d2 < MID_LOD_D2:
		return MID_THINK_STRIDE
	return FAR_THINK_STRIDE


# Throttled emergent election (LACreatureLeadership) — dispatches by species `hierarchy` mode. No registry,
# no appointment: every creature runs the same local rules and the whole tree (juvenile→parent→…→pack leader)
# falls out. "flat"/base = one local leader; "family" adds parent-following for the young; "command" adds a
# multi-level rank tree among adults. Reflexes + pathing stay per-individual regardless.
func _elect_leader(pos: Vector3) -> void:
	_leader_elect_cd = LEADER_ELECT_STRIDE
	var radius: float = flock_radius * LEADER_RADIUS_MULT
	# 1. Parent-following (family/command): a juvenile attaches to its nearest family adult (parent/elder),
	#    who in turn follows the pack leader — so the family→pack tree self-assembles. Orphans (no adult kin
	#    nearby) fall through to the rank rules below; a matured creature stops following its parent.
	if (hierarchy == "family" or hierarchy == "command") and not is_mature():
		var guardian: Node3D = LACreatureLeadership.nearest_family_adult(self, pos, radius)
		if guardian != null and not LACreatureLeadership.would_cycle(self, guardian, 8):
			_leader = guardian
			_is_leader = false
			return
	# 2. Solitary adults (non-herd, e.g. a grown fox) lead only themselves — no adult pack forms.
	if not herd:
		_leader = null
		_is_leader = true
		return
	# 3. Herd adults: a "command" species builds a multi-level rank tree; everyone else a flat pack leader.
	if hierarchy == "command":
		_elect_superior(pos, radius)
	else:
		_elect_flat(pos, radius)


# Flat election (base model / "family" adults): follow the local score-max, or lead if I am it, with
# leader_loyalty hysteresis + self-healing. This is the original single-leader-per-cluster behaviour.
func _elect_flat(pos: Vector3, radius: float) -> void:
	var cand: Node3D = LACreatureLeadership.local_leader(self, pos, radius)
	var top: Node3D = self if cand == null else cand      # the pure local argmax (self if I rank highest)
	if top != self and LACreatureLeadership.would_cycle(self, top, 8):
		top = self                                        # attaching would close a loop → treat myself as root
	# The incumbent leader over me: myself while I lead, else the creature I currently follow.
	if not _is_leader:
		var inc_ok: bool = _leader != null and is_instance_valid(_leader) \
				and pos.distance_squared_to(_leader.global_position) <= radius * radius
		if not inc_ok:
			# Self-healing: my leader died or left → adopt the new local top immediately, NO loyalty margin.
			_leader = null if top == self else top
			_is_leader = (top == self)
			return
	var incumbent: Node3D = self if _is_leader else _leader
	if top == incumbent:
		return                                            # incumbent is still the local top — no change
	# `top` is the local (score, instance_id) argmax above my incumbent. Switch (takeover) if the challenger
	# clears the species loyalty margin. For pure-meritocracy species (leader_loyalty <= 0) ANY higher top
	# wins — local_leader already broke exact-score ties deterministically by instance_id, so we must NOT
	# re-require a strict score margin here (that left equal-stat herds all-leaders, the whole point missed).
	# Humans (high loyalty) cling: a decisive SCORE margin is needed → dynasties, and takeover by force is
	# rare/dramatic. A leader and its followers run the SAME test against the SAME top, so a cluster hands
	# off coherently on one election — no adopt-chains.
	var justified: bool = leader_loyalty <= 0.0 \
			or LACreatureLeadership.leader_score(top) > LACreatureLeadership.leader_score(incumbent) + leader_loyalty
	if justified:
		_leader = null if top == self else top
		_is_leader = (top == self)


# Multi-level ("command") election: attach to my immediate SUPERIOR (nearest higher-rank neighbour), so the
# tree gains depth — grunt→lieutenant→huntmaster. I CLING to my current manager while they stay a valid
# superior (in reach + still out-rank me past my loyalty); I only re-pick when my boss falls below me, dies,
# or leaves — then I attach to the nearest remaining superior, or become a root if none. A mid-node is both a
# follower (of its boss, _is_leader false → it adopts the boss's action) AND a manager (its own subordinates
# attach to it by rank), so the huntmaster's strategy flows down while each lieutenant leads its own sub-hunt.
func _elect_superior(pos: Vector3, radius: float) -> void:
	if _leader != null and is_instance_valid(_leader):
		# Still a valid boss if it out-ranks me past my loyalty and is within the max span (radius×2).
		var max_reach: float = radius * 2.0
		var still_valid: bool = pos.distance_squared_to(_leader.global_position) <= max_reach * max_reach \
				and LACreatureLeadership.leader_score(_leader) \
					> LACreatureLeadership.leader_score(self) + leader_loyalty
		if still_valid:
			_is_leader = false
			return                                            # cling to my current boss (hierarchy stickiness)
	var sup: Node3D = LACreatureLeadership.local_superior(self, pos, radius, leader_loyalty)
	if sup != null and LACreatureLeadership.would_cycle(self, sup, 8):
		sup = null                                            # attaching would close a loop → become a root
	_leader = sup
	_is_leader = (sup == null)


func _physics_process(delta: float) -> void:
	# In the player's hand: VoxelWorld sets our position each frame; skip AI + terrain-snap.
	if _held:
		return
	# Physics shadow drives the body (fling/topple), alive or dead — overrides all AI this frame.
	if _ragdoll:
		LACreatureRagdoll.tick(self, delta)
		return
	# Dead and come to rest: rot in place where it fell (no AI, no movement).
	if _carcass:
		LACreatureRagdoll.decay_tick(self, delta)
		return
	age += delta
	if _think_phase < 0:
		_think_phase = int(get_instance_id())                  # raw id; the think stagger is (id % stride)
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

	# Digestion + marking: a fed creature periodically drops feces (soil fertility + food/musk cue), and
	# more often urinates (territorial musk). Both write to the shared scent/fertility field below it.
	_poop_cd -= delta
	if _poop_cd <= 0.0:
		_poop_cd = randf_range(24.0, 48.0)
		if energy > max_energy * 0.35:
			_deposit_waste(Vector3(pos.x, surf, pos.z), "feces")
	_urine_cd -= delta
	if _urine_cd <= 0.0:
		_urine_cd = randf_range(10.0, 22.0)
		_deposit_waste(Vector3(pos.x, surf, pos.z), "urine")

	# EMERGENT LEADERSHIP: decide (throttled) whether I lead my local same-species cluster or follow its
	# top — done BEFORE the stride is computed so a fresh follower immediately gets the slow follower rate,
	# and a leaderless creature (dead/departed leader) re-elects or self-decides this frame. Non-herd
	# creatures are always their own leader (they never delegate their decision).
	# Participate in leadership if I herd, OR my species is parent-following (family/command) — the latter
	# lets even a solitary species' juveniles follow a parent while its adults stay independent.
	if (herd or hierarchy == "family" or hierarchy == "command") and not _leadership_disabled():
		_leader_elect_cd -= 1
		if _leader_elect_cd <= 0 or (not _is_leader and not is_instance_valid(_leader)):
			_elect_leader(pos)
	else:
		_leader = null
		_is_leader = true

	# DECISION THROTTLE (LOD): run the full cognition cascade only every `stride` frames, where the
	# stride grows with distance to the camera and is heaviest while asleep/resting — see _think_stride.
	# Instance-staggered (id % stride) so the population spreads its think-frames evenly at every rate.
	# An acute event (_force_think, set by scare/damage) re-decides NEXT frame regardless — so a sleeping
	# or distant creature still wakes and reacts. Between think-frames the creature keeps gliding along its
	# last _heading at _eff_speed — movement + metabolism below stay every-frame for smoothness.
	var stride: int = _think_stride()
	var do_think: bool = _force_think or ((int(Engine.get_physics_frames()) + _think_phase) % stride == 0)
	if do_think:
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
				var thirst_action: String = LACreatureThirst.handle_thirst(self, pos, delta)
				if thirst_action == "drink":
					eff_speed = 0.0                      # stand at the water's edge and drink
					state = "drink"
				elif thirst_action == "seek":
					desired = _water_dir_cache
					state = "seek"
				elif _leader != null and is_instance_valid(_leader):
					# FOLLOWER (herd member, squad grunt, OR a parent-following juvenile): adopt my leader's
					# DECISION (its canonical action) and act on it locally — skipping the whole expensive
					# think_* + cognition assessment, which my leader (or the huntmaster above it) already
					# paid. execute_action still finds MY own food/water/heading, so a lieutenant leading a
					# sub-hunt and its grunts each chase their own nearest prey → coordinated, divergent hunts.
					var la: String = LACreatureThink._adoptable_action(
							LACreatureThink.state_to_action(_leader, _leader.state), self)
					var mv_f: Dictionary = LACreatureThink.execute_action(self, la, pos, delta)
					if mv_f.has("heading"):
						desired = mv_f["heading"]
					state = String(mv_f.get("state", state))
					eff_speed = float(mv_f.get("speed", eff_speed))
				elif diet == "scavenger":
					desired = LACreatureThink.think_scavenger(self, pos, delta)   # vultures: soar, follow carrion, circle, feed
				elif can_fly:
					desired = LACreatureThink.think_bird(self, pos, delta)         # sets its own state; may land to feed/drink
				elif diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0):
					desired = LACreatureThink.think_predator(self, pos, desired)
				else:
					desired = LACreatureThink.think_prey(self, pos, desired)

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
			# FOLLOWERS skip this entirely (_is_leader false) — they already adopted the leader's decision
			# above; only leaders (and non-herd creatures) pay the expensive slow-brain escalation.
			if big_pred == null and _is_leader and _cognition != null and state != "roost" and state != "nesting":
				var sig: Dictionary = LASituationSignature.compute(self)
				var innate_action: String = LACreatureThink.state_to_action(self, state)
				var chosen: String = _cognition.decide(self, innate_action, sig, delta)
				if chosen != innate_action:
					var mv: Dictionary = LACreatureThink.execute_action(self, chosen, pos, delta)
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
			# Record the decided direction as a TARGET; the movement block turns _heading toward it
			# smoothly every frame (see below). On an acute flee (_force_think) snap instantly so a
			# startled animal bolts NOW rather than banking into the turn.
			_target_heading = desired.normalized()
			if _force_think:
				_heading = _target_heading
		_eff_speed = eff_speed          # carry this decision to the movement of the next few frames
		_force_think = false

	# MOVEMENT — every frame. The DECIDED heading is a TARGET the creature turns toward smoothly each
	# frame (not snapped), so throttled decisions (every THINK_STRIDE frames) still read as fluid motion
	# instead of 20Hz direction pops. Acute flees snap instantly (see the think block).
	if _target_heading.length() > 0.01:
		var turn_rate: float = BIRD_TURN_RATE if can_fly else GROUND_TURN_RATE
		_heading = _turn_toward(_heading, _target_heading, turn_rate * delta)
	var step: Vector3 = _heading * _eff_speed * delta
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
	if _carcass:
		return LACreatureRagdoll.inspector_payload(self)
	return LACreatureInspector.payload(self)


# --- carcass food contract (only meaningful once dead; scavengers eat via these) ----------------

# A scavenger takes a bite of the carcass; returns the energy actually removed.
func feed(amount: float) -> float:
	return LACreatureRagdoll.feed(self, amount)


# What this body is worth as food. Meat once a carcass; live creatures are hunted, not foraged.
func food_profile() -> Dictionary:
	return LACreatureRagdoll.food_profile(self)


# Remaining meat value in the carcass.
func nutrition() -> float:
	return _carrion
