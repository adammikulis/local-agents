class_name LACreatureFlocking
extends RefCounted

## Same-kind flocking / imitation steering for LACreature, factored out of the main brain.
## Shared by ALL species: cohesion (toward local centre), alignment (match average heading —
## "do what others like me do") and separation (avoid crowding), weighted by the creature's
## per-species flock_* config. `flatten` zeroes Y for ground creatures. Static + dependency-free
## of the LACreature type. (Explicit types only — project rule: no ':=' inferred typing.)
##
## Leadership is UNIFIED into flocking: every neighbour's pull on the group heading/centre is
## scaled by its _influence() — how urgent/committed/senior it is — so the first animals to bolt
## informally "lead" the herd's direction, and a formal rank leader is just a high-influence node
## (no separate leader-bias term). When all are calm the influences are ~equal → ordinary flocking.

# Urgency bonus for a neighbour committed to a directional, high-stakes state.
const URGENCY_FLEE: float = 5.0     # fleeing/panicking → dominates the herd heading (informal leader)
const URGENCY_ACTIVE: float = 1.5   # chase/stalk/throw/seek/drink → committed & directional, moderate pull
# Standing bonus for a formal rank leader (folds LACreatureLeadership into the weighting).
const RANK_INFLUENCE: float = 2.0
# Cross-species alignment pull toward any nearby fleeing/panicking creature — a mixed grazing group
# scatters together (composes with the cross-species alarm-call fear system).
const PANIC_BIAS: float = 0.8

## How strongly neighbour `m` pulls the group's heading/centre. Base 1.0; boosted by urgent state,
## by moving faster than its own cruise speed (commitment), and by formal rank. Missing fields → 0.
static func _influence(m) -> float:
	var w: float = 1.0
	# URGENCY: committed, directional states pull harder than idle grazers.
	var st: String = String(m.get("state"))
	if st == "flee" or st == "panic":
		w += URGENCY_FLEE
	elif st == "chase" or st == "stalk" or st == "throw" or st == "seek" or st == "drink":
		w += URGENCY_ACTIVE
	# SPEED/commitment: moving faster than my cruise speed = more committed to a direction.
	var eff: float = float(m.get("_eff_speed")) if m.get("_eff_speed") != null else 0.0
	var cruise: float = maxf(float(m.get("speed")) if m.get("speed") != null else 0.0, 0.001)
	w += clampf(eff / cruise - 1.0, 0.0, 2.0)
	# RANK: a formal leader (LACreatureLeadership) is just a high-influence node.
	if bool(m.get("_is_leader")):
		w += RANK_INFLUENCE
	return w

static func steer(c, pos: Vector3, flatten: bool) -> Vector3:
	if c.flock_weight <= 0.0:
		return Vector3.ZERO
	var mates: Array = c.get_tree().get_nodes_in_group("species_" + String(c.species))
	var center: Vector3 = Vector3.ZERO
	var align: Vector3 = Vector3.ZERO
	var separation: Vector3 = Vector3.ZERO
	var wsum: float = 0.0                       # sum of neighbour influence weights
	var sep_dist: float = maxf(c.size * 4.0, 1.5)
	for m in mates:
		if m == c or not is_instance_valid(m):
			continue
		var op: Vector3 = m.global_position
		var d: float = pos.distance_to(op)
		if d > c.flock_radius or d < 0.0001:
			continue
		# Weighted cohesion + alignment: an urgent/committed/senior neighbour swings the group's
		# centre AND heading toward itself → the herd turns to follow the mover (informal leadership).
		var w: float = _influence(m)
		center += op * w
		align += m._heading * w
		wsum += w
		# Separation is UNWEIGHTED: crowding avoidance is about proximity, not influence.
		if d < sep_dist:
			separation += (pos - op) / d          # stronger the closer they are
	if wsum <= 0.0:
		return Vector3.ZERO
	center /= wsum
	# align: weighted sum, direction is what matters (normalised below), so no divide needed.
	var cohesion: Vector3 = center - pos
	if flatten:
		cohesion.y = 0.0
		align.y = 0.0
		separation.y = 0.0
	var out: Vector3 = Vector3.ZERO
	if cohesion.length() > 0.001:
		out += cohesion.normalized() * c.flock_cohesion
	if align.length() > 0.001:
		out += align.normalized() * c.flock_alignment
	if separation.length() > 0.001:
		out += separation.normalized() * c.flock_separation
	# CROSS-SPECIES panic: align with any nearby fleeing creature of ANY species (not just my kind),
	# so a mixed grazing group scatters as one. Reuses the shared frame-stamped spatial index (cheap).
	var panic_align: Vector3 = Vector3.ZERO
	var idx = LACreatureSenses._fresh_index(c, ["creature"])
	for o in idx.query("creature", pos, c.flock_radius):
		if o == c or not is_instance_valid(o):
			continue
		var os: String = String(o.get("state"))
		if os != "flee" and os != "panic":
			continue
		var od: float = pos.distance_to(o.global_position)
		if od > c.flock_radius or od < 0.0001:
			continue
		panic_align += o._heading * _influence(o)     # more panicked/committed movers pull harder
	if flatten:
		panic_align.y = 0.0
	if panic_align.length() > 0.001:
		out += panic_align.normalized() * c.flock_alignment * PANIC_BIAS
	return out * c.flock_weight
