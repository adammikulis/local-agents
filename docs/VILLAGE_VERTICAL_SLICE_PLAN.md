# Neolithic Village Vertical Slice Plan

This document is a full implementation plan for a deterministic neolithic village simulation vertical slice.

Design intent:
- Water-first settlement logic.
- Procedural terrain and resources.
- Small population tribal society.
- Oral tradition and quasi-religious belief systems.
- Graph-backed truths vs beliefs.
- Deterministic replay and branchable timelines.

## 0) Current Baseline (Already Implemented)

- [x] Deterministic simulation foundation exists (`SimulationClock`, `FixedStepSimulation`, `DeterministicRNG`, `SimulationStateHasher`).
- [x] Core resource/economy scaffolding exists (community/household/individual ledgers, carry limits, transfer/trade/waste flows).
- [x] Graph truth-vs-belief APIs exist in `BackstoryGraphService` (truth upsert/read, belief upsert/read, conflict query).
- [x] Thought/dialogue prompt state already includes belief conflict context.
- [x] Core headless simulation tests pass for deterministic/resource/economy/dream-label behavior.
- [x] Scene skeletons exist for `AgesWorld`, primitive environment/settlement actors, villager capsule, debug overlay, and simulation HUD.
- [x] Oral tradition graph spaces (`oral_knowledge`, `ritual_event`, `sacred_site`) are implemented for deterministic slice coverage.
- [x] Procedural worldgen/hydrology and water-first spawn scoring are implemented for deterministic slice coverage.

## 0.1) Phase Gate Checklist (Merge-Blocking)

- [ ] No phase execution begins without a planning sub-agent pass that publishes scope, owners, coupling risks, and acceptance criteria.
- [ ] Every phase must define:
- [ ] required automated tests
- [ ] required deterministic artifacts (hash snapshots/fixtures)
- [ ] required graph query outputs (where graph schema changed)
- [ ] required docs updates (schema/playbook/config changes)
- [ ] Phase cannot be marked complete unless:
- [ ] parse check passes
- [ ] targeted phase tests pass
- [ ] core headless suite remains green
- [ ] no new fallback behavior is introduced
- [ ] Required artifacts by phase:
- [ ] Phase 1+: worldgen hash fixture + environment snapshot
- [ ] Phase 2+: water-first spawn score breakdown artifact
- [ ] Phase 3+: economy travel/logistics regression artifact
- [ ] Phase 4+: belief-truth conflict query artifact
- [ ] Phase 5+: oral lineage + taboo/ritual query artifact
- [ ] Phase 6+: branch diff artifact (resource + belief deltas)
- [ ] Phase 7+: LLM evidence trace + KV-isolation test logs
- [ ] Phase 8+: end-to-end 30-day deterministic replay artifact

## 1) Vertical Slice Definition

### 1.1 Included
- [ ] Procedural map generation (terrain, water, biomes, resources).
- [ ] Initial settlement seeded near reliable water.
- [ ] Population of capsule villagers with roles and daily loops.
- [ ] Subsistence economy (gather, produce, carry, consume, waste).
- [ ] Primitive social/cultural layer (rituals, taboos, oral knowledge transfer).
- [ ] Truth vs belief separation in graph memory.
- [ ] Time controls (play/pause/ff/rewind) and branch forking.
- [ ] Deterministic verification and headless tests.

### 1.2 Excluded (for this slice)
- [ ] Metal-age tech trees and advanced craft specialization.
- [ ] Full combat/warfare systems.
- [ ] Complex diplomacy beyond local tribe interactions.
- [ ] Large city infrastructure (walls, formal roads, monetary systems).

### 1.3 Done Criteria
- [ ] Same seed + same choices yields identical hash timelines.
- [ ] Village survives and grows organically over 30 in-game days.
- [ ] Settlement location and growth remain strongly water/resource-driven.
- [ ] Cultural knowledge transfer affects outcomes (food/water risk, route choice, taboo compliance).
- [ ] Belief-truth conflicts visibly impact NPC behavior/dialogue.

## 2) Determinism Contract

### 2.1 Simulation Loop
- [ ] Fixed-step tick rate is constant and globally enforced.
- [ ] All per-tick iteration uses stable sorted key order.
- [ ] All random choices derive from deterministic domain seeds.
- [ ] No wall-clock time or nondeterministic APIs in simulation path.

### 2.2 RNG Domains
- [ ] Separate seed domains for: environment, settlement, economy, social, cognition, events.
- [ ] Domain names are static constants.
- [ ] Seed derivation includes world id + branch id + tick + entity id when relevant.

### 2.3 State Hashing
- [ ] Define canonical hash payload order and schema version.
- [ ] Hash includes: environment state, ledgers, villagers, beliefs/truth references, branch metadata.
- [ ] Add regression fixtures for hash stability after refactors.

## 3) Procedural Environment Plan

### 3.1 Terrain Layers
- [ ] Elevation map via fractal noise (base shape + detail octaves).
- [ ] Moisture map via low-frequency noise + river proximity diffusion.
- [ ] Temperature map via latitude proxy + elevation penalty + noise modulation.

### 3.2 Hydrology (Water-First)
- [ ] Identify springs/sources from elevation peaks and moisture thresholds.
- [ ] Compute downhill flow paths to produce streams/rivers.
- [ ] Merge tributaries and mark flow magnitude.
- [ ] Tag floodplain risk tiles near high-flow channels.
- [ ] Assign water reliability score per tile (perennial/seasonal/poor).

### 3.3 Biomes and Resource Distribution
- [ ] Biomes from {elevation, moisture, temperature} classification.
- [ ] Spawn gatherables by biome (berries, roots, game chance, fish chance).
- [ ] Spawn materials by biome (wood density, stone outcrop density, clay pockets).
- [ ] Spawn fertility index for primitive cultivation potential.

### 3.4 Voronoi + Noise Strategy
- [ ] Implement Voronoi regions using deterministic site seeds.
- [ ] Use Voronoi for macro partitioning: watershed districts, clan influence cells, travel zones.
- [ ] Blend Voronoi edges with noise masks to avoid artificial straight boundaries.
- [ ] Add toggleable modes for A/B testing:
- [ ] Noise-only.
- [ ] Voronoi-only.
- [ ] Hybrid Voronoi+Noise (default candidate).
- [ ] Record deterministic perf + quality metrics for mode selection.

## 4) Settlement Seeding and Growth

### 4.1 Spawn Site Selection
- [ ] Score candidate origins with weighted utility:
- [ ] `water_reliability` (highest weight).
- [ ] `flood_safety` (penalty).
- [ ] `nearby_food_density`.
- [ ] `nearby_wood_density`.
- [ ] `stone_access`.
- [ ] `walkability/slope`.
- [ ] Keep top-N deterministic candidates and pick via seeded tie-break.

### 4.2 Initial Village Layout (Neolithic)
- [ ] Water access point marker (riverbank/spring).
- [ ] Hearth/common fire node.
- [ ] Storage pit/shed.
- [ ] 3-8 hut cluster arranged by slope + proximity.
- [ ] Footpaths connecting huts, hearth, storage, water, and nearby gathering zones.

### 4.3 Organic Growth Rules
- [x] Hut expansion occurs when household crowding + resource throughput thresholds are met.
- [x] New structures bias toward path adjacency and safe distance from floodplain.
- [ ] Resource depletion forces path extension, temporary camps, or relocation pressure.
- [x] Abandon underperforming huts if access cost exceeds threshold for sustained period.
- [ ] Emergent pathing from movement:
- [x] Every villager traversal contributes heat to traversed tile/edge.
- [ ] Heat above threshold creates or strengthens path segments automatically.
- [x] Paths decay if unused for sustained periods.
- [x] Re-used routes become preferred for logistics/job planning.

## 5) Economy and Material Flow (Subsistence)

### 5.1 Resource Model (Minimal)
- [ ] Community + household + individual ledgers track:
- [ ] food
- [ ] water
- [ ] wood
- [ ] stone
- [ ] tools
- [ ] waste

### 5.2 Production/Consumption
- [ ] Daily gather and craft output scales by role, energy, route cost, and local abundance.
- [ ] Consumption is survival-first (water and food priority).
- [ ] Tool wear and replacement are tracked.
- [ ] Waste accumulates and affects local desirability and illness risk (lightweight model).

### 5.3 Carry and Logistics
- [ ] Carry capacity depends on strength + tools.
- [ ] All material movement is explicitly assigned to carriers.
- [ ] Route traversal cost affects delivered quantity and timing.
- [ ] Delivery failures are represented as partial transfers (never silent).
- [ ] Route choice feeds path heat accumulation to enable auto-trail formation.
- [x] Movement speed modifiers are explicit and deterministic:
- [x] Faster movement on established paths (based on path strength/quality).
- [x] Slower movement through brush/forest density.
- [x] Additional penalties for steep slope and shallow-water crossings.
- [x] Seasonal/weather modifiers apply as deterministic multipliers (when enabled).

## 6) Tribal Social and Cultural System

### 6.1 Social Structure
- [ ] Core roles: elder, gatherer, hunter, crafter, caregiver.
- [ ] Family units + household memberships persisted in resources and graph.
- [ ] Social ties (kinship, trust, rivalry) influence cooperation.

### 6.2 Quasi-Religious Belief Layer
- [x] Sacred sites exist as map-linked entities (grove/spring/stone circle).
- [ ] Taboos constrain behavior (avoid hunting area, protect spring, ritual day restrictions).
- [ ] Omen events bias decisions under uncertainty.
- [x] Group rituals can increase cohesion and align beliefs.

### 6.3 Oral Tradition and Tribal Knowledge
- [ ] Knowledge is spoken, not written.
- [ ] Elder-to-youth transfer events occur on schedule and via opportunistic social contact.
- [x] Knowledge categories:
- [x] water route reliability
- [x] safe foraging zones
- [x] seasonal weather cues
- [x] toolcraft recipes
- [x] taboos/ritual obligations
- [ ] Confidence decays if knowledge is not repeated/reinforced.
- [ ] Story retellings can drift in details while preserving motifs.
- [ ] Survival-relevant knowledge retention is measured and surfaced.

## 7) Truth vs Belief Graph Model

### 7.1 Graph Spaces
- [ ] `truth` space for canonical world facts.
- [ ] `belief` space for per-NPC claims.
- [ ] Existing memory/event/relationship spaces integrated as evidence context.
- [ ] `oral_knowledge` space for spoken tradition units and transfer lineage.
- [ ] `ritual_event` space for ritual occurrences and outcomes.
- [ ] `sacred_site` space for map-linked spiritual/cultural anchors.

### 7.2 Claim Schema
- [ ] `claim_key = lower(subject_id)|lower(predicate)`.
- [ ] Canonical truth stores `object_value` + normalized compare value.
- [ ] Belief stores per-NPC `object_value` + confidence.
- [ ] Belief-truth conflict query is first-class API.
- [ ] Claim metadata includes provenance fields (`source_kind`, `source_id`, `speaker_npc_id`, `transmission_hops`).
- [ ] All claim writes include deterministic `world_day` and `updated_at` semantics.

### 7.3 Use in Cognition
- [ ] Thought prompts include compact beliefs + active conflicts.
- [ ] Dialogue prompts include speaker/listener belief contexts.
- [ ] NPC action choice can follow belief even when objectively false.

### 7.4 Contradiction Handling
- [ ] Contradictions are detected and queryable, not auto-resolved silently.
- [ ] Truth updates can invalidate high-confidence beliefs and trigger social events.
- [ ] Conflict severity score combines belief confidence and impact category.

### 7.5 Environment and Settlement Graph Coverage
- [ ] Environment graph entities:
- [ ] `tile` nodes (or coarse region nodes if tile density is too high).
- [ ] `water_node` + `water_segment` entities with flow and permanence metadata.
- [ ] `resource_node` entities with regeneration and depletion parameters.
- [ ] Settlement graph entities:
- [ ] `settlement_anchor`, `structure`, `path_segment`, `household`.
- [ ] Behavioral graph links:
- [ ] `npc -> HAS_BELIEF -> belief`.
- [ ] `npc -> HAS_ORAL_KNOWLEDGE -> oral_knowledge`.
- [ ] `npc -> PARTICIPATED_IN -> ritual_event`.
- [ ] `oral_knowledge -> DERIVES_FROM -> oral_knowledge` (lineage chain).

## 8) Cypher Coverage Plan

- [ ] Expand Cypher playbook for each new graph-backed feature.
- [ ] Required query templates:
- [ ] truths for subject
- [ ] beliefs for NPC
- [ ] belief-truth conflicts
- [ ] oral transmission timeline
- [ ] sacred site taboo compliance events
- [ ] seasonal knowledge retention trends
- [ ] oral knowledge for NPC (current repertoire + confidence)
- [ ] ritual_event participant timelines per NPC
- [ ] sacred site ritual history + taboo log
- [ ] Add docs examples for each query with expected result shape.
- [ ] Add write templates as well as read templates for each new graph space.
- [ ] Add conflict-debug templates (why this belief differs from truth, lineage provenance walk).
- [ ] Add integrity templates:
- [ ] duplicate claim-key detector
- [ ] orphan node detector (knowledge/belief without owner NPC)
- [ ] invalid world_day ordering detector

## 9) Time Control and Branching

- [x] Checkpoints at deterministic intervals and key events.
- [x] Branch creation from any checkpoint with immutable lineage links.
- [x] Fast-forward uses deterministic batch stepping only.
- [x] Rewind restores checkpoint + deterministic replay of events.
- [x] Branch diff tools include:
- [x] population delta
- [x] resource delta
- [x] belief divergence
- [x] culture continuity score delta

## 10) Presentation Layer (Minimal but Inspectable)

- [ ] Terrain overlay toggles: height, water, biome, resource density.
- [ ] Settlement overlay: huts, hearth, storage, paths, sacred sites.
- [ ] NPC overlay: role, task, carried resources, fatigue.
- [ ] Cultural overlay: current ritual state, taboo violations, oral knowledge coverage.
- [ ] Truth vs belief inspector panel for selected NPC/claim.

### 10.1 Scene and Visual Composition (Godot Primitives)

- [ ] Create core world scene `AgesWorld.tscn` with:
- [ ] `Node3D` root + simulation controller node.
- [ ] `TerrainRoot` (`Node3D`) for generated terrain meshes/chunks.
- [ ] `WaterRoot` (`Node3D`) for river/stream geometry.
- [ ] `SettlementRoot` (`Node3D`) for huts, storage, hearth, sacred markers.
- [ ] `VillagerRoot` (`Node3D`) for NPC entities.
- [ ] `DebugOverlayRoot` (`Node3D`) for path/resource/claim visualization.
- [ ] Terrain collision uses `StaticBody3D` + `CollisionShape3D`/heightfield-compatible setup.
- [ ] Water uses simple mesh + optional `Area3D` for interaction zones (not full fluid sim).
- [ ] Villagers use primitive capsule representation:
- [ ] `CharacterBody3D` (preferred for deterministic movement) or constrained `RigidBody3D` if needed.
- [ ] `MeshInstance3D` with `CapsuleMesh`.
- [ ] `CollisionShape3D` with `CapsuleShape3D`.
- [ ] Buildings are primitive neolithic placeholders:
- [ ] Huts: `StaticBody3D` + `MeshInstance3D` using `BoxMesh` (or low-poly hut mesh later).
- [ ] Storage pit/shed: `StaticBody3D` + `BoxMesh`/`CylinderMesh`.
- [ ] Hearth/common fire: `StaticBody3D` marker + simple emissive mesh/particle (optional).
- [ ] Sacred sites: primitive stones/markers (`BoxMesh`/`CylinderMesh`) with clear visual tag.
- [ ] Path visuals:
- [ ] Mesh strips or decals along path graph.
- [ ] Optional color intensity from usage heat.
- [ ] Visual path thickness/intensity reflects heat and recent usage decay.
- [ ] Material palette remains intentionally simple and readable:
- [ ] Terrain by biome tint.
- [ ] Water by flow class tint.
- [ ] Villager role color accents.
- [ ] Cultural state highlights (ritual active, taboo zones, conflict markers).
- [ ] Keep scene graph shallow and deterministic:
- [ ] One controller per domain (environment, settlement, villagers, UI overlay).
- [ ] No hidden per-frame random visual jitter in simulation-critical nodes.
- [ ] Add visual debug toggles:
- [ ] collision shapes
- [ ] path graph
- [ ] resource nodes
- [ ] belief-truth conflict markers over NPCs

### 10.2 Scene File Checklist and Naming

- [x] `addons/local_agents/scenes/simulation/AgesWorld.tscn` (root composition scene).
- [x] `addons/local_agents/scenes/simulation/environment/TerrainChunk.tscn` (terrain tile/chunk primitive).
- [x] `addons/local_agents/scenes/simulation/environment/WaterSegment.tscn` (river/stream segment visual + optional area).
- [x] `addons/local_agents/scenes/simulation/settlement/HutPrimitive.tscn` (cube-based hut placeholder).
- [x] `addons/local_agents/scenes/simulation/settlement/StoragePrimitive.tscn` (storage pit/shed primitive).
- [x] `addons/local_agents/scenes/simulation/settlement/HearthPrimitive.tscn` (common fire marker).
- [x] `addons/local_agents/scenes/simulation/settlement/SacredSitePrimitive.tscn` (ritual marker stones).
- [x] `addons/local_agents/scenes/simulation/actors/VillagerCapsule.tscn` (capsule NPC body).
- [x] `addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.tscn` (small green capsule edible plant primitive).
- [x] `addons/local_agents/scenes/simulation/actors/RabbitSphere.tscn` (white sphere rabbit primitive).
- [x] `addons/local_agents/scenes/simulation/debug/DebugOverlay.tscn` (path/resource/claims overlays).
- [x] `addons/local_agents/scenes/simulation/ui/SimulationHud.tscn` (play/pause/ff/rewind/branch controls).

Naming rules:
- [ ] Scene files use `PascalCase.tscn`.
- [ ] Script files use matching `PascalCase.gd` or existing project style where required.
- [ ] Root node names match scene name (`HutPrimitive` root in `HutPrimitive.tscn`).
- [ ] Generated runtime instances use stable ids in names (`Hut_<id>`, `Villager_<npc_id>`).

### 10.3 Node Composition and Organization Rules

Ownership and boundaries:
- [ ] One controller node per domain under `AgesWorld`:
- [ ] `EnvironmentController`
- [ ] `SettlementController`
- [ ] `VillagerController`
- [ ] `CultureController`
- [x] `EcologyController` (plants, rabbits, smell propagation/debug).
- [ ] `SimulationHud` scene/controller pair
- [ ] Domain controllers own child visuals and are the only nodes allowed to create/destroy those visuals.
- [ ] Cross-domain coordination flows through `SimulationController` mediator (signal up, call down).

Composition rules:
- [ ] Keep scene trees shallow: avoid deep nesting beyond what transform grouping requires.
- [ ] Separate runtime state from visual node state:
- [ ] Runtime state lives in custom `Resource` and graph records.
- [ ] Scene nodes reflect state, never become source-of-truth.
- [ ] No business logic in anonymous scene callbacks.
- [ ] No randomization in `_process` for simulation-critical nodes.

Node type defaults:
- [ ] Terrain/buildings/sacred markers default to `StaticBody3D` + `CollisionShape3D` + `MeshInstance3D`.
- [ ] Villagers default to `CharacterBody3D` capsules for deterministic movement.
- [ ] Use `Area3D` for interaction zones (water access, taboo region, ritual radius), not physics hacks.
- [ ] Use `Marker3D` spawn points for deterministic placement previews/debug.

Signals and updates:
- [ ] Child primitive nodes emit intent/events upward only (interaction entered, clicked, etc.).
- [ ] Domain controller applies authoritative state updates and pushes transforms/material state downward.
- [ ] Visual refresh is tick-driven or event-driven, not polling-heavy per frame.

Organization and reuse:
- [ ] Shared primitive materials in a dedicated simulation material folder.
- [ ] Shared mesh/shape setup encapsulated in primitive scenes, not duplicated in world scene.
- [ ] Use instance scenes for repeated structures/NPCs; avoid ad-hoc dynamic node assembly when a reusable scene exists.

Debug and inspector discipline:
- [ ] Debug overlay nodes remain separate from gameplay collision nodes.
- [ ] Every spawned villager/structure has inspectable metadata id on node (`npc_id`, `structure_id`).
- [ ] Add optional label billboards only in debug mode to avoid visual clutter.

### 10.4 Ecology and Smell Slice (Current Branch Scope)

- [x] Add edible plant actors that render as small thin green capsules.
- [x] Plant growth progresses slowly over time and gates edible state.
- [x] Rabbit actors render as white spheres and move by explicit state.
- [x] Rabbits use smell to seek food and consume edible plants.
- [x] Seed propagation occurs through rabbit digestion (`eat -> digest -> poop -> spawn plants`).
- [x] Any living entity can emit smell by joining `living_smell_source` and exposing `get_smell_source_payload()`.
- [x] Smell debug visualization can be toggled through debug overlay visibility flags.
- [x] Core simulation smell/wind fields run on shared sparse voxel grid primitives (no active hex runtime path).
- [x] Temperature debug can be visualized as translucent voxel overlays using blue-to-red spectrum.
- [x] Debug UI supports per-layer smell selection and independent smell/wind/temperature toggles.
- [x] Smell clouds decay over time and decay faster with rain intensity.
- [x] Smell clouds move with wind direction + wind intensity when wind is enabled.
- [x] Rabbits move slowly while foraging and switch to fast flee movement under perceived danger smells.

## 11) Data Model and Resources Checklist

### 11.1 Environment Resources
- [ ] `WorldTileResource` (height/moisture/temp/biome/water/flood risk).
- [ ] `WaterNetworkResource` (nodes, segments, flow, seasonality).
- [ ] `ResourceNodeResource` (type, yield curve, regeneration profile).
- [ ] `RegionPartitionResource` (Voronoi cell id + blended boundary weights).
- [ ] `WorldGenConfigResource` (noise scales/octaves/seed domains/thresholds).
- [ ] `HydrologyConfigResource` (flow rules, river thresholds, floodplain parameters).
- [ ] `TerrainTraversalProfileResource` (brush density, slope factor, water crossing cost, biome speed multipliers).

### 11.2 Settlement Resources
- [x] `SettlementAnchorResource` (water/hearth/storage/sacred markers).
- [x] `PathNetworkResource` (footpaths, traversal cost, usage heat).
- [x] `StructureStateResource` (hut/storage/hearth lifecycle).
- [ ] `SpawnCandidateResource` (score breakdown for water-first selection debugging).
- [x] `SettlementGrowthConfigResource` (expansion/abandonment thresholds).
- [x] `PathFormationConfigResource` (heat gain, creation threshold, strengthening curve, decay rate).
- [x] `PathTraversalConfigResource` (path speed bonus curve by path strength/usage).

### 11.3 Culture Resources
- [ ] `BeliefProfileResource` (core motifs, taboo sets, ritual propensity).
- [ ] `OralKnowledgeResource` (knowledge item, confidence, source lineage, last retold tick).
- [ ] `RitualStateResource` (active ritual, participants, effect windows).
- [ ] `TabooRuleResource` (rule id, trigger context, enforcement severity).
- [ ] `SacredSiteResource` (site id, type, bounds, associated taboo/ritual sets).
- [ ] `KnowledgeTransmissionConfigResource` (decay rates, reinforcement gains, drift chance).

### 11.4 Resource Usage Rules (Mandatory)
- [ ] Simulation state crossing system boundaries must use named `Resource` types, not ad-hoc dictionaries.
- [ ] Snapshot payload assembly may output dictionaries, but source-of-truth in-memory state remains resource-backed.
- [ ] Each resource class includes `to_dict()` and (where applicable) `from_dict()` with bounds validation.
- [ ] Resource schemas include explicit version field for migration-safe evolution where long-lived persistence is expected.
- [ ] Load-order-sensitive references use `preload` patterns to keep headless parse stable.

### 11.5 Graph Usage Rules (Mandatory)
- [ ] Every new graph-backed feature adds:
- [ ] space constants
- [ ] upsert/read APIs
- [ ] contradiction/integrity checks
- [ ] cypher playbook entries
- [ ] tests covering write + recall + conflict paths
- [ ] Graph writes from simulation ticks are deterministic and idempotent by label/claim key strategy.
- [ ] Graph node labels include stable composite keys (`world/branch/entity/tick`) where replay safety requires uniqueness.

### 11.6 Master Configuration Resource (Single Source of Truth)
- [ ] Create `NeolithicSimConfigResource` as the top-level run config.
- [ ] It references all sub-config resources:
- [ ] worldgen/hydrology/voronoi config
- [ ] traversal/path formation/path traversal config
- [ ] settlement growth and spawn scoring config
- [ ] economy and carry config
- [ ] culture/belief/oral transmission config
- [ ] LLM request profiles and scheduler config
- [ ] Add config versioning + run metadata fields:
- [ ] `schema_version`
- [ ] `world_seed`
- [ ] `branch_seed_strategy`
- [ ] `llm_profile_version`
- [ ] `simulation_profile_id`
- [ ] Every deterministic test fixture records the exact `NeolithicSimConfigResource` identity/hash used.

## 12) Testing Matrix

### 12.1 Determinism
- [ ] Same-seed replay hash equality over 30 days.
- [ ] Branch divergence deterministic under fixed fork decisions.
- [ ] Stable ordering tests for map gen, economy loops, and graph writes.

### 12.2 Environment
- [ ] River flow validity tests (downhill monotonicity constraints).
- [ ] Spawn scoring tests guarantee top candidates favor reliable water.
- [ ] Voronoi hybrid mode snapshot tests.

### 12.3 Simulation Behavior
- [ ] Village survives baseline scenario without starvation collapse.
- [ ] Resource depletion triggers path extension or adaptation.
- [ ] Carry constraints enforce realistic movement limits.
- [x] Emergent trails appear on high-traffic routes and decay when traffic drops.
- [x] Movement speed profile test passes:
- [x] Path route travel time < brush route travel time for same distance.
- [x] High brush + slope routes are correctly penalized.

### 12.4 Culture and Cognition
- [ ] Oral transfer raises youth knowledge confidence deterministically.
- [ ] Knowledge decay occurs without retelling reinforcement.
- [ ] Belief-truth conflict case test (paternity mismatch style).
- [ ] Ritual/taboo effects measurable in behavior logs.
- [ ] Oral lineage reconstruction test (knowledge provenance chain is queryable and stable).
- [ ] Knowledge drift bounds test (motif preserved while detail mutation allowed).
- [ ] Oral lineage idempotency test (re-upsert + re-link produce the same ancestor chain).
- [ ] Sacred site + ritual writes remain deterministic and surface through `ritual_event_participants` and `sacred_site_taboo_log`.

### 12.5 Runtime/CI
- [ ] Core headless suite for deterministic fast checks.
- [ ] Runtime-heavy suite with local model validates no dependency/empty-generation errors.
- [ ] CI artifact capture for branch diff failures and hash mismatches.
- [ ] CI checks for graph/resource schema regressions (playbook keys and resource field contracts).

## 13) Parallel Sub-Agent Implementation Plan

This work is designed for parallel execution with strict ownership boundaries.

### 13.1 Agent A: Environment Core
Ownership:
- [ ] `addons/local_agents/simulation/worldgen/*`
- [ ] environment resources under `configuration/parameters/simulation/`
Responsibilities:
- [ ] noise maps, hydrology, biome classification, Voronoi hybrid partition.
Deliverables:
- [ ] deterministic worldgen APIs + tests + baseline fixtures.

### 13.2 Agent B: Settlement and Growth
Ownership:
- [ ] settlement seeding and growth controllers/services.
Responsibilities:
- [ ] water-first spawn scoring, anchors, hut/path growth loops.
Deliverables:
- [ ] growth rules + tests for survivability and expansion.

### 13.3 Agent C: Economy and Logistics
Ownership:
- [ ] economy/ledger/carry systems.
Responsibilities:
- [ ] subsistence throughput tuning, carry-path routing, failure semantics.
Deliverables:
- [ ] economy balancing harness + deterministic regression tests.

### 13.4 Agent D: Graph Truth/Belief/Culture
Ownership:
- [ ] graph services + culture resources + cypher docs.
Responsibilities:
- [ ] truths/beliefs, oral transmission graph records, conflict queries, playbook expansion.
Deliverables:
- [ ] schema/API/query suite + documentation updates.

### 13.5 Agent E: Cognition Integration
Ownership:
- [ ] dream/thought/dialogue services and simulation controller cognition hooks.
Responsibilities:
- [ ] inject belief/culture context into prompts, preserve labeling semantics.
Deliverables:
- [ ] prompt contracts + runtime-heavy cognition tests.

### 13.6 Agent F: UI + Timeline Tools
Ownership:
- [ ] simulation HUD, inspectors, branch diff views.
- [ ] `addons/local_agents/scenes/simulation/*` scene composition and visual controller wiring.
Responsibilities:
- [ ] controls and minimal visualization for debugging and demo.
Deliverables:
- [ ] inspectable vertical slice UI with branch comparisons.

### 13.7 Agent G: CI/Quality
Ownership:
- [ ] test harnesses and workflows.
Responsibilities:
- [ ] deterministic gates, runtime-heavy health checks, artifact policy.
Deliverables:
- [ ] CI gates aligned to vertical slice done criteria.

### 13.8 Integration Rules
- [ ] Each agent works in scoped commits with explicit file ownership.
- [ ] Shared contracts (resource schemas and graph payload fields) are versioned and reviewed first.
- [ ] Before phases begin, a planning sub-agent issues decomposition + coupling-risk recommendations for integration order.
- [ ] Shared contracts are published as canonical docs before cross-agent merges:
- [ ] resource schema table
- [ ] graph node/edge field table
- [ ] cypher playbook key index
- [ ] Merge order:
- [ ] A + D foundations first.
- [ ] B + C next.
- [ ] E then F.
- [ ] G hardening last but can scaffold early.
- [ ] No agent introduces fallback paths for required dependencies.

## 14) Contract Tables (Initial)

Published artifact: `docs/VERTICAL_SLICE_CONTRACT_TABLES.md`

### 14.1 Resource Schema Table

| Resource | Purpose | Required Fields | Deterministic Notes |
|---|---|---|---|
| `WorldGenConfigResource` | Noise/hydrology generation config | `schema_version`, `seed_domain`, `elevation_noise`, `moisture_noise`, `temperature_noise`, `voronoi_mode` | Config is hash-included; changing values changes world deterministically. |
| `HydrologyConfigResource` | River/flow model params | `schema_version`, `source_threshold`, `flow_accumulation_threshold`, `floodplain_radius`, `seasonality_factor` | Must not read runtime clock; seasonal changes are tick/day derived only. |
| `WorldTileResource` | Per-tile environment state | `schema_version`, `tile_id`, `elevation`, `moisture`, `temperature`, `biome`, `water_class`, `flood_risk` | `tile_id` ordering must be stable for hashing/serialization. |
| `WaterNetworkResource` | Water graph topology | `schema_version`, `nodes`, `segments`, `total_flow_index` | Node/segment arrays sorted by id before hashing. |
| `ResourceNodeResource` | Gatherable material source | `schema_version`, `node_id`, `resource_type`, `yield_rate`, `regen_rate`, `depletion`, `position` | Regeneration/depletion updated only in tick loop. |
| `RegionPartitionResource` | Voronoi/hybrid partition metadata | `schema_version`, `region_id`, `site_position`, `boundary_weight` | Deterministic site seeds only. |
| `SpawnCandidateResource` | Water-first spawn scoring | `schema_version`, `candidate_id`, `position`, `score_total`, `score_breakdown` | Score breakdown is persisted for reproducible debugging. |
| `SettlementAnchorResource` | Core village anchors | `schema_version`, `anchor_id`, `anchor_type`, `position`, `household_id` | Anchor ids are stable composite labels. |
| `PathNetworkResource` | Footpath graph | `schema_version`, `nodes`, `edges`, `usage_heat` | Edges sorted by `(from,to)` before serialization. |
| `StructureStateResource` | Hut/storage/hearth lifecycle | `schema_version`, `structure_id`, `structure_type`, `state`, `position`, `durability` | State transitions are explicit events. |
| `SettlementGrowthConfigResource` | Expansion/abandon thresholds | `schema_version`, `expand_threshold`, `abandon_threshold`, `max_distance_from_water` | Pure config; no mutable runtime state. |
| `BeliefProfileResource` | NPC cultural disposition | `schema_version`, `npc_id`, `motifs`, `taboo_ids`, `ritual_propensity` | Updates via deterministic social events. |
| `OralKnowledgeResource` | Spoken tradition unit | `schema_version`, `knowledge_id`, `category`, `content`, `confidence`, `source_npc_id`, `lineage`, `last_retold_tick` | Drift and decay are seeded and bounded. |
| `RitualStateResource` | Ritual runtime state | `schema_version`, `ritual_id`, `site_id`, `participants`, `start_tick`, `end_tick`, `effects` | Participant ordering sorted by npc_id. |
| `TabooRuleResource` | Behavioral restrictions | `schema_version`, `taboo_id`, `trigger_context`, `prohibited_action`, `severity` | Enforcement effects deterministic by rule id + tick. |
| `SacredSiteResource` | Spiritual map anchor | `schema_version`, `site_id`, `site_type`, `position`, `radius`, `taboo_ids` | Used in settlement desirability and ritual triggers. |
| `KnowledgeTransmissionConfigResource` | Oral transfer tuning | `schema_version`, `decay_rate`, `reinforcement_gain`, `drift_chance`, `motif_retention_floor` | Drift chance seeded per transmission event. |

### 14.2 Graph Node/Edge Field Table

| Entity | Kind | Required Fields | Required Links |
|---|---|---|---|
| `truth` | Node | `type=truth`, `truth_id`, `claim_key`, `subject_id`, `predicate`, `object_value`, `object_norm`, `world_day`, `confidence`, `metadata`, `updated_at` | Optional `NPC -[:HAS_TRUTH]-> Truth` when `subject_id` is NPC. |
| `belief` | Node | `type=belief`, `belief_id`, `npc_id`, `claim_key`, `subject_id`, `predicate`, `object_value`, `object_norm`, `world_day`, `confidence`, `metadata`, `updated_at` | `NPC -[:HAS_BELIEF]-> Belief`. |
| `oral_knowledge` | Node | `type=oral_knowledge`, `knowledge_id`, `npc_id`, `category`, `content`, `confidence`, `motifs`, `world_day`, `updated_at` | `NPC -[:HAS_ORAL_KNOWLEDGE]-> OralKnowledge`. |
| `ritual_event` | Node | `type=ritual_event`, `ritual_id`, `site_id`, `world_day`, `participants`, `effects`, `updated_at` | `NPC -[:PARTICIPATED_IN]-> RitualEvent`, `RitualEvent -[:AT_SITE]-> SacredSite`. |
| `sacred_site` | Node | `type=sacred_site`, `site_id`, `site_type`, `position`, `taboo_ids`, `metadata`, `updated_at` | `Structure/Anchor -[:NEAR_SITE]-> SacredSite` (optional). |
| `knowledge_lineage` | Edge | `type=knowledge_lineage`, `source_knowledge_id`, `target_knowledge_id`, `speaker_npc_id`, `listener_npc_id`, `transmission_hops`, `world_day` | `OralKnowledge -[:DERIVES_FROM]-> OralKnowledge`. |
| `belief_ref` | Edge | `type=belief_ref`, `npc_id`, `belief_id`, `claim_key` | `NPC -[:HAS_BELIEF]-> Belief`. |
| `truth_ref` | Edge | `type=truth_ref`, `subject_id`, `predicate`, `claim_key` | `NPC -[:HAS_TRUTH]-> Truth` (if NPC subject). |
| `taboo_violation` | Edge/Event | `type=taboo_violation`, `npc_id`, `taboo_id`, `site_id`, `world_day`, `severity` | `NPC/Event` linkage to enable auditing and social consequences. |

### 14.3 Cypher Playbook Key Index

| Key | Category | Intent | Min Params | Expected Output |
|---|---|---|---|---|
| `upsert_npc` | write | Create/update NPC node | `npc_id`, `name` | NPC node |
| `upsert_memory_and_link` | write | Memory + ownership edge | `npc_id`, `memory_id`, `summary` | NPC, edge, memory |
| `relationship_state` | read | Relationship profile + aggregates | `source_npc_id`, `target_npc_id`, `world_day` | profile + recent stats |
| `npc_backstory_context` | read | Consolidated NPC context | `npc_id`, `world_day`, `limit` | relationships/memories/states |
| `recent_relationship_events` | read | Pairwise social event timeline | `source_npc_id`, `target_npc_id`, `window_start` | event rows |
| `quest_state_timeline` | read | Quest progression | `npc_id`, `limit` | quest state rows |
| `exclusive_membership_conflicts` | integrity | Contradiction scan | `limit` | conflicting NPC rows |
| `post_death_activity` | integrity | Impossible activity scan | `npc_id`, `world_day` | violation rows |
| `memory_recall_candidates` | read | Prompt grounding memories | `npc_id`, `limit` | ranked memory rows |
| `truths_for_subject` | read | Canonical claims | `subject_id`, `world_day`, `limit` | truth rows |
| `beliefs_for_npc` | read | NPC belief claims | `npc_id`, `world_day`, `limit` | belief rows |
| `belief_truth_conflicts` | conflict | Belief vs truth mismatch | `npc_id`, `world_day`, `limit` | conflict rows |
| `oral_knowledge_for_npc` | read | NPC oral repertoire | `npc_id`, `world_day`, `limit` | oral knowledge rows |
| `oral_transmission_timeline` | read | Knowledge handoff chain | `knowledge_id` or `npc_id`, `limit` | lineage rows |
| `ritual_event_participants` | read | Ritual events featuring an NPC | `npc_id`, `world_day`, `limit` | ritual rows |
| `sacred_site_ritual_history` | read | Ritual events by site | `site_id`, `world_day`, `limit` | ritual rows |
| `sacred_site_taboo_log` | read | Taboo associations for a site | `site_id` | taboo id lists |
| `taboo_violation_log` | integrity | Cultural rule breaches | `npc_id` or `site_id`, `world_day`, `limit` | violation rows |
| `orphan_belief_nodes` | integrity | Beliefs lacking owner edge | `limit` | orphan node ids |
| `duplicate_claim_key_scan` | integrity | Duplicate/conflicting canonical truths | `limit` | claim collision rows |
| `invalid_world_day_ordering` | integrity | Temporal ordering errors | `limit` | broken lineage rows |

## 15) Phased Execution Plan (Incremental Test Slices)

This section breaks delivery into small, testable slices.  
Canonical checklist ownership remains in Sections 1-17; phases reference those items without removing any.

### 15.1 Phase 0: Baseline Lock (Very Fast Validation)
- [ ] Freeze current baseline behavior and hash fixtures (Sections 0, 2.3, 12.1).
- [ ] Confirm current scene skeletons load and remain parse-clean (Sections 10.2, 10.3).
- [ ] Confirm existing graph truth/belief APIs and tests remain green (Sections 7, 12.4, 12.5).
Test slice:
- [ ] Run core headless suite and parse check; verify no regression before new worldgen work.

### 15.2 Phase 1: Environment Core (No Settlement Yet)
- [ ] Implement worldgen configs/resources and deterministic terrain maps (Sections 3.1, 11.1, 11.4).
- [ ] Implement hydrology and water reliability scoring (Sections 3.2, 11.1).
- [ ] Implement initial Voronoi+noise partition pass (Section 3.4).
Test slice:
- [ ] Environment snapshot/hash tests pass for fixed seeds (Sections 12.1, 12.2).
- [ ] Visual sanity scene shows terrain + water overlays only (Section 10).

### 15.3 Phase 2: Water-First Spawn + Primitive Settlement Seed
- [ ] Implement spawn candidate scoring and selection resources (Sections 4.1, 11.2).
- [ ] Place minimal anchors (water/hearth/storage/huts) and starter footpaths (Sections 4.2, 10.1).
- [ ] Persist spawn rationale into debug/graph artifacts (Sections 7.5, 8, 14.2).
Test slice:
- [ ] Deterministic spawn test confirms chosen origin favors reliable water (Section 12.2).
- [ ] Manual visual check: one seeded neolithic settlement appears and is stable across replay.

### 15.4 Phase 3: Subsistence Loop (Survival First)
- [ ] Connect environmental yields to production/consumption (Sections 5.1, 5.2).
- [ ] Implement carry/path logistics and partial delivery semantics (Sections 5.3, 10.1).
- [ ] Add hut growth/abandon rules based on survival utility (Section 4.3).
Test slice:
- [ ] 5-10 day simulation survives baseline scenario (Section 12.3).
- [ ] Carry constraints and non-negative ledger invariants validated (Sections 2, 12.3).

### 15.5 Phase 4: Beliefs, Truths, and Social Cognition Depth
- [ ] Complete truth/belief contradiction flows and conflict severity handling (Sections 7.2, 7.4).
- [ ] Expand cognition prompts and scheduler behavior under deterministic ordering (Sections 7.3, 17.4, 17.7).
- [ ] Expand cypher templates and integrity queries for belief/truth model (Section 8, 14.3).
Test slice:
- [ ] Belief-truth conflict cases alter NPC dialogue/action choices (Sections 1.3, 12.4).
- [ ] Deterministic replay still matches hash fixtures under cognition load (Sections 2, 12.1).

### 15.6 Phase 5: Oral Tradition + Tribal Belief Layer
- [ ] Implement oral knowledge graph spaces and lineage edges (Sections 6.3, 7.1, 14.2).
- [ ] Implement sacred sites/taboos/ritual events and their behavioral effects (Sections 6.2, 7.1).
- [ ] Add culture resources and transmission configs (Sections 11.3, 14.1).
Test slice:
- [ ] Oral transfer, confidence decay, and motif-preserving drift tests pass (Section 12.4).
- [ ] Taboo/ritual event logs queryable via playbook keys (Sections 8, 14.3).
- [ ] Oral lineage idempotency + ancestry reconstruction verifiable via `oral_transmission_timeline` (Sections 8, 12.4, 14.3).
- [ ] Sacred site rituals + taboo sets remain deterministic and visible through `ritual_event_participants`/`sacred_site_taboo_log` (Sections 8, 14.3).

### 15.7 Phase 6: Timeline Controls + Branching Universes
- [ ] Finalize checkpoint/fork/replay mechanics and diff tooling (Section 9).
- [ ] Ensure graph and resource snapshots remain branch-safe and deterministic (Sections 2.3, 11.4, 11.5).
Test slice:
- [ ] Create branch at fixed tick, diverge decisions, confirm deterministic diffs (Sections 9, 12.1).

### 15.8 Phase 7: `llama.cpp-server` Production Hardening
- [x] Finalize server lifecycle, pinning, profiles, and request contracts (Sections 17.1-17.3).
- [x] Enforce context budgets, pruning, KV/cache isolation, and evidence trace persistence (Sections 17.4-17.9).
- [x] Add and enforce runtime-heavy CI checks for dependency/empty-generation/isolation failures (Sections 12.5, 17.10).
Test slice:
- [x] Parallel cognition runs complete without KV bleed; evidence traces are stored and replay-auditable.

### 15.9 Phase 8: Demo-Ready Vertical Slice
- [x] Complete minimal HUD/inspector workflows and debug overlays (Sections 10, 13.6).
- [x] Verify done criteria across a 30-day seeded run (Section 1.3).
- [x] Final docs pass: schema table, graph field table, playbook keys aligned to implementation (Section 14).
Test slice:
- [x] End-to-end run: generate world, seed settlement, survive/grow, show culture effects, fork timeline, inspect graph evidence.

## 16) Non-Negotiable Defaults

- [ ] Graph-first and Resource-first implementation bias.
- [ ] Cypher playbook must expand with graph schema evolution.
- [ ] Deterministic behavior prioritized over feature complexity.
- [ ] No local fallback execution paths for required runtime dependencies.
- [ ] Headless-safe tests for all core simulation logic.

## 17) LLM Runtime + Graph Recall Contract

### 17.1 Runtime Mode Decision
- [x] Primary inference backend for the vertical slice is `llama.cpp-server` (not ad-hoc mixed modes).
- [x] `AgentRuntime` calls are treated as orchestration wrappers around server-backed inference, not a separate fallback behavior.
- [x] Server lifecycle manager is defined (start, health-check, restart, shutdown) with explicit errors surfaced to simulation/UI.

### 17.2 Version and Capability Pinning
- [ ] Pin exact `llama.cpp` server revision/build in scripts and docs.
- [x] Record enabled capabilities used by this project (parallel requests, speculative decoding, batching).
- [x] Add runtime startup report including version, flags, context size, and thread/gpu settings.

### 17.3 Deterministic Request Contract
- [x] Every request includes deterministic fields:
- [x] `seed`
- [x] `temperature`
- [x] `top_p`
- [x] `max_tokens`
- [x] `stop`
- [x] `reset_context`
- [x] `cache_prompt`
- [x] Define per-task generation profiles:
- [x] narrator direction
- [x] internal thought
- [x] dialogue exchange
- [x] dream generation
- [x] oral transmission utterance
- [x] Keep profile constants in versioned config resources, not scattered literals.

### 17.4 Graph Recall Pipeline (Exact Order)
- [x] Define fixed retrieval order per generation task:
- [x] 1) villager state/resource snapshot
- [x] 2) high-salience waking memories
- [x] 3) dream memories (explicitly labeled uncertain)
- [x] 4) beliefs
- [x] 5) belief-truth conflicts
- [x] 6) role/household/economic context
- [x] 7) oral knowledge and ritual/taboo context (when implemented)
- [x] Retrieval merge/sort is deterministic (stable key ordering + explicit scoring).
- [x] Context assembler emits canonical JSON shape with schema version.

### 17.5 Token Budget and Context Pruning
- [x] Set hard token budgets per context section (state, memories, beliefs, conflicts, culture).
- [x] Use deterministic truncation rules (importance then recency then id order).
- [x] Reject oversize payloads with explicit errors; do not silently mutate contract behavior.

### 17.6 KV/Cache Isolation and Parallel Safety
- [x] Enforce per-request/per-NPC context isolation for internal thought/dialogue/dream generation.
- [x] No bleed-over of conversational KV cache between NPCs.
- [ ] If server session reuse is used, session affinity policy is explicit and deterministic.
- [x] `reset_context` default is task-specific and documented.
- [x] Prompt-cache reuse is opt-in per task and disabled where contamination risk exists.

### 17.7 Scheduling and Throughput
- [x] Define deterministic generation scheduler:
- [x] stable NPC ordering
- [x] stable dialogue pairing order
- [x] bounded generations per tick
- [x] deferred queue policy for overflow
- [ ] Document speculative decoding usage constraints and expected behavior under load.

### 17.8 Failure Policy (Fail-Fast)
- [x] On server unavailable/timeout/model-not-loaded, simulation emits explicit dependency errors and halts affected phase.
- [x] No fallback to synthetic/local stub outputs for required cognition features.
- [x] Retry behavior is bounded and deterministic (fixed retry count/backoff policy).

### 17.9 Evidence Trace and Auditability
- [x] Persist generation evidence trace for each LLM output:
- [x] query keys used
- [x] referenced graph node ids/claim ids
- [x] prompt profile id
- [x] seed and sampler params
- [x] Store trace in graph/event logs for replay debugging.

### 17.10 LLM/Graph Test Requirements
- [x] Deterministic replay test for server-backed generation with fixed seed profiles.
- [x] KV isolation test: two NPCs generating concurrently must not share context artifacts.
- [x] Recall pipeline test: expected sections present in canonical order.
- [x] Empty-generation and dependency-error CI guards remain mandatory.

## 18) Local LLM Enrichment Plan (Richer Simulation Experience)

### 18.1 Role-Specialized Generation Profiles
- [ ] Define separate LLM prompt/profile templates by social role:
- [ ] elder
- [ ] hunter
- [ ] gatherer
- [ ] crafter
- [ ] caregiver
- [ ] narrator/director
- [ ] Profiles differ in tone, risk bias, knowledge salience, and ritual/taboo sensitivity.
- [ ] Profiles are stored in config resources and versioned (`llm_profile_version`).

### 18.2 Event-Driven Narrative Generation
- [ ] Trigger rich generation on meaningful events instead of every tick:
- [ ] scarcity spike
- [ ] taboo violation
- [ ] ritual completion/failure
- [ ] major belief-truth reveal
- [ ] migration/settlement shift
- [ ] Keep low-impact ticks lightweight (no unnecessary generation spam).

### 18.3 Rumor and Oral Retelling Generation
- [ ] Add spoken retelling generation events (`speaker -> listener -> claim/knowledge`).
- [ ] Generate controlled detail drift while preserving core motifs.
- [ ] Persist transmission lineage (`source`, `hops`, `confidence shift`) in graph.
- [ ] Add repeat-reinforcement effects for frequently retold knowledge.

### 18.4 Belief-Aware Intent Suggestions
- [ ] LLM proposes intent options based on current belief/knowledge context.
- [ ] Deterministic simulation layer remains final decision authority.
- [ ] Intent schema includes:
- [ ] `intent_type`
- [ ] `target`
- [ ] `reasoning_summary`
- [ ] `belief_dependencies`
- [ ] `confidence`

### 18.5 Memory Condensation and Folk Narrative Layers
- [ ] Periodically summarize raw memories into compact narrative layers:
- [ ] practical lessons (survival knowledge)
- [ ] social stories (trust/betrayal/kinship)
- [ ] mythic stories (ritual/omen motifs)
- [ ] Keep condensed summaries as first-class graph entities referenced by future prompts.

### 18.6 Cultural Pressure and Tribe-Level Mood
- [ ] Generate tribe-level “cultural weather” outputs (omens, tensions, cohesion mood).
- [ ] Apply bounded, deterministic effect windows (e.g., N ticks) to behavior weights.
- [ ] Tie shifts to environment/economy signals to avoid arbitrary narrative swings.

### 18.7 Parallel Inference Lanes
- [ ] Define separate logical inference lanes/sessions:
- [ ] narrator lane
- [ ] npc cognition lane
- [ ] ritual/oral tradition lane
- [ ] Keep strict context/KV isolation between lanes.
- [ ] Add deterministic scheduling priority for lane execution under load.

### 18.8 Player-Facing Story Contrast (Truth vs Belief)
- [ ] UI/inspectors show side-by-side:
- [ ] what happened (truth/evidence)
- [ ] what NPCs think happened (belief spread)
- [ ] Provide provenance drill-down (who told whom, when confidence changed).

### 18.9 Quality and Safety Gates for Rich Generation
- [ ] Add validation checks on generated outputs:
- [ ] non-empty text
- [ ] required labels (`is_dream`, `is_factual`, claim provenance tags)
- [ ] contract-compliant JSON shape where structured output is required
- [ ] Add CI/runtime-heavy assertions for:
- [ ] no empty-generation
- [ ] no dependency fallback usage
- [ ] stable evidence trace persistence
- [ ] no cross-NPC context contamination

### 18.10 Heuristic-First Dialogue and Behavior (LLM Budget Control)
- [ ] Implement a heuristic/rule layer for routine low-value interactions:
- [ ] greetings
- [ ] farewells
- [ ] simple acknowledgements
- [ ] repeated transactional phrases (basic handoff confirmations)
- [ ] Add per-NPC learned micro-heuristics from repeated outcomes (deterministic updates):
- [ ] preferred greeting style by relationship context
- [ ] route-choice shortcuts for common errands
- [ ] basic taboo-safe defaults in sacred zones
- [ ] Add explicit LLM trigger policy:
- [ ] Use heuristic path by default for routine interactions.
- [ ] Trigger LLM only for novel/high-uncertainty/high-impact situations.
- [ ] Trigger LLM when heuristic confidence is below threshold.
- [ ] Persist heuristic confidence and last-update metadata in resource/graph state.
- [ ] Add safeguards to avoid heuristic lock-in:
- [ ] periodic reevaluation windows
- [ ] fallback to LLM for unresolved repeated failures
- [ ] disagreement checks when beliefs/truth conflicts intensify
- [ ] Add metrics and tests:
- [ ] `% interactions resolved by heuristics vs LLM`
- [ ] response quality floor checks for heuristic outputs
- [ ] deterministic behavior tests for heuristic learning updates
