extends "res://addons/local_agents/scenes/simulation/actors/AnimalActor.gd"
class_name MammalActor

# Mammal (animal/mammal/...): a warm-blooded animal. Every real capability — locomotion,
# nav, jump, smell emission/sensing, diet, and breeding — lives in AnimalActor. This layer
# only tags the mammal taxonomy/groups and a mammalian default scent. Concrete mammals
# (rabbit, fox, villager) inherit this and specialize chemistry, subtype, and behavior.

func _register_creature_groups() -> void:
	add_to_group("living_mammal")
	add_to_group("mammal_actor")

func taxonomy_category() -> String:
	return "mammal"

func _default_smell_kind() -> String:
	return "mammal"

func _default_emission_chemicals() -> Dictionary:
	return {"ammonia": 0.4}
