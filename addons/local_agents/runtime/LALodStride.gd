class_name LALodStride
extends RefCounted

## One canonical relevance-driven update-stride LOD, shared by every CPU/GPU subsystem that throttles its
## own update rate by how relevant a target currently is: creature physics/animation/thinking, plant/tree
## settle, field-force sweep, companion tick. ACTORS AND RENDERING ONLY — never apply it to the FIELD's
## physics, where it would make the planet's behaviour depend on where the camera points. Relevance is a
## smooth 0..1 score -- 1 = fully relevant (update every tick), 0 = irrelevant (update as rarely as the
## caller's max_stride allows) -- with no named distance tiers or branch cutoffs: both formulas below are
## continuous and asymptotic, so each call site tunes one "how far until this stops mattering" number.

## Smooth 0..1 relevance from a distance and a characteristic distance (the distance at which relevance
## has fallen to 0.5). No hard cutoff: exactly 1 at distance 0, asymptotically approaches 0 as distance
## grows -- one intuitive tuning number per call site instead of a rate+cap pair.
static func relevance_from_distance(distance: float, characteristic_distance: float) -> float:
	return characteristic_distance / (characteristic_distance + maxf(distance, 0.0))


## Update stride from a 0..1 relevance score: stride is base_stride's reciprocal-scaled-by-relevance (fully
## relevant -> base_stride; half as relevant -> double the wait; ...), capped at max_stride so nothing goes
## fully dormant. base_stride is the "even at maximum relevance, don't update faster than this" floor
## (1 = every tick; a decision cascade that never needs 60 Hz resolution can floor higher). No separate
## rate constant to tune -- the mapping is fixed, only the floor/cap vary per call site by how much
## staleness that subsystem can tolerate.
static func stride_for(relevance: float, max_stride: int, base_stride: int = 1) -> int:
	var r: float = maxf(relevance, float(base_stride) / float(max_stride))
	return clampi(int(round(float(base_stride) / r)), base_stride, max_stride)


## True on this tick if `stride`-throttled work assigned to `phase` should run. `phase` is any
## caller-stable per-instance/per-cell integer (e.g. get_instance_id(), a cell index) so instances sharing
## the same stride land on different ticks instead of all skipping/running in lockstep.
static func should_run(tick: int, phase: int, stride: int) -> bool:
	return (tick + phase) % stride == 0
