class_name LACreatureFlocking
extends RefCounted

## Same-kind flocking / imitation steering for LACreature, factored out of the main brain.
## Shared by ALL species: cohesion (toward local centre), alignment (match average heading —
## "do what others like me do") and separation (avoid crowding), weighted by the creature's
## per-species flock_* config. `flatten` zeroes Y for ground creatures. Static + dependency-free
## of the LACreature type. (Explicit types only — project rule: no ':=' inferred typing.)

# Extra pull a follower feels toward its emergent local leader (see LACreatureLeadership), on top of the
# ordinary flock average — makes the herd wheel visibly BEHIND its elder rather than just centring itself.
const LEADER_BIAS: float = 0.6

static func steer(c, pos: Vector3, flatten: bool) -> Vector3:
	if c.flock_weight <= 0.0:
		return Vector3.ZERO
	var mates: Array = c.get_tree().get_nodes_in_group("species_" + String(c.species))
	var center: Vector3 = Vector3.ZERO
	var align: Vector3 = Vector3.ZERO
	var separation: Vector3 = Vector3.ZERO
	var n: int = 0
	var sep_dist: float = maxf(c.size * 4.0, 1.5)
	for m in mates:
		if m == c or not is_instance_valid(m):
			continue
		var op: Vector3 = m.global_position
		var d: float = pos.distance_to(op)
		if d > c.flock_radius or d < 0.0001:
			continue
		center += op
		align += m._heading
		if d < sep_dist:
			separation += (pos - op) / d          # stronger the closer they are
		n += 1
	if n == 0:
		return Vector3.ZERO
	center /= float(n)
	align /= float(n)
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
	# Leader-biased cohesion/alignment: a follower drifts toward + orients behind its emergent local leader
	# (LACreatureLeadership). Non-followers (_leader == null) are unaffected, so non-herd behaviour is intact.
	var leader = c._leader
	if leader != null and is_instance_valid(leader):
		var lp: Vector3 = leader.global_position
		var ld: float = pos.distance_to(lp)
		if ld < c.flock_radius and ld > 0.0001:
			var to_leader: Vector3 = lp - pos
			var lead_head: Vector3 = leader._heading
			if flatten:
				to_leader.y = 0.0
				lead_head.y = 0.0
			if to_leader.length() > 0.001:
				out += to_leader.normalized() * c.flock_cohesion * LEADER_BIAS
			if lead_head.length() > 0.001:
				out += lead_head.normalized() * c.flock_alignment * LEADER_BIAS
	return out * c.flock_weight
