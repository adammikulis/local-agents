@tool
extends RefCounted

const FieldScene = preload("res://addons/local_agents/scenes/simulation/PlantRabbitField.tscn")

func run_test(tree: SceneTree) -> bool:
	var field = FieldScene.instantiate()
	tree.get_root().add_child(field)
	var ecology = field.get_node_or_null("EcologyController")
	if ecology == null:
		push_error("EcologyController missing from PlantRabbitField scene")
		field.queue_free()
		return false

	ecology.call("set_debug_overlay", null)
	ecology.call("clear_generated")
	ecology.call("spawn_random", 4, 3)
	for _i in range(0, 200):
		ecology.call("_physics_process", 0.1)

	var profiles: Array = ecology.call("collect_living_entity_profiles")
	var saw_animal_mouth_carry = false
	for profile_variant in profiles:
		if not (profile_variant is Dictionary):
			continue
		var profile = profile_variant as Dictionary
		var taxonomy: Array = profile.get("taxonomy_path", [])
		var is_animal = false
		for token_variant in taxonomy:
			if String(token_variant) == "animal":
				is_animal = true
				break
		if not is_animal:
			continue
		var carry_channels: Dictionary = profile.get("carry_channels", {})
		if float(carry_channels.get("mouth", 0.0)) > 0.0:
			saw_animal_mouth_carry = true
			break
	if not saw_animal_mouth_carry:
		push_error("Expected animal living profiles to expose mouth carry capability")
		field.queue_free()
		return false

	var shelters: Array = ecology.call("collect_shelter_sites")
	if shelters.is_empty():
		push_error("Expected generic shelter construction to produce shelter sites")
		field.queue_free()
		return false
	var best_progress = 0.0
	for site_variant in shelters:
		if not (site_variant is Dictionary):
			continue
		var site = site_variant as Dictionary
		best_progress = maxf(best_progress, float(site.get("progress", 0.0)))
	if best_progress <= 0.0:
		push_error("Expected shelter site progress to increase from capability-driven work")
		field.queue_free()
		return false

	field.queue_free()
	print("Ecology shelter capability test passed")
	return true
