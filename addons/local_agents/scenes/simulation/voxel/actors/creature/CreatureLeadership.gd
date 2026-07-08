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
const W_MATURITY: float = 1.0     # age relative to maturity — the DOMINANT axis (a village elder far out-ranks
                                  # a young adult), so keep a wide cap (below) or command tiers can't form.
const W_SIZE: float = 1.2         # body size (dominance; matches the sim's size-ranked predator fear)
const W_VIGOR: float = 0.6        # energy fraction (a starving leader loses rank → drift is automatic)
const W_COMPETENCE: float = 0.15  # learned situations mastered (knows-what-to-do; per-situation, small)
const MATURITY_CAP: float = 6.0   # elders keep gaining rank up to 6× maturity — a WIDE spread so multi-level
                                  # command trees have distinct rungs (a tiny spread collapses every tier flat).


## A creature's emergent leadership rank — CHEAP reads only, no scans. Higher = more fit to lead.
static func leader_score(c) -> float:
	var maturity: float = clampf(c.age / maxf(c.maturity_age, 0.001), 0.0, MATURITY_CAP)
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


## Would making `cand` the leader of `follower` create a cycle? Ranks change over time and elections are
## staggered, so two creatures whose ranks cross between their election frames can briefly each out-rank the
## other and point at each other (A→B while B→A) — a cycle with no root, where nobody runs real cognition.
## Walk cand's existing _leader chain (cheap, capped): if `follower` is already up-chain of cand, attaching
## would close a loop, so reject. Keeps the forest a proper tree (every chain terminates at a root leader).
static func would_cycle(follower, cand, max_hops: int) -> bool:
	var node = cand
	var hops: int = 0
	while node != null and is_instance_valid(node) and hops < max_hops:
		if node == follower:
			return true
		node = node.get("_leader")
		hops += 1
	return false


## Immediate SUPERIOR for `c` (the `command`-mode tree builder): the NEAREST same-species creature that
## out-ranks c by more than `loyalty`, within `radius`. Unlike local_leader (which returns the local MAX and
## so builds a flat star), this returns c's DIRECT manager — so repeated attachment forms a multi-LEVEL tree:
## a grunt reports to a nearby lieutenant, who reports to the huntmaster, who (being the local max, with no
## higher-ranked neighbour) reports to nobody. Nearest-not-highest is what gives the tree its depth. Returns
## null when no same-species creature out-ranks c here (c is a local root / top of its cluster). Distance
## ties broken by the larger instance_id for determinism.
## Rank-scaled span-of-control: how far a candidate manager S can reach down to a subordinate whose rank is
## `sub_score`. The bigger S out-ranks the subordinate, the farther it reaches — so a huntmaster's span covers
## the whole band while a lieutenant's covers only its immediate few. This is what makes tiers form spatially:
## a grunt attaches to a NEARBY lieutenant (tight span) before the distant huntmaster (wide span) captures it.
const REACH_BASE: float = 0.35    # a barely-superior manager reaches only ~a third of the base radius
const REACH_GAIN: float = 0.25    # ...plus this much of the base radius per point of rank it leads by
const REACH_MAX_MULT: float = 2.0 # cap: even the huntmaster's span is bounded (keeps the tree local + query cheap)

static func local_superior(c, pos: Vector3, radius: float, loyalty: float):
	var idx = LACreatureSenses._fresh_index(c, ["species_" + String(c.species)])
	# Query out to the largest span any manager could have (rank-scaled reach, below, filters per candidate).
	var q_radius: float = radius * REACH_MAX_MULT
	var cands: Array = idx.query("species_" + String(c.species), pos, q_radius)
	var my_score: float = leader_score(c)
	var best = null
	var best_d2: float = q_radius * q_radius + 1.0
	var best_id: int = 0
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		if m.get("_carcass") or m.get("_dead") or m.get("_held") or m.get("_dying"):
			continue
		var s: float = leader_score(m)
		if s <= my_score + loyalty:
			continue                      # not a superior — doesn't out-rank me past the loyalty margin
		# S reaches me only if I am within its rank-scaled span of control.
		var reach: float = radius * minf(REACH_BASE + REACH_GAIN * (s - my_score), REACH_MAX_MULT)
		var d2: float = pos.distance_squared_to(m.global_position)
		if d2 > reach * reach:
			continue
		var mid: int = int(m.get_instance_id())
		if d2 < best_d2 or (d2 == best_d2 and mid > best_id):
			best_d2 = d2
			best_id = mid
			best = m
	return best   # null ⇒ no in-span superior nearby ⇒ c is a local root


## Nearest mature same-species creature sharing c's `family_id` within `radius` — c's parent / family elder.
## Offspring inherit a founder's family_id (see EcologyService), so same family_id == same lineage; a founder
## with no kin nearby just gets null. Used so juveniles of `family`/`command`-mode species follow their
## family's adult (who in turn follows the pack leader), forming the natural juvenile→parent→pack tree without
## any explicit parent pointer. Skips the dead/carried/dying. Distance ties broken by the larger instance_id.
static func nearest_family_adult(c, pos: Vector3, radius: float):
	var fam: int = int(c.family_id)
	var idx = LACreatureSenses._fresh_index(c, ["species_" + String(c.species)])
	var cands: Array = idx.query("species_" + String(c.species), pos, radius)
	var r2: float = radius * radius
	var best = null
	var best_d2: float = r2 + 1.0
	var best_id: int = 0
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		if int(m.get("family_id")) != fam or not m.call("is_mature"):
			continue
		if m.get("_carcass") or m.get("_dead") or m.get("_held") or m.get("_dying"):
			continue
		var d2: float = pos.distance_squared_to(m.global_position)
		if d2 > r2:
			continue
		var mid: int = int(m.get_instance_id())
		if d2 < best_d2 or (d2 == best_d2 and mid > best_id):
			best_d2 = d2
			best_id = mid
			best = m
	return best   # null ⇒ no adult kin nearby (orphan / founder) ⇒ fall back to rank/self
