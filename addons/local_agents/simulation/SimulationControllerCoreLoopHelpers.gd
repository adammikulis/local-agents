extends RefCounted
class_name LocalAgentsSimulationControllerCoreLoopHelpers

static func ensure_initialized(svc) -> void:
    if svc._initialized:
        return
    if svc._rng == null:
        svc._rng = svc.DeterministicRngScript.new()
    if svc._narrator == null:
        svc._narrator = svc.NarratorScript.new()
    if svc._dreams == null:
        svc._dreams = svc.DreamScript.new()
    if svc._mind == null:
        svc._mind = svc.MindScript.new()
    if svc._store == null:
        svc._store = svc.StoreScript.new()
    if svc._branch_analysis == null:
        svc._branch_analysis = svc.BranchAnalysisServiceScript.new()
    if svc._culture_cycle == null:
        svc._culture_cycle = svc.CulturalCycleSystemScript.new()

    if svc._community_ledger_system == null:
        svc._community_ledger_system = svc.CommunityLedgerScript.new()
    if svc._household_ledger_system == null:
        svc._household_ledger_system = svc.HouseholdLedgerScript.new()
    if svc._individual_ledger_system == null:
        svc._individual_ledger_system = svc.IndividualLedgerScript.new()
    if svc._economy_system == null:
        svc._economy_system = svc.EconomyScript.new()

    if svc._market_config == null:
        svc._market_config = svc.MarketConfigResourceScript.new()
    if svc._transfer_rules == null:
        svc._transfer_rules = svc.TransferRuleResourceScript.new()
    svc._economy_system.set_market_config(svc._market_config)
    svc._economy_system.set_transfer_rules(svc._transfer_rules)

    if svc._backstory_service == null:
        svc._backstory_service = svc.BackstoryServiceScript.new()
        svc.add_child(svc._backstory_service)
    if svc._world_generator == null:
        svc._world_generator = svc.WorldGeneratorScript.new()
    if svc._hydrology_system == null:
        svc._hydrology_system = svc.HydrologySystemScript.new()
    if svc._settlement_seeder == null:
        svc._settlement_seeder = svc.SettlementSeederScript.new()
    if svc._weather_system == null:
        svc._weather_system = svc.WeatherSystemScript.new()
    if svc._erosion_system == null:
        svc._erosion_system = svc.ErosionSystemScript.new()
    if svc._solar_system == null:
        svc._solar_system = svc.SolarExposureSystemScript.new()
    if svc._worldgen_config == null:
        svc._worldgen_config = svc.WorldGenConfigResourceScript.new()
    if svc._flow_network_system == null:
        svc._flow_network_system = svc.SpatialFlowNetworkSystemScript.new()
    if svc._structure_lifecycle_system == null:
        svc._structure_lifecycle_system = svc.StructureLifecycleSystemScript.new()
    if svc._flow_traversal_profile == null:
        svc._flow_traversal_profile = svc.FlowTraversalProfileResourceScript.new()
    if svc._flow_formation_config == null:
        svc._flow_formation_config = svc.FlowFormationConfigResourceScript.new()
    if svc._flow_runtime_config == null:
        svc._flow_runtime_config = svc.FlowRuntimeConfigResourceScript.new()
    if svc._structure_lifecycle_config == null:
        svc._structure_lifecycle_config = svc.StructureLifecycleConfigResourceScript.new()
    if svc._flow_network_system != null:
        svc._flow_network_system.set_flow_profile(svc._flow_traversal_profile)
        svc._flow_network_system.set_flow_formation_config(svc._flow_formation_config)
        svc._flow_network_system.set_flow_runtime_config(svc._flow_runtime_config)
    if svc._structure_lifecycle_system != null:
        svc._structure_lifecycle_system.set_config(svc._structure_lifecycle_config)

    if svc._community_ledger == null:
        svc._community_ledger = svc._community_ledger_system.initial_community_ledger()
    if svc._narrator_directive_resource == null:
        svc._narrator_directive_resource = svc.NarratorDirectiveResourceScript.new()
    if svc._cognition_contract_config == null:
        svc._cognition_contract_config = svc.CognitionContractConfigResourceScript.new()
    svc._apply_cognition_contract()
    svc._apply_llama_server_integration()
    svc._initialized = true

static func configure_environment(svc, config_resource = null) -> Dictionary:
    ensure_initialized(svc)
    if config_resource != null:
        svc._worldgen_config = config_resource
    if svc._worldgen_config == null:
        svc._worldgen_config = svc.WorldGenConfigResourceScript.new()
    if svc._world_generator == null:
        svc._world_generator = svc.WorldGeneratorScript.new()
    if svc._hydrology_system == null:
        svc._hydrology_system = svc.HydrologySystemScript.new()
    if svc._settlement_seeder == null:
        svc._settlement_seeder = svc.SettlementSeederScript.new()
    if svc._rng == null:
        return {"ok": false, "error": "rng_unavailable"}

    var world_seed = svc._rng.derive_seed("environment", svc.world_id, svc.active_branch_id, 0)
    var hydrology_seed = svc._rng.derive_seed("hydrology", svc.world_id, svc.active_branch_id, 0)
    var weather_seed = svc._rng.derive_seed("weather", svc.world_id, svc.active_branch_id, 0)
    var erosion_seed = svc._rng.derive_seed("erosion", svc.world_id, svc.active_branch_id, 0)
    var solar_seed = svc._rng.derive_seed("solar", svc.world_id, svc.active_branch_id, 0)
    var settlement_seed = svc._rng.derive_seed("settlement", svc.world_id, svc.active_branch_id, 0)

    svc._environment_snapshot = svc._world_generator.generate(world_seed, svc._worldgen_config)
    if svc._hydrology_system != null and svc._hydrology_system.has_method("set_compute_enabled"):
        svc._hydrology_system.set_compute_enabled(true)
    svc._water_network_snapshot = svc._hydrology_system.build_network(svc._environment_snapshot, svc._worldgen_config)
    svc._water_network_snapshot["seed"] = hydrology_seed
    svc._weather_snapshot = {}
    if svc._weather_system != null:
        svc._weather_system.set_emit_rows(false)
        svc._weather_system.set_compute_enabled(true)
        var weather_setup: Dictionary = svc._weather_system.configure_environment(svc._environment_snapshot, svc._water_network_snapshot, weather_seed)
        if bool(weather_setup.get("ok", false)):
            svc._weather_snapshot = svc._weather_system.current_snapshot(0)
    svc._weather_snapshot["seed"] = weather_seed
    svc._erosion_snapshot = {}
    svc._erosion_changed_last_tick = false
    svc._erosion_changed_tiles_last_tick = []
    if svc._erosion_system != null:
        svc._erosion_system.set_emit_rows(false)
        svc._erosion_system.set_compute_enabled(true)
        if svc._erosion_system.has_method("set_geomorph_apply_interval_ticks"):
            svc._erosion_system.call("set_geomorph_apply_interval_ticks", 6)
        svc._erosion_system.configure_environment(svc._environment_snapshot, svc._water_network_snapshot, erosion_seed)
        svc._erosion_snapshot = svc._erosion_system.current_snapshot(0)
    svc._erosion_snapshot["seed"] = erosion_seed
    svc._solar_snapshot = {}
    if svc._solar_system != null:
        svc._solar_system.set_emit_rows(false)
        if svc._solar_system.has_method("set_sync_stride"):
            svc._solar_system.call("set_sync_stride", 4)
        svc._solar_system.set_compute_enabled(true)
        var solar_setup: Dictionary = svc._solar_system.configure_environment(svc._environment_snapshot, solar_seed)
        if bool(solar_setup.get("ok", false)):
            svc._solar_snapshot = svc._solar_system.current_snapshot(0)
    svc._solar_snapshot["seed"] = solar_seed
    if svc._flow_network_system != null:
        svc._flow_network_system.configure_environment(svc._environment_snapshot, svc._water_network_snapshot)
    svc._spawn_artifact = svc._settlement_seeder.select_site(svc._environment_snapshot, svc._water_network_snapshot, svc._worldgen_config)
    svc._spawn_artifact["seed"] = settlement_seed
    var chosen = svc._spawn_artifact.get("chosen", {})
    svc._community_anchor_position = Vector3(float(chosen.get("x", 0.0)), 0.0, float(chosen.get("y", 0.0)))
    svc._seed_sacred_site()
    if svc._structure_lifecycle_system != null:
        svc._structure_lifecycle_system.ensure_core_anchors(svc._community_anchor_position)

    return {
        "ok": true,
        "environment": svc._environment_snapshot.duplicate(true),
        "hydrology": svc._water_network_snapshot.duplicate(true),
        "weather": svc._weather_snapshot.duplicate(true),
        "erosion": svc._erosion_snapshot.duplicate(true),
        "solar": svc._solar_snapshot.duplicate(true),
        "spawn": svc._spawn_artifact.duplicate(true),
    }

static func register_villager(svc, npc_id: String, display_name: String, initial_state: Dictionary = {}) -> Dictionary:
    ensure_initialized(svc)
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
    var villager_state = svc.VillagerStateResourceScript.new()
    villager_state.from_dict(state_payload)
    svc._villagers[npc_id] = villager_state
    svc._villager_positions[npc_id] = svc._spawn_offset_position(npc_id, 2.8)

    if not svc._household_members.has(household_id):
        var membership = svc.HouseholdMembershipResourceScript.new()
        membership.household_id = household_id
        svc._household_members[household_id] = membership
        svc._household_positions[household_id] = svc._spawn_offset_position(household_id, 4.0)
    var members_resource = svc._household_members[household_id]
    members_resource.add_member(npc_id)

    if not svc._household_ledgers.has(household_id):
        svc._household_ledgers[household_id] = svc._household_ledger_system.initial_household_ledger(household_id)
    if not svc._individual_ledgers.has(npc_id):
        svc._individual_ledgers[npc_id] = svc._individual_ledger_system.initial_individual_ledger(npc_id)

    var carry_profile = svc.CarryProfileResourceScript.new()
    carry_profile.strength = clampf(float(initial_state.get("strength", 0.5)), 0.0, 1.5)
    carry_profile.tool_efficiency = maxf(0.0, float(initial_state.get("tool_efficiency", 0.0)))
    svc._carry_profiles[npc_id] = carry_profile

    var profile_variant = initial_state.get("profession_profile", null)
    if profile_variant != null and profile_variant is Resource:
        svc._economy_system.set_profession_profile(profile_variant)

    var upsert = svc._backstory_service.upsert_npc(npc_id, display_name, {}, {"source": "simulation"})
    return {"ok": bool(upsert.get("ok", false)), "npc_id": npc_id}

static func process_tick(svc, tick: int, fixed_delta: float, include_state: bool = true) -> Dictionary:
    ensure_initialized(svc)
    svc._resource_event_sequence = 0
    svc._last_partial_delivery_count = 0
    svc._household_growth_metrics = {}
    svc._structure_lifecycle_events = {"expanded": [], "abandoned": []}
    svc._oral_tick_events = []
    svc._ritual_tick_events = []
    svc._culture_driver_events = []
    svc._cultural_policy = {}
    if svc._flow_network_system != null:
        svc._flow_network_system.step_decay()
    svc._erosion_changed_last_tick = false
    svc._erosion_changed_tiles_last_tick = []
    if svc._weather_system != null:
        svc._weather_snapshot = svc._weather_system.step(tick, fixed_delta)
    if svc._hydrology_system != null:
        var hydrology_step: Dictionary = svc._hydrology_system.step(tick, fixed_delta, svc._environment_snapshot, svc._water_network_snapshot, svc._weather_snapshot)
        svc._environment_snapshot = hydrology_step.get("environment", svc._environment_snapshot)
        svc._water_network_snapshot = hydrology_step.get("hydrology", svc._water_network_snapshot)
    if svc._erosion_system != null:
        var erosion_result: Dictionary = svc._erosion_system.step(tick, fixed_delta, svc._environment_snapshot, svc._water_network_snapshot, svc._weather_snapshot)
        svc._environment_snapshot = erosion_result.get("environment", svc._environment_snapshot)
        svc._water_network_snapshot = erosion_result.get("hydrology", svc._water_network_snapshot)
        svc._erosion_snapshot = erosion_result.get("erosion", svc._erosion_snapshot)
        svc._erosion_changed_last_tick = bool(erosion_result.get("changed", false))
        svc._erosion_changed_tiles_last_tick = (erosion_result.get("changed_tiles", []) as Array).duplicate(true)
    if svc._solar_system != null:
        svc._solar_snapshot = svc._solar_system.step(tick, fixed_delta, svc._environment_snapshot, svc._weather_snapshot)
    if svc._flow_network_system != null:
        svc._flow_network_system.configure_environment(svc._environment_snapshot, svc._water_network_snapshot)
    var npc_ids = svc._sorted_npc_ids()
    for npc_id in npc_ids:
        svc._apply_need_decay(npc_id, fixed_delta)

    svc._run_resource_pipeline(tick, npc_ids)
    svc._run_structure_lifecycle(tick)
    svc._run_culture_cycle(tick)

    if svc.narrator_enabled and tick > 0 and tick % 24 == 0:
        if not svc._generate_narrator_direction(tick):
            return svc._dependency_error_result(tick, "narrator")

    if svc.thoughts_enabled:
        if svc._is_thought_tick(tick):
            svc._enqueue_thought_npcs(npc_ids)
        if not svc._drain_thought_queue(tick, svc._generation_cap("thought", 8)):
            return svc._dependency_error_result(tick, "thought")

    if svc.dialogue_enabled:
        if svc._is_dialogue_tick(tick):
            svc._enqueue_dialogue_pairs(npc_ids)
        if not svc._drain_dialogue_queue(tick, svc._generation_cap("dialogue", 4)):
            return svc._dependency_error_result(tick, "dialogue")

    if svc.dreams_enabled:
        if svc._is_dream_tick(tick):
            svc._enqueue_dream_npcs(npc_ids)
        if not svc._drain_dream_queue(tick, svc._generation_cap("dream", 8)):
            return svc._dependency_error_result(tick, "dream")

    var event_id: int = -1
    var should_persist_tick: bool = svc.persist_tick_history_enabled and (tick % maxi(1, svc.persist_tick_history_interval) == 0)
    var state_payload: Dictionary = {}
    if include_state or should_persist_tick:
        var snapshot = current_snapshot(svc, tick)
        if include_state:
            state_payload = snapshot
        if should_persist_tick:
            event_id = svc._store.begin_event(svc.world_id, svc.active_branch_id, tick, "tick", snapshot)
            if tick % 48 == 0:
                svc._store.create_checkpoint(
                    svc.world_id,
                    svc.active_branch_id,
                    tick,
                    str(hash(JSON.stringify(snapshot, "", false, true))),
                    svc._branch_lineage.duplicate(true),
                    svc._branch_fork_tick
                )
    else:
        state_payload = {
            "tick": tick,
            "environment_signals": svc.build_environment_signal_snapshot(tick).to_dict(),
        }
    svc._last_tick_processed = tick
    return {
        "ok": true,
        "tick": tick,
        "event_id": event_id,
        "state": state_payload,
    }

static func current_snapshot(svc, tick: int) -> Dictionary:
    ensure_initialized(svc)
    var snapshot_resource = svc.SnapshotResourceScript.new()
    var env_signal_snapshot = svc.build_environment_signal_snapshot(tick)
    snapshot_resource.world_id = svc.world_id
    snapshot_resource.branch_id = svc.active_branch_id
    snapshot_resource.tick = tick
    snapshot_resource.community = svc.BundleResourceScript.new()
    snapshot_resource.community.from_dict(svc._community_ledger.to_dict())
    snapshot_resource.households = svc._serialize_household_ledgers()
    snapshot_resource.individuals = svc._serialize_individual_ledgers()
    snapshot_resource.market_prices = svc._last_market_prices.duplicate(true)

    return {
        "world_id": svc.world_id,
        "branch_id": svc.active_branch_id,
        "tick": tick,
        "branch_lineage": svc._branch_lineage.duplicate(true),
        "branch_fork_tick": svc._branch_fork_tick,
        "worldgen_config": svc._worldgen_config.to_dict() if svc._worldgen_config != null else {},
        "environment_snapshot": svc._environment_snapshot.duplicate(true),
        "water_network_snapshot": svc._water_network_snapshot.duplicate(true),
        "weather_snapshot": svc._weather_snapshot.duplicate(true),
        "erosion_snapshot": svc._erosion_snapshot.duplicate(true),
        "solar_snapshot": svc._solar_snapshot.duplicate(true),
        "erosion_changed": svc._erosion_changed_last_tick,
        "erosion_changed_tiles": svc._erosion_changed_tiles_last_tick.duplicate(true),
        "environment_signals": env_signal_snapshot.to_dict(),
        "spawn_artifact": svc._spawn_artifact.duplicate(true),
        "flow_network": svc._flow_network_system.export_network() if svc._flow_network_system != null else {},
        "flow_formation_config": svc._flow_formation_config.to_dict() if svc._flow_formation_config != null else {},
        "flow_runtime_config": svc._flow_runtime_config.to_dict() if svc._flow_runtime_config != null else {},
        "flow_traversal_profile": svc._flow_traversal_profile.to_dict() if svc._flow_traversal_profile != null else {},
        "structure_lifecycle_config": svc._structure_lifecycle_config.to_dict() if svc._structure_lifecycle_config != null else {},
        "anchors": svc._structure_lifecycle_system.export_anchors() if svc._structure_lifecycle_system != null else [],
        "structures": svc._structure_lifecycle_system.export_structures() if svc._structure_lifecycle_system != null else {},
        "structure_lifecycle_runtime": svc._structure_lifecycle_system.export_runtime_state() if svc._structure_lifecycle_system != null else {},
        "structure_lifecycle_events": svc._structure_lifecycle_events.duplicate(true),
        "sacred_site_id": svc._sacred_site_id,
        "cultural_cycle_state": svc._culture_cycle.export_state() if svc._culture_cycle != null else {},
        "culture_retention": svc._culture_cycle.retention_metrics() if (svc._culture_cycle != null and svc._culture_cycle.has_method("retention_metrics")) else {},
        "culture_driver_events": svc._culture_driver_events.duplicate(true),
        "cultural_policy": svc._cultural_policy.duplicate(true),
        "culture_context_cues": svc._culture_context_cues.duplicate(true),
        "oral_transfer_events": svc._oral_tick_events.duplicate(true),
        "ritual_events": svc._ritual_tick_events.duplicate(true),
        "partial_delivery_count": svc._last_partial_delivery_count,
        "villagers": svc._serialize_villagers(),
        "community_ledger": svc._community_ledger.to_dict(),
        "household_ledgers": svc._serialize_household_ledgers(),
        "individual_ledgers": svc._serialize_individual_ledgers(),
        "carry_profiles": svc._serialize_carry_profiles(),
        "market_prices": svc._last_market_prices.duplicate(true),
        "economy_snapshot": snapshot_resource.to_dict(),
        "directive": svc._directive_text(),
        "cognition_contract": svc._cognition_contract_config.to_dict() if (svc._cognition_contract_config != null and svc._cognition_contract_config.has_method("to_dict")) else {},
        "llama_server_options": svc._llama_server_options.duplicate(true),
        "cognition_scheduler": {
            "pending_thoughts": svc._pending_thought_npc_ids.duplicate(true),
            "pending_dialogues": svc._pending_dialogue_pairs.duplicate(true),
            "pending_dreams": svc._pending_dream_npc_ids.duplicate(true),
        },
    }
