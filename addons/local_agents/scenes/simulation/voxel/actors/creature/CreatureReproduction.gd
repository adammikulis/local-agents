class_name LACreatureReproduction
extends RefCounted

## Per-creature courtship + gestation for LACreature — the individual side of breeding that DISSOLVED the
## old top-down population god-tick (LAEcologyBreeding._tick_breeding). Reproduction is now an emergent
## per-creature drive: a mature, WELL-FED, non-pregnant, off-cooldown adult seeks a nearby mature same-species
## mate (spatial-index query, O(k), like leadership's local_leader), and on reaching one CONCEIVES — the
## bearer enters GESTATION (a timed carry that drains energy every frame), and at term BIRTHS one offspring
## beside itself, then goes on a post-birth cooldown. So a new generation FALLS OUT of animals living and
## eating, not a scripted spawn tick.
##
## STABILITY — conception is gated on two things so the population self-regulates instead of exploding:
##   1. ENERGY: both the bearer and the mate must be well-fed (energy above MIN_ENERGY_FRAC of max). Food and
##      the digestion/metabolism budget therefore throttle breeding emergently — a starving region breeds
##      less, a fat region breeds freely — which is the real regulator.
##   2. The per-species pop_cap SOFT CEILING (LAEcologyBreeding.species_below_cap via the service): a creature
##      cannot conceive once its species is at/over cap, so the population rides up to the cap and holds there
##      (matching the old god-tick's steady state) — the cap is the hard backstop against any runaway.
## In-flight pregnancies complete even if the pop nudges just over cap during gestation, so the population
## oscillates gently around the cap by the number of concurrent pregnancies — bounded, never explosive.
##
## The BIRTH itself reuses the shared heredity machinery (one owner, LAEcologyBreeding): crossover+mutation
## genome from both parents, the bearer's natal nest, and the kinship graph (add_offspring + the mate bond) —
## reached through LAEcologyService.birth_offspring so the creature never depends on the breeding module type.
##
## Called from LACreature._physics_process (tick) like LACreatureMetabolism/LACreatureDigestion, plus a
## courtship-steering hook in the decision cascade (courtship_heading). Mate/gestation state lives on the
## creature as plain fields (pregnant, _gestation_t, _mate, _repro_cd). Static + dependency-free of the
## LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)

# --- tuning (exposed as named consts so the population can be retuned under a live run) --------------------
const MIN_ENERGY_FRAC: float = 0.55     # well-fed-enough-to-breed gate. Kept comfortably above the gestation drain (a
                                        # pregnancy costs GESTATION_ENERGY_COST over gestation ON TOP of metabolism, so
                                        # conceiving while only marginally fed risks starving the mother mid-gestation), but
                                        # low enough that grazers in the cool land band still breed fast enough to keep the
                                        # herbivore base — and the predators that depend on it — supplied. Eased from 0.6.
const GESTATION_SECONDS: float = 12.0   # seconds a bearer carries a pregnancy before giving birth
const GESTATION_ENERGY_COST: float = 24.0   # total energy the bearer pays, drained smoothly across gestation (trimmed from
                                        # 30 so pregnancy is survivable in the cool land band without a starvation death spiral)
const POST_BIRTH_COOLDOWN: float = 13.0     # seconds a bearer must recover (refeed) before conceiving again — shortened from
                                        # 18 so the herbivore base replaces attrition fast enough to sustain the food web
const MATE_REFRACTORY: float = 6.0      # short pair-bond cooldown put on the partner at conception (stops the SAME
                                        # pairing from both conceiving at once; keeps the effective birth rate sane)
const MATE_SEEK_RADIUS: float = 16.0    # how far a courting adult looks for a mate (herds already cluster same-species)
const MATING_RADIUS: float = 3.0        # within this range of a ready mate, conception happens (else steer closer)
# FERTILITY declines with age (LACreatureSenescence.fertility_mult 1.0→0.0 from prime toward max_age). Below
# STERILE_FLOOR an old creature is effectively barren; between there and prime, its effective energy bar rises
# (need = MIN_ENERGY_FRAC / fertility_mult), so breeding TAPERS off with age before ceasing — an emergent
# reproductive-senescence window, straight off the one senescence curve, no per-age cases.
const STERILE_FLOOR: float = 0.15       # fertility_mult at/below which the creature can no longer conceive (barren)


## Per-frame reproduction tick: run the cooldown down, and if pregnant advance the gestation clock, drain the
## gestation energy cost, and give birth at term. Called early in _physics_process (after digestion, before
## the metabolism burn) so the gestation drain is part of this frame's energy accounting. Pure state — no
## steering (that is courtship_heading, driven from the decision cascade). `delta` is the (possibly LOD
## catch-up) frame time, so gestation/cooldown keep correct time for distant creatures too.
static func tick(c, delta: float) -> void:
	if c._repro_cd > 0.0:
		c._repro_cd = maxf(0.0, c._repro_cd - delta)
	if not c.pregnant:
		return
	# Carrying young costs energy every frame (spread the total cost across the gestation period). The period
	# is compressed by LA_EVO_FAST for evolution-observation runs, so the drain uses the same shortened duration
	# and the TOTAL energy cost per birth stays GESTATION_ENERGY_COST regardless of the compression.
	var gest_dur: float = GESTATION_SECONDS / LAAblate.evo_fast()
	c.energy = maxf(0.0, c.energy - GESTATION_ENERGY_COST * (delta / gest_dur))
	c._gestation_t -= delta
	if c._gestation_t <= 0.0:
		_give_birth(c)


## True once this creature could start a pregnancy RIGHT NOW: mature, not already pregnant, off cooldown,
## well-fed, AND its species is still below its pop_cap (the soft ceiling). Used by the seeker to gate its
## own courtship — the O(n) cap check happens once here per seeker, never per candidate.
static func ready_to_breed(c) -> bool:
	if not _is_fertile(c):
		return false
	if c._ecology == null or not c._ecology.has_method("can_species_breed"):
		return false
	return bool(c._ecology.can_species_breed(c.species))


## Lightweight fertility test with NO pop_cap (group-scan) cost — mature, not pregnant, off cooldown, and
## well-fed. Used to filter mate CANDIDATES cheaply inside the seek loop (the cap is checked once for the
## seeker in ready_to_breed, and again implicitly since both share a species).
static func _is_fertile(c) -> bool:
	if not c.is_mature() or c.pregnant or c._repro_cd > 0.0:
		return false
	# Reproductive senescence: fertility falls with age (LACreatureSenescence). An old creature is barren below
	# STERILE_FLOOR; above it, declining fertility RAISES the energy bar to conceive, so breeding tapers off with
	# age before stopping — emergent, from the one senescence curve. Prime creatures (fert 1.0) are unchanged.
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


## Courtship steering (called from the decision cascade when should_seek_mate is true): find the nearest
## fertile same-species mate within MATE_SEEK_RADIUS. If one is within MATING_RADIUS, CONCEIVE (this creature
## becomes the bearer, gestation begins, the partner gets a short refractory) and return `fallback` (no more
## steering needed). Otherwise steer toward the chosen mate, or return `fallback` if none is in range.
static func courtship_heading(c, pos: Vector3, fallback: Vector3) -> Vector3:
	var mate = _nearest_fertile_mate(c, pos)
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


## Nearest fertile, valid, same-species OTHER creature within MATE_SEEK_RADIUS (spatial index, O(k)) —
## mirrors LACreatureLeadership.local_leader's query. Candidates are filtered by the cheap _is_fertile only.
static func _nearest_fertile_mate(c, pos: Vector3):
	var sp: String = "species_" + String(c.species)
	var idx = LACreatureSenses._fresh_index(c, [sp])
	var cands: Array = idx.query(sp, pos, MATE_SEEK_RADIUS)
	var best = null
	var best_d: float = MATE_SEEK_RADIUS
	for m in cands:
		if m == c or not is_instance_valid(m):
			continue
		if not _is_fertile(m):
			continue
		var d: float = pos.distance_to((m as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = m
	return best


## Begin a pregnancy: `c` is the bearer (carries + births), `mate` the other parent. The partner is put on a
## short refractory so the same pairing doesn't both conceive at once; its genome/lineage is captured at birth.
## `mate` is untyped so the dynamic `_repro_cd` field access resolves at runtime (like the other Creature* helpers).
static func _conceive(c, mate) -> void:
	c.pregnant = true
	c._gestation_t = GESTATION_SECONDS / LAAblate.evo_fast()
	c._mate = mate
	if mate != null and is_instance_valid(mate):
		mate._repro_cd = maxf(mate._repro_cd, MATE_REFRACTORY / LAAblate.evo_fast())


## Give birth at term: route through the shared heredity machinery (LAEcologyService.birth_offspring →
## LAEcologyBreeding.birth_child) so the offspring gets the crossover+mutation genome, the natal nest, and the
## kinship edges — then clear the pregnancy and start the post-birth cooldown. If the mate has since died the
## breeding module births from the bearer alone (a single-parent line) rather than losing the young.
static func _give_birth(c) -> void:
	c.pregnant = false
	c._gestation_t = 0.0
	var mate = c._mate
	c._mate = null
	c._repro_cd = POST_BIRTH_COOLDOWN / LAAblate.evo_fast()
	if c._ecology != null and c._ecology.has_method("birth_offspring"):
		c._ecology.birth_offspring(c.species, c, mate)
