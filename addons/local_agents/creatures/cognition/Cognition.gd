class_name LACognition
extends RefCounted


const CONFIDENCE_THRESHOLD: float = 1.0    # a learned entry must reach this to override the innate rules
const START_WEIGHT: float = 0.4            # confidence of a freshly self-observed heuristic
const LLM_SEED_WEIGHT: float = 2.0         # slow-brain decisions are trusted enough to act on at once
const MAX_WEIGHT: float = 6.0
const MIN_WEIGHT: float = -2.0
const LEARN_RATE: float = 0.6

const W_DAMAGE: float = 6.0                # aversion per unit of fractional HP lost since the last decision
const W_FEAR: float = 0.25                 # aversion per unit rise in the panic/fear level (predator dread)
const W_O2: float = 1.0                    # aversion for being fully out of breath in my medium (suffocating)
const W_TEMP: float = 1.0                  # aversion at a temperature where metabolism stops entirely (freezing
                                           # or protein denaturation). Was 0.03 per °C outside a comfort band;
                                           # _comfort_deviation is now a bounded 0..1 shortfall of the body's
                                           # own reaction rate, so the weight is on the same scale as W_O2.
const TERM_CAP: float = 1.0                # clamp on each individual aversive term so one sense can't dominate

const RISK_RETAIN: float = 0.7             # how much remembered pain carries frame-to-frame (rest decays)
const RISK_MAX: float = 2.0               # ceiling on remembered pain per entry
const RISK_TOLERANCE: float = 1.3          # how strongly hunger/thirst buys back an aversive action
const RISK_REVIVE_FLOOR: float = -1.0

const VETO_WEIGHT: float = RISK_REVIVE_FLOOR
const SAFE_FALLBACK_ACTION: String = "wander"   # the always-available benign roam a veto redirects to
const AVERSION_SHARE: float = -0.6

# Social learning: how much one sighting of a confident neighbour shifts my confidence, by relatedness.
const KIN_RELATEDNESS: float = 1.0
const SPECIES_RELATEDNESS: float = 0.35
const OBSERVE_TRANSFER: float = 0.3
const OBSERVE_MAX_NEIGHBOURS: int = 6      # cap the per-observation scan for performance

var policy: Dictionary = {}

var _sched = null                          # LocalAgentCognitionScheduler (shared; injected)
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
var _last_veto: bool = false             # did the last decide() REFUSE a learned-lethal action? (Creature reads this to retreat)
var _last_was_fallback: bool = false     # was _last_action a veto REDIRECT (not a free choice)? gates the durability guard

# lifetime stats (surfaced to the inspector + harness)
var escalations: int = 0
var decisions: int = 0
var lessons: int = 0                       # heuristics acquired socially
var vetoes: int = 0                        # times this brain REFUSED a learned-lethal action (Half C, surfaced to harness)

var _last_choice: Dictionary = {}          # {action, how, e, h, w, n}   how: reflex|habit|instinct
var _last_ask: Dictionary = {}             # {action, source, e, h, w, n}   source: llm|teacher

const HISTORY_CAP: int = 40
var _history: Array = []

func _push_history(kind: String, action: String, how: String, sig: Dictionary) -> void:
	if not _history.is_empty():
		var prev: Dictionary = _history[-1]
		if String(prev.get("kind", "")) == kind and String(prev.get("action", "")) == action:
			return                                  # no real change — don't spam the stream
	_history.append({
		"ts": Time.get_ticks_msec(), "kind": kind, "action": action, "how": how,
		"e": int(sig.get("e", 2)), "h": int(sig.get("h", 3)),
	})
	if _history.size() > HISTORY_CAP:
		_history.pop_front()

## The bounded decision history for the thought-inspector's "stream" — read-only, oldest first.
func history() -> Array:
	return _history


func set_scheduler(s) -> void:
	_sched = s


## The shared slow-brain scheduler (LocalAgentCognitionScheduler), or null. Surfaced so the creature's highlight can
## ask the scheduler whether it is currently thinking/queued (read-only; starts no model path).
func scheduler():
	return _sched


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
	_last_veto = false
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
		var w: float = float((learned as Dictionary).get("weight", 0.0))
		var risk: float = float((learned as Dictionary).get("risk", 0.0))
		var eff: float = w
		if w > RISK_REVIVE_FLOOR:                       # never revive an action learned as reliably lethal
			eff += risk * _drive_urgency(c) * RISK_TOLERANCE
		if eff >= CONFIDENCE_THRESHOLD:
			var la: String = String((learned as Dictionary).get("action", ""))
			if LAActionRegistry.is_valid(la):
				chosen = la
		elif _should_escalate(c, learned):
			_escalate(c, sig, innate_action)
	elif _should_escalate(c, null):
		_escalate(c, sig, innate_action)

	chosen = _apply_veto(chosen, innate_action, learned)

	_record_choice(chosen, "habit" if chosen != innate_action else "instinct", sig)
	_snapshot(c, key, chosen, senses)
	return chosen


func learn_and_veto(c, action: String, sig: Dictionary, delta: float) -> String:
	_last_veto = false
	if LAActionRegistry.is_reflex(action):
		_record_choice(action, "reflex", sig)
		return action

	var key: int = int(sig.get("key", -1))

	# Sample the full sense state ONCE and reinforce the PREVIOUS action from how the whole welfare changed
	# since — identical machinery to decide(), just without the expensive assessment that follows it there.
	var senses: Dictionary = _sample_senses(c)
	_reinforce(c, senses)

	decisions += 1
	var learned = policy.get(key, null)
	var chosen: String = _apply_veto(action, action, learned)
	_record_choice(chosen, "habit" if chosen != action else "instinct", sig)
	_snapshot(c, key, chosen, senses)
	return chosen


func _apply_veto(chosen: String, innate_action: String, learned) -> String:
	if chosen == innate_action and learned != null \
			and String((learned as Dictionary).get("action", "")) == innate_action \
			and float((learned as Dictionary).get("weight", 0.0)) <= VETO_WEIGHT:
		_last_veto = true
		vetoes += 1
		return _safe_fallback(innate_action)
	return chosen


## Snapshot this decision's key/action + the full welfare senses, so the NEXT tick's _reinforce can measure
## how the whole welfare changed since. Shared by decide() and learn_and_veto() so leaders and followers keep
## a consistent last-decision record even as a creature flips between leading and following.
func _snapshot(c, key: int, chosen: String, senses: Dictionary) -> void:
	_last_key = key
	_last_action = chosen
	_last_was_fallback = _last_veto     # capture whether THIS decision was a veto redirect (survives the reset next tick)
	_last_energy = LACognizerAdapter.energy(c)
	_last_hydration = LACognizerAdapter.hydration(c)
	_last_health = float(senses.get("health", LACognizerAdapter.health(c)))
	_last_fear = float(senses.get("fear", 0.0))
	_last_o2 = float(senses.get("o2", 1.0))
	_last_temp = float(senses.get("temp", _last_temp))


# Snapshot the current fast-path pick so the thought inspector can phrase it. Cheap; no allocation churn.
func _record_choice(action: String, how: String, sig: Dictionary) -> void:
	_last_choice = {
		"action": action, "how": how,
		"e": int(sig.get("e", 2)), "h": int(sig.get("h", 3)),
		"w": int(sig.get("w", 0)), "n": int(sig.get("n", 0)),
	}
	_push_history("fast", action, how, sig)


## Sample the creature's full welfare senses right now. Cheap O(1) scalar reads (+ one field temp probe);
## called once per decision, which is already throttled — no per-frame or neighbour scan. Returns
## {health, fear, o2, temp}: HP, the panic/fear level, the breath fraction in-medium, and ambient °C.
func _sample_senses(c) -> Dictionary:
	return LACognizerAdapter.senses(c, _last_temp)


func _reinforce(c, senses: Dictionary) -> void:
	if _last_key < 0 or _last_action == "":
		return
	var de: float = 0.0
	var me: float = LACognizerAdapter.max_energy(c)
	if me > 0.0:
		de = (LACognizerAdapter.energy(c) - _last_energy) / me
	var dh: float = 0.0
	var mh: float = LACognizerAdapter.max_hydration(c)
	if mh > 0.0:
		dh = (LACognizerAdapter.hydration(c) - _last_hydration) / mh
	var appetitive: float = (de + dh) * 8.0

	# Aversive senses (each >= 0, individually capped so one can't swamp the sum).
	var aversive: float = 0.0
	# Damage: fraction of HP lost since the last decision.
	var mhp: float = LACognizerAdapter.max_health(c)
	if mhp > 0.0:
		var dhp: float = (_last_health - float(senses.get("health", LACognizerAdapter.health(c)))) / mhp
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
	if entry != null and String((entry as Dictionary).get("action", "")) != _last_action \
			and _last_was_fallback \
			and float((entry as Dictionary).get("weight", 0.0)) <= VETO_WEIGHT:
		return
	if entry == null or String((entry as Dictionary).get("action", "")) != _last_action:
		policy[_last_key] = {"action": _last_action, "weight": START_WEIGHT, "risk": 0.0}
		entry = policy[_last_key]
	var w: float = float((entry as Dictionary)["weight"]) + reward * LEARN_RATE
	(entry as Dictionary)["weight"] = clampf(w, MIN_WEIGHT, MAX_WEIGHT)
	# Remember the pain alone (Half B): fades when the action stops hurting, so stale aversion doesn't stick.
	var prev_risk: float = float((entry as Dictionary).get("risk", 0.0))
	(entry as Dictionary)["risk"] = clampf(prev_risk * RISK_RETAIN + aversive, 0.0, RISK_MAX)


func _comfort_deviation(t: float) -> float:
	return 1.0 - LACreatureRespiration.temp_band(t)


# Drive urgency in [0,1]: how hard hunger OR thirst is pushing this creature right now (fractional deficit).
# This is what discounts remembered pain in decide() — the hungrier/thirstier, the more risk it will accept.
func _drive_urgency(c) -> float:
	var hunger: float = 0.0
	var me: float = LACognizerAdapter.max_energy(c)
	if me > 0.0:
		hunger = clampf(1.0 - LACognizerAdapter.energy(c) / me, 0.0, 1.0)
	var thirst: float = 0.0
	var mh: float = LACognizerAdapter.max_hydration(c)
	if mh > 0.0:
		thirst = clampf(1.0 - LACognizerAdapter.hydration(c) / mh, 0.0, 1.0)
	return maxf(hunger, thirst)


func _should_escalate(c, learned) -> bool:
	# PLAYER CONTROL: the slow brain is opt-out per creature (config-driven `llm_enabled`, default on). When
	# off, this creature never escalates — it runs purely on its fast reinforced policy + innate cascade.
	if c != null and not LACognizerAdapter.llm_enabled(c):
		return false
	if _sched == null or _pending or _cooldown > 0.0:
		return false
	if learned == null:
		return true                                   # never-seen situation
	var w: float = float((learned as Dictionary).get("weight", 0.0))
	var pressed: bool = LACognizerAdapter.energy(c) < LACognizerAdapter.max_energy(c) * 0.4 or LACognizerAdapter.hydration(c) < LACognizerAdapter.max_hydration(c) * 0.4
	return w < 0.2 and pressed


func _escalate(c, sig: Dictionary, innate_action: String) -> void:
	if not _sched.request(c, self, sig, innate_action):
		return
	_pending = true
	var cad: float = float(Engine.get_meta("la_llm_cadence", 0.0)) if Engine.has_meta("la_llm_cadence") else 0.0
	_cooldown = cad if cad > 0.0 else 6.0
	escalations += 1


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
	_push_history(source, action, source, sig)   # source: "llm" | "teacher"


func on_llm_failed() -> void:
	_pending = false


func last_choice() -> Dictionary:
	return _last_choice


func last_ask() -> Dictionary:
	return _last_ask


## True while this creature has a slow-brain escalation in flight — the panel shows "asking the model…".
func is_thinking() -> bool:
	return _pending


## Did the most recent decide() REFUSE a learned-lethal action (Half C)? Creature.gd reads this to steer the
## body AWAY from the hazard (a committed retreat) rather than merely coasting on the safe fallback's heading.
func was_vetoed() -> bool:
	return _last_veto


func _safe_fallback(lethal_action: String) -> String:
	if lethal_action != SAFE_FALLBACK_ACTION:
		return SAFE_FALLBACK_ACTION
	# The benign roam itself is what was learned lethal here (rare): fall to a different valid, non-lethal action.
	if lethal_action != "rest":
		return "rest"
	return "flock"


## SOCIAL LEARNING: copy confident heuristics from same-species creatures this one can SEE, weighted
## by relatedness. Throttled and neighbour-capped so it stays cheap. Called by the creature each tick.
func observe(c, delta: float) -> void:
	_observe_cd -= delta
	if _observe_cd > 0.0:
		return
	_observe_cd = LASimRng.shared().randf_range(1.5, 3.0)
	var seen: int = 0
	for m in LACognizerAdapter.neighbours(c):
		if seen >= OBSERVE_MAX_NEIGHBOURS:
			break
		if m == c or not is_instance_valid(m) or not (m is Node3D):
			continue
		if not LACognizerAdapter.sees(c, m):
			continue                                  # only learn from herd-mates you actually see
		var mc = LACognizerAdapter.cognition_of(m)
		if mc == null:
			continue
		seen += 1
		var kin: bool = LACognizerAdapter.neighbour_family_id(m) == LACognizerAdapter.family_id(c)
		var rel: float = KIN_RELATEDNESS if kin else SPECIES_RELATEDNESS
		for key in mc.policy.keys():
			var e = mc.policy[key]
			var demo_w: float = float((e as Dictionary).get("weight", 0.0))
			if demo_w >= CONFIDENCE_THRESHOLD:
				_absorb_observation(int(key), String((e as Dictionary).get("action", "")), rel, demo_w)
			elif demo_w <= AVERSION_SHARE:
				_absorb_aversion(int(key), String((e as Dictionary).get("action", "")), rel, demo_w)
		# Also inherit their confident CUE associations — this is how "watch the vultures" spreads
		# culturally: a youngster copies which signs mean food from the elders it grows up watching.
		for ck in mc.cue_values.keys():
			var demo_cv: float = float(mc.cue_values[ck])
			if demo_cv >= CONFIDENCE_THRESHOLD:
				var cgain: float = rel * OBSERVE_TRANSFER * _confidence_mult(demo_cv)
				cue_values[ck] = clampf(cue_value(String(ck)) + cgain, CUE_MIN, CUE_MAX)
			elif demo_cv <= AVERSION_SHARE:
				# The same aversion spread for CUE associations: a confidently-negative cue (a sign kin learned
				# reliably precedes danger) transmits its dread to nearby kin — fear of a warning sign is cultural too.
				var closs: float = rel * OBSERVE_TRANSFER * _confidence_mult(absf(demo_cv))
				cue_values[ck] = clampf(cue_value(String(ck)) - closs, CUE_MIN, CUE_MAX)


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


func _absorb_aversion(key: int, action: String, rel: float, demo_weight: float) -> void:
	if not LAActionRegistry.is_valid(action):
		return
	var fear: float = rel * OBSERVE_TRANSFER * _confidence_mult(absf(demo_weight))
	var entry = policy.get(key, null)
	if entry == null:
		# Never faced this: plant the fear as a fresh negative entry so repeated sightings drive it to the veto floor.
		policy[key] = {"action": action, "weight": clampf(-fear, MIN_WEIGHT, MAX_WEIGHT), "risk": 0.0}
		lessons += 1
	elif String((entry as Dictionary)["action"]) == action:
		# My entry is about the SAME action they fear: deepen my aversion toward their proven-lethal knowledge.
		(entry as Dictionary)["weight"] = clampf(float((entry as Dictionary)["weight"]) - fear, MIN_WEIGHT, MAX_WEIGHT)
	# else: I already favour a different action here (I don't take their feared move) — leave my safer habit intact.


# Sound-based social learning: a heard call (e.g. a kin's forage cry) nudges my policy for MY
# current situation toward `action`, weighted by relatedness — carries past the vision cone.
func learn_from_sound(c, action: String, rel: float) -> void:
	var sig: Dictionary = LASituationSignature.compute(c)
	# A deliberate call is a clear demonstration — treat it as a moderately confident teacher.
	_absorb_observation(int(sig.get("key", -1)), action, rel, 2.0)


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
