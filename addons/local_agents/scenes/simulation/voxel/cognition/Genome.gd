class_name LAGenome
extends RefCounted

## A creature's heritable makeup. Two parts:
##   * traits   — the numeric "genes" (speed, size, senses, EYE field-of-view, metabolism, flock
##                weights…) that vary per individual and drift across generations.
##   * instincts— a SMALL set of genetically-baked reaction priors:
##                signature_key(int) -> {action:String, weight:float}. Unlike a lifetime of learned
##                habits (which spread socially, not by inheritance), these change only slowly —
##                by mutation, crossover, and rare "canalization" of a behaviour a lineage has
##                relied on for generations (the Baldwin effect). This is how "some reactions are
##                baked into genetics, like real life" while the rest is learned by watching kin.
##
## Species identity (diet, colour, preys_on, flags…) is carried verbatim in `base_config` and never
## mutated — evolution here varies degree, not kind (emergent-everything: differences through
## properties, not new per-case code).
##
## (Explicit types only — project rule: no ':=' inferred typing.)

# The numeric config keys treated as heritable genes. `eye_fov` makes sight itself evolvable.
# (Plain Array literal — a PackedStringArray(...) constructor is not a constant expression.)
const GENE_KEYS: Array = [
	"speed", "size", "sense_radius", "eye_fov", "metabolism", "max_energy", "thirst_rate",
	"maturity_age", "throw_range", "cruise_height",
	"flock_cohesion", "flock_alignment", "flock_separation", "flock_radius", "flock_weight",
]

# Genetic instincts are deliberately few — instinct is expensive to encode, so real genomes bake in
# only the most vital reactions and leave the rest to learning.
const MAX_INSTINCTS: int = 5
# A behaviour only becomes genetically assimilated once a lineage has held it at near-max confidence
# (it has been reliably useful for a long time), and even then only rarely per breeding.
const CANALIZE_MIN_WEIGHT: float = 5.0
const CANALIZE_CHANCE: float = 0.06
const INSTINCT_SEED_WEIGHT: float = 1.6

var base_config: Dictionary = {}     # full species template (identity + starting gene values)
var traits: Dictionary = {}          # gene_key -> float (this individual's values)
var instincts: Dictionary = {}       # signature_key:int -> {action:String, weight:float}
var generation: int = 0


## Build the ancestral genome for a species from its static config template. Gene values start at
## the template's numbers; instincts start empty — gen-0 animals rely on baked reflexes (the innate
## cascade), the slow brain, and watching each other.
static func from_config(cfg: Dictionary) -> LAGenome:
	var g: LAGenome = LAGenome.new()
	g.base_config = cfg.duplicate(true)
	for k in GENE_KEYS:
		if cfg.has(k):
			g.traits[k] = float(cfg[k])
	return g


## The config dict LACreature.setup() consumes: identity from base_config, gene values overlaid.
func express() -> Dictionary:
	var out: Dictionary = base_config.duplicate(true)
	for k in traits.keys():
		out[k] = traits[k]
	return out


## The Baldwin effect: rarely, a behaviour a creature has ingrained for its whole life sinks into
## the germline as an instinct prior its offspring may be born with. NOT wholesale thought copying —
## only the deepest, most consistently-rewarded habits, and only sometimes.
func maybe_canalize(policy: Dictionary) -> void:
	for key in policy.keys():
		var entry = policy[key]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if float(entry.get("weight", 0.0)) < CANALIZE_MIN_WEIGHT:
			continue
		if randf() >= CANALIZE_CHANCE:
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


## Sexual reproduction: each gene comes from one parent (nudged toward the midpoint), and the few
## genetic instincts are unioned (higher confidence wins on conflict).
static func crossover(a: LAGenome, b: LAGenome) -> LAGenome:
	var g: LAGenome = LAGenome.new()
	g.base_config = a.base_config.duplicate(true)
	g.generation = maxi(a.generation, b.generation) + 1
	for k in GENE_KEYS:
		var av: float = float(a.traits.get(k, b.traits.get(k, 0.0)))
		var bv: float = float(b.traits.get(k, av))
		var pick: float = av if randf() < 0.5 else bv
		g.traits[k] = lerpf(pick, (av + bv) * 0.5, 0.25)
	for src in [a, b]:
		for key in (src as LAGenome).instincts.keys():
			var e: Dictionary = (src as LAGenome).instincts[key]
			var prev = g.instincts.get(key, null)
			if prev == null or float(e["weight"]) > float((prev as Dictionary)["weight"]):
				g.instincts[key] = {"action": e["action"], "weight": float(e["weight"])}
	g._prune_instincts()
	return g


## Small random drift on the numeric genes, clamped to stay sane. Rare instinct forgetting keeps the
## baked priors from ossifying so the population keeps exploring.
func mutate(rate: float = 0.08) -> LAGenome:
	for k in traits.keys():
		var base: float = float(traits[k])
		var delta: float = base * rate * randf_range(-1.0, 1.0)
		traits[k] = maxf(0.01, base + delta)
	if not instincts.is_empty() and randf() < 0.15:
		var keys: Array = instincts.keys()
		instincts.erase(keys[randi() % keys.size()])
	return self


## Asexual/seed fallback (single parent): clone genes + instincts, bump generation.
static func from_parent(a: LAGenome) -> LAGenome:
	var g: LAGenome = LAGenome.new()
	g.base_config = a.base_config.duplicate(true)
	g.traits = a.traits.duplicate(true)
	g.generation = a.generation + 1
	for key in a.instincts.keys():
		g.instincts[key] = (a.instincts[key] as Dictionary).duplicate(true)
	return g
