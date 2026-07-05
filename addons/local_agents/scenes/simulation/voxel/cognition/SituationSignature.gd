class_name LASituationSignature
extends RefCounted

## Turns a creature's current inner/outer state into a small discrete key. That key is what the
## fast policy (System 1) looks up, what a learned heuristic is filed under, and what an escalation
## trace records. It MUST stay cheap — it is computed every tick for every creature — so it reads
## only O(1) scalar state (energy, hydration, one water probe, the shared day/night flag) and never
## scans neighbour groups. The richer, expensive context (who is nearby / in view) is gathered only
## on the rare escalation path and handed to the LLM in its prompt.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

# Bucket boundaries (fractions of max). Coarse on purpose: fewer buckets = faster convergence of
# learned heuristics and a smaller genome to inherit.
const ENERGY_BUCKETS: int = 4      # starving / low / ok / full
const HYDRATION_BUCKETS: int = 3   # parched / thirsty / ok


static func energy_bucket(frac: float) -> int:
	if frac < 0.25:
		return 0
	if frac < 0.5:
		return 1
	if frac < 0.85:
		return 2
	return 3


static func hydration_bucket(frac: float) -> int:
	if frac < 0.3:
		return 0
	if frac < 0.6:
		return 1
	return 2


## Compute the signature for `c`. Returns a Dictionary:
##   key   : int  — packed, the fast-path lookup key
##   text  : String — stable human-readable form (prompts, traces, dataset)
##   e/h/w/n : the raw feature components (for feedback + prompt building)
static func compute(c) -> Dictionary:
	var e_frac: float = 0.0
	if c.max_energy > 0.0:
		e_frac = clampf(c.energy / c.max_energy, 0.0, 1.0)
	var h_frac: float = 0.0
	if c.max_hydration > 0.0:
		h_frac = clampf(c.hydration / c.max_hydration, 0.0, 1.0)
	var e: int = energy_bucket(e_frac)
	var h: int = hydration_bucket(h_frac)

	var at_water: int = 0
	if c._material != null and c._material.has_method("is_water_at"):
		if c._material.is_water_at(c.global_position.x, c.global_position.z):
			at_water = 1
	var night: int = 0
	if c._ecology != null and c._ecology.has_method("is_night") and c._ecology.is_night():
		night = 1

	var key: int = ((e * HYDRATION_BUCKETS + h) * 2 + at_water) * 2 + night
	var text: String = "e%d/h%d/%s/%s" % [
		e, h,
		"wet" if at_water == 1 else "dry",
		"night" if night == 1 else "day",
	]
	return {"key": key, "text": text, "e": e, "h": h, "w": at_water, "n": night}
