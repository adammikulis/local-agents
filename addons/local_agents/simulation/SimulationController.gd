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
const PathNetworkSystemScript = preload("res://addons/local_agents/simulation/PathNetworkSystem.gd")
const TerrainTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/TerrainTraversalProfileResource.gd")
const PathFormationConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/PathFormationConfigResource.gd")

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

var world_id: String = "world_main"
var active_branch_id: String = "main"
var _rng
var _narrator
var _dreams
var _mind
var _store
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
var _path_network_system
var _terrain_traversal_profile
var _path_formation_config
var _villager_positions: Dictionary = {}
var _household_positions: Dictionary = {}
var _community_anchor_position: Vector3 = Vector3.ZERO
var _last_partial_delivery_count: int = 0

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
    if _path_network_system == null:
        _path_network_system = PathNetworkSystemScript.new()
    if _terrain_traversal_profile == null:
        _terrain_traversal_profile = TerrainTraversalProfileResourceScript.new()
    if _path_formation_config == null:
        _path_formation_config = PathFormationConfigResourceScript.new()
    if _path_network_system != null:
        _path_network_system.set_traversal_profile(_terrain_traversal_profile)
        _path_network_system.set_formation_config(_path_formation_config)

    if _community_ledger == null:
        _community_ledger = _community_ledger_system.initial_community_ledger()
    if _narrator_directive_resource == null:
        _narrator_directive_resource = NarratorDirectiveResourceScript.new()

func configure(seed_text: String, narrator_enabled: bool = true, dream_llm_enabled: bool = true) -> void:
    _rng.set_base_seed_from_text(seed_text)
    self.narrator_enabled = narrator_enabled
    _narrator.enabled = narrator_enabled
    _dreams.llm_enabled = dream_llm_enabled
    _mind.llm_enabled = dream_llm_enabled
    _store.open()
    configure_environment(_worldgen_config)

func configure_environment(config_resource = null) -> Dictionary:
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
    if _path_network_system != null:
        _path_network_system.configure_environment(_environment_snapshot, _water_network_snapshot)
    _spawn_artifact = _settlement_seeder.select_site(_environment_snapshot, _water_network_snapshot, _worldgen_config)
    _spawn_artifact["seed"] = settlement_seed
    var chosen = _spawn_artifact.get("chosen", {})
    _community_anchor_position = Vector3(float(chosen.get("x", 0.0)), 0.0, float(chosen.get("y", 0.0)))

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

func set_cognition_features(enable_thoughts: bool, enable_dialogue: bool, enable_dreams: bool) -> void:
    thoughts_enabled = enable_thoughts
    dialogue_enabled = enable_dialogue
    dreams_enabled = enable_dreams

func set_narrator_directive(text: String) -> void:
    if _narrator_directive_resource == null:
        _narrator_directive_resource = NarratorDirectiveResourceScript.new()
    _narrator_directive_resource.set_text(text, -1)

func set_dream_influence(npc_id: String, influence: Dictionary) -> void:
    _dreams.set_dream_influence(npc_id, influence)

func set_profession_profile(profile_resource) -> void:
    if profile_resource == null:
        return
    _economy_system.set_profession_profile(profile_resource)

func set_terrain_traversal_profile(profile_resource) -> void:
    if profile_resource == null:
        _terrain_traversal_profile = TerrainTraversalProfileResourceScript.new()
    else:
        _terrain_traversal_profile = profile_resource
    if _path_network_system != null:
        _path_network_system.set_traversal_profile(_terrain_traversal_profile)

func set_path_formation_config(config_resource) -> void:
    if config_resource == null:
        _path_formation_config = PathFormationConfigResourceScript.new()
    else:
        _path_formation_config = config_resource
    if _path_network_system != null:
        _path_network_system.set_formation_config(_path_formation_config)

func register_villager(npc_id: String, display_name: String, initial_state: Dictionary = {}) -> Dictionary:
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
    _resource_event_sequence = 0
    _last_partial_delivery_count = 0
    if _path_network_system != null:
        _path_network_system.step_decay()
    var npc_ids = _sorted_npc_ids()
    for npc_id in npc_ids:
        _apply_need_decay(npc_id, fixed_delta)

    _run_resource_pipeline(tick, npc_ids)

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
        _store.create_checkpoint(world_id, active_branch_id, tick, str(hash(JSON.stringify(snapshot, "", false, true))))
    return {
        "ok": true,
        "tick": tick,
        "event_id": event_id,
        "state": snapshot,
    }

func current_snapshot(tick: int) -> Dictionary:
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
        "worldgen_config": _worldgen_config.to_dict() if _worldgen_config != null else {},
        "environment_snapshot": _environment_snapshot.duplicate(true),
        "water_network_snapshot": _water_network_snapshot.duplicate(true),
        "spawn_artifact": _spawn_artifact.duplicate(true),
        "path_network": _path_network_system.snapshot() if _path_network_system != null else {},
        "path_formation_config": _path_formation_config.to_dict() if _path_formation_config != null else {},
        "terrain_traversal_profile": _terrain_traversal_profile.to_dict() if _terrain_traversal_profile != null else {},
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
    var bundle = BundleResourceScript.new()
    bundle.from_dict(payload)
    var normalized = payload.duplicate(true)
    if not bundle.to_dict().is_empty():
        normalized["resource_bundle"] = bundle.to_dict()
    var event_id: int = _store.append_resource_event(world_id, active_branch_id, tick, _resource_event_sequence, event_type, scope, owner_id, normalized)
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
        if _path_network_system != null:
            profile = _path_network_system.route_profile(start, target)
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
        if _path_network_system != null:
            var carry_weight = _economy_system.assignment_weight(delivered_assignment)
            _path_network_system.record_traversal(start, target, carry_weight)
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
