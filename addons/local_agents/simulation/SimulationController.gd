extends Node
class_name LocalAgentsSimulationController

signal narrator_direction_generated(tick, direction)
signal villager_dream_recorded(npc_id, tick, memory_id, dream_text, effect)
signal villager_thought_recorded(npc_id, tick, memory_id, thought_text)
signal villager_dialogue_recorded(source_npc_id, target_npc_id, tick, event_id, dialogue_text)
signal simulation_dependency_error(tick, phase, error_code)

const DeterministicRngScript = preload("res://addons/local_agents/simulation/DeterministicRNG.gd")
const NarratorScript = preload("res://addons/local_agents/simulation/NarratorDirector.gd")
const DreamScript = preload("res://addons/local_agents/simulation/VillagerDreamService.gd")
const MindScript = preload("res://addons/local_agents/simulation/VillagerMindService.gd")
const StoreScript = preload("res://addons/local_agents/simulation/SimulationStore.gd")
const BackstoryServiceScript = preload("res://addons/local_agents/graph/BackstoryGraphService.gd")
const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const SettlementSeederScript = preload("res://addons/local_agents/simulation/SettlementSeeder.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const SpatialFlowNetworkSystemScript = preload("res://addons/local_agents/simulation/SpatialFlowNetworkSystem.gd")
const StructureLifecycleSystemScript = preload("res://addons/local_agents/simulation/StructureLifecycleSystem.gd")
const BranchAnalysisServiceScript = preload("res://addons/local_agents/simulation/BranchAnalysisService.gd")
const CulturalCycleSystemScript = preload("res://addons/local_agents/simulation/CulturalCycleSystem.gd")
const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const FlowFormationConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowFormationConfigResource.gd")
const FlowRuntimeConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowRuntimeConfigResource.gd")
const StructureLifecycleConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd")

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
var _worldgen_config
var _environment_snapshot: Dictionary = {}
var _water_network_snapshot: Dictionary = {}
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
var _last_tick_processed: int = 0
var _initialized: bool = false

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

func _ready() -> void:
    _ensure_initialized()

func _ensure_initialized() -> void:
    if _initialized:
        return
    if _rng == null:
        _rng = DeterministicRngScript.new()
    if _narrator == null:
        _narrator = NarratorScript.new()
    if _dreams == null:
        _dreams = DreamScript.new()
    if _mind == null:
        _mind = MindScript.new()
    if _store == null:
        _store = StoreScript.new()
    if _branch_analysis == null:
        _branch_analysis = BranchAnalysisServiceScript.new()
    if _culture_cycle == null:
        _culture_cycle = CulturalCycleSystemScript.new()

    if _community_ledger_system == null:
        _community_ledger_system = CommunityLedgerScript.new()
    if _household_ledger_system == null:
        _household_ledger_system = HouseholdLedgerScript.new()
    if _individual_ledger_system == null:
        _individual_ledger_system = IndividualLedgerScript.new()
    if _economy_system == null:
        _economy_system = EconomyScript.new()

    if _market_config == null:
        _market_config = MarketConfigResourceScript.new()
    if _transfer_rules == null:
        _transfer_rules = TransferRuleResourceScript.new()
    _economy_system.set_market_config(_market_config)
    _economy_system.set_transfer_rules(_transfer_rules)

    if _backstory_service == null:
        _backstory_service = BackstoryServiceScript.new()
        add_child(_backstory_service)
    if _world_generator == null:
        _world_generator = WorldGeneratorScript.new()
    if _hydrology_system == null:
        _hydrology_system = HydrologySystemScript.new()
    if _settlement_seeder == null:
        _settlement_seeder = SettlementSeederScript.new()
    if _worldgen_config == null:
        _worldgen_config = WorldGenConfigResourceScript.new()
    if _flow_network_system == null:
        _flow_network_system = SpatialFlowNetworkSystemScript.new()
    if _structure_lifecycle_system == null:
        _structure_lifecycle_system = StructureLifecycleSystemScript.new()
    if _flow_traversal_profile == null:
        _flow_traversal_profile = FlowTraversalProfileResourceScript.new()
    if _flow_formation_config == null:
        _flow_formation_config = FlowFormationConfigResourceScript.new()
    if _flow_runtime_config == null:
        _flow_runtime_config = FlowRuntimeConfigResourceScript.new()
    if _structure_lifecycle_config == null:
        _structure_lifecycle_config = StructureLifecycleConfigResourceScript.new()
    if _flow_network_system != null:
        _flow_network_system.set_flow_profile(_flow_traversal_profile)
        _flow_network_system.set_flow_formation_config(_flow_formation_config)
        _flow_network_system.set_flow_runtime_config(_flow_runtime_config)
    if _structure_lifecycle_system != null:
        _structure_lifecycle_system.set_config(_structure_lifecycle_config)

    if _community_ledger == null:
        _community_ledger = _community_ledger_system.initial_community_ledger()
    if _narrator_directive_resource == null:
        _narrator_directive_resource = NarratorDirectiveResourceScript.new()
    _initialized = true

func configure(seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
    _ensure_initialized()
    _reset_store_for_instance()
    _rng.set_base_seed_from_text(seed_text)
    active_branch_id = "main"
    _branch_lineage = []
    _branch_fork_tick = -1
    _last_tick_processed = 0
    self.narrator_enabled = narrator_enabled
    _narrator.enabled = narrator_enabled
    _dreams.llm_enabled = dream_llm_enabled
    _mind.llm_enabled = dream_llm_enabled
    _store.open(_store_path_for_instance())
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
    _ensure_initialized()
    if config_resource != null:
        _worldgen_config = config_resource
    if _worldgen_config == null:
        _worldgen_config = WorldGenConfigResourceScript.new()
    if _world_generator == null:
        _world_generator = WorldGeneratorScript.new()
    if _hydrology_system == null:
        _hydrology_system = HydrologySystemScript.new()
    if _settlement_seeder == null:
        _settlement_seeder = SettlementSeederScript.new()
    if _rng == null:
        return {"ok": false, "error": "rng_unavailable"}

    var world_seed = _rng.derive_seed("environment", world_id, active_branch_id, 0)
    var hydrology_seed = _rng.derive_seed("hydrology", world_id, active_branch_id, 0)
    var settlement_seed = _rng.derive_seed("settlement", world_id, active_branch_id, 0)

    _environment_snapshot = _world_generator.generate(world_seed, _worldgen_config)
    _water_network_snapshot = _hydrology_system.build_network(_environment_snapshot, _worldgen_config)
    _water_network_snapshot["seed"] = hydrology_seed
    if _flow_network_system != null:
        _flow_network_system.configure_environment(_environment_snapshot, _water_network_snapshot)
    _spawn_artifact = _settlement_seeder.select_site(_environment_snapshot, _water_network_snapshot, _worldgen_config)
    _spawn_artifact["seed"] = settlement_seed
    var chosen = _spawn_artifact.get("chosen", {})
    _community_anchor_position = Vector3(float(chosen.get("x", 0.0)), 0.0, float(chosen.get("y", 0.0)))
    _seed_sacred_site()
    if _structure_lifecycle_system != null:
        _structure_lifecycle_system.ensure_core_anchors(_community_anchor_position)

    return {
        "ok": true,
        "environment": _environment_snapshot.duplicate(true),
        "hydrology": _water_network_snapshot.duplicate(true),
        "spawn": _spawn_artifact.duplicate(true),
    }

func get_environment_snapshot() -> Dictionary:
    return _environment_snapshot.duplicate(true)

func get_water_network_snapshot() -> Dictionary:
    return _water_network_snapshot.duplicate(true)

func get_spawn_artifact() -> Dictionary:
    return _spawn_artifact.duplicate(true)

func get_backstory_service():
    return _backstory_service

func get_store():
    return _store

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

func set_living_entity_profiles(profiles: Array) -> void:
    _ensure_initialized()
    _external_living_entity_profiles.clear()
    for row_variant in profiles:
        if not (row_variant is Dictionary):
            continue
        _external_living_entity_profiles.append((row_variant as Dictionary).duplicate(true))

func register_villager(npc_id: String, display_name: String, initial_state: Dictionary = {}) -> Dictionary:
    _ensure_initialized()
    if npc_id.strip_edges() == "":
        return {"ok": false, "error": "invalid_npc_id"}

    var state_payload: Dictionary = {
        "npc_id": npc_id,
        "display_name": display_name,
        "mood": "neutral",
        "morale": 0.5,
        "fear": 0.0,
        "energy": 1.0,
        "hunger": 0.0,
        "profession": "general",
    }
    for key in initial_state.keys():
        state_payload[key] = initial_state[key]

    var household_id = String(initial_state.get("household_id", "household_%s" % npc_id))
    state_payload["household_id"] = household_id
    var villager_state = VillagerStateResourceScript.new()
    villager_state.from_dict(state_payload)
    _villagers[npc_id] = villager_state
    _villager_positions[npc_id] = _spawn_offset_position(npc_id, 2.8)

    if not _household_members.has(household_id):
        var membership = HouseholdMembershipResourceScript.new()
        membership.household_id = household_id
        _household_members[household_id] = membership
        _household_positions[household_id] = _spawn_offset_position(household_id, 4.0)
    var members_resource = _household_members[household_id]
    members_resource.add_member(npc_id)

    if not _household_ledgers.has(household_id):
        _household_ledgers[household_id] = _household_ledger_system.initial_household_ledger(household_id)
    if not _individual_ledgers.has(npc_id):
        _individual_ledgers[npc_id] = _individual_ledger_system.initial_individual_ledger(npc_id)

    var carry_profile = CarryProfileResourceScript.new()
    carry_profile.strength = clampf(float(initial_state.get("strength", 0.5)), 0.0, 1.5)
    carry_profile.tool_efficiency = maxf(0.0, float(initial_state.get("tool_efficiency", 0.0)))
    _carry_profiles[npc_id] = carry_profile

    var profile_variant = initial_state.get("profession_profile", null)
    if profile_variant != null and profile_variant is Resource:
        _economy_system.set_profession_profile(profile_variant)

    var upsert = _backstory_service.upsert_npc(npc_id, display_name, {}, {"source": "simulation"})
    return {"ok": bool(upsert.get("ok", false)), "npc_id": npc_id}

func process_tick(tick: int, fixed_delta: float) -> Dictionary:
    _ensure_initialized()
    _resource_event_sequence = 0
    _last_partial_delivery_count = 0
    _household_growth_metrics = {}
    _structure_lifecycle_events = {"expanded": [], "abandoned": []}
    _oral_tick_events = []
    _ritual_tick_events = []
    _culture_driver_events = []
    if _flow_network_system != null:
        _flow_network_system.step_decay()
    var npc_ids = _sorted_npc_ids()
    for npc_id in npc_ids:
        _apply_need_decay(npc_id, fixed_delta)

    _run_resource_pipeline(tick, npc_ids)
    _run_structure_lifecycle(tick)
    _run_culture_cycle(tick)

    if narrator_enabled and tick > 0 and tick % 24 == 0:
        if not _generate_narrator_direction(tick):
            return _dependency_error_result(tick, "narrator")

    if thoughts_enabled and _is_thought_tick(tick):
        for npc_id in npc_ids:
            if not _run_thought_cycle(npc_id, tick):
                return _dependency_error_result(tick, "thought")

    if dialogue_enabled and _is_dialogue_tick(tick):
        if not _run_dialogue_cycle(npc_ids, tick):
            return _dependency_error_result(tick, "dialogue")

    if dreams_enabled and _is_dream_tick(tick):
        for npc_id in npc_ids:
            if not _run_dream_cycle(npc_id, tick):
                return _dependency_error_result(tick, "dream")

    var snapshot = current_snapshot(tick)
    var event_id = _store.begin_event(world_id, active_branch_id, tick, "tick", snapshot)
    if tick % 48 == 0:
        _store.create_checkpoint(
            world_id,
            active_branch_id,
            tick,
            str(hash(JSON.stringify(snapshot, "", false, true))),
            _branch_lineage.duplicate(true),
            _branch_fork_tick
        )
    _last_tick_processed = tick
    return {
        "ok": true,
        "tick": tick,
        "event_id": event_id,
        "state": snapshot,
    }

func current_snapshot(tick: int) -> Dictionary:
    _ensure_initialized()
    var snapshot_resource = SnapshotResourceScript.new()
    snapshot_resource.world_id = world_id
    snapshot_resource.branch_id = active_branch_id
    snapshot_resource.tick = tick
    snapshot_resource.community = BundleResourceScript.new()
    snapshot_resource.community.from_dict(_community_ledger.to_dict())
    snapshot_resource.households = _serialize_household_ledgers()
    snapshot_resource.individuals = _serialize_individual_ledgers()
    snapshot_resource.market_prices = _last_market_prices.duplicate(true)

    return {
        "world_id": world_id,
        "branch_id": active_branch_id,
        "tick": tick,
        "branch_lineage": _branch_lineage.duplicate(true),
        "branch_fork_tick": _branch_fork_tick,
        "worldgen_config": _worldgen_config.to_dict() if _worldgen_config != null else {},
        "environment_snapshot": _environment_snapshot.duplicate(true),
        "water_network_snapshot": _water_network_snapshot.duplicate(true),
        "spawn_artifact": _spawn_artifact.duplicate(true),
        "flow_network": _flow_network_system.export_network() if _flow_network_system != null else {},
        "flow_formation_config": _flow_formation_config.to_dict() if _flow_formation_config != null else {},
        "flow_runtime_config": _flow_runtime_config.to_dict() if _flow_runtime_config != null else {},
        "flow_traversal_profile": _flow_traversal_profile.to_dict() if _flow_traversal_profile != null else {},
        "structure_lifecycle_config": _structure_lifecycle_config.to_dict() if _structure_lifecycle_config != null else {},
        "anchors": _structure_lifecycle_system.export_anchors() if _structure_lifecycle_system != null else [],
        "structures": _structure_lifecycle_system.export_structures() if _structure_lifecycle_system != null else {},
        "structure_lifecycle_runtime": _structure_lifecycle_system.export_runtime_state() if _structure_lifecycle_system != null else {},
        "structure_lifecycle_events": _structure_lifecycle_events.duplicate(true),
        "sacred_site_id": _sacred_site_id,
        "cultural_cycle_state": _culture_cycle.export_state() if _culture_cycle != null else {},
        "culture_driver_events": _culture_driver_events.duplicate(true),
        "oral_transfer_events": _oral_tick_events.duplicate(true),
        "ritual_events": _ritual_tick_events.duplicate(true),
        "partial_delivery_count": _last_partial_delivery_count,
        "villagers": _serialize_villagers(),
        "community_ledger": _community_ledger.to_dict(),
        "household_ledgers": _serialize_household_ledgers(),
        "individual_ledgers": _serialize_individual_ledgers(),
        "carry_profiles": _serialize_carry_profiles(),
        "market_prices": _last_market_prices.duplicate(true),
        "economy_snapshot": snapshot_resource.to_dict(),
        "directive": _directive_text(),
    }

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
    emit_signal("narrator_direction_generated", tick, result.get("text", ""))
    return true

func _run_thought_cycle(npc_id: String, tick: int) -> bool:
    var villager_state = _villagers.get(npc_id, null)
    if villager_state == null:
        return true
    var state: Dictionary = villager_state.to_dict()
    var world_day = int(tick / 24)
    state["belief_context"] = _belief_context_for_npc(npc_id, world_day, 6)
    var recall = _mind.select_recall_context(_backstory_service, npc_id, world_day, 5, 2)
    var seed = _rng.derive_seed("thought", npc_id, active_branch_id, tick)
    var thought = _mind.generate_internal_thought(npc_id, state, recall, seed, _directive_text())
    if not bool(thought.get("ok", false)):
        return _emit_dependency_error(tick, "thought", String(thought.get("error", "thought_failed")))
    var thought_text = String(thought.get("text", "")).strip_edges()
    if thought_text == "":
        return true

    var refs = _memory_refs_from_recall(recall)
    var thought_memory_id = "thought:%s:%s:%d" % [world_id, npc_id, tick]
    var memory = _backstory_service.add_thought_memory(
        thought_memory_id,
        npc_id,
        thought_text,
        world_day,
        refs,
        0.42,
        0.72,
        {
            "source": "llm_internal_thought",
            "is_internal_thought": true,
            "is_factual": false,
        }
    )
    if not bool(memory.get("ok", false)):
        return _emit_dependency_error(tick, "thought_memory", "backstory_write_failed")
    emit_signal("villager_thought_recorded", npc_id, tick, thought_memory_id, thought_text)
    return true

func _run_dialogue_cycle(npc_ids: Array, tick: int) -> bool:
    if npc_ids.size() < 2:
        return true
    for index in range(0, npc_ids.size() - 1, 2):
        var source_id = String(npc_ids[index])
        var target_id = String(npc_ids[index + 1])
        var source_state_resource = _villagers.get(source_id, null)
        var target_state_resource = _villagers.get(target_id, null)
        if source_state_resource == null or target_state_resource == null:
            continue
        var source_state: Dictionary = source_state_resource.to_dict()
        var target_state: Dictionary = target_state_resource.to_dict()
        var world_day = int(tick / 24)
        source_state["belief_context"] = _belief_context_for_npc(source_id, world_day, 4)
        target_state["belief_context"] = _belief_context_for_npc(target_id, world_day, 4)
        var source_recall = _mind.select_recall_context(_backstory_service, source_id, world_day, 4, 1)
        var target_recall = _mind.select_recall_context(_backstory_service, target_id, world_day, 4, 1)
        var seed = _rng.derive_seed("dialogue", source_id + "->" + target_id, active_branch_id, tick)
        var result = _mind.generate_dialogue_exchange(source_id, target_id, source_state, target_state, source_recall, target_recall, seed, _directive_text())
        if not bool(result.get("ok", false)):
            return _emit_dependency_error(tick, "dialogue", String(result.get("error", "dialogue_failed")))
        var dialogue_text = String(result.get("text", "")).strip_edges()
        if dialogue_text == "":
            continue

        var event_id = "dialogue:%s:%s:%s:%d" % [world_id, source_id, target_id, tick]
        _backstory_service.record_event(
            event_id,
            "villager_dialogue",
            dialogue_text,
            world_day,
            "",
            [source_id, target_id],
            {
                "source": "llm_dialogue",
                "is_factual": true,
                "source_recall": _memory_refs_from_recall(source_recall),
                "target_recall": _memory_refs_from_recall(target_recall),
            }
        )
        emit_signal("villager_dialogue_recorded", source_id, target_id, tick, event_id, dialogue_text)
    return true

func _run_dream_cycle(npc_id: String, tick: int) -> bool:
    var villager_state = _villagers.get(npc_id, null)
    if villager_state == null:
        return true
    var state: Dictionary = villager_state.to_dict()
    var seed = _rng.derive_seed("dream", npc_id, active_branch_id, tick)
    var dream = _dreams.generate_dream_text(npc_id, state, seed, _directive_text())
    if not bool(dream.get("ok", false)):
        return _emit_dependency_error(tick, "dream", String(dream.get("error", "dream_failed")))
    var dream_text = String(dream.get("text", "")).strip_edges()
    if dream_text == "":
        return true
    var influence = _dreams.get_dream_influence(npc_id)
    var metadata = _dreams.dream_memory_metadata(influence, seed)
    var world_day = int(tick / 24)
    var memory_id = "dream:%s:%s:%d" % [world_id, npc_id, tick]
    var memory = _backstory_service.add_dream_memory(memory_id, npc_id, dream_text, world_day, influence, 0.55, 0.65, metadata)
    if not bool(memory.get("ok", false)):
        return _emit_dependency_error(tick, "dream_memory", "backstory_write_failed")
    var effect = _dreams.compute_dream_effect(dream_text)
    var next_state: Dictionary = _dreams.apply_dream_effect(state, effect)
    villager_state.from_dict(next_state)
    emit_signal("villager_dream_recorded", npc_id, tick, memory_id, dream_text, effect)
    return true

func _run_resource_pipeline(tick: int, npc_ids: Array) -> void:
    _last_market_prices = _economy_system.compute_market_prices(_community_ledger)
    _log_resource_event(tick, "sim_transfer_event", "community", "community_main", {
        "kind": "market_price_update",
        "prices": _last_market_prices.duplicate(true),
    })

    for npc_id in npc_ids:
        var villager_state_resource = _villagers.get(npc_id, null)
        if villager_state_resource == null:
            continue
        var villager_state: Dictionary = villager_state_resource.to_dict()
        var econ_state = _individual_ledgers.get(npc_id, _individual_ledger_system.initial_individual_ledger(npc_id))
        var production: Dictionary = _economy_system.villager_production(villager_state, econ_state, tick)
        _community_ledger = _community_ledger_system.deposit(_community_ledger, {
            "food": float(production.get("food", 0.0)),
            "water": float(production.get("water", 0.0)),
            "wood": float(production.get("wood", 0.0)),
            "stone": float(production.get("stone", 0.0)),
            "tools": float(production.get("tools", 0.0)),
            "currency": float(production.get("currency", 0.0)),
        })
        econ_state.wage_due += float(production.get("wage_due", 0.0))
        _individual_ledgers[npc_id] = _individual_ledger_system.ensure_bounds(econ_state)
        _log_resource_event(tick, "sim_production_event", "individual", npc_id, {
            "production": production.duplicate(true),
        })

    _community_ledger = _community_ledger_system.produce(_community_ledger, _villagers.size(), tick)
    _log_resource_event(tick, "sim_production_event", "community", "community_main", {
        "delta": {
            "food": 0.18 * _villagers.size() * (1.0 if (tick % 24) < 18 else 0.65),
            "water": 0.14 * _villagers.size(),
            "wood": 0.05 * _villagers.size(),
            "stone": 0.03 * _villagers.size(),
            "currency": 0.02 * _villagers.size(),
        },
    })

    _community_ledger = _community_ledger_system.consume_upkeep(_community_ledger, 1.0)
    _log_resource_event(tick, "sim_transfer_event", "community", "community_main", {
        "kind": "upkeep",
        "delta": {"tools": -0.03, "wood": -0.04, "stone": -0.02},
    })

    var household_ids = _household_members.keys()
    household_ids.sort()
    for household_id_variant in household_ids:
        var household_id = String(household_id_variant)
        var members_resource = _household_members.get(household_id, null)
        var members: Array = []
        if members_resource != null:
            members = members_resource.member_ids
        var household_ledger = _household_ledgers.get(household_id, _household_ledger_system.initial_household_ledger(household_id))
        var transport_capacity = _economy_system.total_transport_capacity(members, _carry_profiles)

        var ration_request: Dictionary = _household_ledger_system.ration_request_for_members(members.size(), _transfer_rules)
        var withdrawal: Dictionary = _community_ledger_system.withdraw(_community_ledger, ration_request)
        _community_ledger = withdrawal.get("ledger", _community_ledger)
        var ration_granted: Dictionary = withdrawal.get("granted", {})

        var ration_transport: Dictionary = _economy_system.allocate_carrier_assignments(ration_granted, members, _carry_profiles)
        var route_adjusted = _apply_route_transport(
            ration_transport.get("assignments", {}),
            _community_anchor_position,
            _household_position(household_id),
            tick
        )
        var ration_moved: Dictionary = route_adjusted.get("moved_payload", {})
        var ration_unmoved: Dictionary = _merge_payloads(
            ration_transport.get("remaining_payload", {}),
            route_adjusted.get("unmoved_payload", {})
        )
        if not ration_unmoved.is_empty():
            _community_ledger = _community_ledger_system.deposit(_community_ledger, ration_unmoved)
        _apply_carry_assignments(members, route_adjusted.get("assignments", {}))

        _log_resource_event(tick, "sim_transfer_event", "household", household_id, {
            "kind": "community_ration",
            "requested": ration_request.duplicate(true),
            "granted": ration_granted.duplicate(true),
            "moved": ration_moved.duplicate(true),
            "unmoved": ration_unmoved.duplicate(true),
            "transport_capacity_weight": transport_capacity,
            "route_profiles": route_adjusted.get("route_profiles", {}),
        })
        _household_growth_metrics[household_id] = {
            "throughput": _sum_payload(ration_moved),
            "path_strength": _mean_route_path_strength(route_adjusted.get("route_profiles", {})),
        }

        household_ledger = _household_ledger_system.apply_ration(household_ledger, ration_moved)

        var trade_step: Dictionary = _economy_system.household_trade_step(household_ledger, _community_ledger, _last_market_prices, transport_capacity)
        household_ledger = trade_step.get("household", household_ledger)
        _community_ledger = trade_step.get("community", _community_ledger)
        var trades: Array = trade_step.get("trades", [])
        if not trades.is_empty():
            var trade_payload: Dictionary = trade_step.get("transport_payload", {})
            var trade_transport: Dictionary = _economy_system.allocate_carrier_assignments(trade_payload, members, _carry_profiles)
            _apply_carry_assignments(members, trade_transport.get("assignments", {}))
            _log_resource_event(tick, "sim_transfer_event", "household", household_id, {
                "kind": "market_trade",
                "trades": trades,
                "spent": float(trade_step.get("spent", 0.0)),
                "earned": float(trade_step.get("earned", 0.0)),
                "transport_payload": trade_payload.duplicate(true),
                "transport_weight_used": float(trade_step.get("transport_weight_used", 0.0)),
                "transport_capacity_weight": float(trade_step.get("transport_capacity_weight", 0.0)),
            })

        var household_before = household_ledger.to_dict()
        household_ledger = _household_ledger_system.consume_for_members(household_ledger, members.size(), _transfer_rules)
        _log_resource_event(tick, "sim_transfer_event", "household", household_id, {
            "kind": "household_consumption",
            "member_count": members.size(),
            "before": {
                "food": float(household_before.get("food", 0.0)),
                "water": float(household_before.get("water", 0.0)),
            },
            "after": {
                "food": float(household_ledger.food),
                "water": float(household_ledger.water),
            },
        })

        for npc_id_variant in members:
            var npc_id = String(npc_id_variant)
            var econ_state = _individual_ledgers.get(npc_id, _individual_ledger_system.initial_individual_ledger(npc_id))
            var inv_before = econ_state.inventory.to_dict()
            econ_state = _individual_ledger_system.distribute_from_household(econ_state, household_ledger, 0.25)
            econ_state = _individual_ledger_system.consume_personal(econ_state, _transfer_rules)
            var wage_due = float(econ_state.wage_due)
            if wage_due > 0.0:
                var wage_result: Dictionary = _community_ledger_system.withdraw(_community_ledger, {"currency": wage_due})
                _community_ledger = wage_result.get("ledger", _community_ledger)
                var wage_granted = float(wage_result.get("granted", {}).get("currency", 0.0))
                econ_state = _individual_ledger_system.pay_wage(econ_state, wage_granted)
                _log_resource_event(tick, "sim_transfer_event", "individual", npc_id, {
                    "kind": "wage_payment",
                    "wage_due": wage_due,
                    "wage_paid": wage_granted,
                })
            econ_state = _individual_ledger_system.ensure_bounds(econ_state)
            _individual_ledgers[npc_id] = econ_state

            _log_resource_event(tick, "sim_transfer_event", "individual", npc_id, {
                "kind": "household_distribution_and_personal_consumption",
                "before": {
                    "food": float(inv_before.get("food", 0.0)),
                    "water": float(inv_before.get("water", 0.0)),
                    "currency": float(inv_before.get("currency", 0.0)),
                    "energy": float(econ_state.energy),
                },
                "after": {
                    "food": float(econ_state.inventory.food),
                    "water": float(econ_state.inventory.water),
                    "currency": float(econ_state.inventory.currency),
                    "energy": float(econ_state.energy),
                },
            })

        var taxed: Dictionary = _household_ledger_system.collect_tax(household_ledger, _transfer_rules)
        household_ledger = taxed.get("ledger", household_ledger)
        var tax_amount = float(taxed.get("tax", 0.0))
        _community_ledger = _community_ledger_system.deposit(_community_ledger, {"currency": tax_amount})
        _log_resource_event(tick, "sim_transfer_event", "household", household_id, {
            "kind": "tax_paid",
            "currency": tax_amount,
        })

        household_ledger = _household_ledger_system.enforce_non_negative(household_ledger)
        _household_ledgers[household_id] = household_ledger

    var waste_step: Dictionary = _economy_system.process_waste(_community_ledger, _household_ledgers, _individual_ledgers)
    _community_ledger = waste_step.get("community", _community_ledger)
    _household_ledgers = waste_step.get("households", _household_ledgers)
    _individual_ledgers = waste_step.get("individuals", _individual_ledgers)
    _log_resource_event(tick, "sim_transfer_event", "community", "community_main", {
        "kind": "waste_processing",
        "incoming_waste": float(waste_step.get("incoming_waste", 0.0)),
        "processed_waste": float(waste_step.get("processed_waste", 0.0)),
        "recycled_wood": float(waste_step.get("recycled_wood", 0.0)),
        "recycled_currency": float(waste_step.get("recycled_currency", 0.0)),
    })

    _community_ledger = _community_ledger_system.clamp_to_capacity(_community_ledger)
    _assert_resource_invariants(tick, npc_ids)

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
    var refs: Array = []
    for key in ["waking", "dreams"]:
        var rows: Array = recall.get(key, [])
        for row_variant in rows:
            if row_variant is Dictionary:
                var row: Dictionary = row_variant
                refs.append(String(row.get("memory_id", "")))
    return refs

func _sorted_npc_ids() -> Array:
    var ids = _villagers.keys()
    ids.sort()
    var out: Array = []
    for item in ids:
        out.append(String(item))
    return out

func _serialize_villagers() -> Dictionary:
    var out = {}
    var ids = _villagers.keys()
    ids.sort()
    for npc_id in ids:
        var villager_state = _villagers.get(npc_id, null)
        if villager_state == null:
            continue
        out[String(npc_id)] = villager_state.to_dict()
    return out

func _serialize_household_ledgers() -> Dictionary:
    var out = {}
    var ids = _household_ledgers.keys()
    ids.sort()
    for household_id in ids:
        var ledger = _household_ledgers[household_id]
        out[String(household_id)] = ledger.to_dict()
    return out

func _serialize_individual_ledgers() -> Dictionary:
    var out = {}
    var ids = _individual_ledgers.keys()
    ids.sort()
    for npc_id in ids:
        var state = _individual_ledgers[npc_id]
        out[String(npc_id)] = state.to_dict()
    return out

func _serialize_carry_profiles() -> Dictionary:
    var out = {}
    var ids = _carry_profiles.keys()
    ids.sort()
    for npc_id in ids:
        var profile = _carry_profiles[npc_id]
        out[String(npc_id)] = profile.to_dict()
    return out

func _belief_context_for_npc(npc_id: String, world_day: int, limit: int) -> Dictionary:
    var out := {
        "beliefs": [],
        "conflicts": [],
    }
    if _backstory_service == null:
        return out
    if _backstory_service.has_method("get_beliefs_for_npc"):
        var beliefs_result: Dictionary = _backstory_service.call("get_beliefs_for_npc", npc_id, world_day, limit)
        if bool(beliefs_result.get("ok", false)):
            out["beliefs"] = beliefs_result.get("beliefs", [])
    if _backstory_service.has_method("get_belief_truth_conflicts"):
        var conflicts_result: Dictionary = _backstory_service.call("get_belief_truth_conflicts", npc_id, world_day, limit)
        if bool(conflicts_result.get("ok", false)):
            out["conflicts"] = conflicts_result.get("conflicts", [])
    return out

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

func _apply_carry_assignments(members: Array, assignments: Dictionary) -> void:
    for npc_id_variant in members:
        var npc_id = String(npc_id_variant)
        var econ_state = _individual_ledgers.get(npc_id, _individual_ledger_system.initial_individual_ledger(npc_id))
        var assignment: Dictionary = assignments.get(npc_id, {})
        if assignment.is_empty():
            econ_state = _individual_ledger_system.apply_carry_assignment(econ_state, {}, 0.0)
            _individual_ledgers[npc_id] = _individual_ledger_system.ensure_bounds(econ_state)
            continue
        var carried_weight = _economy_system.assignment_weight(assignment)
        econ_state = _individual_ledger_system.apply_carry_assignment(econ_state, assignment, carried_weight)
        econ_state = _individual_ledger_system.complete_carry_delivery(econ_state)
        _individual_ledgers[npc_id] = _individual_ledger_system.ensure_bounds(econ_state)

func _apply_route_transport(assignments: Dictionary, start: Vector3, target: Vector3, tick: int) -> Dictionary:
    var delivered_assignments: Dictionary = {}
    var moved_payload: Dictionary = {}
    var unmoved_payload: Dictionary = {}
    var profiles: Dictionary = {}
    var npc_ids = assignments.keys()
    npc_ids.sort()
    for npc_id_variant in npc_ids:
        var npc_id = String(npc_id_variant)
        var assignment: Dictionary = assignments.get(npc_id, {})
        var profile: Dictionary = {}
        if _flow_network_system != null:
            profile = _flow_network_system.evaluate_route(start, target, {
                "tick": tick,
                "rain_intensity": 0.0,
            })
        var efficiency = clampf(float(profile.get("delivery_efficiency", 1.0)), 0.2, 1.0)
        var jitter = _rng.randomf("route_delivery", npc_id, active_branch_id, tick)
        efficiency = clampf(efficiency - (0.12 * jitter), 0.15, 1.0)
        var delivered_assignment: Dictionary = {}
        for resource in assignment.keys():
            var amount = maxf(0.0, float(assignment.get(resource, 0.0)))
            if amount <= 0.0:
                continue
            var delivered = amount * efficiency
            var shortfall = amount - delivered
            if delivered > 0.0:
                delivered_assignment[resource] = delivered
                moved_payload[resource] = float(moved_payload.get(resource, 0.0)) + delivered
            if shortfall > 0.0:
                unmoved_payload[resource] = float(unmoved_payload.get(resource, 0.0)) + shortfall
                _last_partial_delivery_count += 1
        delivered_assignments[npc_id] = delivered_assignment
        if _flow_network_system != null:
            var carry_weight = _economy_system.assignment_weight(delivered_assignment)
            _flow_network_system.record_flow(start, target, carry_weight)
            profile["delivery_efficiency_final"] = efficiency
            profiles[npc_id] = profile
    return {
        "assignments": delivered_assignments,
        "moved_payload": moved_payload,
        "unmoved_payload": unmoved_payload,
        "route_profiles": profiles,
    }

func _merge_payloads(primary: Dictionary, secondary: Dictionary) -> Dictionary:
    var out = primary.duplicate(true)
    for key in secondary.keys():
        var resource = String(key)
        out[resource] = float(out.get(resource, 0.0)) + float(secondary.get(resource, 0.0))
    return out

func _spawn_offset_position(entity_id: String, radius: float) -> Vector3:
    var seed = _rng.derive_seed("entity_position", entity_id, active_branch_id, 0)
    var angle = float(abs(seed % 3600)) * 0.001745329
    return _community_anchor_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)

func _household_position(household_id: String) -> Vector3:
    if _household_positions.has(household_id):
        return _household_positions[household_id]
    var generated = _spawn_offset_position(household_id, 4.0)
    _household_positions[household_id] = generated
    return generated

func _sum_payload(payload: Dictionary) -> float:
    var total = 0.0
    var keys = payload.keys()
    keys.sort_custom(func(a, b): return String(a) < String(b))
    for key in keys:
        total += maxf(0.0, float(payload.get(String(key), 0.0)))
    return total

func _mean_route_path_strength(route_profiles: Dictionary) -> float:
    var keys = route_profiles.keys()
    if keys.is_empty():
        return 0.0
    keys.sort_custom(func(a, b): return String(a) < String(b))
    var total = 0.0
    for key in keys:
        var row: Dictionary = route_profiles.get(String(key), {})
        total += clampf(float(row.get("avg_path_strength", 0.0)), 0.0, 1.0)
    return total / float(keys.size())

func _household_member_counts() -> Dictionary:
    var counts: Dictionary = {}
    var household_ids = _household_members.keys()
    household_ids.sort()
    for household_id_variant in household_ids:
        var household_id = String(household_id_variant)
        var members_resource = _household_members.get(household_id, null)
        if members_resource == null:
            counts[household_id] = 0
            continue
        counts[household_id] = int(members_resource.member_ids.size())
    return counts

func _seed_sacred_site() -> void:
    _sacred_site_id = "site:%s:%s:spring" % [world_id, active_branch_id]
    if _backstory_service == null:
        return
    var site_pos = {
        "x": _community_anchor_position.x + 1.0,
        "y": 0.0,
        "z": _community_anchor_position.z - 1.0,
    }
    _backstory_service.upsert_sacred_site(
        _sacred_site_id,
        "spring",
        site_pos,
        4.5,
        ["taboo_water_waste"],
        0,
        {"source": "simulation_seed"}
    )

func _run_culture_cycle(tick: int) -> void:
    if _culture_cycle == null:
        return
    var household_members: Dictionary = {}
    var household_ids = _household_members.keys()
    household_ids.sort()
    for household_id_variant in household_ids:
        var household_id = String(household_id_variant)
        var members_resource = _household_members.get(household_id, null)
        household_members[household_id] = members_resource.member_ids.duplicate() if members_resource != null else []
    var result: Dictionary = _culture_cycle.step(tick, {
        "graph_service": _backstory_service,
        "rng": _rng,
        "world_id": world_id,
        "branch_id": active_branch_id,
        "household_members": household_members,
        "npc_ids": _sorted_npc_ids(),
        "sacred_site_id": _sacred_site_id,
        "deterministic_seed": _rng.derive_seed("culture_driver", world_id, active_branch_id, tick),
        "culture_context": _build_culture_context(tick),
    })
    _culture_driver_events = result.get("drivers", [])
    _oral_tick_events = result.get("oral_events", [])
    _ritual_tick_events = result.get("ritual_events", [])
    for driver_variant in _culture_driver_events:
        if not (driver_variant is Dictionary):
            continue
        var driver = _ensure_culture_event_metadata(driver_variant as Dictionary)
        var scope = String(driver.get("scope", "settlement")).strip_edges()
        if scope == "":
            scope = "settlement"
        var owner_id = String(driver.get("owner_id", "")).strip_edges()
        if owner_id == "":
            owner_id = "settlement_main"
        _log_resource_event(tick, "sim_culture_event", scope, owner_id, {
            "kind": "cultural_driver",
            "event": driver,
        })
    for oral_event_variant in _oral_tick_events:
        if not (oral_event_variant is Dictionary):
            continue
        var oral_event = _ensure_culture_event_metadata(oral_event_variant as Dictionary)
        var household_id = String(oral_event.get("household_id", ""))
        _log_resource_event(tick, "sim_culture_event", "household", household_id, {
            "kind": "oral_transfer",
            "event": oral_event,
        })
    for ritual_event_variant in _ritual_tick_events:
        if not (ritual_event_variant is Dictionary):
            continue
        var ritual_event = _ensure_culture_event_metadata(ritual_event_variant as Dictionary)
        _log_resource_event(tick, "sim_culture_event", "settlement", "settlement_main", {
            "kind": "ritual_event",
            "event": ritual_event,
        })

func _ensure_culture_event_metadata(event: Dictionary) -> Dictionary:
    var out := event.duplicate(true)
    var salience := clampf(float(out.get("salience", 0.0)), 0.0, 1.0)
    var gain_loss := clampf(float(out.get("gain_loss", 0.0)), -1.0, 1.0)
    out["salience"] = salience
    out["gain_loss"] = gain_loss
    var metadata_variant = out.get("metadata", {})
    var metadata: Dictionary = {}
    if metadata_variant is Dictionary:
        metadata = (metadata_variant as Dictionary).duplicate(true)
    metadata["salience"] = salience
    metadata["gain_loss"] = gain_loss
    out["metadata"] = metadata
    return out

func _apply_snapshot(snapshot: Dictionary) -> void:
    world_id = String(snapshot.get("world_id", world_id))
    active_branch_id = String(snapshot.get("branch_id", active_branch_id))
    _branch_lineage = (snapshot.get("branch_lineage", []) as Array).duplicate(true)
    _branch_fork_tick = int(snapshot.get("branch_fork_tick", _branch_fork_tick))
    _environment_snapshot = snapshot.get("environment_snapshot", {}).duplicate(true)
    _water_network_snapshot = snapshot.get("water_network_snapshot", {}).duplicate(true)
    _spawn_artifact = snapshot.get("spawn_artifact", {}).duplicate(true)
    _sacred_site_id = String(snapshot.get("sacred_site_id", _sacred_site_id))
    if _culture_cycle != null:
        _culture_cycle.import_state(snapshot.get("cultural_cycle_state", {}))
    _culture_driver_events = snapshot.get("culture_driver_events", [])

    _community_ledger = _community_ledger_system.initial_community_ledger()
    _apply_community_dict(_community_ledger, snapshot.get("community_ledger", {}))

    _household_ledgers.clear()
    var household_rows: Dictionary = snapshot.get("household_ledgers", {})
    var household_ids = household_rows.keys()
    household_ids.sort_custom(func(a, b): return String(a) < String(b))
    for household_id_variant in household_ids:
        var household_id = String(household_id_variant)
        var ledger = _household_ledger_system.initial_household_ledger(household_id)
        _apply_household_dict(ledger, household_rows.get(household_id, {}))
        _household_ledgers[household_id] = ledger

    _individual_ledgers.clear()
    var individual_rows: Dictionary = snapshot.get("individual_ledgers", {})
    var npc_ids = individual_rows.keys()
    npc_ids.sort_custom(func(a, b): return String(a) < String(b))
    for npc_id_variant in npc_ids:
        var npc_id = String(npc_id_variant)
        var state = VillagerEconomyStateResourceScript.new()
        state.npc_id = npc_id
        state.inventory = VillagerInventoryResourceScript.new()
        _apply_individual_dict(state, individual_rows.get(npc_id, {}))
        _individual_ledgers[npc_id] = _individual_ledger_system.ensure_bounds(state)

    _villagers.clear()
    var villager_rows: Dictionary = snapshot.get("villagers", {})
    var villager_ids = villager_rows.keys()
    villager_ids.sort_custom(func(a, b): return String(a) < String(b))
    for npc_id_variant in villager_ids:
        var npc_id = String(npc_id_variant)
        var villager_state = VillagerStateResourceScript.new()
        villager_state.from_dict(villager_rows.get(npc_id, {}))
        _villagers[npc_id] = villager_state

    _carry_profiles.clear()
    var carry_rows: Dictionary = snapshot.get("carry_profiles", {})
    var carry_ids = carry_rows.keys()
    carry_ids.sort_custom(func(a, b): return String(a) < String(b))
    for npc_id_variant in carry_ids:
        var npc_id = String(npc_id_variant)
        var profile = CarryProfileResourceScript.new()
        _apply_carry_profile_dict(profile, carry_rows.get(npc_id, {}))
        _carry_profiles[npc_id] = profile

    if _flow_network_system != null:
        _flow_network_system.configure_environment(_environment_snapshot, _water_network_snapshot)
        _flow_network_system.import_network(snapshot.get("flow_network", {}))

    if _structure_lifecycle_system != null:
        _structure_lifecycle_system.import_lifecycle_state(
            snapshot.get("structures", {}),
            snapshot.get("anchors", []),
            snapshot.get("structure_lifecycle_runtime", {})
        )

func _build_culture_context(tick: int) -> Dictionary:
    var households: Array = []
    var structure_rows: Dictionary = _structure_lifecycle_system.export_structures() if _structure_lifecycle_system != null else {}
    var household_ids = _household_members.keys()
    household_ids.sort()
    for household_id_variant in household_ids:
        var household_id = String(household_id_variant)
        var members_resource = _household_members.get(household_id, null)
        var members: Array = members_resource.member_ids.duplicate() if members_resource != null else []
        members.sort()
        var member_count = members.size()
        var ledger = _household_ledgers.get(household_id, null)
        var ledger_row: Dictionary = ledger.to_dict() if ledger != null else {}
        var structures: Array = structure_rows.get(household_id, [])
        var active_structures = 0
        for structure_variant in structures:
            if not (structure_variant is Dictionary):
                continue
            var structure = structure_variant as Dictionary
            if String(structure.get("state", "")) == "active":
                active_structures += 1
        var pos = _household_position(household_id)
        var tile = _tile_context_for_position(pos)
        var belonging_index = clampf(
            float(member_count) * 0.32 +
            clampf(float(active_structures) * 0.26, 0.0, 1.0) +
            clampf((maxf(0.0, float(ledger_row.get("food", 0.0))) + maxf(0.0, float(ledger_row.get("water", 0.0)))) * 0.09, 0.0, 1.0),
            0.0,
            3.0
        )
        var bone_signal = clampf(
            maxf(0.0, float(ledger_row.get("tools", 0.0))) * 0.08 + maxf(0.0, float(ledger_row.get("waste", 0.0))) * 0.04,
            0.0,
            1.0
        )
        households.append({
            "household_id": household_id,
            "members": members,
            "member_count": member_count,
            "food": maxf(0.0, float(ledger_row.get("food", 0.0))),
            "water": maxf(0.0, float(ledger_row.get("water", 0.0))),
            "wood": maxf(0.0, float(ledger_row.get("wood", 0.0))),
            "stone": maxf(0.0, float(ledger_row.get("stone", 0.0))),
            "tools": maxf(0.0, float(ledger_row.get("tools", 0.0))),
            "currency": maxf(0.0, float(ledger_row.get("currency", 0.0))),
            "debt": maxf(0.0, float(ledger_row.get("debt", 0.0))),
            "waste": maxf(0.0, float(ledger_row.get("waste", 0.0))),
            "active_structures": active_structures,
            "belonging_index": belonging_index,
            "bone_signal": bone_signal,
            "x": pos.x,
            "z": pos.z,
            "biome": String(tile.get("biome", "plains")),
            "temperature": float(tile.get("temperature", 0.5)),
            "moisture": float(tile.get("moisture", 0.5)),
            "water_reliability": float(tile.get("water_reliability", 0.5)),
            "flood_risk": float(tile.get("flood_risk", 0.0)),
        })

    var individuals: Array = []
    var npc_ids = _sorted_npc_ids()
    for npc_id in npc_ids:
        var state_resource = _villagers.get(npc_id, null)
        var econ_state = _individual_ledgers.get(npc_id, null)
        var state = state_resource.to_dict() if state_resource != null else {}
        var econ = econ_state.to_dict() if econ_state != null else {}
        var inv: Dictionary = econ.get("inventory", {})
        individuals.append({
            "npc_id": npc_id,
            "household_id": String(state.get("household_id", "")),
            "morale": float(state.get("morale", 0.5)),
            "fear": float(state.get("fear", 0.0)),
            "hunger": float(state.get("hunger", 0.0)),
            "energy": float(state.get("energy", 1.0)),
            "food": float(inv.get("food", 0.0)),
            "water": float(inv.get("water", 0.0)),
            "currency": float(inv.get("currency", 0.0)),
            "tools": float(inv.get("tools", 0.0)),
            "waste": float(inv.get("waste", 0.0)),
        })
    if individuals.size() > 20:
        individuals.resize(20)

    return {
        "tick": tick,
        "community": _community_ledger.to_dict() if _community_ledger != null else {},
        "households": households,
        "individuals": individuals,
        "living_entities": _external_living_entity_profiles.duplicate(true),
        "recent_events": _recent_resource_event_context(maxi(0, tick - 24), tick),
    }

func _tile_context_for_position(position: Vector3) -> Dictionary:
    var tile_id = "%d:%d" % [int(round(position.x)), int(round(position.z))]
    var tile_index: Dictionary = _environment_snapshot.get("tile_index", {})
    var tile = tile_index.get(tile_id, {})
    var water_tiles: Dictionary = _water_network_snapshot.get("water_tiles", {})
    var water = water_tiles.get(tile_id, {})
    return {
        "biome": String(tile.get("biome", "plains")),
        "temperature": clampf(float(tile.get("temperature", 0.5)), 0.0, 1.0),
        "moisture": clampf(float(tile.get("moisture", 0.5)), 0.0, 1.0),
        "water_reliability": clampf(float(water.get("water_reliability", 0.5)), 0.0, 1.0),
        "flood_risk": clampf(float(water.get("flood_risk", 0.0)), 0.0, 1.0),
    }

func _recent_resource_event_context(tick_from: int, tick_to: int) -> Array:
    if _store == null:
        return []
    var rows: Array = _store.list_resource_events(world_id, active_branch_id, tick_from, tick_to)
    var out: Array = []
    for row_variant in rows:
        if not (row_variant is Dictionary):
            continue
        var row = row_variant as Dictionary
        var payload: Dictionary = row.get("payload", {})
        out.append({
            "tick": int(row.get("tick", 0)),
            "event_type": String(row.get("event_type", "")),
            "scope": String(row.get("scope", "")),
            "owner_id": String(row.get("owner_id", "")),
            "kind": String(payload.get("kind", "")),
            "magnitude": _event_magnitude(payload),
        })
    out.sort_custom(func(a, b):
        var ad = a as Dictionary
        var bd = b as Dictionary
        return int(ad.get("tick", 0)) < int(bd.get("tick", 0))
    )
    if out.size() > 48:
        out = out.slice(out.size() - 48, out.size())
    return out

func _event_magnitude(payload: Dictionary) -> float:
    var total = 0.0
    var bundle: Dictionary = payload.get("resource_bundle", {})
    if not bundle.is_empty():
        var bundle_keys = bundle.keys()
        bundle_keys.sort_custom(func(a, b): return String(a) < String(b))
        for key_variant in bundle_keys:
            var key = String(key_variant)
            total += absf(float(bundle.get(key, 0.0)))
    var delta: Dictionary = payload.get("delta", {})
    if not delta.is_empty():
        var delta_keys = delta.keys()
        delta_keys.sort_custom(func(a, b): return String(a) < String(b))
        for key_variant in delta_keys:
            var key = String(key_variant)
            total += absf(float(delta.get(key, 0.0)))
    var moved: Dictionary = payload.get("moved", {})
    if not moved.is_empty():
        var moved_keys = moved.keys()
        moved_keys.sort_custom(func(a, b): return String(a) < String(b))
        for key_variant in moved_keys:
            var key = String(key_variant)
            total += absf(float(moved.get(key, 0.0)))
    return clampf(total, 0.0, 1000000.0)

func _apply_community_dict(ledger, payload_variant) -> void:
    if not (payload_variant is Dictionary):
        return
    var payload = payload_variant as Dictionary
    ledger.food = maxf(0.0, float(payload.get("food", ledger.food)))
    ledger.water = maxf(0.0, float(payload.get("water", ledger.water)))
    ledger.wood = maxf(0.0, float(payload.get("wood", ledger.wood)))
    ledger.stone = maxf(0.0, float(payload.get("stone", ledger.stone)))
    ledger.tools = maxf(0.0, float(payload.get("tools", ledger.tools)))
    ledger.currency = maxf(0.0, float(payload.get("currency", ledger.currency)))
    ledger.labor_pool = maxf(0.0, float(payload.get("labor_pool", ledger.labor_pool)))
    ledger.storage_capacity = maxf(1.0, float(payload.get("storage_capacity", ledger.storage_capacity)))
    ledger.spoiled = maxf(0.0, float(payload.get("spoiled", ledger.spoiled)))
    ledger.waste = maxf(0.0, float(payload.get("waste", ledger.waste)))

func _apply_household_dict(ledger, payload_variant) -> void:
    if not (payload_variant is Dictionary):
        return
    var payload = payload_variant as Dictionary
    ledger.food = maxf(0.0, float(payload.get("food", ledger.food)))
    ledger.water = maxf(0.0, float(payload.get("water", ledger.water)))
    ledger.wood = maxf(0.0, float(payload.get("wood", ledger.wood)))
    ledger.stone = maxf(0.0, float(payload.get("stone", ledger.stone)))
    ledger.tools = maxf(0.0, float(payload.get("tools", ledger.tools)))
    ledger.currency = maxf(0.0, float(payload.get("currency", ledger.currency)))
    ledger.debt = maxf(0.0, float(payload.get("debt", ledger.debt)))
    ledger.housing_quality = clampf(float(payload.get("housing_quality", ledger.housing_quality)), 0.0, 1.0)
    ledger.waste = maxf(0.0, float(payload.get("waste", ledger.waste)))

func _apply_individual_dict(state, payload_variant) -> void:
    if not (payload_variant is Dictionary):
        return
    var payload = payload_variant as Dictionary
    state.wage_due = maxf(0.0, float(payload.get("wage_due", state.wage_due)))
    state.moved_total_weight = maxf(0.0, float(payload.get("moved_total_weight", state.moved_total_weight)))
    state.energy = clampf(float(payload.get("energy", state.energy)), 0.0, 1.0)
    state.health = clampf(float(payload.get("health", state.health)), 0.0, 1.0)
    var inv_payload: Dictionary = payload.get("inventory", {})
    var inv = state.inventory
    inv.food = maxf(0.0, float(inv_payload.get("food", inv.food)))
    inv.water = maxf(0.0, float(inv_payload.get("water", inv.water)))
    inv.wood = maxf(0.0, float(inv_payload.get("wood", inv.wood)))
    inv.stone = maxf(0.0, float(inv_payload.get("stone", inv.stone)))
    inv.tools = maxf(0.0, float(inv_payload.get("tools", inv.tools)))
    inv.currency = maxf(0.0, float(inv_payload.get("currency", inv.currency)))
    inv.waste = maxf(0.0, float(inv_payload.get("waste", inv.waste)))
    inv.carried_food = maxf(0.0, float(inv_payload.get("carried_food", inv.carried_food)))
    inv.carried_water = maxf(0.0, float(inv_payload.get("carried_water", inv.carried_water)))
    inv.carried_wood = maxf(0.0, float(inv_payload.get("carried_wood", inv.carried_wood)))
    inv.carried_stone = maxf(0.0, float(inv_payload.get("carried_stone", inv.carried_stone)))
    inv.carried_tools = maxf(0.0, float(inv_payload.get("carried_tools", inv.carried_tools)))
    inv.carried_currency = maxf(0.0, float(inv_payload.get("carried_currency", inv.carried_currency)))
    inv.carried_weight = maxf(0.0, float(inv_payload.get("carried_weight", inv.carried_weight)))

func _apply_carry_profile_dict(profile, payload_variant) -> void:
    if not (payload_variant is Dictionary):
        return
    var payload = payload_variant as Dictionary
    profile.strength = clampf(float(payload.get("strength", profile.strength)), 0.0, 1.5)
    profile.tool_efficiency = maxf(0.0, float(payload.get("tool_efficiency", profile.tool_efficiency)))
    profile.base_capacity = maxf(0.1, float(payload.get("base_capacity", profile.base_capacity)))
    profile.strength_multiplier = maxf(0.0, float(payload.get("strength_multiplier", profile.strength_multiplier)))
    profile.max_tool_bonus = maxf(0.0, float(payload.get("max_tool_bonus", profile.max_tool_bonus)))
    profile.tool_bonus_factor = maxf(0.0, float(payload.get("tool_bonus_factor", profile.tool_bonus_factor)))
    profile.min_capacity = maxf(0.0, float(payload.get("min_capacity", profile.min_capacity)))
