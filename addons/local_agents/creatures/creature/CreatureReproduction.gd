class_name LACreatureReproduction
extends RefCounted


const MIN_ENERGY_FRAC: float = 0.55     # well-fed-enough-to-breed gate. Kept comfortably above the gestation drain (a
const GESTATION_SECONDS: float = 12.0   # seconds a bearer carries a pregnancy before giving birth
const GESTATION_OVERHEAD: float = 1.35  # mother's cost / newborn's mass — placenta, remodelling, the work of
                                        # building tissue is never free (mammalian reproductive efficiency
                                        # measures out around 0.7-0.8, i.e. an overhead near 1.3)
const RESORB_FRACTION: float = 0.5      # of the mass already invested, this much is recovered on resorption;
                                        # the rest has already been spent building tissue and is respired
const POST_BIRTH_COOLDOWN: float = 8.0      # seconds a bearer must recover (refeed) before conceiving again — shortened from
                                        # 18 so the herbivore base replaces attrition fast enough to sustain the food web
const MATE_REFRACTORY: float = 6.0      # short pair-bond cooldown put on the partner at conception (stops the SAME
                                        # pairing from both conceiving at once; keeps the effective birth rate sane)
const MATE_SEEK_RADIUS: float = 26.0    # how far a courting adult looks for a mate — widened so a THINNED population
const MATING_RADIUS: float = 3.0        # within this range of a ready mate, conception happens (else steer closer)
const STERILE_FLOOR: float = 0.15       # fertility_mult at/below which the creature can no longer conceive (barren)

const DEFAULT_DENSITY_RADIUS: float = 12.0  # fallback sensing radius if a tuned species omits breed_density_radius
const CROWD_SOFT_FRAC: float = 0.45     # fraction of carrying density at/below which breeding stays at full rate
const CROWD_COOLDOWN_MULT: float = 6.0  # post-birth cooldown multiplier as local density approaches carrying (staggers births)


static func tick(c, delta: float) -> void:
	if c._repro_cd > 0.0:
		c._repro_cd = maxf(0.0, c._repro_cd - delta)
	if not c.pregnant:
		return
	var gest_dur: float = GESTATION_SECONDS / LAAblate.evo_fast()
	var total: float = gestation_cost(c)
	var due: float = total * (delta / maxf(gest_dur, 0.0001))
	var paid: float = LACreatureBodyMass.draw(c, due)
	c._gestation_paid += paid
	# RELATIVE tolerance, not an absolute one. A `due - 0.0001` epsilon is meaningless against an insect's
	# per-frame instalment (order 1e-8 once physiology is derived from real body mass) — the test could never
	# fire, so resorption would never happen for anything smaller than a person.
	if paid < due * 0.999:
		c.energy += c._gestation_paid * RESORB_FRACTION
		if c._material != null and c._material.has_method("respire_at"):
			c._material.respire_at(c.global_position, c._gestation_paid * (1.0 - RESORB_FRACTION))
		c.pregnant = false
		c._gestation_t = 0.0
		c._gestation_paid = 0.0
		c._mate = null
		c._repro_cd = POST_BIRTH_COOLDOWN / LAAblate.evo_fast()
		LASimReport.event("resorption", {"species": c.species})
		return
	c._gestation_t -= delta
	if c._gestation_t <= 0.0:
		_give_birth(c)


static func gestation_cost(c) -> float:
	return LACreatureBodyMass.live_mass(c.config) * GESTATION_OVERHEAD


## True once this creature could start a pregnancy RIGHT NOW: mature, not already pregnant, off cooldown,
## well-fed, AND its species is still below its pop_cap (the soft ceiling). Used by the seeker to gate its
## own courtship — the O(n) cap check happens once here per seeker, never per candidate.
static func ready_to_breed(c) -> bool:
	# Only FEMALES initiate: the female is the bearer (she gestates + births) and the chooser. Males court but
	# never start a pregnancy, so the courtship loop runs from the female side and picks the best available male.
	if bool(c.get("is_male")):
		return false
	if not _is_fertile(c):
		return false
	# LOCAL density ceiling: a creature in a neighbourhood already at its carrying density does not breed, so a
	# region settles at carrying capacity instead of overshooting then ageing out together. Counted once per
	# seeker here (O(k), reusing the mate-seek frame index) — never per candidate. Opt-in per species.
	var carry: float = _carrying_density(c)
	if carry > 0.0 and float(_local_conspecifics(c, c.global_position)) >= carry:
		return false
	if c._ecology == null or not c._ecology.has_method("can_species_breed"):
		return false
	return bool(c._ecology.can_species_breed(c.species))


## Per-species LOCAL carrying capacity: the conspecific count (within breed_density_radius) at/above which this
## creature stops breeding. 0/absent = the density rule is OFF for this species (energy + pop_cap regulate it).
static func _carrying_density(c) -> float:
	return float(c.config.get("breed_carrying_density", 0.0))


## Radius over which local conspecific density is sensed (falls back to DEFAULT_DENSITY_RADIUS).
static func _density_radius(c) -> float:
	return float(c.config.get("breed_density_radius", DEFAULT_DENSITY_RADIUS))


## Count of live same-species OTHERS within breed_density_radius of `pos` — the local conspecific density. Reuses
## the frame-stamped spatial index (the same species group the mate-seek queries), so it is O(k), not an O(n) scan.
static func _local_conspecifics(c, pos: Vector3) -> int:
	var radius: float = _density_radius(c)
	var sp: String = "species_" + String(c.species)
	var idx = LACreatureSenses._fresh_index(c, [sp])
	var cands: Array = idx.query(sp, pos, radius)
	var n: int = 0
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		if pos.distance_to((m as Node3D).global_position) <= radius:
			n += 1
	return n


static func _crowd_cooldown_mult(c) -> float:
	var carry: float = _carrying_density(c)
	if carry <= 0.0:
		return 1.0
	var count: float = float(_local_conspecifics(c, c.global_position))
	var soft: float = carry * CROWD_SOFT_FRAC
	if count <= soft:
		return 1.0
	var t: float = clampf((count - soft) / maxf(carry - soft, 0.001), 0.0, 1.0)
	return lerpf(1.0, CROWD_COOLDOWN_MULT, t)


static func _is_fertile(c) -> bool:
	if not c.is_mature() or c.pregnant or c._repro_cd > 0.0:
		return false
	var fert: float = 1.0
	if c.senescence != null:
		fert = c.senescence.fertility_mult(c)
	if fert <= STERILE_FLOOR:
		return false
	var need: float = clampf(MIN_ENERGY_FRAC / clampf(fert, STERILE_FLOOR, 1.0), MIN_ENERGY_FRAC, 0.95)
	return c.energy >= c.max_energy * need


## Cascade gate: should this creature spend a think-frame steering toward a mate? (Just ready_to_breed —
## kept as a named predicate so the call site in Creature.gd reads clearly, mirroring nesting's should_seek_nest.)
static func should_seek_mate(c) -> bool:
	return ready_to_breed(c)


static func courtship_heading(c, pos: Vector3, fallback: Vector3) -> Vector3:
	var mate = _best_mate(c, pos)
	if mate == null:
		return fallback
	var mate3: Node3D = mate as Node3D
	var d: float = pos.distance_to(mate3.global_position)
	if d <= MATING_RADIUS:
		_conceive(c, mate3)
		return fallback
	var toward: Vector3 = mate3.global_position - pos
	if toward.length() > 0.001:
		return toward.normalized()
	return fallback


static func _best_mate(c, pos: Vector3):
	var sp: String = "species_" + String(c.species)
	var idx = LACreatureSenses._fresh_index(c, [sp])
	var cands: Array = idx.query(sp, pos, MATE_SEEK_RADIUS)
	var best = null
	var best_v: float = -1.0e9
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		if not bool(m.get("is_male")) or not _is_fertile(m):
			continue
		var d: float = pos.distance_to((m as Node3D).global_position)
		if d > MATE_SEEK_RADIUS:
			continue
		var v: float = LAAppraisal.mate_value(c, m, d, MATE_SEEK_RADIUS)
		if v > best_v:
			best_v = v
			best = m
	return best


static func _conceive(c, mate) -> void:
	c.pregnant = true
	c._gestation_t = GESTATION_SECONDS / LAAblate.evo_fast()
	c._gestation_paid = 0.0
	c._mate = mate
	if mate != null and is_instance_valid(mate):
		mate._repro_cd = maxf(mate._repro_cd, MATE_REFRACTORY / LAAblate.evo_fast())


static func _give_birth(c) -> void:
	c.pregnant = false
	c._gestation_t = 0.0
	c._gestation_paid = 0.0
	var mate = c._mate if (c._mate != null and is_instance_valid(c._mate)) else null
	c._mate = null
	c._repro_cd = (POST_BIRTH_COOLDOWN / LAAblate.evo_fast()) * _crowd_cooldown_mult(c)
	if c._ecology != null and c._ecology.has_method("birth_offspring"):
		c._ecology.birth_offspring(c.species, c, mate)
