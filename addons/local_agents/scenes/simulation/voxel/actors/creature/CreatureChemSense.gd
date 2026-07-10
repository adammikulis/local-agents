class_name LACreatureChemSense
extends RefCounted

## Chemical-affinity learning for LACreature — the smell/taste side of cognition, built on the shared
## scent field (LAMaterialField3D scent channels) plus the literal-DNA cue priors (LADNA cue_priors).
##
## Nothing here decides a chemical is "good" or "bad". A cue's valence is LEARNED (from how eating a food
## with a given taste signature actually felt, and from fear the rest of cognition already reinforces) or
## BORN-IN (the genome's cue priors, refined by a lifetime of that learning and spread to kin culturally by
## LACognition.observe()). This is the same generic reward machinery LACognition already runs for "watch the
## vultures" cues — one level down, about the chemicals a creature smells and tastes rather than the animals
## it sees. So a scavenger learns rotten meat tastes worse than a fresh kill, a herbivore born blood-wary
## keeps clear of a blood scent, and a hungry animal banks toward a smell it has learned means food — all
## without one chemical being hardcoded anywhere.
##
## Two entry points, both O(1):
##   * on_eat(c, profile, gained)  — after a bite: mint a taste cue from the food's (type, state) and
##                                   reinforce it by how much energy the bite actually delivered.
##   * steer(c, pos, desired)      — each forage think tick: bias the heading toward scent channels the
##                                   creature has learned to like and away from ones it has learned to fear,
##                                   scaled by hunger (a fed animal ignores it, so day-0 behaviour is intact).
##   * seed_priors(c)              — once at birth: reinforce the genome's born-in cue priors into cognition.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)

# The scent channels a creature can smell, paired with the cue key its learned valence is stored under. One
# row per LAMaterialField3D channel: [channel_index, cue_key]. The cue key is just the generic reward-channel
# string LACognition.reinforce_cue / cue_value already understand — the SIGN of the value is never set here.
const SCENT_CUES: Array = [
	[LAMaterialField3D.SCENT_PREY, "scent:prey"],
	[LAMaterialField3D.SCENT_PREDATOR, "scent:predator"],
	[LAMaterialField3D.SCENT_BLOOD, "scent:blood"],
	[LAMaterialField3D.SCENT_FOOD, "scent:food"],
	[LAMaterialField3D.SCENT_ALARM, "scent:alarm"],
]

# Taste reward tuning. A bite delivers a fraction of max energy; a "par" bite is worth NEUTRAL_BITE_FRAC of
# max energy — above that the taste is liked (a positive cue), below it (a decayed scrap / grazed-down plant)
# the taste is disliked (a negative cue). A food whose (type,state) signature RELIABLY underfeeds therefore
# trains an aversion to its own taste, and a rich one an appetite, with no food ever hardcoded good or bad.
# Decayed food always yields a lower cue than the same food fresh (half the energy), so the ordering holds
# for any body size regardless of where the neutral lands.
const NEUTRAL_BITE_FRAC: float = 0.14
const TASTE_REWARD_CAP: float = 1.0

# How strongly a born-in [0,1] DNA prior seeds its learned cue (before lifetime learning refines it). Each
# row maps a genome cue-prior gene to a cue key and a sign: blood-wariness is an AVERSION to the blood scent;
# carrion-appetite an appetite for the food scent; water-affinity a draw to water. Add a gene->cue row to
# grow the innate set — no code branch. (water has no scent channel today, so its prior is stored as a born-in
# valence that spreads culturally and is ready the moment a water scent channel lands — see SCENT_CUES.)
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


## Mint the taste cue key for a food profile — its (type, state) signature. Two foods that feed a creature
## the same way (carbs/living, meat/decayed, …) share a signature, so learning about one transfers to the next.
static func taste_key(profile: Dictionary) -> String:
	return "taste:%s/%s" % [String(profile.get("type", "")), String(profile.get("state", ""))]


## Reinforce the taste cue of a food just eaten, by how much energy the bite delivered (the same appetitive
## valence the rest of cognition already learns from). `gained` is the raw energy of the bite; the felt reward
## is that as a fraction of max energy, mapped through a neutral so a rich bite is positive and a meagre one
## negative. O(1): one dict write. No effect if the creature has no cognition or the bite gave nothing.
static func on_eat(c, profile: Dictionary, gained: float) -> void:
	if c == null or gained <= 0.0:
		return
	if c._cognition == null:
		return
	var max_energy: float = maxf(float(c.max_energy), 1.0)
	var frac: float = gained / max_energy
	var felt: float = clampf(frac / NEUTRAL_BITE_FRAC - 1.0, -TASTE_REWARD_CAP, TASTE_REWARD_CAP)
	c._cognition.reinforce_cue(taste_key(profile), felt)


## Bias a foraging heading by learned scent affinity. For each scent channel the creature can smell, look up
## the learned valence of that channel's cue and add its gradient (toward the source for a liked scent, away
## for a feared one), the whole nudge scaled by how hungry the creature is — so a fed animal ignores smells
## entirely (day-0 behaviour) and a starving one commits to a smell it has learned means food. Returned in
## world space; the caller reprojects the final heading into the local tangent plane. O(channels) = O(1).
static func steer(c, pos: Vector3, desired: Vector3) -> Vector3:
	if c == null or c._cognition == null or c._material == null:
		return desired
	if not c._material.has_method("scent_gradient"):
		return desired
	if STEER_SUPPRESS_STATES.has(String(c.state)):
		return desired
	var hunger: float = 0.0
	if c.max_energy > 0.0:
		hunger = clampf(1.0 - float(c.energy) / float(c.max_energy), 0.0, 1.0)
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


## Seed the creature's born-in chemical instincts, once, at birth: reinforce each DNA cue prior (decoded from
## the genome strand) into cognition as a starting valence. A blood-wary lineage is born giving the blood
## scent a negative cue (it keeps clear before ever being hurt); a carrion-hungry one a positive food-scent
## cue. Lifetime learning (on_eat / fear) then refines these, and LACognition.observe() spreads them to kin.
static func seed_priors(c) -> void:
	if c == null or c._cognition == null or c._genome == null:
		return
	if not c._genome.has_method("decode_gene"):
		return
	for row in PRIOR_MAP:
		var prior: float = c._genome.decode_gene(String(row[0]))
		c._cognition.reinforce_cue(String(row[1]), prior * float(row[2]) * PRIOR_SCALE)
