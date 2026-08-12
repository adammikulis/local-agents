class_name LACreatureChemSense
extends RefCounted


const SCENT_CUES: Array = [
	[LAScentChannels.SCENT_PREY, "scent:prey"],
	[LAScentChannels.SCENT_PREDATOR, "scent:predator"],
	[LAScentChannels.SCENT_BLOOD, "scent:blood"],
	[LAScentChannels.SCENT_FOOD, "scent:food"],
	[LAScentChannels.SCENT_ALARM, "scent:alarm"],
]

const NEUTRAL_BITE_FRAC: float = 0.14
const TASTE_REWARD_CAP: float = 1.0

const TOXIN_DAMAGE_FRAC: float = 0.16      # HP lost as a fraction of max_health, per unit toxicity, per bite
const TOXIN_FELT_PENALTY: float = 2.2      # aversive taste subtracted from felt, per unit toxicity

const TASTE_AVOID_THRESHOLD: float = -0.4  # a taste cue at/below this is refused when not desperate
const TASTE_DESPERATE_FRAC: float = 0.3    # below this energy fraction, hunger overrides the taste aversion

const PRIOR_SCALE: float = 2.0
const PRIOR_MAP: Array = [
	["blood_wariness", "scent:blood", -1.0],
	["carrion_appetite", "scent:food", 1.0],
	["water_affinity", "scent:water", 1.0],
]

# Smell steering: how hard a starving creature banks toward/away from a learned scent, and the states in
# which the bias is suppressed (survival + thirst overrides own the heading — a fleeing/drinking animal is
# not foraging by smell). cue_value below this magnitude is treated as "no opinion" and skipped.
const STEER_WEIGHT: float = 1.2
const STEER_CUE_EPS: float = 0.05
const STEER_SUPPRESS_STATES: Array = ["flee", "panic", "drink", "seek"]


static func taste_key(profile: Dictionary) -> String:
	var base: String = "taste:%s/%s" % [String(profile.get("type", "")), String(profile.get("state", ""))]
	if float(profile.get("toxicity", 0.0)) > 0.0:
		base += "/toxic"
	return base


static func toxin_damage(c, profile: Dictionary) -> float:
	if c == null:
		return 0.0
	var toxicity: float = clampf(float(profile.get("toxicity", 0.0)), 0.0, 1.0)
	if toxicity <= 0.0:
		return 0.0
	return maxf(0.0, float(c.max_health)) * TOXIN_DAMAGE_FRAC * toxicity


static func avoids_food(c, profile: Dictionary) -> bool:
	if c == null or c._cognition == null:
		return false
	if c._cognition.cue_value(taste_key(profile)) > TASTE_AVOID_THRESHOLD:
		return false
	if c.max_energy > 0.0 and c.energy < c.max_energy * TASTE_DESPERATE_FRAC:
		return false   # desperate: hunger overrides the taste aversion (risk the bad taste rather than starve)
	return true


static func on_eat(c, profile: Dictionary, gained: float) -> void:
	if c == null or gained <= 0.0:
		return
	if c._cognition == null:
		return
	# Divide-by-zero guard only — an EPSILON, not a plausible-looking 1.0. With physiology derived from real
	# body mass a rabbit's whole reserve is 0.004, so a floor of 1.0 replaced the denominator outright and
	# every bite registered as flavourless whatever it was worth, which silently disables taste learning.
	var max_energy: float = maxf(float(c.max_energy), 1.0e-9)
	var frac: float = gained / max_energy
	var felt: float = frac / NEUTRAL_BITE_FRAC - 1.0
	# TOXICITY folds an aversive term into `felt` BEFORE the clamp, so a poison drives the taste cue NEGATIVE even
	# when the same bite fed the animal — the net feeling is bad, so a POSITIVE cue never forms for a toxic taste
	# and the creature (and, via observe(), its kin) learns to shun it. Driven off the toxicity value, no branch.
	var toxicity: float = clampf(float(profile.get("toxicity", 0.0)), 0.0, 1.0)
	if toxicity > 0.0:
		felt -= toxicity * TOXIN_FELT_PENALTY
	felt = clampf(felt, -TASTE_REWARD_CAP, TASTE_REWARD_CAP)
	c._cognition.reinforce_cue(taste_key(profile), felt)


static func steer(c, pos: Vector3, desired: Vector3) -> Vector3:
	if c == null or c._cognition == null or c._material == null:
		return desired
	if not c._material.has_method("scent_gradient"):
		return desired
	if STEER_SUPPRESS_STATES.has(String(c.state)):
		return desired
	# The single hunger signal (energy deficit AND an empty gut): a creature buffering a meal in its gut is not
	# hungry and ignores food smells, so digestion and this smell-steering agree on when the animal forages.
	var hunger: float = LACreatureDigestion.hunger(c)
	if hunger <= 0.0:
		return desired
	var bias: Vector3 = Vector3.ZERO
	for row in SCENT_CUES:
		var val: float = c._cognition.cue_value(String(row[1]))
		if absf(val) < STEER_CUE_EPS:
			continue
		var grad: Vector3 = c._material.scent_gradient(pos, int(row[0]))   # points UP-gradient (toward source)
		if grad.length() < 0.001:
			continue
		bias += grad.normalized() * val                                    # liked (+) toward, feared (-) away
	if bias.length() < 0.001:
		return desired
	return desired + bias.normalized() * STEER_WEIGHT * hunger


static func seed_priors(c) -> void:
	if c == null or c._cognition == null or c._genome == null:
		return
	if not c._genome.has_method("decode_gene"):
		return
	for row in PRIOR_MAP:
		var prior: float = c._genome.decode_gene(String(row[0]))
		c._cognition.reinforce_cue(String(row[1]), prior * float(row[2]) * PRIOR_SCALE)
