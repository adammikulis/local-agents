# Vertical Slice Contract Tables

Canonical contract artifact for Section 14 of `docs/VILLAGE_VERTICAL_SLICE_PLAN.md`.

This document is implementation-aligned to current runtime code in:
- `addons/local_agents/configuration/parameters/simulation/*.gd`
- `addons/local_agents/graph/BackstoryGraphService.gd`
- `addons/local_agents/simulation/SimulationController.gd`

## 14.1 Resource Schema Table

| Resource | Purpose | Required Fields (contract) | Source |
|---|---|---|---|
| `LocalAgentsWorldGenConfigResource` | Deterministic worldgen, hydrology, spawn scoring config | `schema_version`, `simulated_year`, `progression_profile_id`, `map_width`, `map_height`, `voxel_world_height`, `voxel_sea_level`, `elevation_frequency`, `moisture_frequency`, `temperature_frequency`, `spring_elevation_threshold`, `spring_moisture_threshold`, `flow_merge_threshold`, `floodplain_flow_threshold`, spawn weight fields | `addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd` |
| `LocalAgentsWorldTileResource` | Per-tile environment state | `schema_version`, `tile_id`, `x`, `y`, `elevation`, `moisture`, `temperature`, `slope`, `biome`, `food_density`, `wood_density`, `stone_density` | `addons/local_agents/configuration/parameters/simulation/WorldTileResource.gd` |
| `LocalAgentsSpawnCandidateResource` | Water-first spawn candidate scoring artifact | `schema_version`, `candidate_id`, `tile_id`, `x`, `y`, `score_total`, `score_breakdown` | `addons/local_agents/configuration/parameters/simulation/SpawnCandidateResource.gd` |
| `LocalAgentsEnvironmentSignalSnapshotResource` | Tick-stable environment/hydrology/weather/erosion/solar snapshot | `schema_version`, `tick`, `environment_snapshot`, `water_network_snapshot`, `weather_snapshot`, `erosion_snapshot`, `solar_snapshot`, `erosion_changed`, `erosion_changed_tiles` | `addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd` |
| `LocalAgentsVoxelTimelapseSnapshotResource` | Replay-oriented world timelapse snapshot | `schema_version`, `tick`, `time_of_day`, `simulated_year`, `simulated_seconds`, `world`, `hydrology`, `weather`, `erosion`, `solar` | `addons/local_agents/configuration/parameters/simulation/VoxelTimelapseSnapshotResource.gd` |
| `LocalAgentsFlowNetworkResource` | Runtime flow/logistics network export | `schema_version`, `edges`, `edge_count` | `addons/local_agents/configuration/parameters/simulation/FlowNetworkResource.gd` |
| `LocalAgentsFlowTraversalProfileResource` | Deterministic movement + delivery profile | `schema_version`, base/path/terrain/weather flow speed+efficiency fields, `eta_divisor` | `addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd` |
| `LocalAgentsFlowFormationConfigResource` | Path/flow heat-strength formation/decay config | `schema_version`, `heat_decay_per_tick`, `strength_decay_per_tick`, `heat_gain_per_weight`, `strength_gain_factor`, `max_heat`, `max_strength` | `addons/local_agents/configuration/parameters/simulation/FlowFormationConfigResource.gd` |
| `LocalAgentsFlowRuntimeConfigResource` | Seasonal/weather runtime multipliers | `schema_version`, seasonal cycle/modifier fields, weather slowdown fields | `addons/local_agents/configuration/parameters/simulation/FlowRuntimeConfigResource.gd` |
| `LocalAgentsStructureLifecycleConfigResource` | Shelter expansion/abandon/depletion rules | `schema_version`, crowding/throughput thresholds, abandon sustain rules, camp spawn rules | `addons/local_agents/configuration/parameters/simulation/StructureLifecycleConfigResource.gd` |
| `LocalAgentsStructureStateResource` | Structure runtime state | `schema_version`, `structure_id`, `structure_type`, `household_id`, `state`, `position`, `durability`, `created_tick`, `last_updated_tick` | `addons/local_agents/configuration/parameters/simulation/StructureStateResource.gd` |
| `LocalAgentsSettlementAnchorResource` | Settlement anchors | `schema_version`, `anchor_id`, `anchor_type`, `household_id`, `position` | `addons/local_agents/configuration/parameters/simulation/SettlementAnchorResource.gd` |
| `LocalAgentsCommunityLedgerResource` | Community stock ledger | `food`, `water`, `wood`, `stone`, `tools`, `currency`, `labor_pool`, `storage_capacity`, `spoiled`, `waste` | `addons/local_agents/configuration/parameters/simulation/CommunityLedgerResource.gd` |
| `LocalAgentsHouseholdLedgerResource` | Household stock ledger | `household_id`, `food`, `water`, `wood`, `stone`, `tools`, `currency`, `debt`, `housing_quality`, `waste` | `addons/local_agents/configuration/parameters/simulation/HouseholdLedgerResource.gd` |
| `LocalAgentsVillagerEconomyStateResource` | Individual economy state | `npc_id`, `inventory`, `wage_due`, `moved_total_weight`, `energy`, `health` | `addons/local_agents/configuration/parameters/simulation/VillagerEconomyStateResource.gd` |
| `LocalAgentsVillagerStateResource` | Individual simulation state | `npc_id`, `display_name`, `mood`, `morale`, `fear`, `energy`, `hunger`, `profession`, `household_id`, `last_dream_effect` | `addons/local_agents/configuration/parameters/simulation/VillagerStateResource.gd` |
| `LocalAgentsCarryProfileResource` | Carry capacity profile | `strength`, `tool_efficiency`, `base_capacity`, `strength_multiplier`, `max_tool_bonus`, `tool_bonus_factor`, `min_capacity` | `addons/local_agents/configuration/parameters/simulation/CarryProfileResource.gd` |
| `LocalAgentsResourceBundleResource` | Canonical resource payload wrapper | `food`, `water`, `wood`, `stone`, `tools`, `currency`, `labor_pool`, `waste` | `addons/local_agents/configuration/parameters/simulation/ResourceBundleResource.gd` |
| `LocalAgentsCognitionContractConfigResource` | Per-task LLM contract + budgets | `schema_version`, `llm_profile_version`, `context_schema_version`, profile resources, budget fields | `addons/local_agents/configuration/parameters/simulation/CognitionContractConfigResource.gd` |
| `LocalAgentsLlmRequestProfileResource` | Deterministic generation profile | `schema_version`, `profile_id`, `temperature`, `top_p`, `max_tokens`, `stop`, `reset_context`, `cache_prompt`, `retry_count`, `retry_seed_step`, `output_json` | `addons/local_agents/configuration/parameters/simulation/LlmRequestProfileResource.gd` |

## 14.2 Graph Node/Edge Field Table

### Spaces

`BackstoryGraphService` graph spaces:
`npc`, `faction`, `place`, `quest`, `event`, `memory`, `quest_state`, `dialogue_state`, `world_time`, `relationship_profile`, `relationship_event`, `truth`, `belief`, `oral_knowledge`, `ritual_event`, `sacred_site`.

Source: `addons/local_agents/graph/BackstoryGraphService.gd`

### Node Contracts

| Node Type | Required Fields |
|---|---|
| `truth` | `type`, `truth_id`, `claim_key`, `subject_id`, `predicate`, `object_value`, `object_norm`, `world_day`, `confidence`, `metadata`, `updated_at` |
| `belief` | `type`, `belief_id`, `npc_id`, `claim_key`, `subject_id`, `predicate`, `object_value`, `object_norm`, `world_day`, `confidence`, `metadata`, `updated_at` |
| `oral_knowledge` | `type`, `knowledge_id`, `npc_id`, `category`, `content`, `confidence`, `motifs`, `world_day`, `metadata`, `updated_at` |
| `ritual_event` | `type`, `ritual_id`, `site_id`, `world_day`, `participants`, `effects`, `metadata`, `updated_at` |
| `sacred_site` | `type`, `site_id`, `site_type`, `position`, `radius`, `taboo_ids`, `world_day`, `metadata`, `updated_at` |
| `memory` | `type`, `memory_id`, `npc_id`, `summary`, `conversation_id`, `message_id`, `world_day`, `importance`, `confidence`, `tags`, `metadata`, `updated_at` |
| `relationship_profile` | `type`, `relationship_key`, `source_npc_id`, `target_npc_id`, `tags`, `long_term`, `world_day`, `metadata`, `updated_at` |

### Edge Contracts

| Edge Kind | Required Fields |
|---|---|
| `HAS_TRUTH` | `type=truth_ref`, `subject_id`, `predicate`, `claim_key` |
| `HAS_BELIEF` | `type=belief_ref`, `npc_id`, `belief_id`, `claim_key` |
| `HAS_ORAL_KNOWLEDGE` | `type=oral_knowledge_ref`, `npc_id`, `knowledge_id`, `world_day`, `confidence` |
| `DERIVES_FROM` | `type=knowledge_lineage`, `source_knowledge_id`, `derived_knowledge_id`, `speaker_npc_id`, `listener_npc_id`, `transmission_hops`, `world_day` |
| `AT_SITE` | `type=ritual_site_ref`, `ritual_id`, `site_id` |
| `PARTICIPATED_IN` | `type=participation`, `npc_id`, `ritual_id`, `world_day` |
| `HAS_MEMORY` | `type=memory_ref`, `npc_id`, `memory_id`, `world_day`, `importance` |

## 14.3 Cypher Playbook Key Index

Playbook keys are returned by:
`LocalAgentsBackstoryGraphService.get_cypher_playbook()`

Source: `addons/local_agents/graph/BackstoryGraphService.gd`

| Key | Category | Intent | Min Params |
|---|---|---|---|
| `upsert_npc` | write | Create/update NPC node | `npc_id`, `name` |
| `upsert_memory_and_link` | write | Create/update memory + ownership edge | `npc_id`, `memory_id`, `summary` |
| `relationship_state` | read | Relationship profile + recent aggregates | `source_npc_id`, `target_npc_id`, `world_day` |
| `npc_backstory_context` | read | Consolidated context query | `npc_id`, `world_day`, `limit` |
| `recent_relationship_events` | read | Pairwise event timeline | `source_npc_id`, `target_npc_id`, `window_start`, `world_day`, `limit` |
| `quest_state_timeline` | read | Quest progression timeline | `npc_id`, `world_day`, `limit` |
| `exclusive_membership_conflicts` | integrity | Exclusive-membership contradiction scan | `limit` |
| `post_death_activity` | integrity | Impossible activity scan after death | `npc_id`, `world_day`, `limit` |
| `memory_recall_candidates` | read | Prompt grounding memories | `npc_id`, `world_day`, `limit` |
| `truths_for_subject` | read | Canonical claims by subject | `subject_id`, `world_day`, `limit` |
| `beliefs_for_npc` | read | NPC belief claims | `npc_id`, `world_day`, `limit` |
| `belief_truth_conflicts` | conflict | Belief-vs-truth mismatches | `npc_id`, `world_day`, `limit` |
| `oral_knowledge_for_npc` | read | Oral repertoire by NPC | `npc_id`, `world_day`, `limit` |
| `oral_transmission_timeline` | read | Oral lineage chain | `knowledge_id`, `limit` |
| `ritual_event_participants` | read | Ritual participation timeline for NPC | `npc_id`, `world_day`, `limit` |
| `sacred_site_ritual_history` | read | Ritual history for site | `site_id`, `world_day`, `limit` |
| `sacred_site_taboo_log` | read | Taboo associations by site | `site_id` |

### Runtime Evidence Linkage

LLM evidence traces are persisted as `sim_llm_trace_event` resource events and queryable through:
- `LocalAgentsSimulationController.list_llm_trace_events(tick_from, tick_to, task)`

Source: `addons/local_agents/simulation/SimulationController.gd`
