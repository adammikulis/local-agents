class_name LACreatureLeadership
extends RefCounted

## Emergent LOCAL leadership for LACreature — factored out like LACreatureFlocking, static + dependency-
## free of the LACreature type (dynamic access).
##
## EMERGENT-EVERYTHING: no appointment, no registry, no scripted succession. Each creature independently
## computes whether it is the top-ranked SAME-SPECIES individual within its own radius (then it is a
## LEADER and self-decides), or else finds its local top (its LEADER) and adopts that leader's DECISION —
## the single canonical action symbol — so the heavy "what to do" assessment (senses scans + cognition
## escalation + LLM) runs ONCE per local leader and the followers reuse it, pathing themselves. The map
## therefore has MANY leaders, one per local cluster; a spreading herd fissions into new local leaders.
##
## Leadership is CONTESTED + SELF-HEALING: rank is built from live age/size/energy/experience, so a
## starving/ageing/dying/departing leader loses rank and is displaced (see Creature._elect_leader, where
## the per-species `leader_loyalty` margin tunes how sticky an incumbent is — humans cling → dynasties,
## animals near-meritocratic → the biggest/oldest/best-fed leads). (Explicit types only — no ':=' .)

# Rank weights — a "well-rounded alpha": elder + biggest + best-fed + most-experienced. Tunable.
const W_MATURITY: float = 1.0     # age relative to maturity (elders lead; capped at 2x)
const W_SIZE: float = 1.2         # body size (dominance; matches the sim's size-ranked predator fear)
const W_VIGOR: float = 0.6        # energy fraction (a starving leader loses rank → drift is automatic)
const W_COMPETENCE: float = 0.15  # learned situations mastered (knows-what-to-do; per-situation, small)


## A creature's emergent leadership rank — CHEAP reads only, no scans. Higher = more fit to lead.
static func leader_score(c) -> float:
	var maturity: float = clampf(c.age / maxf(c.maturity_age, 0.001), 0.0, 2.0)
	var vigor: float = c.energy / maxf(c.max_energy, 1.0)
	var competence: float = 0.0
	if c.has_method("get_cognition"):
		var cog = c.get_cognition()
		if cog != null and cog.has_method("policy_size"):
			competence = float(cog.policy_size())
	return W_MATURITY * maturity + W_SIZE * c.size + W_VIGOR * vigor + W_COMPETENCE * competence


## The local leader for `c`: the highest-ranked SAME-SPECIES creature within `radius` (bare distance, NO
## vision cone — leadership is proximity-based). Returns null when `c` itself is the local maximum (c IS a
## leader → it self-decides). The returned node is always STRICTLY higher-ranked than c (and is itself
## nobody's follower in its own radius, so it runs full cognition) → no adopt-chains, no blind-leading-the-
## blind. Reuses the shared frame-stamped spatial index (one rebuild per group per frame). Exact-score
## ties are broken by the larger get_instance_id() so ordering is deterministic (no flip-flop at loyalty 0).
static func local_leader(c, pos: Vector3, radius: float):
	var idx = LACreatureSenses._fresh_index(c, ["species_" + String(c.species)])
	var cands: Array = idx.query("species_" + String(c.species), pos, radius)
	var r2: float = radius * radius
	var best = null
	var best_score: float = leader_score(c)
	var best_id: int = int(c.get_instance_id())
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		# A leader must be a live, free creature — skip the dead / carried / dying.
		if m.get("_carcass") or m.get("_dead") or m.get("_held") or m.get("_dying"):
			continue
		if pos.distance_squared_to(m.global_position) > r2:
			continue
		var s: float = leader_score(m)
		var mid: int = int(m.get_instance_id())
		if s > best_score or (s == best_score and mid > best_id):
			best_score = s
			best_id = mid
			best = m
	return best   # null ⇒ c is the local leader
