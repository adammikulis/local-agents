extends RefCounted

static func configure(controller, seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
	controller._ensure_initialized()
	controller._reset_store_for_instance()
	controller._rng.set_base_seed_from_text(seed_text)
	controller.active_branch_id = "main"
	controller._branch_lineage = []
	controller._branch_fork_tick = -1
	controller._last_tick_processed = 0
	controller._pending_thought_npc_ids.clear()
	controller._pending_dream_npc_ids.clear()
	controller._pending_dialogue_pairs.clear()
	controller.narrator_enabled = narrator_enabled
	controller._narrator.enabled = narrator_enabled
	controller._dreams.llm_enabled = dream_llm_enabled
	controller._mind.llm_enabled = dream_llm_enabled
	if controller._culture_cycle != null:
		controller._culture_cycle.llm_enabled = dream_llm_enabled
	controller._store.open(controller._store_path_for_instance())
	apply_llama_server_integration(controller)
	controller.configure_environment(controller._worldgen_config)

static func reset_store_for_instance(controller) -> void:
	if controller._store != null:
		controller._store.close()
	var path = controller._store_path_for_instance()
	for suffix in ["", "-wal", "-shm", "-journal"]:
		var candidate = path + suffix
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)

static func set_cognition_features(controller, enable_thoughts: bool, enable_dialogue: bool, enable_dreams: bool) -> void:
	controller._ensure_initialized()
	controller.thoughts_enabled = enable_thoughts
	controller.dialogue_enabled = enable_dialogue
	controller.dreams_enabled = enable_dreams
	if controller._culture_cycle != null:
		controller._culture_cycle.llm_enabled = enable_thoughts or enable_dialogue or enable_dreams

static func set_cognition_contract_config(controller, config_resource) -> void:
	controller._ensure_initialized()
	if config_resource == null:
		controller._cognition_contract_config = controller.CognitionContractConfigResourceScript.new()
	else:
		controller._cognition_contract_config = config_resource
	apply_cognition_contract(controller)
	apply_llama_server_integration(controller)

static func apply_cognition_contract(controller) -> void:
	if controller._cognition_contract_config == null:
		controller._cognition_contract_config = controller.CognitionContractConfigResourceScript.new()
	if controller._cognition_contract_config.has_method("ensure_defaults"):
		controller._cognition_contract_config.call("ensure_defaults")
	if controller._narrator != null and controller._narrator.has_method("set_request_profile"):
		controller._narrator.call("set_request_profile", controller._cognition_contract_config.call("profile_for_task", "narrator_direction"))
	if controller._mind != null and controller._mind.has_method("set_request_profile"):
		controller._mind.call("set_request_profile", "internal_thought", controller._cognition_contract_config.call("profile_for_task", "internal_thought"))
		controller._mind.call("set_request_profile", "dialogue_exchange", controller._cognition_contract_config.call("profile_for_task", "dialogue_exchange"))
	if controller._mind != null and controller._mind.has_method("set_contract_limits"):
		controller._mind.call("set_contract_limits", {
			"context_schema_version": int(controller._cognition_contract_config.get("context_schema_version")),
			"max_prompt_chars": int(controller._cognition_contract_config.get("max_prompt_chars")),
			"state_chars": int(controller._cognition_contract_config.get("budget_state_chars")),
			"waking_memories": int(controller._cognition_contract_config.get("budget_waking_memories")),
			"dream_memories": int(controller._cognition_contract_config.get("budget_dream_memories")),
			"beliefs": int(controller._cognition_contract_config.get("budget_beliefs")),
			"conflicts": int(controller._cognition_contract_config.get("budget_conflicts")),
			"oral_knowledge": int(controller._cognition_contract_config.get("budget_oral_knowledge")),
			"ritual_events": int(controller._cognition_contract_config.get("budget_ritual_events")),
			"taboo_ids": int(controller._cognition_contract_config.get("budget_taboo_ids")),
		})
	if controller._dreams != null and controller._dreams.has_method("set_request_profile"):
		controller._dreams.call("set_request_profile", controller._cognition_contract_config.call("profile_for_task", "dream_generation"))
	if controller._culture_cycle != null and controller._culture_cycle.has_method("set_request_profile"):
		controller._culture_cycle.call("set_request_profile", controller._cognition_contract_config.call("profile_for_task", "oral_transmission_utterance"))

static func set_llama_server_options(controller, options: Dictionary) -> void:
	controller._ensure_initialized()
	for key_variant in options.keys():
		var key = String(key_variant)
		controller._llama_server_options[key] = options[key]
	apply_llama_server_integration(controller)

static func get_llama_server_options(controller) -> Dictionary:
	controller._ensure_initialized()
	return controller._llama_server_options.duplicate(true)

static func apply_llama_server_integration(controller) -> void:
	var generation_options: Dictionary = controller._llama_server_options.duplicate(true)
	var resolved_model_path: String = resolve_llama_model_path(controller, generation_options)
	if resolved_model_path != "":
		generation_options["server_model_path"] = resolved_model_path
		if not generation_options.has("model_path"):
			generation_options["model_path"] = resolved_model_path
		if not generation_options.has("server_model"):
			generation_options["server_model"] = resolved_model_path.get_file()
	var resolved_runtime_dir: String = resolve_runtime_directory(controller, generation_options)
	if resolved_runtime_dir != "":
		generation_options["runtime_directory"] = resolved_runtime_dir
	if controller._narrator != null and controller._narrator.has_method("set_runtime_options"):
		controller._narrator.call("set_runtime_options", generation_options)
	if controller._mind != null and controller._mind.has_method("set_runtime_options"):
		controller._mind.call("set_runtime_options", generation_options)
	if controller._dreams != null and controller._dreams.has_method("set_runtime_options"):
		controller._dreams.call("set_runtime_options", generation_options)
	if controller._culture_cycle != null and controller._culture_cycle.has_method("set_runtime_options"):
		controller._culture_cycle.call("set_runtime_options", generation_options)
	if controller._backstory_service != null and controller._backstory_service.has_method("set_embedding_options"):
		var embedding_options: Dictionary = generation_options.duplicate(true)
		embedding_options["normalize"] = true
		embedding_options["server_embeddings"] = true
		if not embedding_options.has("server_pooling"):
			embedding_options["server_pooling"] = "mean"
		if resolved_model_path != "":
			embedding_options["server_model_path"] = resolved_model_path
			if not embedding_options.has("model_path"):
				embedding_options["model_path"] = resolved_model_path
			if not embedding_options.has("server_model"):
				embedding_options["server_model"] = resolved_model_path.get_file()
		if resolved_runtime_dir != "":
			embedding_options["runtime_directory"] = resolved_runtime_dir
		controller._backstory_service.call("set_embedding_options", embedding_options)

static func resolve_llama_model_path(controller, options: Dictionary) -> String:
	for key in ["server_model_path", "model_path", "model"]:
		var candidate: String = String(options.get(key, "")).strip_edges()
		if candidate == "":
			continue
		var normalized: String = controller.RuntimePathsScript.normalize_path(candidate)
		if normalized != "" and FileAccess.file_exists(normalized):
			return normalized
	if OS.has_environment("LOCAL_AGENTS_TEST_GGUF"):
		var from_env: String = controller.RuntimePathsScript.normalize_path(OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges())
		if from_env != "" and FileAccess.file_exists(from_env):
			return from_env
	if Engine.has_singleton("AgentRuntime"):
		var runtime = Engine.get_singleton("AgentRuntime")
		if runtime != null and runtime.has_method("get_default_model_path"):
			var runtime_model: String = controller.RuntimePathsScript.normalize_path(String(runtime.call("get_default_model_path")).strip_edges())
			if runtime_model != "" and FileAccess.file_exists(runtime_model):
				return runtime_model
	var fallback: String = controller.RuntimePathsScript.resolve_default_model()
	if fallback != "" and FileAccess.file_exists(fallback):
		return fallback
	return ""

static func resolve_runtime_directory(controller, options: Dictionary) -> String:
	var explicit_dir: String = controller.RuntimePathsScript.normalize_path(String(options.get("runtime_directory", "")).strip_edges())
	if explicit_dir != "":
		return explicit_dir
	var runtime_dir: String = controller.RuntimePathsScript.runtime_dir()
	if runtime_dir != "":
		return runtime_dir
	return ""

static func set_narrator_directive(controller, text: String) -> void:
	controller._ensure_initialized()
	if controller._narrator_directive_resource == null:
		controller._narrator_directive_resource = controller.NarratorDirectiveResourceScript.new()
	controller._narrator_directive_resource.set_text(text, -1)

static func set_dream_influence(controller, npc_id: String, influence: Dictionary) -> void:
	controller._ensure_initialized()
	controller._dreams.set_dream_influence(npc_id, influence)

static func set_profession_profile(controller, profile_resource) -> void:
	controller._ensure_initialized()
	if profile_resource == null:
		return
	controller._economy_system.set_profession_profile(profile_resource)

static func set_flow_traversal_profile(controller, profile_resource) -> void:
	controller._ensure_initialized()
	if profile_resource == null:
		controller._flow_traversal_profile = controller.FlowTraversalProfileResourceScript.new()
	else:
		controller._flow_traversal_profile = profile_resource
	if controller._flow_network_system != null:
		controller._flow_network_system.set_flow_profile(controller._flow_traversal_profile)

static func set_flow_formation_config(controller, config_resource) -> void:
	controller._ensure_initialized()
	if config_resource == null:
		controller._flow_formation_config = controller.FlowFormationConfigResourceScript.new()
	else:
		controller._flow_formation_config = config_resource
	if controller._flow_network_system != null:
		controller._flow_network_system.set_flow_formation_config(controller._flow_formation_config)

static func set_flow_runtime_config(controller, config_resource) -> void:
	controller._ensure_initialized()
	if config_resource == null:
		controller._flow_runtime_config = controller.FlowRuntimeConfigResourceScript.new()
	else:
		controller._flow_runtime_config = config_resource
	if controller._flow_network_system != null:
		controller._flow_network_system.set_flow_runtime_config(controller._flow_runtime_config)

static func set_structure_lifecycle_config(controller, config_resource) -> void:
	controller._ensure_initialized()
	if config_resource == null:
		controller._structure_lifecycle_config = controller.StructureLifecycleConfigResourceScript.new()
	else:
		controller._structure_lifecycle_config = config_resource
	if controller._structure_lifecycle_system != null:
		controller._structure_lifecycle_system.set_config(controller._structure_lifecycle_config)

static func set_culture_context_cues(controller, cues: Dictionary) -> void:
	controller._ensure_initialized()
	controller._culture_context_cues = cues.duplicate(true)

static func set_living_entity_profiles(controller, profiles: Array) -> void:
	controller._ensure_initialized()
	controller._external_living_entity_profiles.clear()
	for row_variant in profiles:
		if not (row_variant is Dictionary):
			continue
		controller._external_living_entity_profiles.append((row_variant as Dictionary).duplicate(true))
