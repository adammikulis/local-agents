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
const SimulationConfigControllerScript = preload("res://addons/local_agents/simulation/controller/SimulationConfigController.gd")
const SimulationSnapshotControllerScript = preload("res://addons/local_agents/simulation/controller/SimulationSnapshotController.gd")
const SimulationRuntimeFacadeScript = preload("res://addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd")
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
var _last_tick_profile: Dictionary = {}
var _native_view_metrics: Dictionary = {}
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
var locality_processing_enabled: bool = true
var locality_dynamic_tick_rate_enabled: bool = true
var locality_activity_radius_tiles: int = 1
var weather_gpu_compute_enabled: bool = true
var hydrology_gpu_compute_enabled: bool = true
var erosion_gpu_compute_enabled: bool = true
var solar_gpu_compute_enabled: bool = true
var resource_pipeline_interval_ticks: int = 2
var structure_lifecycle_interval_ticks: int = 2
var culture_cycle_interval_ticks: int = 4
var _pending_thought_npc_ids: Array = []
var _pending_dream_npc_ids: Array = []
var _pending_dialogue_pairs: Array = []
func _ready() -> void:
    _ensure_initialized()
func _ensure_initialized() -> void:
    SimulationControllerCoreLoopHelpersScript.ensure_initialized(self)
    SimulationRuntimeFacadeScript.ensure_native_sim_core_initialized(self)
func configure(seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
    SimulationConfigControllerScript.configure(self, seed_text, narrator_enabled, dream_llm_enabled)
func _store_path_for_instance() -> String:
    return ProjectSettings.globalize_path("user://local_agents/sim_%d.sqlite3" % get_instance_id())

func _reset_store_for_instance() -> void:
    SimulationConfigControllerScript.reset_store_for_instance(self)

func configure_environment(config_resource = null) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.configure_environment(self, config_resource)

func get_environment_snapshot() -> Dictionary:
    return SimulationSnapshotControllerScript.get_environment_snapshot(self)

func get_water_network_snapshot() -> Dictionary:
    return SimulationSnapshotControllerScript.get_water_network_snapshot(self)

func get_weather_snapshot() -> Dictionary:
    return SimulationSnapshotControllerScript.get_weather_snapshot(self)

func get_erosion_snapshot() -> Dictionary:
    return SimulationSnapshotControllerScript.get_erosion_snapshot(self)

func get_solar_snapshot() -> Dictionary:
    return SimulationSnapshotControllerScript.get_solar_snapshot(self)

func runtime_backend_metrics() -> Dictionary:
    return SimulationSnapshotControllerScript.runtime_backend_metrics(self)

func set_native_view_metrics(metrics: Dictionary) -> void:
    _native_view_metrics = metrics.duplicate(true) if metrics != null else {}

func get_native_view_metrics() -> Dictionary:
    return _native_view_metrics.duplicate(true)

func build_environment_signal_snapshot(tick: int = -1):
    return SimulationSnapshotControllerScript.build_environment_signal_snapshot(self, tick)

func get_spawn_artifact() -> Dictionary:
    return SimulationSnapshotControllerScript.get_spawn_artifact(self)

func get_backstory_service():
    return SimulationSnapshotControllerScript.get_backstory_service(self)

func get_store():
    return SimulationSnapshotControllerScript.get_store(self)

func list_llm_trace_events(tick_from: int, tick_to: int, task: String = "") -> Array:
    return SimulationSnapshotControllerScript.list_llm_trace_events(self, tick_from, tick_to, task)

func get_active_branch_id() -> String:
    return SimulationSnapshotControllerScript.get_active_branch_id(self)

func fork_branch(new_branch_id: String, fork_tick: int) -> Dictionary:
    return SimulationSnapshotControllerScript.fork_branch(self, new_branch_id, fork_tick)

func restore_to_tick(target_tick: int, branch_id: String = "") -> Dictionary:
    return SimulationSnapshotControllerScript.restore_to_tick(self, target_tick, branch_id)

func branch_diff(base_branch_id: String, compare_branch_id: String, tick_from: int, tick_to: int) -> Dictionary:
    return SimulationSnapshotControllerScript.branch_diff(self, base_branch_id, compare_branch_id, tick_from, tick_to)

func set_cognition_features(enable_thoughts: bool, enable_dialogue: bool, enable_dreams: bool) -> void:
    SimulationConfigControllerScript.set_cognition_features(self, enable_thoughts, enable_dialogue, enable_dreams)

func set_cognition_contract_config(config_resource) -> void:
    SimulationConfigControllerScript.set_cognition_contract_config(self, config_resource)

func _apply_cognition_contract() -> void:
    SimulationConfigControllerScript.apply_cognition_contract(self)

func set_llama_server_options(options: Dictionary) -> void:
    SimulationConfigControllerScript.set_llama_server_options(self, options)

func get_llama_server_options() -> Dictionary:
    return SimulationConfigControllerScript.get_llama_server_options(self)

func _apply_llama_server_integration() -> void:
    SimulationConfigControllerScript.apply_llama_server_integration(self)

func _resolve_llama_model_path(options: Dictionary) -> String:
    return SimulationConfigControllerScript.resolve_llama_model_path(self, options)

func _resolve_runtime_directory(options: Dictionary) -> String:
    return SimulationConfigControllerScript.resolve_runtime_directory(self, options)

func set_narrator_directive(text: String) -> void:
    SimulationConfigControllerScript.set_narrator_directive(self, text)

func set_dream_influence(npc_id: String, influence: Dictionary) -> void:
    SimulationConfigControllerScript.set_dream_influence(self, npc_id, influence)

func set_profession_profile(profile_resource) -> void:
    SimulationConfigControllerScript.set_profession_profile(self, profile_resource)

func set_flow_traversal_profile(profile_resource) -> void:
    SimulationConfigControllerScript.set_flow_traversal_profile(self, profile_resource)

func set_flow_formation_config(config_resource) -> void:
    SimulationConfigControllerScript.set_flow_formation_config(self, config_resource)

func set_flow_runtime_config(config_resource) -> void:
    SimulationConfigControllerScript.set_flow_runtime_config(self, config_resource)

func set_structure_lifecycle_config(config_resource) -> void:
    SimulationConfigControllerScript.set_structure_lifecycle_config(self, config_resource)

func set_culture_context_cues(cues: Dictionary) -> void:
    SimulationConfigControllerScript.set_culture_context_cues(self, cues)

func set_living_entity_profiles(profiles: Array) -> void:
    SimulationConfigControllerScript.set_living_entity_profiles(self, profiles)

func register_villager(npc_id: String, display_name: String, initial_state: Dictionary = {}) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.register_villager(self, npc_id, display_name, initial_state)

func process_tick(tick: int, fixed_delta: float, include_state: bool = true) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.process_tick(self, tick, fixed_delta, include_state)

func current_snapshot(tick: int) -> Dictionary:
    return SimulationControllerCoreLoopHelpersScript.current_snapshot(self, tick)

func set_gpu_compute_modes(weather_enabled: bool, hydrology_enabled: bool, erosion_enabled: bool, solar_enabled: bool) -> void:
    weather_gpu_compute_enabled = weather_enabled
    hydrology_gpu_compute_enabled = hydrology_enabled
    erosion_gpu_compute_enabled = erosion_enabled
    solar_gpu_compute_enabled = solar_enabled
    _sync_compute_preferences()

func set_weather_gpu_compute_enabled(enabled: bool) -> void:
    weather_gpu_compute_enabled = enabled
    _sync_compute_preferences()

func set_hydrology_gpu_compute_enabled(enabled: bool) -> void:
    hydrology_gpu_compute_enabled = enabled
    _sync_compute_preferences()

func set_erosion_gpu_compute_enabled(enabled: bool) -> void:
    erosion_gpu_compute_enabled = enabled
    _sync_compute_preferences()

func set_solar_gpu_compute_enabled(enabled: bool) -> void:
    solar_gpu_compute_enabled = enabled
    _sync_compute_preferences()

func set_locality_processing_config(enabled: bool, dynamic_enabled: bool, radius_tiles: int) -> void:
    locality_processing_enabled = enabled
    locality_dynamic_tick_rate_enabled = dynamic_enabled
    locality_activity_radius_tiles = maxi(0, radius_tiles)

func _sync_compute_preferences() -> void:
    if _hydrology_system != null and _hydrology_system.has_method("set_compute_enabled"):
        _hydrology_system.set_compute_enabled(hydrology_gpu_compute_enabled)
    if _weather_system != null and _weather_system.has_method("set_compute_enabled"):
        _weather_system.set_compute_enabled(weather_gpu_compute_enabled)
    if _erosion_system != null and _erosion_system.has_method("set_compute_enabled"):
        _erosion_system.set_compute_enabled(erosion_gpu_compute_enabled)
    if _solar_system != null and _solar_system.has_method("set_compute_enabled"):
        _solar_system.set_compute_enabled(solar_gpu_compute_enabled)

func _generation_cap(task: String, fallback: int) -> int:
    return SimulationRuntimeFacadeScript.generation_cap(self, task, fallback)

func enqueue_native_voxel_edit_ops(tick: int, voxel_ops: Array, strict: bool = false) -> Dictionary:
    return SimulationRuntimeFacadeScript.enqueue_native_voxel_edit_ops(self, tick, voxel_ops, strict)

func execute_native_voxel_stage(tick: int, stage_name: StringName, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
    return SimulationRuntimeFacadeScript.execute_native_voxel_stage(self, tick, stage_name, payload, strict)

func stamp_default_voxel_target_wall(tick: int, camera_transform: Transform3D, strict: bool = false) -> Dictionary:
    return SimulationRuntimeFacadeScript.stamp_default_voxel_target_wall(self, tick, camera_transform, strict)

func _enqueue_thought_npcs(npc_ids: Array) -> void:
    SimulationRuntimeFacadeScript.enqueue_thought_npcs(self, npc_ids)

func _enqueue_dream_npcs(npc_ids: Array) -> void:
    SimulationRuntimeFacadeScript.enqueue_dream_npcs(self, npc_ids)

func _enqueue_dialogue_pairs(npc_ids: Array) -> void:
    SimulationRuntimeFacadeScript.enqueue_dialogue_pairs(self, npc_ids)

func _drain_thought_queue(tick: int, limit: int) -> bool:
    return SimulationRuntimeFacadeScript.drain_thought_queue(self, tick, limit)

func _drain_dream_queue(tick: int, limit: int) -> bool:
    return SimulationRuntimeFacadeScript.drain_dream_queue(self, tick, limit)

func _drain_dialogue_queue(tick: int, limit: int) -> bool:
    return SimulationRuntimeFacadeScript.drain_dialogue_queue(self, tick, limit)

func _apply_need_decay(npc_id: String, fixed_delta: float) -> void:
    SimulationRuntimeFacadeScript.apply_need_decay(self, npc_id, fixed_delta)

func _generate_narrator_direction(tick: int) -> bool:
    return SimulationRuntimeFacadeScript.generate_narrator_direction(self, tick)

func _run_thought_cycle(npc_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_thought_cycle(self, npc_id, tick)

func _run_dialogue_cycle(npc_ids: Array, tick: int) -> bool:
    return SimulationRuntimeFacadeScript.run_dialogue_cycle(self, npc_ids, tick)

func _run_dialogue_pair(source_id: String, target_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_dialogue_pair(self, source_id, target_id, tick)

func _run_dream_cycle(npc_id: String, tick: int) -> bool:
    return SimulationControllerRuntimeHelpersScript.run_dream_cycle(self, npc_id, tick)

func _run_resource_pipeline(tick: int, npc_ids: Array) -> void:
    SimulationControllerRuntimeHelpersScript.run_resource_pipeline(self, tick, npc_ids)

func _run_structure_lifecycle(tick: int) -> void:
    SimulationRuntimeFacadeScript.run_structure_lifecycle(self, tick)

func _assert_resource_invariants(tick: int, npc_ids: Array) -> void:
    SimulationRuntimeFacadeScript.assert_resource_invariants(self, tick, npc_ids)

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
    SimulationRuntimeFacadeScript.log_resource_event(self, tick, event_type, scope, owner_id, payload)

func _persist_llm_trace_event(tick: int, task: String, actor_ids: Array, trace_variant) -> void:
    SimulationRuntimeFacadeScript.persist_llm_trace_event(self, tick, task, actor_ids, trace_variant)

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
