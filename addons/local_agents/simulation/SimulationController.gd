extends Node
class_name LocalAgentsSimulationController

signal narrator_direction_generated(tick, direction)
signal villager_dream_recorded(npc_id, tick, memory_id, dream_text, effect)
signal villager_thought_recorded(npc_id, tick, memory_id, thought_text)
signal villager_dialogue_recorded(source_npc_id, target_npc_id, tick, event_id, dialogue_text)
signal simulation_dependency_error(tick, phase, error_code)
const DeterministicRngScript = preload("res://addons/local_agents/simulation/DeterministicRNG.gd")
const RuntimePathsScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const NarratorScript = preload("res://addons/local_agents/simulation/NarratorDirector.gd")
const DreamScript = preload("res://addons/local_agents/simulation/VillagerDreamService.gd")
const MindScript = preload("res://addons/local_agents/simulation/VillagerMindService.gd")
const StoreScript = preload("res://addons/local_agents/simulation/SimulationStore.gd")
const BackstoryServiceScript = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")
const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const SettlementSeederScript = preload("res://addons/local_agents/simulation/SettlementSeeder.gd")
const WeatherSystemScript = preload("res://addons/local_agents/simulation/WeatherSystem.gd")
const ErosionSystemScript = preload("res://addons/local_agents/simulation/ErosionSystem.gd")
const SolarExposureSystemScript = preload("res://addons/local_agents/simulation/SolarExposureSystem.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const SpatialFlowNetworkSystemScript = preload("res://addons/local_agents/simulation/SpatialFlowNetworkSystem.gd")
const StructureLifecycleSystemScript = preload("res://addons/local_agents/simulation/StructureLifecycleSystem.gd")
const BranchAnalysisServiceScript = preload("res://addons/local_agents/simulation/BranchAnalysisService.gd")
const CulturalCycleSystemScript = preload("res://addons/local_agents/simulation/CulturalCycleSystem.gd")
const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const FlowFormationConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowFormationConfigResource.gd")
const FlowRuntimeConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowRuntimeConfigResource.gd")
const StructureLifecycleConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd")
const CognitionContractConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/CognitionContractConfigResource.gd")
const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const TileKeyUtilsScript = preload("res://addons/local_agents/simulation/TileKeyUtils.gd")
const SimulationControllerCoreLoopHelpersScript = preload("res://addons/local_agents/simulation/SimulationControllerCoreLoopHelpers.gd")
const SimulationControllerCultureStateHelpersScript = preload("res://addons/local_agents/simulation/SimulationControllerCultureStateHelpers.gd")
const SimulationControllerOpsHelpersScript = preload("res://addons/local_agents/simulation/SimulationControllerOpsHelpers.gd")
const SimulationControllerRuntimeHelpersScript = preload("res://addons/local_agents/simulation/SimulationControllerRuntimeHelpers.gd")
const CommunityLedgerScript = preload("res://addons/local_agents/simulation/CommunityLedgerSystem.gd")
const HouseholdLedgerScript = preload("res://addons/local_agents/simulation/HouseholdLedgerSystem.gd")
const IndividualLedgerScript = preload("res://addons/local_agents/simulation/IndividualLedgerSystem.gd")
const EconomyScript = preload("res://addons/local_agents/simulation/EconomySystem.gd")
const CarryProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/CarryProfileResource.gd")
const MarketConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/MarketConfigResource.gd")
const TransferRuleResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/TransferRuleResource.gd")
const ProfessionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/ProfessionProfileResource.gd")
const BundleResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/ResourceBundleResource.gd")
const SnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/SimulationEconomySnapshotResource.gd")
const VillagerStateResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerStateResource.gd")
const HouseholdMembershipResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/HouseholdMembershipResource.gd")
const NarratorDirectiveResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/NarratorDirectiveResource.gd")
const VillagerEconomyStateResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerEconomyStateResource.gd")
const VillagerInventoryResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerInventoryResource.gd")
var world_id: String = "world_main"
var active_branch_id: String = "main"
var _branch_lineage: Array = []
var _branch_fork_tick: int = -1
var _rng
var _narrator
var _dreams
var _mind
var _store
var _branch_analysis
var _culture_cycle
var _villagers: Dictionary = {}
var _household_members: Dictionary = {}
var _household_ledgers: Dictionary = {}
var _individual_ledgers: Dictionary = {}
var _carry_profiles: Dictionary = {}
var _community_ledger
var _narrator_directive_resource
var _backstory_service
var _world_generator
var _hydrology_system
var _settlement_seeder
var _weather_system
var _erosion_system
var _solar_system
var _worldgen_config
var _environment_snapshot: Dictionary = {}
var _water_network_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _erosion_snapshot: Dictionary = {}
var _solar_snapshot: Dictionary = {}
var _erosion_changed_last_tick: bool = false
var _erosion_changed_tiles_last_tick: Array = []
var _spawn_artifact: Dictionary = {}
var _flow_network_system
var _flow_traversal_profile
var _flow_formation_config
var _flow_runtime_config
var _structure_lifecycle_system
var _structure_lifecycle_config
var _structure_lifecycle_events: Dictionary = {"expanded": [], "abandoned": []}
var _household_growth_metrics: Dictionary = {}
var _external_living_entity_profiles: Array = []
var _villager_positions: Dictionary = {}
var _household_positions: Dictionary = {}
var _community_anchor_position: Vector3 = Vector3.ZERO
var _last_partial_delivery_count: int = 0
var _sacred_site_id: String = ""
var _oral_tick_events: Array = []
var _ritual_tick_events: Array = []
var _culture_driver_events: Array = []
var _cultural_policy: Dictionary = {}
var _culture_context_cues: Dictionary = {}
var _last_tick_processed: int = 0
var _initialized: bool = false
var _cognition_contract_config
var _llama_server_options: Dictionary = {
    "backend": "llama_server",
    "server_base_url": "http://127.0.0.1:8080",
    "server_autostart": true,
    "server_shutdown_on_exit": false,
    "server_start_timeout_ms": 45000,
    "server_ready_timeout_ms": 2500,
    "server_embeddings": true,
    "server_pooling": "mean",
    "cache_prompt": false,
    "server_slots": 4,
}
var _community_ledger_system
var _household_ledger_system
var _individual_ledger_system
var _economy_system
var _resource_event_sequence: int = 0
var _last_market_prices: Dictionary = {}
var _market_config
var _transfer_rules
var narrator_enabled: bool = true
var thoughts_enabled: bool = true
var dialogue_enabled: bool = true
var dreams_enabled: bool = true
var persist_tick_history_enabled: bool = false
var persist_tick_history_interval: int = 24
var resource_event_logging_enabled: bool = false
var weather_step_interval_ticks: int = 2
var hydrology_step_interval_ticks: int = 2
var erosion_step_interval_ticks: int = 4
var solar_step_interval_ticks: int = 4
var _pending_thought_npc_ids: Array = []
var _pending_dream_npc_ids: Array = []
var _pending_dialogue_pairs: Array = []
func _ready() -> void:
    _ensure_initialized()

func _ensure_initialized() -> void:
    SimulationControllerCoreLoopHelpersScript.ensure_initialized(self)

func configure(seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
    _ensure_initialized()
    _reset_store_for_instance()
    _rng.set_base_seed_from_text(seed_text)
    active_branch_id = "main"
    _branch_lineage = []
    _branch_fork_tick = -1
    _last_tick_processed = 0
    _pending_thought_npc_ids.clear()
    _pending_dream_npc_ids.clear()
    _pending_dialogue_pairs.clear()
    self.narrator_enabled = narrator_enabled
    _narrator.enabled = narrator_enabled
    _dreams.llm_enabled = dream_llm_enabled
    _mind.llm_enabled = dream_llm_enabled
    if _culture_cycle != null:
        _culture_cycle.llm_enabled = dream_llm_enabled
    _store.open(_store_path_for_instance())
    _apply_llama_server_integration()
    configure_environment(_worldgen_config)

func _store_path_for_instance() -> String:
    return ProjectSettings.globalize_path("user://local_agents/sim_%d.sqlite3" % get_instance_id())

func _reset_store_for_instance() -> void:
    if _store != null:
        _store.close()
    var path = _store_path_for_instance()
    for suffix in ["", "-wal", "-shm", "-journal"]:
        var candidate = path + suffix
        if FileAccess.file_exists(candidate):
            DirAccess.remove_absolute(candidate)

func configure_environment(config_resource = null) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.configure_environment(self, config_resource)

func get_environment_snapshot() -> Dictionary:
    return _environment_snapshot.duplicate(true)

func get_water_network_snapshot() -> Dictionary:
    return _water_network_snapshot.duplicate(true)

func get_weather_snapshot() -> Dictionary:
    return _weather_snapshot.duplicate(true)

func get_erosion_snapshot() -> Dictionary:
    return _erosion_snapshot.duplicate(true)

func get_solar_snapshot() -> Dictionary:
    return _solar_snapshot.duplicate(true)

func runtime_backend_metrics() -> Dictionary:
    return {
        "hydrology_compute": bool(_hydrology_system != null and _hydrology_system.has_method("is_compute_active") and _hydrology_system.is_compute_active()),
        "weather_compute": bool(_weather_system != null and _weather_system.has_method("is_compute_active") and _weather_system.is_compute_active()),
        "erosion_compute": bool(_erosion_system != null and _erosion_system.has_method("is_compute_active") and _erosion_system.is_compute_active()),
        "solar_compute": bool(_solar_system != null and _solar_system.has_method("is_compute_active") and _solar_system.is_compute_active()),
    }

func build_environment_signal_snapshot(tick: int = -1):
    var snapshot_resource = EnvironmentSignalSnapshotResourceScript.new()
    snapshot_resource.tick = tick if tick >= 0 else _last_tick_processed
    snapshot_resource.environment_snapshot = _environment_snapshot.duplicate(true)
    snapshot_resource.water_network_snapshot = _water_network_snapshot.duplicate(true)
    snapshot_resource.weather_snapshot = _weather_snapshot.duplicate(true)
    snapshot_resource.erosion_snapshot = _erosion_snapshot.duplicate(true)
    snapshot_resource.solar_snapshot = _solar_snapshot.duplicate(true)
    snapshot_resource.erosion_changed = _erosion_changed_last_tick
    snapshot_resource.erosion_changed_tiles = _erosion_changed_tiles_last_tick.duplicate(true)
    return snapshot_resource

func get_spawn_artifact() -> Dictionary:
    return _spawn_artifact.duplicate(true)

func get_backstory_service():
    return _backstory_service

func get_store():
    return _store

func list_llm_trace_events(tick_from: int, tick_to: int, task: String = "") -> Array:
    _ensure_initialized()
    var out: Array = []
    if _store == null:
        return out
    var rows: Array = _store.list_resource_events(world_id, active_branch_id, tick_from, tick_to)
    for row_variant in rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        if String(row.get("event_type", "")) != "sim_llm_trace_event":
            continue
        var payload: Dictionary = row.get("payload", {})
        var task_name = String(payload.get("task", ""))
        if task.strip_edges() != "" and task_name != task.strip_edges():
            continue
        out.append({
            "tick": int(row.get("tick", 0)),
            "task": task_name,
            "scope": String(row.get("scope", "")),
            "owner_id": String(row.get("owner_id", "")),
            "actor_ids": payload.get("actor_ids", []),
            "profile_id": String(payload.get("profile_id", "")),
            "seed": int(payload.get("seed", 0)),
            "query_keys": payload.get("query_keys", []),
            "referenced_ids": payload.get("referenced_ids", []),
            "sampler_params": payload.get("sampler_params", {}),
        })
    out.sort_custom(func(a, b):
        var ad = a as Dictionary
        var bd = b as Dictionary
        var at = int(ad.get("tick", 0))
        var bt = int(bd.get("tick", 0))
        if at != bt:
            return at < bt
        return String(ad.get("task", "")) < String(bd.get("task", ""))
    )
    return out

func get_active_branch_id() -> String:
    return active_branch_id

func fork_branch(new_branch_id: String, fork_tick: int) -> Dictionary:
    _ensure_initialized()
    var target = new_branch_id.strip_edges()
    if target == "":
        return {"ok": false, "error": "invalid_branch_id"}
    if target == active_branch_id:
        return {"ok": false, "error": "branch_id_unchanged"}
    var entry = {
        "branch_id": active_branch_id,
        "tick": maxi(0, fork_tick),
    }
    var next_lineage: Array = _branch_lineage.duplicate(true)
    next_lineage.append(entry)
    var fork_hash = str(hash(JSON.stringify(current_snapshot(maxi(0, fork_tick)), "", false, true)))
    if _store != null:
        _store.create_checkpoint(world_id, target, maxi(0, fork_tick), fork_hash, next_lineage, maxi(0, fork_tick))
    active_branch_id = target
    _branch_lineage = next_lineage
    _branch_fork_tick = maxi(0, fork_tick)
    return {
        "ok": true,
        "branch_id": active_branch_id,
        "lineage": _branch_lineage.duplicate(true),
        "fork_tick": _branch_fork_tick,
    }

func restore_to_tick(target_tick: int, branch_id: String = "") -> Dictionary:
    _ensure_initialized()
    var effective_branch = branch_id.strip_edges()
    if effective_branch == "":
        effective_branch = active_branch_id
    if _store == null:
        return {"ok": false, "error": "store_unavailable"}
    var events: Array = _store.list_events(world_id, effective_branch, 0, maxi(0, target_tick))
    if events.is_empty():
        return {"ok": false, "error": "snapshot_not_found", "tick": target_tick, "branch_id": effective_branch}
    var selected: Dictionary = {}
    for row_variant in events:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        if String(row.get("event_type", "")) != "tick":
            continue
        selected = row
    if selected.is_empty():
        return {"ok": false, "error": "snapshot_not_found", "tick": target_tick, "branch_id": effective_branch}
    var payload: Dictionary = selected.get("payload", {})
    if payload.is_empty():
        return {"ok": false, "error": "snapshot_payload_missing"}
    _apply_snapshot(payload)
    active_branch_id = effective_branch
    _last_tick_processed = int(payload.get("tick", target_tick))
    return {"ok": true, "tick": _last_tick_processed, "branch_id": active_branch_id}

func branch_diff(base_branch_id: String, compare_branch_id: String, tick_from: int, tick_to: int) -> Dictionary:
    _ensure_initialized()
    if _branch_analysis == null:
        return {"ok": false, "error": "branch_analysis_unavailable"}
    return _branch_analysis.compare_branches(
        _store,
        world_id,
        base_branch_id,
        compare_branch_id,
        tick_from,
        tick_to,
        _backstory_service
    )

func set_cognition_features(enable_thoughts: bool, enable_dialogue: bool, enable_dreams: bool) -> void:
    _ensure_initialized()
    thoughts_enabled = enable_thoughts
    dialogue_enabled = enable_dialogue
    dreams_enabled = enable_dreams
    if _culture_cycle != null:
        _culture_cycle.llm_enabled = enable_thoughts or enable_dialogue or enable_dreams

func set_cognition_contract_config(config_resource) -> void:
    _ensure_initialized()
    if config_resource == null:
        _cognition_contract_config = CognitionContractConfigResourceScript.new()
    else:
        _cognition_contract_config = config_resource
    _apply_cognition_contract()
    _apply_llama_server_integration()

func _apply_cognition_contract() -> void:
    if _cognition_contract_config == null:
        _cognition_contract_config = CognitionContractConfigResourceScript.new()
    if _cognition_contract_config.has_method("ensure_defaults"):
        _cognition_contract_config.call("ensure_defaults")
    if _narrator != null and _narrator.has_method("set_request_profile"):
        _narrator.call("set_request_profile", _cognition_contract_config.call("profile_for_task", "narrator_direction"))
    if _mind != null and _mind.has_method("set_request_profile"):
        _mind.call("set_request_profile", "internal_thought", _cognition_contract_config.call("profile_for_task", "internal_thought"))
        _mind.call("set_request_profile", "dialogue_exchange", _cognition_contract_config.call("profile_for_task", "dialogue_exchange"))
    if _mind != null and _mind.has_method("set_contract_limits"):
        _mind.call("set_contract_limits", {
            "context_schema_version": int(_cognition_contract_config.get("context_schema_version")),
            "max_prompt_chars": int(_cognition_contract_config.get("max_prompt_chars")),
            "state_chars": int(_cognition_contract_config.get("budget_state_chars")),
            "waking_memories": int(_cognition_contract_config.get("budget_waking_memories")),
            "dream_memories": int(_cognition_contract_config.get("budget_dream_memories")),
            "beliefs": int(_cognition_contract_config.get("budget_beliefs")),
            "conflicts": int(_cognition_contract_config.get("budget_conflicts")),
            "oral_knowledge": int(_cognition_contract_config.get("budget_oral_knowledge")),
            "ritual_events": int(_cognition_contract_config.get("budget_ritual_events")),
            "taboo_ids": int(_cognition_contract_config.get("budget_taboo_ids")),
        })
    if _dreams != null and _dreams.has_method("set_request_profile"):
        _dreams.call("set_request_profile", _cognition_contract_config.call("profile_for_task", "dream_generation"))
    if _culture_cycle != null and _culture_cycle.has_method("set_request_profile"):
        _culture_cycle.call("set_request_profile", _cognition_contract_config.call("profile_for_task", "oral_transmission_utterance"))

func set_llama_server_options(options: Dictionary) -> void:
    _ensure_initialized()
    for key_variant in options.keys():
        var key = String(key_variant)
        _llama_server_options[key] = options[key]
    _apply_llama_server_integration()

func get_llama_server_options() -> Dictionary:
    _ensure_initialized()
    return _llama_server_options.duplicate(true)

func _apply_llama_server_integration() -> void:
    var generation_options := _llama_server_options.duplicate(true)
    var resolved_model_path := _resolve_llama_model_path(generation_options)
    if resolved_model_path != "":
        generation_options["server_model_path"] = resolved_model_path
        if not generation_options.has("model_path"):
            generation_options["model_path"] = resolved_model_path
        if not generation_options.has("server_model"):
            generation_options["server_model"] = resolved_model_path.get_file()
    var resolved_runtime_dir := _resolve_runtime_directory(generation_options)
    if resolved_runtime_dir != "":
        generation_options["runtime_directory"] = resolved_runtime_dir
    if _narrator != null and _narrator.has_method("set_runtime_options"):
        _narrator.call("set_runtime_options", generation_options)
    if _mind != null and _mind.has_method("set_runtime_options"):
        _mind.call("set_runtime_options", generation_options)
    if _dreams != null and _dreams.has_method("set_runtime_options"):
        _dreams.call("set_runtime_options", generation_options)
    if _culture_cycle != null and _culture_cycle.has_method("set_runtime_options"):
        _culture_cycle.call("set_runtime_options", generation_options)
    if _backstory_service != null and _backstory_service.has_method("set_embedding_options"):
        var embedding_options := generation_options.duplicate(true)
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
        _backstory_service.call("set_embedding_options", embedding_options)

func _resolve_llama_model_path(options: Dictionary) -> String:
    for key in ["server_model_path", "model_path", "model"]:
        var candidate := String(options.get(key, "")).strip_edges()
        if candidate == "":
            continue
        var normalized := RuntimePathsScript.normalize_path(candidate)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    if OS.has_environment("LOCAL_AGENTS_TEST_GGUF"):
        var from_env := RuntimePathsScript.normalize_path(OS.get_environment("LOCAL_AGENTS_TEST_GGUF").strip_edges())
        if from_env != "" and FileAccess.file_exists(from_env):
            return from_env
    if Engine.has_singleton("AgentRuntime"):
        var runtime = Engine.get_singleton("AgentRuntime")
        if runtime != null and runtime.has_method("get_default_model_path"):
            var runtime_model := RuntimePathsScript.normalize_path(String(runtime.call("get_default_model_path")).strip_edges())
            if runtime_model != "" and FileAccess.file_exists(runtime_model):
                return runtime_model
    var fallback := RuntimePathsScript.resolve_default_model()
    if fallback != "" and FileAccess.file_exists(fallback):
        return fallback
    return ""

func _resolve_runtime_directory(options: Dictionary) -> String:
    var explicit_dir := RuntimePathsScript.normalize_path(String(options.get("runtime_directory", "")).strip_edges())
    if explicit_dir != "":
        return explicit_dir
    var runtime_dir := RuntimePathsScript.runtime_dir()
    if runtime_dir != "":
        return runtime_dir
    return ""

func set_narrator_directive(text: String) -> void:
    _ensure_initialized()
    if _narrator_directive_resource == null:
        _narrator_directive_resource = NarratorDirectiveResourceScript.new()
    _narrator_directive_resource.set_text(text, -1)

func set_dream_influence(npc_id: String, influence: Dictionary) -> void:
    _ensure_initialized()
    _dreams.set_dream_influence(npc_id, influence)

func set_profession_profile(profile_resource) -> void:
    _ensure_initialized()
    if profile_resource == null:
        return
    _economy_system.set_profession_profile(profile_resource)

func set_flow_traversal_profile(profile_resource) -> void:
    _ensure_initialized()
    if profile_resource == null:
        _flow_traversal_profile = FlowTraversalProfileResourceScript.new()
    else:
        _flow_traversal_profile = profile_resource
    if _flow_network_system != null:
        _flow_network_system.set_flow_profile(_flow_traversal_profile)

func set_flow_formation_config(config_resource) -> void:
    _ensure_initialized()
    if config_resource == null:
        _flow_formation_config = FlowFormationConfigResourceScript.new()
    else:
        _flow_formation_config = config_resource
    if _flow_network_system != null:
        _flow_network_system.set_flow_formation_config(_flow_formation_config)

func set_flow_runtime_config(config_resource) -> void:
    _ensure_initialized()
    if config_resource == null:
        _flow_runtime_config = FlowRuntimeConfigResourceScript.new()
    else:
        _flow_runtime_config = config_resource
    if _flow_network_system != null:
        _flow_network_system.set_flow_runtime_config(_flow_runtime_config)

func set_structure_lifecycle_config(config_resource) -> void:
    _ensure_initialized()
    if config_resource == null:
        _structure_lifecycle_config = StructureLifecycleConfigResourceScript.new()
    else:
        _structure_lifecycle_config = config_resource
    if _structure_lifecycle_system != null:
        _structure_lifecycle_system.set_config(_structure_lifecycle_config)

func set_culture_context_cues(cues: Dictionary) -> void:
    _ensure_initialized()
    _culture_context_cues = cues.duplicate(true)

func set_living_entity_profiles(profiles: Array) -> void:
    _ensure_initialized()
    _external_living_entity_profiles.clear()
    for row_variant in profiles:
        if not (row_variant is Dictionary):
            continue
        _external_living_entity_profiles.append((row_variant as Dictionary).duplicate(true))

func register_villager(npc_id: String, display_name: String, initial_state: Dictionary = {}) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.register_villager(self, npc_id, display_name, initial_state)

func process_tick(tick: int, fixed_delta: float, include_state: bool = true) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.process_tick(self, tick, fixed_delta, include_state)

func current_snapshot(tick: int) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.current_snapshot(self, tick)

func _generation_cap(task: String, fallback: int) -> int:
    var key = "max_generations_per_tick_%s" % task
    return maxi(1, int(_llama_server_options.get(key, fallback)))

func _enqueue_thought_npcs(npc_ids: Array) -> void:
    for npc_id_variant in npc_ids:
        var npc_id = String(npc_id_variant).strip_edges()
        if npc_id == "" or _pending_thought_npc_ids.has(npc_id):
            continue
        _pending_thought_npc_ids.append(npc_id)

func _enqueue_dream_npcs(npc_ids: Array) -> void:
    for npc_id_variant in npc_ids:
        var npc_id = String(npc_id_variant).strip_edges()
        if npc_id == "" or _pending_dream_npc_ids.has(npc_id):
            continue
        _pending_dream_npc_ids.append(npc_id)

func _enqueue_dialogue_pairs(npc_ids: Array) -> void:
    if npc_ids.size() < 2:
        return
    for index in range(0, npc_ids.size() - 1, 2):
        var source_id = String(npc_ids[index]).strip_edges()
        var target_id = String(npc_ids[index + 1]).strip_edges()
        if source_id == "" or target_id == "":
            continue
        var pair_key = "%s|%s" % [source_id, target_id]
        var already_queued = false
        for pair_variant in _pending_dialogue_pairs:
            if not (pair_variant is Dictionary):
                continue
            var pair = pair_variant as Dictionary
            if "%s|%s" % [String(pair.get("source_id", "")), String(pair.get("target_id", ""))] == pair_key:
                already_queued = true
                break
        if not already_queued:
            _pending_dialogue_pairs.append({
                "source_id": source_id,
                "target_id": target_id,
            })

func _drain_thought_queue(tick: int, limit: int) -> bool:
    var consumed = 0
    while consumed < limit and not _pending_thought_npc_ids.is_empty():
        var npc_id = String(_pending_thought_npc_ids[0]).strip_edges()
        _pending_thought_npc_ids.remove_at(0)
        if npc_id == "":
            continue
        if not _run_thought_cycle(npc_id, tick):
            return false
        consumed += 1
    return true

func _drain_dream_queue(tick: int, limit: int) -> bool:
    var consumed = 0
    while consumed < limit and not _pending_dream_npc_ids.is_empty():
        var npc_id = String(_pending_dream_npc_ids[0]).strip_edges()
        _pending_dream_npc_ids.remove_at(0)
        if npc_id == "":
            continue
        if not _run_dream_cycle(npc_id, tick):
            return false
        consumed += 1
    return true

func _drain_dialogue_queue(tick: int, limit: int) -> bool:
    var consumed = 0
    while consumed < limit and not _pending_dialogue_pairs.is_empty():
        var pair_variant = _pending_dialogue_pairs[0]
        _pending_dialogue_pairs.remove_at(0)
        if not (pair_variant is Dictionary):
            continue
        var pair = pair_variant as Dictionary
        var source_id = String(pair.get("source_id", "")).strip_edges()
        var target_id = String(pair.get("target_id", "")).strip_edges()
        if source_id == "" or target_id == "":
            continue
        if not _run_dialogue_pair(source_id, target_id, tick):
            return false
        consumed += 1
    return true

func _apply_need_decay(npc_id: String, fixed_delta: float) -> void:
    var state = _villagers.get(npc_id, null)
    if state == null:
        return
    state.energy = clampf(float(state.energy) - (0.004 * fixed_delta), 0.0, 1.0)
    state.hunger = clampf(float(state.hunger) + (0.006 * fixed_delta), 0.0, 1.0)

    var econ_state = _individual_ledgers.get(npc_id, null)
    if econ_state != null:
        econ_state.energy = clampf(float(state.energy), 0.0, 1.0)
        _individual_ledgers[npc_id] = _individual_ledger_system.ensure_bounds(econ_state)

func _generate_narrator_direction(tick: int) -> bool:
    var seed = _rng.derive_seed("narrator", world_id, active_branch_id, tick)
    var result = _narrator.generate_direction(current_snapshot(tick), seed, _directive_text())
    if not bool(result.get("ok", false)):
        return _emit_dependency_error(tick, "narrator", String(result.get("error", "narrator_failed")))
    _persist_llm_trace_event(tick, "narrator_direction", [], result.get("trace", {}))
    emit_signal("narrator_direction_generated", tick, result.get("text", ""))
    return true

func _run_thought_cycle(npc_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_thought_cycle(self, npc_id, tick)

func _run_dialogue_cycle(npc_ids: Array, tick: int) -> bool:
    if npc_ids.size() < 2:
        return true
    for index in range(0, npc_ids.size() - 1, 2):
        var source_id = String(npc_ids[index]).strip_edges()
        var target_id = String(npc_ids[index + 1]).strip_edges()
        if source_id == "" or target_id == "":
            continue
        if not _run_dialogue_pair(source_id, target_id, tick):
            return false
    return true

func _run_dialogue_pair(source_id: String, target_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_dialogue_pair(self, source_id, target_id, tick)

func _run_dream_cycle(npc_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_dream_cycle(self, npc_id, tick)

func _run_resource_pipeline(tick: int, npc_ids: Array) -> void:
    SimulationControllerRuntimeHelpersScript.run_resource_pipeline(self, tick, npc_ids)

func _run_structure_lifecycle(tick: int) -> void:
    if _structure_lifecycle_system == null:
        return
    var household_counts = _household_member_counts()
    var result: Dictionary = _structure_lifecycle_system.step_lifecycle(
        tick,
        household_counts,
        _household_growth_metrics,
        _household_positions,
        _water_network_snapshot
    )
    _structure_lifecycle_events = {
        "expanded": result.get("expanded", []),
        "abandoned": result.get("abandoned", []),
    }
    if not _structure_lifecycle_events.get("expanded", []).is_empty():
        _log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
            "kind": "structure_expansion",
            "structure_ids": _structure_lifecycle_events.get("expanded", []),
        })
    if not _structure_lifecycle_events.get("abandoned", []).is_empty():
        _log_resource_event(tick, "sim_structure_event", "settlement", "settlement_main", {
            "kind": "structure_abandonment",
            "structure_ids": _structure_lifecycle_events.get("abandoned", []),
        })

func _assert_resource_invariants(tick: int, npc_ids: Array) -> void:
    for key in ["food", "water", "wood", "stone", "tools", "currency", "labor_pool", "waste"]:
        var value = float(_community_ledger.to_dict().get(key, 0.0))
        if value < -0.000001:
            _emit_dependency_error(tick, "resource_invariant", "community_negative_" + key)

    var household_ids = _household_ledgers.keys()
    household_ids.sort()
    for hid in household_ids:
        var ledger = _household_ledgers.get(String(hid), null)
        if ledger == null:
            continue
        var row = ledger.to_dict()
        for key in ["food", "water", "wood", "stone", "tools", "currency", "debt", "waste"]:
            if float(row.get(key, 0.0)) < -0.000001:
                _emit_dependency_error(tick, "resource_invariant", "household_negative_" + key)

    for npc_id in npc_ids:
        var state = _individual_ledgers.get(npc_id, null)
        if state == null:
            continue
        var row = state.to_dict()
        var inv: Dictionary = row.get("inventory", {})
        for key in ["food", "water", "currency", "tools", "waste"]:
            if float(inv.get(key, 0.0)) < -0.000001:
                _emit_dependency_error(tick, "resource_invariant", "individual_negative_" + key)
        if float(row.get("wage_due", 0.0)) < -0.000001:
            _emit_dependency_error(tick, "resource_invariant", "individual_negative_wage_due")

func _memory_refs_from_recall(recall: Dictionary) -> Array:
    return SimulationControllerOpsHelpersScript.memory_refs_from_recall(recall)

func _sorted_npc_ids() -> Array:
    return SimulationControllerOpsHelpersScript.sorted_npc_ids(self)

func _serialize_villagers() -> Dictionary:
    return SimulationControllerOpsHelpersScript.serialize_villagers(self)

func _serialize_household_ledgers() -> Dictionary:
    return SimulationControllerOpsHelpersScript.serialize_household_ledgers(self)

func _serialize_individual_ledgers() -> Dictionary:
    return SimulationControllerOpsHelpersScript.serialize_individual_ledgers(self)

func _serialize_carry_profiles() -> Dictionary:
    return SimulationControllerOpsHelpersScript.serialize_carry_profiles(self)

func _belief_context_for_npc(npc_id: String, world_day: int, limit: int) -> Dictionary:
    return SimulationControllerOpsHelpersScript.belief_context_for_npc(self, npc_id, world_day, limit)

func _culture_context_for_npc(npc_id: String, world_day: int) -> Dictionary:
    return SimulationControllerOpsHelpersScript.culture_context_for_npc(self, npc_id, world_day)

func _directive_text() -> String:
    if _narrator_directive_resource == null:
        return ""
    return String(_narrator_directive_resource.text)

func _is_thought_tick(tick: int) -> bool:
    return tick > 0 and tick % 24 == 8

func _is_dialogue_tick(tick: int) -> bool:
    return tick > 0 and tick % 24 == 14

func _is_dream_tick(tick: int) -> bool:
    return tick > 0 and tick % 24 == 22

func _emit_dependency_error(tick: int, phase: String, error_code: String) -> bool:
    push_error("Simulation dependency error at tick %d phase %s: %s" % [tick, phase, error_code])
    emit_signal("simulation_dependency_error", tick, phase, error_code)
    return false

func _dependency_error_result(tick: int, phase: String) -> Dictionary:
    return {
        "ok": false,
        "tick": tick,
        "error": "dependency_error",
        "phase": phase,
    }

func _log_resource_event(tick: int, event_type: String, scope: String, owner_id: String, payload: Dictionary) -> void:
    if not resource_event_logging_enabled:
        return
    if _store == null:
        return
    var normalized_scope = scope.strip_edges()
    if normalized_scope == "":
        normalized_scope = "settlement"
    var normalized_owner = owner_id.strip_edges()
    if normalized_owner == "":
        normalized_owner = "settlement_main"
    var bundle = BundleResourceScript.new()
    bundle.from_dict(payload)
    var normalized = payload.duplicate(true)
    if not bundle.to_dict().is_empty():
        normalized["resource_bundle"] = bundle.to_dict()
    var event_id: int = _store.append_resource_event(world_id, active_branch_id, tick, _resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
    if event_id == -1:
        _store.open(_store_path_for_instance())
        event_id = _store.append_resource_event(world_id, active_branch_id, tick, _resource_event_sequence, event_type, normalized_scope, normalized_owner, normalized)
    if event_id == -1:
        _emit_dependency_error(tick, "resource_event_store", "append_failed")
    _resource_event_sequence += 1

func _persist_llm_trace_event(tick: int, task: String, actor_ids: Array, trace_variant) -> void:
    if not resource_event_logging_enabled:
        return
    if not (trace_variant is Dictionary):
        return
    var trace: Dictionary = trace_variant
    if trace.is_empty():
        return
    var query_keys: Array = trace.get("query_keys", [])
    var referenced_ids: Array = trace.get("referenced_ids", [])
    var normalized_actors: Array = _normalize_id_array(actor_ids)
    var normalized_referenced: Array = _normalize_id_array(referenced_ids)
    var profile_id = String(trace.get("profile_id", "")).strip_edges()
    var sampler_params: Dictionary = {}
    var sampler_variant = trace.get("sampler_params", {})
    if sampler_variant is Dictionary:
        sampler_params = (sampler_variant as Dictionary).duplicate(true)
    var payload := {
        "kind": "llm_trace",
        "task": task,
        "actor_ids": normalized_actors,
        "profile_id": profile_id,
        "seed": int(trace.get("seed", 0)),
        "query_keys": _normalize_id_array(query_keys),
        "referenced_ids": normalized_referenced,
        "sampler_params": sampler_params,
    }
    if _store == null:
        _emit_dependency_error(tick, "llm_trace_store", "store_unavailable")
        return
    var scope = "settlement"
    var owner_id = "settlement_main"
    if normalized_actors.size() == 1:
        scope = "individual"
        owner_id = String(normalized_actors[0])
    elif normalized_referenced.size() == 1:
        scope = "individual"
        owner_id = String(normalized_referenced[0])
    _log_resource_event(tick, "sim_llm_trace_event", scope, owner_id, payload)

func _normalize_id_array(values: Array) -> Array:
    return SimulationControllerOpsHelpersScript.normalize_id_array(values)

func _apply_carry_assignments(members: Array, assignments: Dictionary) -> void:
    SimulationControllerOpsHelpersScript.apply_carry_assignments(self, members, assignments)

func _apply_route_transport(assignments: Dictionary, start: Vector3, target: Vector3, tick: int) -> Dictionary:
    return SimulationControllerOpsHelpersScript.apply_route_transport(self, assignments, start, target, tick)

func _merge_payloads(primary: Dictionary, secondary: Dictionary) -> Dictionary:
    return SimulationControllerOpsHelpersScript.merge_payloads(primary, secondary)

func _spawn_offset_position(entity_id: String, radius: float) -> Vector3:
    return SimulationControllerOpsHelpersScript.spawn_offset_position(self, entity_id, radius)

func _household_position(household_id: String) -> Vector3:
    return SimulationControllerOpsHelpersScript.household_position(self, household_id)

func _sum_payload(payload: Dictionary) -> float:
    return SimulationControllerOpsHelpersScript.sum_payload(payload)

func _mean_route_path_strength(route_profiles: Dictionary) -> float:
    return SimulationControllerOpsHelpersScript.mean_route_path_strength(route_profiles)

func _household_member_counts() -> Dictionary:
    return SimulationControllerOpsHelpersScript.household_member_counts(self)

func _seed_sacred_site() -> void:
    SimulationControllerOpsHelpersScript.seed_sacred_site(self)

func _run_culture_cycle(tick: int) -> void:
    SimulationControllerCultureStateHelpersScript.run_culture_cycle(self, tick)

func _ensure_culture_event_metadata(event: Dictionary) -> Dictionary:
    return SimulationControllerCultureStateHelpersScript.ensure_culture_event_metadata(event)

func _apply_snapshot(snapshot: Dictionary) -> void:
    SimulationControllerCultureStateHelpersScript.apply_snapshot(self, snapshot)

func _build_culture_context(tick: int) -> Dictionary:
    return SimulationControllerCultureStateHelpersScript.build_culture_context(self, tick)

func _derive_cultural_policy(drivers: Array) -> Dictionary:
    return SimulationControllerCultureStateHelpersScript.derive_cultural_policy(drivers)

func _cultural_policy_strength(policy_name: String) -> float:
    return clampf(float(_cultural_policy.get(policy_name, 0.0)), 0.0, 1.0)

func _tile_context_for_position(position: Vector3) -> Dictionary:
    return SimulationControllerCultureStateHelpersScript.tile_context_for_position(self, position)

func _recent_resource_event_context(tick_from: int, tick_to: int) -> Array:
    return SimulationControllerCultureStateHelpersScript.recent_resource_event_context(self, tick_from, tick_to)

func _event_magnitude(payload: Dictionary) -> float:
    return SimulationControllerCultureStateHelpersScript.event_magnitude(payload)

func _apply_community_dict(ledger, payload_variant) -> void:
    SimulationControllerCultureStateHelpersScript.apply_community_dict(ledger, payload_variant)

func _apply_household_dict(ledger, payload_variant) -> void:
    SimulationControllerCultureStateHelpersScript.apply_household_dict(ledger, payload_variant)

func _apply_individual_dict(state, payload_variant) -> void:
    SimulationControllerCultureStateHelpersScript.apply_individual_dict(state, payload_variant)

func _apply_carry_profile_dict(profile, payload_variant) -> void:
    SimulationControllerCultureStateHelpersScript.apply_carry_profile_dict(profile, payload_variant)
