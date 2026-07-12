class_name LACreatureMicrobiome
extends RefCounted

## LACreatureMicrobiome — the per-creature GUT FLORA state, owned as an instance on each creature
## (`creature.gut_microbiome`) so all of it lives HERE, off the Creature monolith (the same one-field/one-setup/
## one-tick seam the other Creature* helper modules use — metabolism, thirst, senses). The gut flora ADAPTS to
## what the animal actually eats and MODULATES how much energy it extracts from a bite: the eating path asks this
## module for a yield multiplier and scales the energy the food is worth by it.
##
## The model is one emergent scalar pair, no per-species branch (config-over-cases):
##   * `flora` (0..1) is the gut community's current composition — 1 = plant/cellulose-fermenting flora,
##     0 = meat-digesting flora. It DRIFTS slowly toward the recent diet (a gut community re-cultures over time).
##   * `recent_diet` (0..1) is a fast running average of what has recently been eaten (1 = all carbs/plants,
##     0 = all meat/fat), nudged on every bite (the eating path calls note_food with the food's profile).
## The realised digestive-yield multiplier (`multiplier()`, what the eating path scales food energy by) is HIGH
## when the flora MATCHES the recent diet (a well-adapted gut) and LOW when they diverge, PLUS a cellulose-
## fermentation bonus for a plant-flora gut working plant food. So a herbivore whose flora is plant-tuned and who
## eats plants extracts the full ~1.12 fermentation bonus; switch it to meat and its `recent_diet` swings toward
## meat immediately while its slow `flora` lags — the mismatch drops the yield (it digests the meat poorly) until
## the flora re-cultures toward meat and recovers to the base rate. Emergent: diet drives flora, flora drives
## energy return; there is no `if species == "X"`.
##
## PER-CREATURE state only (never a field CA); O(1) per creature per frame. Explicit types only (no ':=').

# Current gut-flora composition (0 = meat-digesting, 1 = plant/cellulose-fermenting). Slow to change.
var flora: float = 0.5
# Fast running average of the recently eaten food's plant-fraction (0 = meat, 1 = carbs). Nudged per bite.
var recent_diet: float = 0.5

# How well plant-flora ferments plant food: the peak yield BONUS when flora == recent_diet == 1 (a plant-tuned
# gut on plant matter). Chosen so a settled herbivore lands near ~1.12 — a modest cellulose-fermentation edge —
# while a carnivore on meat sits at the ~1.0 base rate.
const PLANT_FERMENT_BONUS: float = 0.14
# Worst-case yield floor when the flora fully mismatches the current diet (a herbivore gut fed pure meat):
# digestion still works, just poorly, until the flora re-cultures. Never below this (starvation guard).
const MISMATCH_FLOOR: float = 0.6
# Flora re-culturing rate toward the recent diet, per second. `delta` already carries the sim's time scale
# (Engine.time_scale fast-forward), so a diet switch re-adapts in the same compressed time as everything else.
const FLORA_DRIFT: float = 0.04
# Per-bite pull of recent_diet toward the just-eaten food's plant-fraction (fast — a meal shifts intake now).
const DIET_EMA: float = 0.25


## Seed the flora + recent-diet from the creature's diet, once at spawn (called from LACreature.setup like the
## other Creature* modules, after `diet` is known). A herbivore is born plant-tuned and adapted; a carnivore
## meat-tuned. Falls back to the config dict if the creature is not passed.
func setup(creature, config: Dictionary) -> void:
	var diet: String = "herbivore"
	if creature != null and "diet" in creature:
		diet = String(creature.diet)
	else:
		diet = String(config.get("diet", "herbivore"))
	flora = _diet_plant_frac(diet)
	recent_diet = flora                                  # born adapted to its native diet


## Record a bite: pull recent_diet toward this food's plant-fraction. Called from the eating path with the food
## profile so the microbiome learns diet from the SAME event that credits energy (one source of truth).
func note_food(profile: Dictionary, biomass: float) -> void:
	if biomass <= 0.0:
		return
	var pf: float = _food_plant_frac(profile)
	recent_diet = recent_diet + (pf - recent_diet) * DIET_EMA


## Advance the flora toward the recent diet this frame (re-culturing). No death gate — this only shifts the gut
## community; the yield it produces is read on demand via multiplier(). O(1).
func tick(_creature, delta: float) -> void:
	if delta <= 0.0:
		return
	flora = move_toward(flora, recent_diet, FLORA_DRIFT * delta)


## The realised digestive-yield multiplier the eating path scales food energy by. High when the flora matches the
## recent diet (adapted gut), floored when they diverge (a diet the gut isn't cultured for), plus a cellulose-
## fermentation bonus for a plant-flora gut working plant food. Bounded [MISMATCH_FLOOR, ~1.14].
func multiplier() -> float:
	var fit: float = 1.0 - absf(flora - recent_diet)                 # 1 = adapted, 0 = fully mismatched
	var adapted_eff: float = MISMATCH_FLOOR + (1.0 - MISMATCH_FLOOR) * clampf(fit, 0.0, 1.0)
	var ferment: float = 1.0 + PLANT_FERMENT_BONUS * clampf(flora, 0.0, 1.0) * clampf(recent_diet, 0.0, 1.0)
	return adapted_eff * ferment


## How well-adapted the gut is to what it is currently eating (0..1) — telemetry / HUD / debugging.
func adaptation() -> float:
	return clampf(1.0 - absf(flora - recent_diet), 0.0, 1.0)


## Map a food profile to its plant-fraction: carbs = plant (1.0), meat/fat = animal (0.0). One rule, all foods.
func _food_plant_frac(profile: Dictionary) -> float:
	var t: String = String(profile.get("type", "carbs"))
	if t == "meat" or t == "fat":
		return 0.0
	return 1.0


## The plant-fraction a diet is born tuned to. Not efficiency knobs — just where each gut starts before it
## adapts to lived diet. Kept close to the endpoints so a herbivore starts near full plant-ferment, a carnivore
## near pure meat, with omnivores in the middle (they adapt either way from experience).
func _diet_plant_frac(diet: String) -> float:
	match diet:
		"herbivore":
			return 0.9
		"carnivore":
			return 0.1
		"scavenger":
			return 0.15
		"omnivore":
			return 0.5
	return 0.5
