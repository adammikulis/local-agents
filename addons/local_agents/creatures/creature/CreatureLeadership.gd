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


## A creature's emergent leadership rank — CHEAP reads only, no scans. Higher = more fit to lead. Delegates to
## the shared valuator (LAAppraisal.dominance) so rank and mate choice run on ONE phenotype-scoring rule; with
## default weights this is the same well-rounded-alpha ranking as before, and a species that courts on ornament
## (dominance_traits.display) now leads on it too. The W_* / MATURITY_CAP consts above are retained as the
## documented default weights (mirrored in LAAppraisal.DEFAULT_WEIGHTS).
static func leader_score(c) -> float:
	return LAAppraisal.dominance(c)


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


# ============================================================================================================
# ELECTION STATE-MACHINE — moved here from Creature.gd so ALL leadership logic lives in this one module (the
# creature just calls maybe_elect each physics frame). Functions take the creature `c` by dynamic access, like
# the queries above. Roles set on c: `_leader` (immediate manager, or null if root) + `_is_leader` (true at a
# tree root). Throttled by c._leader_elect_cd.
# ============================================================================================================
const LEADER_ELECT_STRIDE: int = 45        # re-run the (cheap, throttled) local election ~every 0.75 s
const LEADER_RADIUS_MULT: float = 3.0      # leadership neighbourhood = flock_radius × this. Wider than the
                                           # flocking/vision radius on purpose: an alpha's SOCIAL pull reaches
                                           # farther than one body-length of steering, so a band holds one
                                           # leader as it spreads to graze instead of fissioning into many.
# LEASH: a follower keeps its (still-valid) leader while within this × the leadership radius, even after it
# has drifted past `radius` — it regroups back (CreatureFlocking regroup pull) instead of self-promoting to a
# leader-of-one. Only a truly gone leader (dead/carried/beyond-leash) or a genuinely higher-ranked local
# challenger triggers re-election. This is what stops the "everyone is a leader of one" churn on the sphere.
const LEASH_MULT: float = 4.0


# A leader is only followable while it is a live, free creature — not dead/carrying/dying/carried. Mirrors the
# skip used in the local_* queries so "is my current leader still valid?" and "who could lead?" agree.
static func _leader_valid(ldr) -> bool:
	return ldr != null and is_instance_valid(ldr) \
			and not ldr.get("_carcass") and not ldr.get("_dead") \
			and not ldr.get("_held") and not ldr.get("_dying")

# A/B / verification kill-switch: LA_NO_LEADERSHIP=1 makes every creature its own leader (no delegation),
# i.e. the pre-leadership behaviour, for on/off population + perf comparison. Read once (env is process-wide).
static var _off: int = -1
static func disabled() -> bool:
	if _off < 0:
		_off = 1 if OS.get_environment("LA_NO_LEADERSHIP") == "1" else 0
	return _off == 1


## Per-frame leadership gate for creature `c`: (throttled) decide whether c leads or follows. c participates if
## it herds OR its species is parent-following (family/command) — the latter lets a solitary species' juveniles
## follow a parent while its adults stay independent. Non-participants (and the A/B kill-switch) are always
## their own leader. Called every physics frame from Creature._physics_process.
static func maybe_elect(c, pos: Vector3) -> void:
	if disabled() or not (c.herd or c.hierarchy == "family" or c.hierarchy == "command"):
		c._leader = null
		c._is_leader = true
		return
	c._leader_elect_cd -= 1
	if c._leader_elect_cd <= 0 or (not c._is_leader and not is_instance_valid(c._leader)):
		elect(c, pos)


## Throttled emergent election — dispatches by species `hierarchy` mode. No registry, no appointment: every
## creature runs the same local rules and the whole tree (juvenile→parent→…→pack leader) falls out.
static func elect(c, pos: Vector3) -> void:
	c._leader_elect_cd = LEADER_ELECT_STRIDE
	var radius: float = c.flock_radius * LEADER_RADIUS_MULT
	# 1. Parent-following (family/command): a juvenile attaches to its nearest family adult (parent/elder),
	#    who in turn follows the pack leader → the family→pack tree self-assembles. Orphans (no adult kin
	#    nearby) fall through to the rank rules; a matured creature stops following its parent.
	if (c.hierarchy == "family" or c.hierarchy == "command") and not c.is_mature():
		var guardian = nearest_family_adult(c, pos, radius)
		if guardian != null and not would_cycle(c, guardian, 8):
			c._leader = guardian
			c._is_leader = false
			return
	# 2. Solitary adults (non-herd, e.g. a grown fox) lead only themselves — no adult pack forms.
	if not c.herd:
		c._leader = null
		c._is_leader = true
		return
	# 3. Herd adults: a "command" species builds a multi-level rank tree; everyone else a flat pack leader.
	if c.hierarchy == "command":
		elect_superior(c, pos, radius)
	else:
		elect_flat(c, pos, radius)


## Flat election (base model / "family" adults): follow the local score-max, or lead if I am it, with
## leader_loyalty hysteresis + self-healing. The original single-leader-per-cluster behaviour.
static func elect_flat(c, pos: Vector3, radius: float) -> void:
	var cand = local_leader(c, pos, radius)
	var top = c if cand == null else cand                 # the pure local argmax (self if c ranks highest)
	if top != c and would_cycle(c, top, 8):
		top = c                                           # attaching would close a loop → treat c as root
	# The incumbent leader over c: itself while it leads, else the creature it currently follows.
	if not c._is_leader:
		# Sticky: keep the current leader while it is still a live, free creature AND within the LEASH (a
		# generous multiple of `radius`). A mere drift past `radius` no longer demotes — the follower regroups
		# back toward its leader/kin (CreatureFlocking) rather than becoming a leader-of-one. Only a truly gone
		# leader (dead/carried/beyond-leash) forces the immediate self-heal below.
		var leash: float = radius * LEASH_MULT
		var leader_ok: bool = _leader_valid(c._leader) \
				and pos.distance_squared_to(c._leader.global_position) <= leash * leash
		if not leader_ok:
			# Self-healing: leader died or is truly out of reach → adopt the new local top, NO loyalty margin.
			c._leader = null if top == c else top
			c._is_leader = (top == c)
			return
	var incumbent = c if c._is_leader else c._leader
	if top == incumbent:
		return                                            # incumbent is still the local top — no change
	# Switch (takeover) if the challenger clears the loyalty margin. loyalty<=0 → any higher top wins (the
	# id-tiebreak in local_leader already ordered them); high loyalty → a decisive score margin (dynasties).
	var justified: bool = c.leader_loyalty <= 0.0 \
			or leader_score(top) > leader_score(incumbent) + c.leader_loyalty
	if justified:
		c._leader = null if top == c else top
		c._is_leader = (top == c)


## Multi-level ("command") election: attach to c's immediate SUPERIOR (nearest higher-rank in span), so the
## tree gains depth — grunt→lieutenant→huntmaster. c CLINGS to its current boss while they stay a valid
## superior (in reach + still out-rank c past its loyalty); it re-picks only when the boss falls below it,
## dies, or leaves — then attaches to the nearest remaining superior, or becomes a root if none.
static func elect_superior(c, pos: Vector3, radius: float) -> void:
	if _leader_valid(c._leader):
		# Still a valid boss if it out-ranks c past c's loyalty and is within the LEASH (same generous reach
		# as the flat election): a subordinate clings to its boss across a drift rather than defecting the
		# instant it strays past the tight span — it regroups back toward the boss (CreatureFlocking).
		var leash: float = radius * LEASH_MULT
		var still_valid: bool = pos.distance_squared_to(c._leader.global_position) <= leash * leash \
				and leader_score(c._leader) > leader_score(c) + c.leader_loyalty
		if still_valid:
			c._is_leader = false
			return                                        # cling to the current boss (hierarchy stickiness)
	var sup = local_superior(c, pos, radius, c.leader_loyalty)
	if sup != null and would_cycle(c, sup, 8):
		sup = null                                        # attaching would close a loop → become a root
	c._leader = sup
	c._is_leader = (sup == null)
