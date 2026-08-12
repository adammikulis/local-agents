@tool
@icon("res://addons/local_agents/icons/local_agent_creature.svg")
class_name LocalAgentCreature
extends CharacterBody3D


const GROUP_SELECTABLE: String = "selectable"
const GROUP_PLANT: String = "plant"
const GROUP_CREATURE: String = "creature"
const GROUP_ROCK: String = "rock"
const GROUP_CARRION: String = "carrion"
const PREDATOR_SIZE_RATIO: float = 1.2     # flee anything this many times my size that hunts
# Turn rates + coast avoidance live in LACreatureLocomotion (which owns the movement step); the think and
# physics-rate stride constants live in LACreatureLod (which owns the decision + update cadence).

var energy: float = 100.0
var max_energy: float = 100.0
var disease: LACreatureDisease = null
var gut_microbiome: LACreatureMicrobiome = null  # adaptive gut flora — modulates digestive yield (LACreatureMicrobiome)
var lactate: float = 0.0                     # muscle LACTATE (0..1): the anaerobic-exertion fatigue byproduct.
var _water_force: Vector3 = Vector3.ZERO     # cached water-current sweep (recomputed on a stride; raycast-heavy)
var body_temp: float = 20.0                 # °C of the BODY, not the air. Newton-cools toward ambient with a
var respiratory_capacity: float = 1.0       # heritable gas-exchange surface packed into the body's area
var thermogenesis: float = 0.0              # heritable: how hard the body raises oxygen throughput when cold.
                                            # 0 IS an ectotherm; high IS an endotherm. One continuum, no flag.
var _resp_capacity: float = 0.0             # last tick's AEROBIC CAPACITY per second (what the body's surface and
var _resp_rate: float = 0.0                 # last tick's REALISED oxidation, per second — the measured metabolic

var mass_kg: float = 0.5                     # real body mass in kilograms (species data; not the `size` gene)
var structural_mass: float = 0.0             # bone/muscle/organ in simulation mass units (the non-labile half)
var bite_rate: float = 1.0                   # mass units a mouth can process per second (∝ aerobic capacity)

var breath_capacity: float = 6.0
var _breath: float = 6.0
var breathes: String = "air"

# --- health / HP (emergent damage: blasts & lightning deal graded, deterministic damage;
# 0 HP = death). Bigger creatures carry more HP; set from `size` at spawn. ---
var health: float = 100.0
var max_health: float = 100.0
var food_value: float = 55.0
var max_age: float = 90.0
var hungry_at: float = 0.7

var gut: float = 0.0                          # biomass currently buffered in the gut (energy-equivalent units)
var gut_capacity: float = 0.0                 # max gut fill (set at spawn ~ max_energy * CAPACITY_FRAC)
var gut_waste: float = 0.0                    # indigestible residue awaiting excretion (feeds LACreatureExcretion)
var microbiome: float = 1.0                   # gut-flora digestive-efficiency scalar (herbivores ferment plants)
var gut_digestibility: float = 1.0            # mass-weighted digestibility of what is in the gut (LAFood state)

# --- thirst (emergent: drink from the water field or die of dehydration) ---
# hydration mirrors energy: full at max, drains at thirst_rate, drinking refills, 0 = death.
var hydration: float = 100.0
var max_hydration: float = 100.0
var thirst_rate: float = 1.0
const THIRSTY_FRACTION: float = 0.5        # below this, seeking water interrupts other drives


var _material = null                          # LAMaterialField (temp_at / depth_at / is_water_at)
var _water_dir_cache: Vector3 = Vector3.ZERO
var _water_search_cd: float = 0.0

var throws: bool = false
var throw_range: float = 14.0
var _throw_cd: float = 0.0
var has_rock: bool = false
var _rock_visual: MeshInstance3D = null
var _dying: bool = false

var terrain = null                       # LAVoxelTerrainService (injected)
var config: Dictionary = {}

@export_group("Standalone")
## Configure this creature from its species file during _ready, with a flat-ground terrain at Ground Y.
## Turn off if a world (LocalAgentSimWorld / EcologyService) will call setup() for it instead.
@export var standalone_on_ready: bool = false
@export var standalone_species: String = ""
## World Y of the flat ground plane this creature stands on when running standalone.
@export_range(-1000.0, 1000.0, 0.05, "or_less", "or_greater", "suffix:m") var ground_y: float = 0.0

var species: String = "creature"
var diet: String = "herbivore"
var speed: float = 3.0
var size: float = 0.5
var color: Color = Color(0.7, 0.7, 0.7)
var is_male: bool = false
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
var hierarchy: String = "flat"
var nocturnal: bool = false
var _sense_mult: float = 1.0

var flock_cohesion: float = 0.5
var flock_alignment: float = 0.5
var flock_separation: float = 0.8
var flock_radius: float = 8.0
var flock_weight: float = 0.7

var age: float = 0.0
var state: String = "wander"

var _held: bool = false

var _ragdoll: bool = false
var _carcass: bool = false
var _dead: bool = false
var _shadow: RigidBody3D = null
var _settle_t: float = 0.0
var _decay_age: float = 0.0
var _carrion: float = 0.0                     # meat MASS left on the carcass (drawn from the live body at death)
var _carrion_initial: float = 0.0             # what the body weighed when it died — the rot/shrink denominator
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
var _anim_accum: float = 0.0
var _anim_phase: int = -1
var _anim_stride: int = 1            # last computed animation-update stride (1 = every frame); telemetry reads it
var _collision_shape: CollisionShape3D = null
var _collision_on: bool = true
var _model_run_speed: float = 999.0
var _vis_prev_pos: Vector3 = Vector3.ZERO
var _vis_t: float = 0.0

# --- behavior-state debug tint (DebugPanel HIGHLIGHT · BEHAVIOR) -----------------------------------
# Per-creature state only; the shared enabled-category set + all the painting logic live in LACreatureTint.
var _tint_category: String = ""                   # the category currently painted on this creature ("" = none)
var _tint_mat: StandardMaterial3D = null          # per-creature emissive overlay (reused across colours)
var _tint_targets: Array = []                      # cached MeshInstance3D nodes to overlay (lazy)

var _panic_timer: float = 0.0
var _panic_source: Vector3 = Vector3.ZERO

# --- decision throttling (cadence owned by LACreatureLod): think every N frames (instance-staggered),
# move every frame ---
var _eff_speed: float = 0.0                 # decided speed, carried between think-frames
var _think_phase: int = -1                  # per-instance stagger offset (lazily set on first tick)
var _force_think: bool = false              # acute event (scare/damage) → re-decide next frame

var _leader: Node3D = null
var _is_leader: bool = true
var _leader_elect_cd: int = 0

# Injected ecology service — broadcast calls, spawns.
var _ecology = null

var _poop_cd: float = 0.0
var _urine_cd: float = 0.0

var eye_fov: float = 220.0
var hearing_range: float = 12.0            # calls carry this far, in every direction, even at night
var _call_cd: float = 0.0

var family_id: int = 0
var band_id: int = 0
var _band_solo: int = 0
var _assoc: Dictionary = {}                # instance id -> association bond with that companion
var _assoc_cd: float = 0.0                 # seconds until the next (coarse) association sample
var _genome = null                         # LADNA (literal DNA strand → traits + baked instinct priors)
var _cognition = null                      # LACognition (per-creature learned policy + slow-brain hook)
var bond: LACreatureBond = null
@export_group("Cognition")
@export var llm_enabled: bool = true
var _migrate_dir: Vector3 = Vector3.ZERO   # steady heading chosen when the 'migrate' action fires
var _veto_dir: Vector3 = Vector3.ZERO      # committed retreat heading when cognition VETOES a learned-lethal action
var _veto_timer: float = 0.0               # seconds left on the current retreat commitment (latched, anti-oscillation)

var _target_altitude: float = 12.0         # per-frame desired flight height above ground (flyers descend to feed/circle)
var _cue_pos: Vector3 = Vector3.ZERO       # a heard/smelt carrion cue to investigate
var _cue_cd: float = 0.0                    # seconds the current cue stays salient
var _pursued_cue: String = ""              # the LEARNED cue key currently being investigated
var _pursued_cd: float = 0.0               # window to credit that cue if food follows (else it decays)

var nests: bool = false
var nest_habitat: String = ""                    # "tree" | "ground" | "water" (default derived from can_fly)
var has_nest: bool = false
var nest_pos: Vector3 = Vector3(INF, INF, INF)   # sentinel = no nest yet
var _nest_node = null                            # LANest (the placed home site)

var pregnant: bool = false
var _gestation_t: float = 0.0                    # seconds of gestation remaining while pregnant
var _gestation_paid: float = 0.0                 # body mass already invested in the young (recovered on resorption)
var _mate = null                                 # LocalAgentCreature partner captured at conception (for the birth genome/bond)
var _repro_cd: float = 0.0                       # seconds until this creature may conceive again (post-birth / pair refractory)

var _growth: float = 1.0                          # cached visual growth scale (1.0 = full adult); updated by the life-stage tick
var senescence: LACreatureSenescence = null


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


## Enable/disable a behavior-state highlight globally (called by VoxelDebugWiring from the DebugPanel).
## The tint applies to whichever creatures are in a matching state; multiple categories can be on at once.
static func set_behavior_highlight(category: String, col: Color, on: bool) -> void:
	LACreatureTint.set_highlight(category, col, on)


## Force a fresh tint evaluation (VoxelDebugWiring calls this on a checkbox toggle so live creatures
## update at once rather than waiting for their next state change).
func refresh_state_tint() -> void:
	LACreatureTint.refresh(self)


func set_ecology(e) -> void:
	_ecology = e


func set_material_field(w) -> void:
	_material = w


# The game's LAFlameFX combustion visual — resolved lazily + guarded (never top-level `preload`d) so a
# core creature parses and dies-burned with the game deleted; it just skips the flame prop. Null when absent.
const FLAME_FX_PATH: String = "res://addons/local_agents/sim/actors/FlameFX.gd"
static var _flame_fx_script: GDScript = null
static var _flame_fx_resolved: bool = false

static func _resolve_flame_fx() -> GDScript:
	if _flame_fx_resolved:
		return _flame_fx_script
	_flame_fx_resolved = true
	if ResourceLoader.exists(FLAME_FX_PATH):
		_flame_fx_script = load(FLAME_FX_PATH) as GDScript
	return _flame_fx_script


# Organic matter combusts — bursts into flame (not incandescent glow) and dies burned. The flame is
# detached at the spot so it lingers as the body drops, rather than freeing with the creature.
func _combust() -> void:
	if _dying:
		return
	var parent: Node = get_parent()
	var flame_script: GDScript = _resolve_flame_fx()
	if parent != null and flame_script != null and flame_script.has_method("make"):
		var flame: Node3D = flame_script.make()
		parent.add_child(flame)
		flame.global_position = global_position
		var timer: SceneTreeTimer = get_tree().create_timer(2.5)
		timer.timeout.connect(func(): if is_instance_valid(flame): flame.queue_free())
	die("burned", Vector3(0.0, 2.0, 0.0))


# A thrown rock struck me — I die (drop a corpse).
func on_struck() -> void:
	die("struck")


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


func apply_field_force(force: Vector3, delta: float) -> void:
	if _held or _ragdoll or _carcass:
		return
	LACreatureFieldForces.apply(self, force, delta)


func die(cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying:
		return
	_dying = true
	LASimReport.event("death", {"cause": cause, "species": species, "who": cause + ":" + species})
	# A death cry: nearby animals hear it and startle (predators may later home in on it).
	if _ecology != null and _ecology.has_method("broadcast_call"):
		_ecology.broadcast_call(global_position, species, "distress", self)
	LACreatureRagdoll.launch(self, impulse, true)


func setup(_terrain, _config: Dictionary, _genome_arg = null) -> void:
	LACreatureSetup.apply(self, _terrain, _config, _genome_arg)


# Library drop-in self-config: a Creature.tscn placed in a scene with standalone_on_ready = true
# configures itself here (config empty + no terrain injected). Inert for sim creatures (flag default off).
func _ready() -> void:
	if Engine.is_editor_hint():
		return                            # @tool is for the inspector warnings only — never simulate in-editor
	if standalone_on_ready and config.is_empty() and terrain == null:
		setup_standalone(standalone_species, {"ground_y": ground_y})


## Inspector validation for a Creature dropped into a scene (species id typos, an ignored species).
## The checks live in LocalAgentCreatureWarnings so nothing but exports lands in this file.
func _get_configuration_warnings() -> PackedStringArray:
	return LocalAgentCreatureWarnings.check(self)


func setup_standalone(config_source = {}, opts: Dictionary = {}) -> void:
	LACreatureStandalone.setup(self, config_source, opts)


# The shared System-2 scheduler (FunctionGemma budget/queue), injected by the ecology after setup.
func set_cognition_scheduler(s) -> void:
	if _cognition != null:
		_cognition.set_scheduler(s)


func get_cognition():
	return _cognition


func get_genome():
	return _genome


## The bloodline this creature descends from (fixed for life).
func get_family_id() -> int:
	return family_id


## The band it currently runs with (changes as its associations do). Named apart from get_family_id so a
## caller has to say which of the two it means.
func get_band_id() -> int:
	return band_id


static func _species_group(sp: String) -> String:
	return "species_%s" % sp


# Visual-only animation: play idle/move/run (or bob a rigless model) from actual displacement.
# Kept out of _physics_process so it never perturbs movement/AI, only presentation. The animation-
# framerate LOD, the collision LOD and the playback itself all live in LACreatureAnim.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return                            # @tool guard
	if LAAblate.off("anim"):
		return
	if _model_root == null:
		return
	if _ragdoll or _carcass:
		return                            # the shadow/decay owns the transform; don't drive idle/run anim
	LACreatureAnim.tick(self, delta)


var _lod_accum: float = 0.0


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return                            # @tool guard
	if LAAblate.off("creatures"):
		return
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
	if _think_phase < 0:
		_think_phase = int(get_instance_id())
	var lod_dt: float = LACreatureLod.phys_gate(self, delta)
	if lod_dt < 0.0:
		return                            # not this creature's update frame — its dt keeps accumulating
	delta = lod_dt
	var prof: bool = LACreatureProfile.ensure()
	var _pt: int = Time.get_ticks_usec() if prof else 0
	LACreatureLifeStage.tick(self, delta)   # advance age (life-stage owner)
	# Ageing: grade speed / max_energy reserve down along the senescence curve (runs AFTER the age advance,
	# BEFORE the reproduction/metabolism ticks that read the updated traits + the senescence factor).
	if senescence != null:
		senescence.tick(self, delta)
	if _think_phase < 0:
		_think_phase = int(get_instance_id())                  # raw id; the think stagger is (id % stride)
	_throw_cd -= delta
	# Night perception: nocturnal species gain range after dark, diurnal ones lose it.
	_sense_mult = 1.0
	if _ecology != null and _ecology.has_method("is_night_at") and _ecology.is_night_at(global_position):
		_sense_mult = 1.4 if nocturnal else 0.7
	LACreatureDigestion.ambient_graze(self, global_position, delta)
	# Digestion: the gut converts buffered food into energy (+ pending feces) this frame — run BEFORE the
	# metabolism burn/starvation check so a creature that just ate is credited its digested energy and won't
	# starve with a full gut. Empty gut = no energy (must eat). See LACreatureDigestion.
	LACreatureDigestion.tick(self, delta)
	LACreatureReproduction.tick(self, delta)
	# Disease/immune: progress any active infection, fight it (immune system), express symptoms (energy/speed),
	# recover-with-immunity or die of disease. Owned by LACreatureDisease; a no-op until the disease work lands.
	if disease != null and disease.tick(self, delta):
		return
	# Tameness/companion upkeep: bond decays slowly, and a lapsed bond drops its command (LACreatureBond).
	if bond != null:
		bond.tick(self, delta)
	# Gut flora re-cultures toward the recent diet (modulates the next bite's energy yield). No death gate.
	if gut_microbiome != null:
		gut_microbiome.tick(self, delta)
	# Thirst + ageing — see LACreatureMetabolism. Death stops us.
	if LACreatureMetabolism.tick(self, delta):
		return
	if terrain == null:
		return

	var pos: Vector3 = global_position

	if LACreatureRespiration.tick(self, pos, delta):
		return

	LACreatureFieldForces.tick(self, delta)

	# Temperature comfort + combustion, emergent from the shared field at my feet.
	if LACreatureMetabolism.tick_environment(self, pos, delta):
		return
	# Breathing: drown when submerged past my breath reserve, or suffocate in O2-depleted smoke.
	if LACreatureMetabolism.tick_breath(self, pos, delta):
		return
	# Short-term exertion chemistry: sprinting builds muscle lactate, resting clears it (see the speed cap below).
	LACreatureMetabolism.tick_exertion(self, delta)
	if prof:
		LACreatureProfile.add("cr_meta", _pt)
		_pt = Time.get_ticks_usec()

	var up: Vector3 = terrain.up_at(pos)
	var up_dir0: Vector3 = (pos - terrain.planet_center()).normalized()
	var ground_pos: Vector3 = terrain.surface_point(up_dir0)
	if is_nan(ground_pos.x):
		return                            # unmeshed / off-terrain: skip this frame
	if prof:
		LACreatureProfile.add("cr_terrain", _pt)
		_pt = Time.get_ticks_usec()

	# Digestion + marking: a fed creature periodically drops feces (soil fertility + food/musk cue), and
	# more often urinates (territorial musk). Both write to the shared scent/fertility field below it.
	LACreatureExcretion.tick(self, ground_pos, delta)

	var _at: int = Time.get_ticks_usec() if prof else 0
	LACreatureAffiliation.tick(self, pos, delta)
	if prof:
		LACreatureProfile.add("cr_affil", _at)
	LACreatureLeadership.maybe_elect(self, pos)

	if prof:
		LACreatureProfile.add("cr_glue", _pt)
		_pt = Time.get_ticks_usec()
	var stride: int = LACreatureLod.think_stride(self)
	var do_think: bool = _force_think or ((int(Engine.get_physics_frames()) + _think_phase) % stride == 0)
	if do_think:
		LASimReport.event("decision")   # telemetry: discretionary decisions/run — proves the AI-tick stride knob bites
		var desired: Vector3 = _heading
		_wander_timer -= delta
		_veto_timer -= delta
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
		if bond != null and bond.is_commanded():
			var cmv: Dictionary = LACreatureThink.execute_action(self, bond.command(), pos, delta)
			if cmv.has("heading"):
				desired = cmv["heading"]
			state = String(cmv.get("state", state))
			eff_speed = float(cmv.get("speed", eff_speed))
		elif _panic_timer > 0.0:
			# TERROR: sprint straight away from what was heard/felt. Overrides everything.
			state = "panic"
			var away: Vector3 = pos - _panic_source
			away = away - up * away.dot(up)      # keep the flee in the local tangent plane
			if away.length() > 0.001:
				desired = away.normalized()
			eff_speed = speed * 2.1
			_emit_call("alarm")                          # screech so unseeing herd-mates also bolt
		else:
			# Did a cognition decision run THIS tick (leader decide() OR follower learn_and_veto)? Gates the
			# shared veto-retreat below so a stale veto from a past tick never hijacks a flee/drink frame.
			var cognized: bool = false
			# Universal, emergent: flee any nearby larger hunter first (no hardcoded pairs).
			var big_pred: Node3D = LACreatureSenses.nearest_larger_predator(self, pos)
			if big_pred != null:
				state = "flee"
				var away: Vector3 = pos - big_pred.global_position
				away = away - up * away.dot(up)  # keep the flee in the local tangent plane
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
					var la: String = LACreatureThink._adoptable_action(
							LACreatureThink.state_to_action(_leader, _leader.state), self)
					if _cognition != null and state != "roost" and state != "nesting":
						var sig_f: Dictionary = LASituationSignature.compute(self)
						la = _cognition.learn_and_veto(self, la, sig_f, delta)
						cognized = true
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

			desired = LACreatureChemSense.steer(self, pos, desired)

			if LACreatureReproduction.should_seek_mate(self):
				desired = LACreatureReproduction.courtship_heading(self, pos, desired)

			# Nesting/roosting drive (ANY nesting species, config-driven): head home to roost at night
			# or to breed, establishing the site the first time. Offspring inherit it (philopatry).
			if nests and LACreatureNesting.should_seek_nest(self):
				desired = _handle_nesting(pos, desired)
				if state == "sleep":
					eff_speed = speed * 0.05          # barely stir while sleeping at the nest

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
				cognized = true

			if cognized and _cognition.was_vetoed():
				if _veto_timer <= 0.0:
					# Dominant learned-lethal case is water (drowning): retreat to DRY LAND (opposite the nearest
					# water). No water sensed -> back out the way it came (reverse heading). Latched, anti-oscillation.
					var wdir: Vector3 = LACreatureThirst.find_water_dir(self, pos)
					_veto_dir = (-wdir) if wdir.length() > 0.001 else (-_heading)
					_veto_timer = randf_range(1.5, 2.5)
				if _veto_dir.length() > 0.001:
					desired = _veto_dir
					eff_speed = speed

			if big_pred == null and _wander_timer <= 0.0:
				_wander_timer = randf_range(1.2, 3.0)
				var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0) * 0.6
				desired = (desired + jitter)

			if big_pred == null and _panic_timer <= 0.0 and lactate > 0.45 and energy > max_energy * 0.35 \
					and (state == "wander" or state == "flock" or state == "migrate"):
				state = "rest"
				eff_speed = speed * 0.08

		desired = desired - up * desired.dot(up)   # decided heading lives in the local tangent plane
		if desired.length() > 0.001:
			_target_heading = desired.normalized()
			if _force_think:
				_heading = _target_heading
		# Muscle lactate caps top speed — a winded animal can't keep sprinting, so it must recover. Biological, not
		# a game meter: exertion earlier this frame built the lactate that now throttles it.
		_eff_speed = eff_speed * (1.0 - 0.5 * lactate)   # carry this decision to the movement of the next few frames
		_force_think = false

	if prof:
		LACreatureProfile.add("cr_think", _pt)
		_pt = Time.get_ticks_usec()
	LACreatureLocomotion.move(self, pos, ground_pos, delta)
	if prof:
		LACreatureProfile.add("cr_move", _pt)

	LACreatureLocomotion.face_heading(self)

	# Behavior-state debug tint: repaint iff my category changed (free early-out when no highlights on).
	LACreatureTint.update(self)


func _rest_period() -> bool:
	if _ecology == null or not _ecology.has_method("is_night_at"):
		return false
	return _ecology.is_night_at(global_position) != nocturnal


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


func hear_call(source_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	match call_type:
		"alarm":
			add_fear(source_pos, 1.2)
		"distress":
			add_fear(source_pos, 0.8)
		"forage":
			if from_species == species and _cognition != null:
				# LINEAGE, not band: a forage call teaches harder when it comes from a RELATIVE, and that is a
				# fact about descent, so it reads through the lineage half of the affiliation seam.
				var kin: bool = caller != null and caller.has_method("get_family_id") \
						and LACreatureAffiliation.neighbour_lineage(caller) == LACreatureAffiliation.lineage_of(self)
				var rel: float = 1.0 if kin else 0.35
				_cognition.learn_from_sound(self, _forage_action(), rel)
		"carrion":
			# A scavenger announced a carcass: any non-herbivore remembers it as a cue to investigate,
			# so it can converge on the kill even without seeing the vultures (sound past line of sight).
			if diet != "herbivore":
				_cue_pos = source_pos
				_cue_cd = 12.0


func is_hunter() -> bool:
	return diet == "carnivore" or (diet == "omnivore" and preys_on.size() > 0)


# Thin forwarder — life-stage/maturity logic lives in LACreatureLifeStage (Phase 2: graded stages).
func is_mature() -> bool:
	return LACreatureLifeStage.is_mature(self)


# Inspector presentation lives in LACreatureInspector; this stays as the group-facing hook.
func get_inspector_payload() -> Dictionary:
	if _carcass:
		return LACreatureRagdoll.inspector_payload(self)
	return LACreatureInspector.payload(self)


# A scavenger takes a bite of the carcass; returns the energy actually removed.
func feed(amount: float) -> float:
	return LACreatureRagdoll.feed(self, amount)


# What this body is worth as food. Meat once a carcass; live creatures are hunted, not foraged.
func food_profile() -> Dictionary:
	return LACreatureRagdoll.food_profile(self)


# Remaining meat mass in the carcass.
func nutrition() -> float:
	return _carrion


func body_mass() -> float:
	return _carrion if _dead else LACreatureBodyMass.body_mass(self)


func draw_body_mass(want: float) -> float:
	if _dead:
		return LACreatureRagdoll.feed(self, want)
	return LACreatureBodyMass.draw(self, want)
