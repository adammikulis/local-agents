class_name LAAppraisal
extends RefCounted


const DEFAULT_WEIGHTS: Dictionary = {
	"maturity": 1.0,     # age relative to maturity — elders out-rank (village elder >> young adult)
	"size": 1.2,         # body size — the raw physical-dominance axis
	"vigor": 0.6,        # energy fraction — a starving contender loses rank, so drift is automatic
	"competence": 0.15,  # learned situations mastered (per-situation, small)
	"display": 0.0,      # ornamental brightness — off unless the species courts on it
}
const MATURITY_CAP: float = 6.0     # elders keep gaining up to 6x maturity — a WIDE spread so command tiers stay distinct

# Female display is expressed FAINTLY (a fraction of the same gene) — the ornament is a male signal, but the
# gene is carried and passed on by both sexes.
const FEMALE_DISPLAY_FACTOR: float = 0.25


## The species' dominance weights (config `dominance_traits`), falling back to DEFAULT_WEIGHTS per-key so a
## species need only override the axes it cares about.
static func _weights(c) -> Dictionary:
	var cfg = c.get("config")
	if cfg is Dictionary and (cfg as Dictionary).has("dominance_traits"):
		var dt = (cfg as Dictionary)["dominance_traits"]
		if dt is Dictionary:
			var w: Dictionary = DEFAULT_WEIGHTS.duplicate()
			for k in dt:
				w[k] = float(dt[k])
			return w
	return DEFAULT_WEIGHTS


## The creature's genetic display gene (0..1), 0 when absent (old genome / non-ornamented species).
static func _display_gene(c) -> float:
	var cfg = c.get("config")
	if cfg is Dictionary and (cfg as Dictionary).has("display"):
		return clampf(float((cfg as Dictionary)["display"]), 0.0, 1.0)
	return 0.0


static func effective_display(c) -> float:
	var gene: float = _display_gene(c)
	if gene <= 0.0:
		return 0.0
	var health_frac: float = clampf(float(c.get("health")) / maxf(float(c.get("max_health")), 1.0), 0.0, 1.0)
	var vigor: float = clampf(float(c.get("energy")) / maxf(float(c.get("max_energy")), 1.0e-9), 0.0, 1.0)
	var condition: float = 0.35 + 0.65 * (health_frac * vigor)     # never fully zero, but poor condition dulls it hard
	var sex_factor: float = 1.0 if bool(c.get("is_male")) else FEMALE_DISPLAY_FACTOR
	return clampf(gene * condition * sex_factor, 0.0, 1.0)


## The per-tick energy cost of MAINTAINING the current display — proportional to how bright the creature is
## trying to be (its gene), so ornament is a real metabolic burden and only the fit stay bright. Read by
## LACreatureMetabolism. Returns 0 for females / undisplayed genomes.
static func display_upkeep(c, delta: float) -> float:
	if not bool(c.get("is_male")):
		return 0.0
	var gene: float = _display_gene(c)
	if gene <= 0.0:
		return 0.0
	return LACreatureRespiration.maintenance_rate(c) * DISPLAY_UPKEEP_OVER_MAINTENANCE * gene * gene * delta

const DISPLAY_UPKEEP_OVER_MAINTENANCE: float = 0.9


static func dominance(c) -> float:
	var w: Dictionary = _weights(c)
	var maturity: float = clampf(float(c.get("age")) / maxf(float(c.get("maturity_age")), 0.001), 0.0, MATURITY_CAP)
	var vigor: float = float(c.get("energy")) / maxf(float(c.get("max_energy")), 1.0e-9)
	var competence: float = 0.0
	if c.has_method("get_cognition"):
		var cog = c.get_cognition()
		if cog != null and cog.has_method("policy_size"):
			competence = float(cog.policy_size())
	return float(w.get("maturity", 0.0)) * maturity \
		+ float(w.get("size", 0.0)) * float(c.get("size")) \
		+ float(w.get("vigor", 0.0)) * vigor \
		+ float(w.get("competence", 0.0)) * competence \
		+ float(w.get("display", 0.0)) * effective_display(c)


static func mate_value(chooser, target, distance: float, seek_radius: float) -> float:
	var w: Dictionary = _weights(chooser)
	var quality: float = dominance(target) + float(w.get("display", 0.0)) * effective_display(target)
	var proximity: float = 1.0 - 0.35 * clampf(distance / maxf(seek_radius, 0.001), 0.0, 1.0)
	return quality * proximity
