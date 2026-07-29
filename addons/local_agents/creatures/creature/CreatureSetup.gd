class_name LACreatureSetup
extends RefCounted

## Spawn-time CONFIGURATION of a LocalAgentCreature: the whole "express the genome/species config onto this
## individual" pass, factored out of the main brain. LocalAgentCreature.setup() is now a one-line forwarder
## into apply().
##
## What it does, in order:
##   * resolve the terrain dependency (flat-ground adapter when no voxel planet is injected);
##   * express the GENOME if one was passed (a bred/evolved offspring), else build an ancestral genome from
##     the species template so EVERY creature has heritable genes;
##   * copy the config keys onto the live traits, with the per-individual jitter that DESYNCS a cohort
##     (maturity, lifespan, founder age spread) and the ~50/50 sex draw on the seeded sim RNG;
##   * build the body + groups + starting heading;
##   * construct the per-creature sub-state modules (cognition, chem-sense priors, digestion, disease,
##     microbiome, bond, senescence), each of which owns its own state off the monolith.
##
## Static + dynamic field access on the passed creature, like the other Creature* modules, so there is no cyclic class
## reference. (Explicit types only, no ':=' inferred typing.)

# COHORT DESYNC: every individual gets its OWN maturity/lifespan, jittered around the species value, so a
# generation doesn't mature, breed and die in lockstep. Without this, founders (all spawned at age 0 with an
# identical species maturity_age) came of age together, bred in one pulse, then that whole cohort aged out
# together — a synchronized boom-bust (the ~frame-360 peak then crash, and the old-age death spike). The spread
# smears each of those events over a window, so births/deaths overlap generations and the population oscillates
# gently around carrying capacity instead of pulsing. randf is on the run's seeded RNG → reproducible.
const MATURITY_VARIANCE: float = 0.45    # ±fraction on per-individual maturity_age
const LIFESPAN_VARIANCE: float = 0.45    # ±fraction on per-individual max_age — WIDE, so even a big single-
                                         # generation boom (an overshoot cohort) ages out over a LONG spread of
                                         # time (overlapping generations) instead of dying together in one pulse
                                         # that crashes the population below its recovery floor (the boom-bust)


static func apply(c, terrain_arg, config_arg: Dictionary, genome_arg) -> void:
	# Terrain is the only hard dependency for the movement path. With no voxel planet injected (a standalone
	# creature on a plain floor), default to the FLAT-ground adapter so up_at/surface_point/ground_point/etc.
	# resolve against y=0 instead of null-derefing. VoxelWorld still injects LAVoxelTerrainService (the sphere
	# adapter) for the planet path; both honour the same duck-typed terrain contract (see LAFlatGroundTerrain).
	c.terrain = terrain_arg if terrain_arg != null else LAFlatGroundTerrain.new()
	# Genome drives the config: an offspring/evolved creature is passed a genome and we express it;
	# otherwise we build an ancestral genome from the species template so EVERY creature has
	# heritable genes (and per-individual variation once bred).
	if genome_arg != null:
		c._genome = genome_arg
		c.config = c._genome.express()
	else:
		c.config = config_arg.duplicate(true)
		c._genome = LADNA.from_config(c.config)
	var config: Dictionary = c.config
	c.species = String(config.get("species", c.species))
	c.diet = String(config.get("diet", c.diet))
	c.speed = float(config.get("speed", c.speed))
	c.size = float(config.get("size", c.size))
	c.color = config.get("color", c.color)
	c.can_fly = bool(config.get("can_fly", c.can_fly))
	c.cruise_height = float(config.get("cruise_height", c.cruise_height))
	c.sense_radius = float(config.get("sense_radius", c.sense_radius))
	c.maturity_age = float(config.get("maturity_age", c.maturity_age))
	# COHORT DESYNC (see MATURITY_VARIANCE): per-individual jitter so a generation doesn't come of age in
	# lockstep. Applied to the founder template AND to bred offspring (extra non-heritable phenotype spread on
	# top of the genome's own maturity gene) — both need breaking up. max_age is jittered separately below.
	c.maturity_age *= 1.0 + randf_range(-MATURITY_VARIANCE, MATURITY_VARIANCE)
	c.preys_on = PackedStringArray(config.get("preys_on", PackedStringArray()))
	c.flees_from = PackedStringArray(config.get("flees_from", PackedStringArray()))
	c.herd = bool(config.get("herd", c.herd))
	c.leader_loyalty = float(config.get("leader_loyalty", c.leader_loyalty))
	c.hierarchy = String(config.get("hierarchy", c.hierarchy))
	c.nocturnal = bool(config.get("nocturnal", c.nocturnal))
	c.flock_cohesion = float(config.get("flock_cohesion", c.flock_cohesion))
	c.flock_alignment = float(config.get("flock_alignment", c.flock_alignment))
	c.flock_separation = float(config.get("flock_separation", c.flock_separation))
	c.flock_radius = float(config.get("flock_radius", c.sense_radius))
	c.flock_weight = float(config.get("flock_weight", c.flock_weight))
	c.max_energy = float(config.get("max_energy", 100.0))
	c.energy = c.max_energy
	# HP scales with body size: a bigger animal endures more before a blast kills it.
	c.max_health = float(config.get("max_health", 30.0 + c.size * 120.0))
	c.health = c.max_health
	c.metabolism = float(config.get("metabolism", c.metabolism))
	c.breath_capacity = float(config.get("breath_capacity", c.breath_capacity))
	c._breath = c.breath_capacity
	c.breathes = String(config.get("breathes", c.breathes))
	c.max_hydration = float(config.get("max_hydration", 100.0))
	c.hydration = c.max_hydration
	c.thirst_rate = float(config.get("thirst_rate", c.thirst_rate))
	c.food_value = float(config.get("food_value", c.size * 90.0))
	c.max_age = float(config.get("max_age", maxf(c.maturity_age * 5.0, 60.0)))
	# COHORT DESYNC: independent lifespan jitter so an age-matched cohort doesn't die of old age all at once
	# (the old-age death spike). max_age is not a heritable gene (it tracks maturity_age*5), so this is the only
	# spread it gets — apply it per individual.
	c.max_age *= 1.0 + randf_range(-LIFESPAN_VARIANCE, LIFESPAN_VARIANCE)
	# FOUNDER AGE SPREAD: the starting population is placed all at once. If every founder began at age 0 they
	# would all cross maturity together and breed in one pulse (the initial boom that then busts). Seed founders
	# across a range of ages — a natural standing age structure of juveniles through adults — so births spread out
	# from frame one. Bred offspring (genome passed) are TRUE newborns (age 0); only the initial cohort is spread.
	if genome_arg == null:
		# Spread founders across juvenile→young-adult (not up to old age): enough to desync the first maturation
		# wave, but WITHOUT front-loading old-age deaths by seeding founders already near the end of their lives
		# (which threw the initial cohort straight into a die-off). A standing age structure of the young + prime.
		c.age = randf() * c.maturity_age * 1.8
	# SEX: ~50/50 at birth via the seeded sim RNG (reproducible; not a heritable trait). A config override
	# ("sex": "male"/"female") is honoured for tests/set-pieces.
	if config.has("sex"):
		c.is_male = String(config.get("sex", "")) == "male"
	else:
		c.is_male = LASimRng.shared().randf() < 0.5
	# ORNAMENT TINT: warm a displaying male's base colour by his display gene so brighter males are visibly
	# brighter. Static (set once from the gene) — as sexual selection raises the lineage's mean display gene the
	# whole population visibly warms over generations, without a per-frame tint that would fight the debug tints.
	var display_gene: float = clampf(float(config.get("display", 0.0)), 0.0, 1.0)
	if c.is_male and display_gene > 0.01:
		c.color = c.color.lerp(Color(1.0, 0.72, 0.28), 0.6 * display_gene)
	c.hungry_at = float(config.get("hungry_at", c.hungry_at))
	c.throws = bool(config.get("throws", c.throws))
	c.throw_range = float(config.get("throw_range", c.throw_range))
	# Perception genes (with sensible per-body defaults) + kin id for social learning.
	c.eye_fov = float(config.get("eye_fov", c.eye_fov))
	c.hearing_range = float(config.get("hearing_range", c.sense_radius * 1.5))
	c.family_id = int(config.get("family_id", c.get_instance_id()))
	# Nesting is general and config-driven: ANY species that actually nests/shelters sets nests:true
	# (birds roost in trees, mammals/snakes burrow or den) — no per-species branch here.
	c.nests = bool(config.get("nests", c.nests))
	c.nest_habitat = String(config.get("nest_habitat", "tree" if c.can_fly else "ground"))
	c.llm_enabled = bool(config.get("llm_enabled", c.llm_enabled))   # export is the default; config may override
	c._target_altitude = c.cruise_height
	c.state = "cruise" if c.can_fly else "wander"
	c._poop_cd = randf_range(20.0, 45.0)
	c._call_cd = randf_range(0.0, 2.0)

	c.collision_layer = 2
	c.collision_mask = 0                  # movement is manual; picked via layer-2 query
	LACreatureBody.build_body(c)
	c.add_to_group(c.GROUP_SELECTABLE)
	c.add_to_group(c._species_group(c.species))
	c.add_to_group(c.GROUP_CREATURE)
	c._heading = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0).normalized()
	if c._heading == Vector3.ZERO:
		c._heading = Vector3.FORWARD

	# The fast/slow brain: born with the genome's baked instinct priors; learns the rest by living
	# and by watching kin. The shared slow-brain scheduler is injected separately (set_cognition_scheduler).
	c._cognition = LACognition.new()
	c._cognition.seed_from_genome(c._genome)
	# Born-in chemical instincts: the genome's cue priors become starting scent valences (a blood-wary
	# lineage is born avoiding the blood scent, a carrion-hungry one drawn to the food scent). Lifetime
	# smell/taste learning refines them and observe() spreads them to kin — see LACreatureChemSense.
	LACreatureChemSense.seed_priors(c)
	# Size the gut from max energy and pick the microbiome from diet (herbivores ferment plant matter).
	LACreatureDigestion.setup(c)
	c.disease = LACreatureDisease.new()      # per-creature disease/immune state (owned off this monolith)
	c.disease.setup(c, config)
	# Gut flora, seeded from diet (herbivores born plant-fermenting); it ADAPTS to what the animal actually eats
	# and modulates digestive yield (see LACreatureMicrobiome + LACreatureDigestion). Dynamicises the old static
	# `microbiome` scalar. Owned off this monolith.
	c.gut_microbiome = LACreatureMicrobiome.new()
	c.gut_microbiome.setup(c, config)
	# Per-creature tameness/companion state (owned off this monolith). A wild creature starts untamed;
	# friendly interaction (feeding/petting, calm proximity to the hand) raises the bond — see LACreatureBond.
	c.bond = LACreatureBond.new()
	c.bond.setup(c, config)
	# Per-creature ageing/senescence state (owned off this monolith). Captures this individual's youthful
	# speed/max_energy baselines NOW (after config/genome expression) so age can grade them down later.
	c.senescence = LACreatureSenescence.new()
	c.senescence.setup(c)
