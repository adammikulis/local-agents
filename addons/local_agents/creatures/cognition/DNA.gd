class_name LADNA
extends RefCounted

## A creature's heritable makeup as a LITERAL DNA SEQUENCE: a strand of 2-bit symbols (four bases,
## A/C/G/T ≡ 0..3), grouped four-to-a-codon (one byte, 0..255), against a FIXED locus table that assigns each
## gene a span of codons. A gene's numeric value is DECODED from its codons (combined big-endian, normalised
## to the gene's [min, max]); an offspring is a genuine RECOMBINATION + point-mutation of two parent strands,
## so drift, blending and (through non-coding SPACER regions between genes) pleiotropy and frameshift room
## all fall out of sequence operations rather than per-trait arithmetic. This is the heredity substrate 0.4
## builds on: chemical-affinity priors, an evolvable diet gradient, personality, and metabolism genes all
## ride the one strand.
##
## Three parts to an individual:
##   * strand:     the codon sequence, holding the quantitative genes (speed…flock_weight), the NEW heritable content
##                 (carnivory diet-gradient, neophobia/boldness personality, basal/active metabolism-rate,
##                 scent/taste senses), a regulatory 'cue_priors' region (born-in chemical valences like
##                 innate blood-wariness for the coming affinity system), plus non-coding spacers + a block of
##                 RESERVED spare loci so future genes never invalidate an already-saved genome (forward-compat).
##   * instincts:  a SMALL set of genetically-baked reaction priors (signature_key:int -> {action, weight}).
##                 Unlike quantitative genes these have arbitrary keys, so they live beside the strand as a
##                 Dictionary. They change only slowly: by crossover, forgetting, and rare "canalization" of a
##                 habit a lineage has relied on for generations (the Baldwin effect).
##   * base_config: species identity (colour, preys_on, flees_from, flags…), carried verbatim and never mutated.
##                 DIET is the one exception: it is not carried here but expressed from the evolvable
##                 `carnivory` gradient (bucketed herbivore/omnivore/carnivore) so it can blend and evolve
##                 while predation targets (preys_on) stay identity.
##
## COMPATIBILITY SEAM: express() decodes to the trait Dictionary LocalAgentCreature.setup() consumes. It
## overrides a gene only when the species config actually set it, and adds the new keys on top.
##
## DETERMINISM: every stochastic draw (crossover points, mutations, canalization) goes through an injected
## LASimRng (never a bare randf()), so a run reproduces from its seed.
##
## (Explicit types only, no ':=' inferred typing.)

# Bump when the on-strand layout changes in a way a loader must know about. Saved genomes stamp this; the
# RESERVED block means adding genes (claiming reserved loci) need NOT bump it — old saves still decode.
const GENOME_FORMAT_VERSION: int = 1

const SYMBOLS_PER_CODON: int = 4       # four 2-bit bases per codon → one byte (0..255) of resolution
const SYMBOL_MAX: int = 3              # a base is 0..3 (A/C/G/T)

# The legacy quantitative genes LocalAgentCreature.setup() consumes. Kept as the canonical list so callers
# can enumerate them and so express() reproduces the SAME-named floats. (Plain Array — a PackedStringArray
# constructor is not a constant expression.)
## There is no `metabolism` gene: a body's burn rate is its gas-exchange surface times the local oxygen times
## the temperature band (LACreatureRespiration). `size` encodes it, because area is size². `max_energy` and
## `thirst_rate` are likewise derived from the species' measured body mass (LACreatureBodyMass).
const GENE_KEYS: Array = [
	"speed", "size", "sense_radius", "eye_fov",
	"maturity_age", "throw_range", "cruise_height",
	"flock_cohesion", "flock_alignment", "flock_separation", "flock_radius", "flock_weight",
]

# The regulatory cue-prior loci → born-in chemical valences the affinity system reads (a positive value =
# innate attraction, drives caution/appetite before anything is learned).
const CUE_KEYS: Array = ["blood_wariness", "water_affinity", "carrion_appetite"]

# THE FIXED LOCUS TABLE, in strand order. Each row: [name, kind, codons, min, max].
#   kind "gene"     — a quantitative gene decoded to out[name] (legacy genes gated by whether the species set
#                     them; NEW genes always expressed).
#   kind "cue"      — a regulatory locus decoded into the cue_priors dict.
#   kind "spacer"   — non-coding DNA between regions: recombination/pleiotropy room + where indels are absorbed.
#   kind "reserved" — spare loci a future gene claims WITHOUT changing strand length (forward-compat).
const LOCI: Array = [
	["speed", "gene", 2, 0.0, 30.0],
	["size", "gene", 2, 0.0, 8.0],
	["sense_radius", "gene", 2, 0.0, 80.0],
	["eye_fov", "gene", 2, 0.0, 360.0],
	# TWO LOCI RESERVED. `max_energy` and `thirst_rate` are not species data: LACreatureBodyMass derives the
	# reserve from the species' measured mass and the water turnover from the body's gas-exchange surface. A
	# legacy gene expresses only when the species config sets its key, and neither key is set, so neither can
	# reach a phenotype. They are `reserved` rather than deleted so the strand LENGTH and every following
	# locus offset are unchanged.
	#
	["_retired_max_energy", "reserved", 2, 0.0, 1.0],
	["_retired_thirst_rate", "reserved", 2, 0.0, 1.0],
	["maturity_age", "gene", 2, 0.0, 120.0],
	["throw_range", "gene", 2, 0.0, 40.0],
	["cruise_height", "gene", 2, 0.0, 60.0],
	["_spacer_a", "spacer", 2, 0.0, 0.0],
	["flock_cohesion", "gene", 1, 0.0, 4.0],
	["flock_alignment", "gene", 1, 0.0, 4.0],
	["flock_separation", "gene", 1, 0.0, 4.0],
	["flock_radius", "gene", 2, 0.0, 80.0],
	["flock_weight", "gene", 1, 0.0, 4.0],
	["_spacer_b", "spacer", 2, 0.0, 0.0],
	["carnivory", "gene", 1, 0.0, 1.0],
	["neophobia", "gene", 1, 0.0, 1.0],
	["boldness", "gene", 1, 0.0, 1.0],
	# RESPIRATORY CAPACITY and THERMOGENESIS are the anatomy and physiology the reaction reads
	# (LACreatureRespiration): how much gas-exchange surface the body packs into its area, and how hard it
	# raises oxygen throughput when it falls below its own enzyme optimum.
	#
	# THERMOGENESIS IS WHERE ENDOTHERM AND ECTOTHERM LIVE, and it is a continuum with no flag anywhere. At 0 the
	# cold-drive term vanishes identically: body temperature tracks ambient, metabolic rate rides the
	# temperature band up and down with the weather, and the animal goes torpid in the cold — an ectotherm, by
	# arithmetic rather than by a branch. High values buy a stable warm body and pay for it in oxygen and fuel.
	# Because it is an ordinary heritable locus under ordinary selection, which strategy pays on THIS planet is
	# something the run decides, not something a species table asserts.
	["respiratory_capacity", "gene", 1, 0.25, 2.5],
	["thermogenesis", "gene", 1, 0.0, 1.0],
	["scent_acuity", "gene", 1, 0.0, 1.0],
	["taste_sensitivity", "gene", 1, 0.0, 1.0],
	["_spacer_c", "spacer", 2, 0.0, 0.0],
	["blood_wariness", "cue", 1, 0.0, 1.0],
	["water_affinity", "cue", 1, 0.0, 1.0],
	["carrion_appetite", "cue", 1, 0.0, 1.0],
	["_spacer_d", "spacer", 2, 0.0, 0.0],
	# Immune CONSTITUTION — how well the animal fights off infection (read by LACreatureDisease). Heritable +
	# mutable, so an epidemic SELECTS for it: plague survivors pass on higher constitution and the population
	# evolves disease resistance. Claimed from a reserved locus, so the strand length is unchanged.
	["constitution", "gene", 2, 0.3, 2.5],
	# DISPLAY — heritable ornament/brightness (read by LAAppraisal). Expressed strongly in males, faintly in
	# females. An HONEST signal: maintaining a bright display costs energy every tick (LACreatureMetabolism) and
	# dulls with poor health/age, so only genuinely fit males stay bright. Females CHOOSE the brightest,
	# highest-dominance males (LACreatureReproduction) → the gene is under sexual selection and a lineage visibly
	# brightens over generations. Claimed from a reserved locus, so the strand length is unchanged.
	["display", "gene", 2, 0.0, 1.0],
	# THERMAL NICHE — where this genome's enzymes work best, and how wide a range they tolerate. Heritable,
	# so an ice cap or a hot spring selects the optimum toward itself and a seasonal band selects for width.
	# Both envelopes are LAPhysical's rather than anybody's: an optimum may sit anywhere liquid water and
	# intact protein overlap, and tolerance is a FRACTION of that envelope's half-range, not a °C somebody
	# picked. Tolerance 0 is a legal genome that cannot function at any temperature and dies at once.
	# Claimed from reserved loci, so strand length and every following offset are unchanged.
	["thermal_optimum_c", "gene", 2, LAPhysical.WATER_FREEZE_C, LAPhysical.PROTEIN_DENATURE_C],
	["thermal_tolerance", "gene", 2, 0.0, 1.0],
	# ADULT BODY MASS, log10 kilograms. The roster spans 5 mg to 400 kg, which is why this is a LOG locus —
	# the note above saying a linear one cannot hold it is answered by taking the log rather than by
	# keeping mass out of the genome. -6..3 spans a microgram to a tonne. Heritable, so a lineage can
	# actually change size: island dwarfing, Bergmann gigantism and r/K shifts are reachable from here.
	["log10_adult_mass_kg", "gene", 2, -6.0, 3.0],
	["_reserved_5", "reserved", 2, 0.0, 1.0],
	["_reserved_6", "reserved", 2, 0.0, 1.0],
	["_reserved_7", "reserved", 2, 0.0, 1.0],
]

# Diet gradient bucketing: carnivory below LOW → herbivore, below HIGH → omnivore, else carnivore.
const DIET_HERBIVORE_MAX: float = 0.34
const DIET_OMNIVORE_MAX: float = 0.66

# Baldwin instincts are deliberately few — instinct is expensive to encode; real genomes bake only the most
# vital reactions and leave the rest to learning.
const MAX_INSTINCTS: int = 5
const CANALIZE_MIN_WEIGHT: float = 5.0     # only a lifelong, near-max-confidence habit may assimilate
const CANALIZE_CHANCE: float = 0.06        # and even then only rarely per breeding
const INSTINCT_SEED_WEIGHT: float = 1.6

# Mutation tuning: per-codon point-mutation probability and the rare non-coding indel chance.
const DEFAULT_MUTATION_RATE: float = 0.08
const INDEL_RATE: float = 0.03
const INSTINCT_FORGET_CHANCE: float = 0.15

# Lazily-built, cached layout: name -> {start_codon, codons, min, max, kind}, plus derived totals + spacer list.
static var _layout_by_name: Dictionary = {}
static var _total_codons: int = 0
static var _spacers: Array = []            # [{start_codon, codons}] — where indels are absorbed
static var _layout_built: bool = false

var base_config: Dictionary = {}           # species identity (colour/preys_on/flags…), never mutated
var strand: PackedByteArray = PackedByteArray()   # the literal codon sequence (one byte per base, 0..3)
var coded_genes: Dictionary = {}           # legacy gene name -> true if the species config set it (express gate)
var instincts: Dictionary = {}             # signature_key:int -> {action:String, weight:float}
var generation: int = 0


# --- LAYOUT ------------------------------------------------------------------------------------------------

## Build (once) and return the locus map. Assigns each row a start codon so gene ranges are fixed offsets.
static func _layout() -> Dictionary:
	if _layout_built:
		return _layout_by_name
	_layout_by_name = {}
	_spacers = []
	var codon_cursor: int = 0
	for row in LOCI:
		var name: String = String(row[0])
		var kind: String = String(row[1])
		var codons: int = int(row[2])
		_layout_by_name[name] = {
			"start_codon": codon_cursor, "codons": codons,
			"min": float(row[3]), "max": float(row[4]), "kind": kind,
		}
		if kind == "spacer":
			_spacers.append({"start_codon": codon_cursor, "codons": codons})
		codon_cursor += codons
	_total_codons = codon_cursor
	_layout_built = true
	return _layout_by_name


## Total codons on the strand (its fixed length in codons).
static func total_codons() -> int:
	_layout()
	return _total_codons


## Introspection for the evolution/affinity work: the ordered locus rows (name, kind, codons, min, max).
static func locus_list() -> Array:
	return LOCI.duplicate(true)


# --- CODON READ / WRITE ------------------------------------------------------------------------------------

static func _codon_byte(s: PackedByteArray, codon_index: int) -> int:
	var b: int = codon_index * SYMBOLS_PER_CODON
	return (int(s[b]) << 6) | (int(s[b + 1]) << 4) | (int(s[b + 2]) << 2) | int(s[b + 3])


static func _set_codon_byte(s: PackedByteArray, codon_index: int, value: int) -> void:
	var b: int = codon_index * SYMBOLS_PER_CODON
	s[b] = (value >> 6) & SYMBOL_MAX
	s[b + 1] = (value >> 4) & SYMBOL_MAX
	s[b + 2] = (value >> 2) & SYMBOL_MAX
	s[b + 3] = value & SYMBOL_MAX


## Decode one gene's codon span (big-endian byte combine) to a float in its [min, max].
func decode_gene(name: String) -> float:
	var loc = LADNA._layout().get(name, null)
	if loc == null:
		return 0.0
	var codons: int = int(loc["codons"])
	var ival: int = 0
	for c in range(codons):
		ival = (ival << 8) | LADNA._codon_byte(strand, int(loc["start_codon"]) + c)
	var maxval: int = (1 << (8 * codons)) - 1
	var t: float = float(ival) / float(maxval)
	return float(loc["min"]) + t * (float(loc["max"]) - float(loc["min"]))


## Encode a float into one gene's codon span (inverse of decode_gene), clamped to [min, max].
func encode_gene(name: String, value: float) -> void:
	var loc = LADNA._layout().get(name, null)
	if loc == null:
		return
	var codons: int = int(loc["codons"])
	var lo: float = float(loc["min"])
	var hi: float = float(loc["max"])
	var t: float = 0.0
	if hi > lo:
		t = clampf((value - lo) / (hi - lo), 0.0, 1.0)
	var maxval: int = (1 << (8 * codons)) - 1
	var ival: int = int(round(t * float(maxval)))
	var start: int = int(loc["start_codon"])
	for c in range(codons):
		var shift: int = 8 * (codons - 1 - c)
		LADNA._set_codon_byte(strand, start + c, (ival >> shift) & 0xFF)


# --- CONSTRUCTION ------------------------------------------------------------------------------------------

## Build the ancestral genome for a species from its static config template. Legacy genes are encoded from
## the template's numbers (and marked coded so express() overrides only those the species actually set).
## The new genes are seeded to sensible born-in values: carnivory from the
## species diet (so gen-0 expresses the same diet, evolvably), personality/senses/metabolism-rate and
## the cue priors to config-or-neutral defaults. Instincts start empty — gen-0 animals rely on baked reflexes,
## the slow brain, and watching kin.
static func from_config(cfg: Dictionary) -> LADNA:
	var g: LADNA = LADNA.new()
	g.base_config = cfg.duplicate(true)
	g.strand = LADNA._blank_strand()
	# Legacy quantitative genes: encode the ones the species set; leave the rest at neutral (mid-range) and
	# ungated so express() won't override an absent gene.
	for k in GENE_KEYS:
		if cfg.has(k):
			g.encode_gene(k, float(cfg[k]))
			g.coded_genes[k] = true
		else:
			g._encode_midpoint(k)
	# flock_radius defaults to sense_radius when a species omits it.
	if not cfg.has("flock_radius") and cfg.has("sense_radius"):
		g.encode_gene("flock_radius", float(cfg["sense_radius"]))
		g.coded_genes["flock_radius"] = true
	# NEW heritable genes — born-in defaults (config-overridable), always expressed.
	g.encode_gene("carnivory", LADNA._carnivory_from_diet(String(cfg.get("diet", "herbivore"))))
	g.encode_gene("neophobia", float(cfg.get("neophobia", 0.5)))
	g.encode_gene("boldness", float(cfg.get("boldness", 0.5)))
	g.encode_gene("respiratory_capacity", float(cfg.get("respiratory_capacity", 1.0)))
	# Ancestral thermogenesis: a species that says nothing starts ECTOTHERMIC (0.0), which is both the ancestral
	# condition in life's actual history and the honest default — endothermy is the derived, expensive trait and
	# a lineage should have to be given it or evolve it. Birds and mammals declare it; everything else does not.
	g.encode_gene("thermogenesis", float(cfg.get("thermogenesis", 0.0)))
	# Ancestral thermal niche: a genome that declares nothing is an unspecialised GENERALIST — its optimum sits
	# at the middle of the envelope and it spans all of it (tolerance 1.0). That is the least assertive prior
	# available, not a comfort range anybody measured: it claims no adaptation and lets the planet narrow the
	# lineage. A zero here would be a genome that cannot function at any temperature, which is a legal genome
	# but a terrible default, and _blank_strand() is zero-filled, so both loci MUST be encoded explicitly.
	g.encode_gene("thermal_optimum_c", float(cfg.get("thermal_optimum_c",
		(LAPhysical.WATER_FREEZE_C + LAPhysical.PROTEIN_DENATURE_C) * 0.5)))
	g.encode_gene("thermal_tolerance", float(cfg.get("thermal_tolerance", 1.0)))
	g.encode_gene("log10_adult_mass_kg",
		log(maxf(float(cfg.get("mass_kg", LACreatureBodyMass.REFERENCE_MASS_KG)), 1.0e-9)) / log(10.0))
	g.encode_gene("scent_acuity", float(cfg.get("scent_acuity", 0.5)))
	g.encode_gene("taste_sensitivity", float(cfg.get("taste_sensitivity", 0.5)))
	g.encode_gene("constitution", float(cfg.get("constitution", 1.2)))   # healthy immune default; epidemics select it up
	g.encode_gene("display", float(cfg.get("display", 0.3)))   # modest starting ornament; sexual selection drives it up
	# Regulatory cue priors — born-in chemical valences for the coming affinity system.
	var carn: float = LADNA._carnivory_from_diet(String(cfg.get("diet", "herbivore")))
	g.encode_gene("blood_wariness", float(cfg.get("blood_wariness", 1.0 - carn)))
	g.encode_gene("water_affinity", float(cfg.get("water_affinity", 0.5)))
	g.encode_gene("carrion_appetite", float(cfg.get("carrion_appetite", carn * 0.6)))
	return g


## STANDING GENETIC VARIATION for a founding population: scatter every quantitative locus by a small fraction
## around the species template, so the founders of a species are individuals rather than CLONES.
##
## WHY NOT JUST CALL mutate(). That was tried and it is the wrong operator here, for a measurable reason. A
## point mutation flips one 2-bit base, and in the high base of a codon that moves the decoded value by up to
## 192/255 of the locus's ENTIRE declared range — for `size`, declared 0..8, a single hit is a body-size change
## of several metres. Mutation is a rare, large, mostly-fatal event; standing variation within a wild
## population is a small continuous scatter about the mean, and they are not the same operator.
##
## Body size in a real wild population varies by a few per cent to a fifth about the species mean, so a small
## fractional jitter is both the honest model and the safe one. Applied through the seeded LASimRng, so a run
## still reproduces exactly from its seed.
const FOUNDER_VARIATION: float = 0.08     # +/- fraction applied to each quantitative locus at founding

func seed_variation(rng: LASimRng, frac: float = FOUNDER_VARIATION) -> LADNA:
	if rng == null:
		rng = LASimRng.shared()
	for row in LOCI:
		var kind: String = String(row[1])
		if kind != "gene" and kind != "cue":
			continue
		var name: String = String(row[0])
		encode_gene(name, decode_gene(name) * (1.0 + rng.randf_range(-frac, frac)))
	return self


## Asexual/seed fallback (single parent): clone strand + instincts + coded set, bump generation.
static func from_parent(a: LADNA) -> LADNA:
	var g: LADNA = LADNA.new()
	g.base_config = a.base_config.duplicate(true)
	g.strand = a.strand.duplicate()
	g.coded_genes = a.coded_genes.duplicate(true)
	g.generation = a.generation + 1
	for key in a.instincts.keys():
		g.instincts[key] = (a.instincts[key] as Dictionary).duplicate(true)
	return g


static func _blank_strand() -> PackedByteArray:
	var s: PackedByteArray = PackedByteArray()
	s.resize(LADNA.total_codons() * SYMBOLS_PER_CODON)   # zero-filled (all base 0) — deterministic, no RNG
	return s


func _encode_midpoint(name: String) -> void:
	var loc = LADNA._layout().get(name, null)
	if loc == null:
		return
	encode_gene(name, (float(loc["min"]) + float(loc["max"])) * 0.5)


static func _carnivory_from_diet(diet: String) -> float:
	match diet:
		"carnivore", "predator":
			return 0.9
		"omnivore":
			return 0.5
		_:
			return 0.1


# --- EXPRESSION --------------------------------------------------------------------------------------------

## The config dict LocalAgentCreature.setup() consumes: identity from base_config, decoded genes overlaid. Legacy
## genes override only where the species set them; the new genes + the diet gradient + the cue_priors dict
## are added on top. DIET is expressed from the carnivory gradient (bucketed), so it is heritable/evolvable
## while base_config stays immutable.
func express() -> Dictionary:
	var out: Dictionary = base_config.duplicate(true)
	var cue_priors: Dictionary = {}
	for row in LOCI:
		var name: String = String(row[0])
		var kind: String = String(row[1])
		if kind == "cue":
			cue_priors[name] = decode_gene(name)
		elif kind == "gene":
			if GENE_KEYS.has(name):
				# Legacy gene: override only if the species actually set it (unset → keep Creature's default).
				if coded_genes.has(name):
					out[name] = decode_gene(name)
			else:
				out[name] = decode_gene(name)   # new gene: always expressed
	# Adult mass is carried in the genome as log10 kg and expressed as the linear kg every consumer reads.
	out["mass_kg"] = pow(10.0, decode_gene("log10_adult_mass_kg"))
	# Diet expressed from the evolvable carnivory gradient.
	var carn: float = decode_gene("carnivory")
	out["diet"] = _diet_bucket(carn)
	out["carnivory"] = carn
	out["cue_priors"] = cue_priors
	return out


static func _diet_bucket(carnivory: float) -> String:
	if carnivory < DIET_HERBIVORE_MAX:
		return "herbivore"
	if carnivory < DIET_OMNIVORE_MAX:
		return "omnivore"
	return "carnivore"


# --- BALDWIN INSTINCTS -------------------------------------------------------------------------------------

## The Baldwin effect: rarely, a behaviour a creature has ingrained for its whole life sinks into the germline
## as an instinct prior its offspring may be born with — NOT wholesale thought copying, only the deepest,
## most consistently-rewarded habits, and only sometimes. Stochastic draw goes through the shared LASimRng.
func maybe_canalize(policy: Dictionary) -> void:
	var rng: LASimRng = LASimRng.shared()
	for key in policy.keys():
		var entry = policy[key]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if float(entry.get("weight", 0.0)) < CANALIZE_MIN_WEIGHT:
			continue
		if rng.randf() >= CANALIZE_CHANCE:
			continue
		instincts[key] = {"action": String(entry.get("action", "")), "weight": INSTINCT_SEED_WEIGHT}
	_prune_instincts()


func _prune_instincts() -> void:
	if instincts.size() <= MAX_INSTINCTS:
		return
	var keys: Array = instincts.keys()
	keys.sort_custom(func(a, b): return float(instincts[a]["weight"]) > float(instincts[b]["weight"]))
	var kept: Dictionary = {}
	for i in range(MAX_INSTINCTS):
		kept[keys[i]] = instincts[keys[i]]
	instincts = kept


# --- RECOMBINATION + MUTATION ------------------------------------------------------------------------------

## Sexual reproduction: a genuine sequence RECOMBINATION of two parent strands — 1 or 2 crossover points
## splice the literal symbol arrays (a cut can fall mid-gene, so genes blend), and the few genetic instincts
## are unioned (higher confidence wins). All stochastic draws go through the injected LASimRng.
static func crossover(a: LADNA, b: LADNA, rng: LASimRng) -> LADNA:
	if rng == null:
		rng = LASimRng.shared()
	var g: LADNA = LADNA.new()
	g.base_config = a.base_config.duplicate(true)
	g.coded_genes = a.coded_genes.duplicate(true)
	for k in b.coded_genes.keys():
		g.coded_genes[k] = true
	g.generation = maxi(a.generation, b.generation) + 1
	g.strand = LADNA._splice(a.strand, b.strand, rng)
	# Union the baked instincts (higher weight wins on conflict).
	for src in [a, b]:
		for key in (src as LADNA).instincts.keys():
			var e: Dictionary = (src as LADNA).instincts[key]
			var prev = g.instincts.get(key, null)
			if prev == null or float(e["weight"]) > float((prev as Dictionary)["weight"]):
				g.instincts[key] = {"action": e["action"], "weight": float(e["weight"])}
	g._prune_instincts()
	return g


## Splice two equal-length strands at 1 or 2 crossover points, starting from a randomly-chosen parent.
static func _splice(a: PackedByteArray, b: PackedByteArray, rng: LASimRng) -> PackedByteArray:
	var n: int = a.size()
	var out: PackedByteArray = PackedByteArray()
	out.resize(n)
	if n == 0:
		return out
	var two_points: bool = rng.randf() < 0.5
	var p1: int = rng.randi_range(1, n - 1)
	var p2: int = n
	if two_points:
		p2 = rng.randi_range(1, n - 1)
		if p2 < p1:
			var tmp: int = p1
			p1 = p2
			p2 = tmp
	var a_first: bool = rng.randf() < 0.5
	var first: PackedByteArray = a if a_first else b
	var second: PackedByteArray = b if a_first else a
	for i in range(n):
		# segment 0 = first parent, segment 1 = second, segment 2 = first again (2-point case).
		if i < p1:
			out[i] = first[i]
		elif i < p2:
			out[i] = second[i]
		else:
			out[i] = first[i]
	return out


## Point mutations on the strand: each codon has `rate` probability of one of its four bases flipping to a
## different base, plus a rare length-neutral indel absorbed inside a non-coding spacer (so it never frame-
## shifts a coding locus), plus rare forgetting of a baked instinct. All draws go through the injected LASimRng.
func mutate(rng: LASimRng, rate: float = DEFAULT_MUTATION_RATE) -> LADNA:
	if rng == null:
		rng = LASimRng.shared()
	var codons: int = LADNA.total_codons()
	for c in range(codons):
		if rng.randf() < rate:
			var sym_index: int = c * SYMBOLS_PER_CODON + rng.randi_range(0, SYMBOLS_PER_CODON - 1)
			var cur: int = int(strand[sym_index])
			var repl: int = rng.randi_range(0, SYMBOL_MAX - 1)
			if repl >= cur:
				repl += 1                       # guarantee a real base change
			strand[sym_index] = repl
	if rng.randf() < INDEL_RATE:
		_indel_in_spacer(rng)
	if not instincts.is_empty() and rng.randf() < INSTINCT_FORGET_CHANCE:
		var keys: Array = instincts.keys()
		instincts.erase(keys[rng.randi_range(0, keys.size() - 1)])
	return self


## A length-neutral indel contained to a non-coding spacer: shift the spacer's symbols one place (insertion =
## right, dropping the tail base and admitting a new base at the head; deletion = the mirror), so the event is a
## genuine insertion/deletion of a base within junk DNA without disturbing the fixed coding loci downstream.
func _indel_in_spacer(rng: LASimRng) -> void:
	LADNA._layout()
	if _spacers.is_empty():
		return
	var sp: Dictionary = _spacers[rng.randi_range(0, _spacers.size() - 1)]
	var start: int = int(sp["start_codon"]) * SYMBOLS_PER_CODON
	var count: int = int(sp["codons"]) * SYMBOLS_PER_CODON
	if count <= 1:
		return
	var insertion: bool = rng.randf() < 0.5
	var new_base: int = rng.randi_range(0, SYMBOL_MAX)
	if insertion:
		for i in range(count - 1, 0, -1):
			strand[start + i] = strand[start + i - 1]
		strand[start] = new_base
	else:
		for i in range(count - 1):
			strand[start + i] = strand[start + i + 1]
		strand[start + count - 1] = new_base


# --- SAVE / LOAD -------------------------------------------------------------------------------------------

## Serialize to a plain-data dict a save can persist (LAGameSave stores it via binary store_var, so the
## PackedByteArray strand round-trips natively). The format version + reserved strand loci mean a future
## build reads this back even after new genes are added.
func snapshot() -> Dictionary:
	return {
		"version": GENOME_FORMAT_VERSION,
		"strand": strand.duplicate(),
		"base_config": base_config.duplicate(true),
		"coded_genes": coded_genes.duplicate(true),
		"instincts": instincts.duplicate(true),
		"generation": int(generation),
	}


## Reconstruct a genome from snapshot() data (forward-compatible: a short/legacy strand is padded to the
## current fixed length, so older saves still decode; unknown extra data is ignored).
static func restore(d: Dictionary) -> LADNA:
	var g: LADNA = LADNA.new()
	if d == null or d.is_empty():
		g.strand = LADNA._blank_strand()
		return g
	g.base_config = (d.get("base_config", {}) as Dictionary).duplicate(true)
	g.coded_genes = (d.get("coded_genes", {}) as Dictionary).duplicate(true)
	g.instincts = (d.get("instincts", {}) as Dictionary).duplicate(true)
	g.generation = int(d.get("generation", 0))
	var saved: PackedByteArray = d.get("strand", PackedByteArray())
	var want: int = LADNA.total_codons() * SYMBOLS_PER_CODON
	if saved.size() == want:
		g.strand = saved.duplicate()
	else:
		# Length drift across versions: keep what overlaps, blank the rest (reserved loci read as neutral).
		g.strand = LADNA._blank_strand()
		var n: int = mini(saved.size(), want)
		for i in range(n):
			g.strand[i] = saved[i]
	return g
