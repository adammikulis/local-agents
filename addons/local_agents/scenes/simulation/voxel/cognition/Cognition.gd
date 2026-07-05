class_name LACognition
extends RefCounted

## The per-creature "brain" that sits on top of the innate cascade. Each tick a creature reports the
## action its innate rules picked plus its cheap situation signature; this object decides whether a
## *learned heuristic* should override that choice, reinforces the previous choice by how the
## creature has fared since, and — rarely, when uncertain — escalates to the slow brain
## (FunctionGemma) via the shared scheduler.
##
## Thinking fast and slow:
##   * Fast (this class, every tick): a dictionary lookup + a weighted comparison. No LLM.
##   * Slow (scheduler, budgeted/async): FunctionGemma picks an action for a novel/uncertain
##     signature; the result is written back as a high-confidence heuristic so the next time that
##     signature recurs it is handled by the fast path. A creature escalates less as it ages.
##
## How discretionary behaviour spreads (NOT by inheriting a parent's thoughts):
##   * SOCIAL learning — the main channel. A creature copies confident heuristics from same-species
##     animals it can SEE (vision cone), weighted by relatedness (family/kin strongest). Habits
##     diffuse through a herd the way flocking already does (imitation).
##   * GENETIC priors — a small baked instinct set from the genome (see LAGenome), evolving slowly.
##   * Survival reflexes (flee/panic/thirst) are innate in the cascade and never learned/overridden.
##
## policy: signature_key:int -> {action:String, weight:float}
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const CONFIDENCE_THRESHOLD: float = 1.0    # a learned entry must reach this to override the innate rules
const START_WEIGHT: float = 0.4            # confidence of a freshly self-observed heuristic
const LLM_SEED_WEIGHT: float = 2.0         # slow-brain decisions are trusted enough to act on at once
const MAX_WEIGHT: float = 6.0
const MIN_WEIGHT: float = -2.0
const LEARN_RATE: float = 0.6

# Social learning: how much one sighting of a confident neighbour shifts my confidence, by relatedness.
const KIN_RELATEDNESS: float = 1.0
const SPECIES_RELATEDNESS: float = 0.35
const OBSERVE_TRANSFER: float = 0.3
const OBSERVE_MAX_NEIGHBOURS: int = 6      # cap the per-observation scan for performance

var policy: Dictionary = {}

var _sched = null                          # LACognitionScheduler (shared; injected)
var _pending: bool = false                 # an LLM request is in flight for this creature
var _cooldown: float = 0.0                 # seconds until this creature may escalate again
var _observe_cd: float = 0.0               # throttles the social-learning scan

# previous discretionary decision, kept so we can reinforce it once its outcome is visible
var _last_key: int = -1
var _last_action: String = ""
var _last_energy: float = -1.0
var _last_hydration: float = -1.0

# lifetime stats (surfaced to the inspector + harness)
var escalations: int = 0
var decisions: int = 0
var lessons: int = 0                       # heuristics acquired socially


func set_scheduler(s) -> void:
	_sched = s


## Pre-load the policy with the genetic instinct priors this individual was born with.
func seed_from_genome(genome) -> void:
	if genome == null:
		return
	for key in genome.instincts.keys():
		var e: Dictionary = genome.instincts[key]
		policy[key] = {"action": String(e.get("action", "")), "weight": float(e.get("weight", 0.0))}


## Decide the action to actually take, given the innate cascade's pick and the current signature.
## Returns an action name from LAActionRegistry. Reflex actions (flee) are never second-guessed.
func decide(c, innate_action: String, sig: Dictionary, delta: float) -> String:
	if LAActionRegistry.is_reflex(innate_action):
		return innate_action

	_cooldown = maxf(0.0, _cooldown - delta)
	var key: int = int(sig.get("key", -1))

	# Reinforce the *previous* discretionary decision from how energy/hydration changed since.
	_reinforce(c)

	decisions += 1
	var learned = policy.get(key, null)
	var chosen: String = innate_action
	if learned != null and float((learned as Dictionary).get("weight", 0.0)) >= CONFIDENCE_THRESHOLD:
		var la: String = String((learned as Dictionary).get("action", ""))
		if LAActionRegistry.is_valid(la):
			chosen = la
	else:
		if _should_escalate(c, learned):
			_escalate(c, sig, innate_action)

	_last_key = key
	_last_action = chosen
	_last_energy = c.energy
	_last_hydration = c.hydration
	return chosen


## Reward the last action by whether the creature is better off (ate / drank / stayed healthy).
func _reinforce(c) -> void:
	if _last_key < 0 or _last_action == "":
		return
	var de: float = 0.0
	if c.max_energy > 0.0:
		de = (c.energy - _last_energy) / c.max_energy
	var dh: float = 0.0
	if c.max_hydration > 0.0:
		dh = (c.hydration - _last_hydration) / c.max_hydration
	var reward: float = clampf((de + dh) * 8.0, -1.0, 1.0)
	var entry = policy.get(_last_key, null)
	if entry == null or String((entry as Dictionary).get("action", "")) != _last_action:
		policy[_last_key] = {"action": _last_action, "weight": START_WEIGHT}
		entry = policy[_last_key]
	var w: float = float((entry as Dictionary)["weight"]) + reward * LEARN_RATE
	(entry as Dictionary)["weight"] = clampf(w, MIN_WEIGHT, MAX_WEIGHT)


func _should_escalate(c, learned) -> bool:
	if _sched == null or _pending or _cooldown > 0.0:
		return false
	if learned == null:
		return true                                   # never-seen situation
	var w: float = float((learned as Dictionary).get("weight", 0.0))
	var pressed: bool = c.energy < c.max_energy * 0.4 or c.hydration < c.max_hydration * 0.4
	return w < 0.2 and pressed


func _escalate(c, sig: Dictionary, innate_action: String) -> void:
	if not _sched.request(c, self, sig, innate_action):
		return
	_pending = true
	_cooldown = 6.0
	escalations += 1


## Called back by the scheduler when FunctionGemma returns an action for `key`. Trusted enough to
## override immediately (seeded above the confidence threshold), then tuned by reinforcement.
func apply_llm_result(key: int, action: String) -> void:
	_pending = false
	if not LAActionRegistry.is_valid(action):
		return
	policy[key] = {"action": action, "weight": LLM_SEED_WEIGHT}


func on_llm_failed() -> void:
	_pending = false


## SOCIAL LEARNING: copy confident heuristics from same-species creatures this one can SEE, weighted
## by relatedness. Throttled and neighbour-capped so it stays cheap. Called by the creature each tick.
func observe(c, delta: float) -> void:
	_observe_cd -= delta
	if _observe_cd > 0.0:
		return
	_observe_cd = randf_range(1.5, 3.0)
	var group: String = "species_" + String(c.species)
	var seen: int = 0
	for m in c.get_tree().get_nodes_in_group(group):
		if seen >= OBSERVE_MAX_NEIGHBOURS:
			break
		if m == c or not is_instance_valid(m) or not (m is Node3D):
			continue
		if not LAVision.sees_node(c, m):
			continue                                  # only learn from herd-mates you actually see
		var mc = null
		if m.has_method("get_cognition"):
			mc = m.get_cognition()
		if mc == null:
			continue
		seen += 1
		var kin: bool = int(m.get("family_id")) == int(c.family_id)
		var rel: float = KIN_RELATEDNESS if kin else SPECIES_RELATEDNESS
		for key in mc.policy.keys():
			var e = mc.policy[key]
			if float((e as Dictionary).get("weight", 0.0)) < CONFIDENCE_THRESHOLD:
				continue                              # only imitate behaviours they're confident in
			_absorb_observation(int(key), String((e as Dictionary).get("action", "")), rel)


func _absorb_observation(key: int, action: String, rel: float) -> void:
	if not LAActionRegistry.is_valid(action):
		return
	var gain: float = rel * OBSERVE_TRANSFER
	var entry = policy.get(key, null)
	if entry == null:
		policy[key] = {"action": action, "weight": START_WEIGHT + gain}
		lessons += 1
	elif String((entry as Dictionary)["action"]) == action:
		(entry as Dictionary)["weight"] = clampf(float((entry as Dictionary)["weight"]) + gain, MIN_WEIGHT, MAX_WEIGHT)
	else:
		# They do something different: erode my confidence; if kin are insistent, adopt their way.
		var w: float = float((entry as Dictionary)["weight"]) - gain * 0.5
		if w < START_WEIGHT * 0.5 and rel >= KIN_RELATEDNESS:
			policy[key] = {"action": action, "weight": START_WEIGHT}
			lessons += 1
		else:
			(entry as Dictionary)["weight"] = w


# Sound-based social learning: a heard call (e.g. a kin's forage cry) nudges my policy for MY
# current situation toward `action`, weighted by relatedness — carries past the vision cone.
func learn_from_sound(c, action: String, rel: float) -> void:
	var sig: Dictionary = LASituationSignature.compute(c)
	_absorb_observation(int(sig.get("key", -1)), action, rel)


func policy_size() -> int:
	return policy.size()
