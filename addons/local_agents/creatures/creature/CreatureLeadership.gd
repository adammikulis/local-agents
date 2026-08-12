class_name LACreatureLeadership
extends RefCounted


const W_MATURITY: float = 1.0     # age relative to maturity — the DOMINANT axis (a village elder far out-ranks
                                  # a young adult), so keep a wide cap (below) or command tiers can't form.
const W_SIZE: float = 1.2         # body size (dominance; matches the sim's size-ranked predator fear)
const W_VIGOR: float = 0.6        # energy fraction (a starving leader loses rank → drift is automatic)
const W_COMPETENCE: float = 0.15  # learned situations mastered (knows-what-to-do; per-situation, small)
const MATURITY_CAP: float = 6.0   # elders keep gaining rank up to 6× maturity — a WIDE spread so multi-level
                                  # command trees have distinct rungs (a tiny spread collapses every tier flat).


static func leader_score(c) -> float:
	return LAAppraisal.dominance(c)


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


static func would_cycle(follower, cand, max_hops: int) -> bool:
	var node = cand
	var hops: int = 0
	while node != null and is_instance_valid(node) and hops < max_hops:
		if node == follower:
			return true
		node = node.get("_leader")
		hops += 1
	return false


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


static func nearest_lineage_adult(c, pos: Vector3, radius: float):
	return _nearest_adult(c, pos, radius, LACreatureAffiliation.lineage_of(c), true)


static func nearest_band_adult(c, pos: Vector3, radius: float):
	return _nearest_adult(c, pos, radius, LACreatureAffiliation.band_of(c), false)


## Shared body of the two queries above: nearest mature, live, free same-species creature whose lineage (or
## band) integer matches `group`. One bounded spatial-hash query and a linear pass over its candidates.
static func _nearest_adult(c, pos: Vector3, radius: float, group: int, by_lineage: bool):
	var idx = LACreatureSenses._fresh_index(c, ["species_" + String(c.species)])
	var cands: Array = idx.query("species_" + String(c.species), pos, radius)
	var r2: float = radius * radius
	var best = null
	var best_d2: float = r2 + 1.0
	var best_id: int = 0
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		var mine: int = LACreatureAffiliation.neighbour_lineage(m) if by_lineage else LACreatureAffiliation.neighbour_band(m)
		if mine != group or not m.call("is_mature"):
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
	return best   # null ⇒ nobody of that group nearby (orphan / founder / newly exiled) ⇒ fall back to rank/self


const LEADER_ELECT_STRIDE: int = 45        # re-run the (cheap, throttled) local election ~every 0.75 s
const LEADER_RADIUS_MULT: float = 3.0      # leadership neighbourhood = flock_radius × this. Wider than the
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
		var guardian = nearest_lineage_adult(c, pos, radius)
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
