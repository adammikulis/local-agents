class_name LACreatureMicrobiome
extends RefCounted


var flora: float = 0.5
# Fast running average of the recently eaten food's plant-fraction (0 = meat, 1 = carbs). Nudged per bite.
var recent_diet: float = 0.5

const PLANT_FERMENT_BONUS: float = 0.14
# Worst-case yield floor when the flora fully mismatches the current diet (a herbivore gut fed pure meat):
# digestion still works, just poorly, until the flora re-cultures. Never below this (starvation guard).
const MISMATCH_FLOOR: float = 0.6
# Flora re-culturing rate toward the recent diet, per second. `delta` already carries the sim's time scale
# (Engine.time_scale fast-forward), so a diet switch re-adapts in the same compressed time as everything else.
const FLORA_DRIFT: float = 0.04
# Per-bite pull of recent_diet toward the just-eaten food's plant-fraction (fast — a meal shifts intake now).
const DIET_EMA: float = 0.25


func setup(creature, config: Dictionary) -> void:
	var diet: String = "herbivore"
	if creature != null and "diet" in creature:
		diet = String(creature.diet)
	else:
		diet = String(config.get("diet", "herbivore"))
	flora = _diet_plant_frac(diet)
	recent_diet = flora                                  # born adapted to its native diet


func note_food(profile: Dictionary, biomass: float) -> void:
	if biomass <= 0.0:
		return
	var pf: float = _food_plant_frac(profile)
	recent_diet = recent_diet + (pf - recent_diet) * DIET_EMA


func tick(_creature, delta: float) -> void:
	if delta <= 0.0:
		return
	flora = move_toward(flora, recent_diet, FLORA_DRIFT * delta)


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
