class_name LACreatureSetup
extends RefCounted


const MATURITY_VARIANCE: float = 0.45    # ±fraction on per-individual maturity_age
const LIFESPAN_VARIANCE: float = 0.45    # ±fraction on per-individual max_age — WIDE, so even a big single-
                                         # generation boom (an overshoot cohort) ages out over a LONG spread of
                                         # time (overlapping generations) instead of dying together in one pulse
                                         # that crashes the population below its recovery floor (the boom-bust)


static func apply(c, terrain_arg, config_arg: Dictionary, genome_arg) -> void:
	c.terrain = terrain_arg if terrain_arg != null else LAFlatGroundTerrain.new()
	if genome_arg != null:
		c._genome = genome_arg
		c.config = c._genome.express()
	else:
		c.config = config_arg.duplicate(true)
		c._genome = LADNA.from_config(c.config).seed_variation(LASimRng.for_domain("life"))
		c.config = c._genome.express()
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
	c.maturity_age *= 1.0 + LASimRng.for_domain("life").randf_range(-MATURITY_VARIANCE, MATURITY_VARIANCE)
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
	# RESPIRATORY ANATOMY, expressed before the body ledger because the ledger's derived rates read it.
	c.respiratory_capacity = float(config.get("respiratory_capacity", c.respiratory_capacity))
	c.thermogenesis = float(config.get("thermogenesis", c.thermogenesis))
	# HP scales with body size: a bigger animal endures more before a blast kills it.
	c.max_health = float(config.get("max_health", 30.0 + c.size * 120.0))
	c.health = c.max_health
	c.breath_capacity = float(config.get("breath_capacity", c.breath_capacity))
	c._breath = c.breath_capacity
	c.breathes = String(config.get("breathes", c.breathes))
	LACreatureBodyMass.apply(c, config)
	c.max_age = float(config.get("max_age", maxf(c.maturity_age * 5.0, 60.0)))
	c.max_age *= 1.0 + LASimRng.for_domain("life").randf_range(-LIFESPAN_VARIANCE, LIFESPAN_VARIANCE)
	if genome_arg == null:
		c.age = LASimRng.for_domain("life").randf() * c.maturity_age * 1.8
	if config.has("sex"):
		c.is_male = String(config.get("sex", "")) == "male"
	else:
		c.is_male = LASimRng.for_domain("life").randf() < 0.5
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
	LACreatureAffiliation.setup(c)
	# Nesting is general and config-driven: ANY species that actually nests/shelters sets nests:true
	# (birds roost in trees, mammals/snakes burrow or den) — no per-species branch here.
	c.nests = bool(config.get("nests", c.nests))
	c.nest_habitat = String(config.get("nest_habitat", "tree" if c.can_fly else "ground"))
	c.llm_enabled = bool(config.get("llm_enabled", c.llm_enabled))   # export is the default; config may override
	c.body_temp = LACreatureRespiration.band_optimum_c()
	c._target_altitude = c.cruise_height
	c.state = "cruise" if c.can_fly else "wander"
	var rng: LASimRng = LASimRng.for_domain("life")
	c._poop_cd = rng.randf_range(20.0, 45.0)
	c._call_cd = rng.randf_range(0.0, 2.0)

	c.collision_layer = 2
	c.collision_mask = 0                  # movement is manual; picked via layer-2 query
	LACreatureBody.build_body(c)
	c.add_to_group(c.GROUP_SELECTABLE)
	c.add_to_group(c._species_group(c.species))
	c.add_to_group(c.GROUP_CREATURE)
	c._heading = Vector3(rng.randf() * 2.0 - 1.0, 0.0, rng.randf() * 2.0 - 1.0).normalized()
	if c._heading == Vector3.ZERO:
		c._heading = Vector3.FORWARD

	# The fast/slow brain: born with the genome's baked instinct priors; learns the rest by living
	# and by watching kin. The shared slow-brain scheduler is injected separately (set_cognition_scheduler).
	c._cognition = LACognition.new()
	c._cognition.seed_from_genome(c._genome)
	LACreatureChemSense.seed_priors(c)
	# Size the gut from max energy and pick the microbiome from diet (herbivores ferment plant matter).
	LACreatureDigestion.setup(c)
	c.disease = LACreatureDisease.new()      # per-creature disease/immune state (owned off this monolith)
	c.disease.setup(c, config)
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
	LACreatureBodyMass.note_spawn(c, genome_arg != null)
