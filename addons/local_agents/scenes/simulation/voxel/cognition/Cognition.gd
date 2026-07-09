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

# --- multi-sense reward valence (Half A) --------------------------------------------------------
# The reinforcement reward is a general valence SUM, not just "did I eat/drink". Energy + hydration
# gains stay primary (the appetitive drive); on top of that we SUBTRACT the discomfort/pain the last
# action brought — HP lost, a spike of fear (predator proximity), running low on breath in my medium
# (drowning/suffocation), or sitting outside my temperature comfort band. So a creature learns to
# avoid predators, cold, and water the SAME way it already learned to seek food: whatever action
# preceded pain earns a negative weight and stops being chosen. Weights are tunable; no per-species code.
const W_DAMAGE: float = 6.0                # aversion per unit of fractional HP lost since the last decision
const W_FEAR: float = 0.25                 # aversion per unit rise in the panic/fear level (predator dread)
const W_O2: float = 1.0                    # aversion for being fully out of breath in my medium (suffocating)
const W_TEMP: float = 0.03                 # aversion per °C outside the comfort band (cold snap / heat)
const TERM_CAP: float = 1.0                # clamp on each individual aversive term so one sense can't dominate

# --- drive-modulated risk tolerance (Half B) ----------------------------------------------------
# Each learned entry also remembers how much that action HURT (its aversive magnitude) separate from its
# net worth, so a driven creature can knowingly discount that pain. RISK_RETAIN fades the memory when the
# action stops hurting; RISK_TOLERANCE is how much of the (drive-scaled) remembered pain is added back to
# the entry's effective weight at decision time — a starving/parched creature discounts discomfort and
# attempts the risky-but-rewarding action; a sated one applies the full aversion and refuses it.
const RISK_RETAIN: float = 0.7             # how much remembered pain carries frame-to-frame (rest decays)
const RISK_MAX: float = 2.0               # ceiling on remembered pain per entry
const RISK_TOLERANCE: float = 1.3          # how strongly hunger/thirst buys back an aversive action

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

# previous discretionary decision, kept so we can reinforce it once its outcome is visible. The extra
# senses (health/fear/breath/temp) are snapshotted alongside energy/hydration so the next reinforce can
# measure how the FULL welfare of the creature changed since the action — not just whether it fed.
var _last_key: int = -1
var _last_action: String = ""
var _last_energy: float = -1.0
var _last_hydration: float = -1.0
var _last_health: float = -1.0            # HP at the last decision — a drop since = damage taken (aversive)
var _last_fear: float = 0.0               # panic/fear level at the last decision — a rise since = dread (aversive)
var _last_o2: float = 1.0                 # breath fraction (0..1) at the last decision — low = suffocating
var _last_temp: float = 15.0             # ambient °C at the last decision — outside comfort band = discomfort

# lifetime stats (surfaced to the inspector + harness)
var escalations: int = 0
var decisions: int = 0
var lessons: int = 0                       # heuristics acquired socially

# Introspection for the thought inspector. These SURFACE the real decision — they do NOT run any model.
#   _last_choice : the most recent fast-path pick (every decide) + how it was reached.
#   _last_ask    : the most recent slow-brain resolution written back by the shared scheduler, tagged
#                  with its source ("llm" = the local FunctionGemma model chose it; "teacher" = the
#                  offline heuristic teacher). This is the natural-language "thought" the panel stars.
var _last_choice: Dictionary = {}          # {action, how, e, h, w, n}   how: reflex|habit|instinct
var _last_ask: Dictionary = {}             # {action, source, e, h, w, n}   source: llm|teacher


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
		_record_choice(innate_action, "reflex", sig)
		return innate_action

	_cooldown = maxf(0.0, _cooldown - delta)
	var key: int = int(sig.get("key", -1))

	# Sample the full sense state ONCE this decision (health/fear/breath/temp) and reinforce the PREVIOUS
	# decision from how that whole welfare changed since — not just energy/hydration.
	var senses: Dictionary = _sample_senses(c)
	_reinforce(c, senses)

	decisions += 1
	var learned = policy.get(key, null)
	var chosen: String = innate_action
	if learned != null:
		# RISK TOLERANCE (Half B): the entry's remembered pain (`risk`) is discounted by how urgently this
		# creature is driven (hunger/thirst), then added back to its net weight. A well-fed animal sees the
		# full aversion (weight stays sub-threshold → it refuses the risky action); a starving/parched one
		# discounts the pain, tipping the same action over the threshold → it attempts the risky-but-rewarding
		# move (wade into cold water to reach food). Reflexes never reach here — they returned above.
		var w: float = float((learned as Dictionary).get("weight", 0.0))
		var risk: float = float((learned as Dictionary).get("risk", 0.0))
		var eff: float = w + risk * _drive_urgency(c) * RISK_TOLERANCE
		if eff >= CONFIDENCE_THRESHOLD:
			var la: String = String((learned as Dictionary).get("action", ""))
			if LAActionRegistry.is_valid(la):
				chosen = la
		elif _should_escalate(c, learned):
			_escalate(c, sig, innate_action)
	elif _should_escalate(c, null):
		_escalate(c, sig, innate_action)

	_record_choice(chosen, "habit" if chosen != innate_action else "instinct", sig)
	_last_key = key
	_last_action = chosen
	_last_energy = c.energy
	_last_hydration = c.hydration
	_last_health = float(senses.get("health", c.health))
	_last_fear = float(senses.get("fear", 0.0))
	_last_o2 = float(senses.get("o2", 1.0))
	_last_temp = float(senses.get("temp", _last_temp))
	return chosen


# Snapshot the current fast-path pick so the thought inspector can phrase it. Cheap; no allocation churn.
func _record_choice(action: String, how: String, sig: Dictionary) -> void:
	_last_choice = {
		"action": action, "how": how,
		"e": int(sig.get("e", 2)), "h": int(sig.get("h", 3)),
		"w": int(sig.get("w", 0)), "n": int(sig.get("n", 0)),
	}


## Sample the creature's full welfare senses right now. Cheap O(1) scalar reads (+ one field temp probe);
## called once per decision, which is already throttled — no per-frame or neighbour scan. Returns
## {health, fear, o2, temp}: HP, the panic/fear level, the breath fraction in-medium, and ambient °C.
func _sample_senses(c) -> Dictionary:
	var o2: float = 1.0
	if c.breath_capacity > 0.0:
		o2 = clampf(c._breath / c.breath_capacity, 0.0, 1.0)
	var temp: float = _last_temp
	if c._material != null and c._material.has_method("temp_at"):
		temp = c._material.temp_at(c.global_position)
	return {"health": c.health, "fear": c._panic_timer, "o2": o2, "temp": temp}


## Reward the last action by how the creature's WHOLE welfare changed since (Half A). Energy + hydration
## gains are the primary appetitive drive; on top we subtract the discomfort it brought — HP lost, a rise
## in fear, running out of breath, or sitting outside the comfort band — so the animal learns to avoid
## predators/cold/drowning exactly as it learns to eat. The aversive magnitude is ALSO stored per entry
## (`risk`) so Half B's decision can discount it by drive. `senses` is the fresh snapshot from decide().
func _reinforce(c, senses: Dictionary) -> void:
	if _last_key < 0 or _last_action == "":
		return
	var de: float = 0.0
	if c.max_energy > 0.0:
		de = (c.energy - _last_energy) / c.max_energy
	var dh: float = 0.0
	if c.max_hydration > 0.0:
		dh = (c.hydration - _last_hydration) / c.max_hydration
	var appetitive: float = (de + dh) * 8.0

	# Aversive senses (each >= 0, individually capped so one can't swamp the sum).
	var aversive: float = 0.0
	# Damage: fraction of HP lost since the last decision.
	if c.max_health > 0.0:
		var dhp: float = (_last_health - float(senses.get("health", c.health))) / c.max_health
		aversive += clampf(maxf(0.0, dhp) * W_DAMAGE, 0.0, TERM_CAP)
	# Fear: a rise in the panic/dread level (predator proximity, felt violence).
	var dfear: float = float(senses.get("fear", 0.0)) - _last_fear
	aversive += clampf(maxf(0.0, dfear) * W_FEAR, 0.0, TERM_CAP)
	# Suffocation: low breath in my medium over the interval (drowning / smoke / beached gills).
	var breath_frac: float = minf(_last_o2, float(senses.get("o2", 1.0)))
	aversive += clampf((1.0 - breath_frac) * W_O2, 0.0, TERM_CAP)
	# Temperature: the worst deviation outside the comfort band across the interval (cold snap / heat).
	var dev: float = maxf(_comfort_deviation(_last_temp), _comfort_deviation(float(senses.get("temp", _last_temp))))
	aversive += clampf(dev * W_TEMP, 0.0, TERM_CAP)

	var reward: float = clampf(appetitive - aversive, -1.0, 1.0)
	var entry = policy.get(_last_key, null)
	if entry == null or String((entry as Dictionary).get("action", "")) != _last_action:
		policy[_last_key] = {"action": _last_action, "weight": START_WEIGHT, "risk": 0.0}
		entry = policy[_last_key]
	var w: float = float((entry as Dictionary)["weight"]) + reward * LEARN_RATE
	(entry as Dictionary)["weight"] = clampf(w, MIN_WEIGHT, MAX_WEIGHT)
	# Remember the pain alone (Half B): fades when the action stops hurting, so stale aversion doesn't stick.
	var prev_risk: float = float((entry as Dictionary).get("risk", 0.0))
	(entry as Dictionary)["risk"] = clampf(prev_risk * RISK_RETAIN + aversive, 0.0, RISK_MAX)


# How far `t` (°C) lies outside the comfort band [COOL, WARM]; 0 inside. Reuses the metabolism band so the
# discomfort the body actually suffers and the aversion the mind learns are the SAME threshold (no drift).
func _comfort_deviation(t: float) -> float:
	if t > LACreatureMetabolism.WARM_COMFORT:
		return t - LACreatureMetabolism.WARM_COMFORT
	if t < LACreatureMetabolism.COOL_COMFORT:
		return LACreatureMetabolism.COOL_COMFORT - t
	return 0.0


# Drive urgency in [0,1]: how hard hunger OR thirst is pushing this creature right now (fractional deficit).
# This is what discounts remembered pain in decide() — the hungrier/thirstier, the more risk it will accept.
func _drive_urgency(c) -> float:
	var hunger: float = 0.0
	if c.max_energy > 0.0:
		hunger = clampf(1.0 - c.energy / c.max_energy, 0.0, 1.0)
	var thirst: float = 0.0
	if c.max_hydration > 0.0:
		thirst = clampf(1.0 - c.hydration / c.max_hydration, 0.0, 1.0)
	return maxf(hunger, thirst)


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


## Called back by the scheduler when the slow brain resolves an escalation for `key`. Trusted enough to
## override immediately (seeded above the confidence threshold), then tuned by reinforcement. `source`
## records WHO decided ("llm" = the local FunctionGemma model; "teacher" = the offline heuristic) and
## `sig` carries the situation so the thought inspector can phrase the decision — pure surfacing, no
## second model path.
func apply_llm_result(key: int, action: String, source: String = "llm", sig: Dictionary = {}) -> void:
	_pending = false
	if not LAActionRegistry.is_valid(action):
		return
	policy[key] = {"action": action, "weight": LLM_SEED_WEIGHT}
	_last_ask = {
		"action": action, "source": source,
		"e": int(sig.get("e", 2)), "h": int(sig.get("h", 3)),
		"w": int(sig.get("w", 0)), "n": int(sig.get("n", 0)),
	}


func on_llm_failed() -> void:
	_pending = false


# --- thought-inspector introspection (read-only; surfaces the real decision, never calls a model) ---

func last_choice() -> Dictionary:
	return _last_choice


func last_ask() -> Dictionary:
	return _last_ask


## True while this creature has a slow-brain escalation in flight — the panel shows "asking the model…".
func is_thinking() -> bool:
	return _pending


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
			var demo_w: float = float((e as Dictionary).get("weight", 0.0))
			if demo_w < CONFIDENCE_THRESHOLD:
				continue                              # only imitate behaviours they're confident in
			_absorb_observation(int(key), String((e as Dictionary).get("action", "")), rel, demo_w)
		# Also inherit their confident CUE associations — this is how "watch the vultures" spreads
		# culturally: a youngster copies which signs mean food from the elders it grows up watching.
		for ck in mc.cue_values.keys():
			var demo_cv: float = float(mc.cue_values[ck])
			if demo_cv < CONFIDENCE_THRESHOLD:
				continue
			var cgain: float = rel * OBSERVE_TRANSFER * _confidence_mult(demo_cv)
			cue_values[ck] = clampf(cue_value(String(ck)) + cgain, CUE_MIN, CUE_MAX)


# Situational learning rate: you learn a thing FASTER the more sure the animal you're watching is —
# a confident demonstrator is proof it's "correct", worth far more than fumbling it yourself. Scales
# ~1x at the confidence threshold up to ~3x for a fully-ingrained expert.
func _confidence_mult(demo_weight: float) -> float:
	var t: float = clampf((demo_weight - CONFIDENCE_THRESHOLD) / maxf(0.001, MAX_WEIGHT - CONFIDENCE_THRESHOLD), 0.0, 1.0)
	return 1.0 + t * 2.0


func _absorb_observation(key: int, action: String, rel: float, demo_weight: float) -> void:
	if not LAActionRegistry.is_valid(action):
		return
	# Watching a confident demonstrator (they clearly know it's right) beats trial-and-error, so the
	# uptake scales with how sure they are — situational learning rate.
	var gain: float = rel * OBSERVE_TRANSFER * _confidence_mult(demo_weight)
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
	# A deliberate call is a clear demonstration — treat it as a moderately confident teacher.
	_absorb_observation(int(sig.get("key", -1)), action, rel, 2.0)


# --- learned CUE associations (emergent "watch the vultures", nothing hardcoded) -------------------
# A creature treats other animals as cues to resources. cue_values maps a generic cue key (e.g. the
# observed animal's "species:state") to a learned worth. The creature is NEVER told which cue means
# food — it discovers it: investigate a cue, and if food follows, the cue's value is reinforced; if
# not, it decays. Useful associations (like circling scavengers → a carcass) emerge and, via observe(),
# spread to kin. This is the same reward machinery as the rest of cognition, one level up (about the
# world's signs rather than one's own actions).
const CUE_LEARN_RATE: float = 0.5
const CUE_MAX: float = 4.0
const CUE_MIN: float = -2.0
var cue_values: Dictionary = {}

func cue_value(key: String) -> float:
	return float(cue_values.get(key, 0.0))

func reinforce_cue(key: String, reward: float) -> void:
	if key == "":
		return
	cue_values[key] = clampf(float(cue_values.get(key, 0.0)) + reward * CUE_LEARN_RATE, CUE_MIN, CUE_MAX)


func policy_size() -> int:
	return policy.size()
