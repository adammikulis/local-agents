# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.

## Operating Rules

- [x] Use concern-based workstreams instead of role roster ownership.
- [x] Keep `AGENTS.md` as the canonical engineering rules file.
- [x] Prefer additive changes and small, reviewable diffs.
- [x] Signal up and call down (mediator orchestration) for cross-system flows.
- [x] Record breaking API/schema changes in this file before merge.
- [x] Keep memory/graph implementation out of this execution stream when separately owned.

## Concern A: Runtime and GDExtension Stability

Scope: `addons/local_agents/gdextensions/localagents/`, `addons/local_agents/runtime/`, `addons/local_agents/agents/`

- [x] Lazy extension initialization path exists (`LocalAgentsExtensionLoader`, placeholder panel activation flow).
- [x] Preflight binary existence checks added before extension initialization to avoid hard crashes when dylib/so/dll is missing.
- [x] `Agent` now guards extension availability and instantiates `AgentNode` safely at runtime.
- [x] Complete end-to-end runtime initialization validation on fresh machines after dependency/build scripts run.
- [x] Add structured runtime health endpoint/API for editor and tests (extension loaded, model loaded, runtime binaries found).
- [x] Add JSON grammar/options coverage in `AgentRuntime` generation path.

Sub-agent split:
- Runtime-Core: extension lifecycle, `AgentRuntime`, `AgentNode` contracts.
- Runtime-API: GDScript bridge consistency and backward-compatible error payloads.

## Concern B: Model Download and Asset Pipeline

Scope: `controllers/ModelDownloadService.gd`, `controllers/DownloadController.gd`, `api/DownloadClient.gd`, `src/ModelDownloadManager.cpp`, `scripts/fetch_dependencies.sh`, `scripts/fetch_runtimes.sh`

- [x] Runtime-side model downloading via `ModelDownloadManager` is present.
- [x] GDScript download client bridge exists (`LocalAgentsDownloadClient`).
- [x] Download tab receives runtime progress/log/finished signals.
- [x] Fixed dependency fetch path resolution bug (`fetch_dependencies.sh` repo root).
- [x] Fix stale Piper voice URLs and add fallback/continue behavior for unavailable voice artifacts.
- [x] Consolidate UI and headless download orchestration behind shared helper(s) to avoid duplicate logic.
- [x] Add checksum and manifest verification for downloaded model/voice artifacts.

Sub-agent split:
- Download-Runtime: native downloader behavior, split GGUF handling, cache behavior.
- Download-GDS: editor/service orchestration, logs, retries, UI status integration.

## Concern C: Chat, Controller Boundaries, and Scene Architecture

Scope: `controllers/ChatController.gd`, `agent_manager/AgentManager.gd`, `editor/*`, `configuration/ui/*`

- [x] Chat + Download + Configuration panel composition is present.
- [x] Null-guard fixes landed for model load and config apply flows when runtime/agent is unavailable.
- [x] Continue decomposition of oversized controllers into mediator + focused services (conversation/session/history).
- [x] Add explicit runtime state badges in Chat tab (runtime loaded/model loaded/speech ready).
- [x] Ensure editor-only and runtime-only responsibilities are separated cleanly.

Sub-agent split:
- UI-Orchestration: mediator/controller boundaries and tab interactions.
- UX-State: status visibility, recoverable error flows, disable/enable behavior.

## Concern D: Memory and Graph Capabilities

Scope: `controllers/ConversationStore.gd`, `docs/NETWORK_GRAPH.md`, future graph/memory tabs

- [x] Conversation persistence and search scaffolding exist via `NetworkGraph`.
- [ ] Finalize schema for memories/edges/episodes/embeddings and indices.
- [ ] Add embedding write pipeline and robust recall APIs (query, top-k, pagination/streaming).
- [ ] Add migration/maintenance tools (purge/export/repair).
- [ ] Implement editor Memory and Graph inspection tabs.

Sub-agent split:
- Graph-Core: schema, persistence contracts, migration safety.
- Graph-UX: memory/graph visualization and inspection workflows.

## Concern E: Speech and Transcription

Scope: `runtime/audio/SpeechService.gd`, `agents/Agent.gd`, native speech/transcription runtime hooks

- [x] Async speech/transcription service and runtime hooks are integrated.
- [x] Agent-level speech playback pipeline exists with async job callbacks.
- [x] Add deterministic smoke tests with small fixtures for speech/transcription success/failure paths.
- [x] Improve voice asset resolution/reporting in UI when assets are missing or mismatched.

Sub-agent split:
- Speech-Runtime: native process lifecycle and payload contracts.
- Speech-GDS: service orchestration, playback, and UX errors.

## Concern F: Test Strategy and CI Gating

Scope: `addons/local_agents/tests/*`, CI pipeline setup

- [x] Headless harness exists (`run_all_tests.gd`).
- [x] Heavy/runtime model helper exists (`test_model_helper.gd`).
- [x] Runtime test harness now includes explicit runtime suite paths and auto-model acquisition logic.
- [x] Finalize policy: runtime suite should fail loudly on model acquisition/inference failure unless explicitly opted out.
- [x] Wire headless tests into CI with separate jobs for core-only and runtime-heavy suites.
- [x] Add CI artifacts/log collection for failed runtime/download checks.

Sub-agent split:
- Test-Harness: harness behavior, skip/fail policy, deterministic outputs.
- CI-Infra: matrix jobs, caching, artifacts, merge gates.

## Concern G: Cross-Platform Build and Packaging

Scope: build scripts, release packaging, binary layout

- [x] macOS build script bundles local extension dependencies and llama tools.
- [x] Provide Linux/Windows parity for bundled binaries and runtime tools.
- [x] Add `build_all.sh` and reproducible packaging outputs per platform.
- [x] Add binary size/performance regression checks per release.

Sub-agent split:
- Build-Systems: platform-specific build scripts and binary staging.
- Release-Quality: packaging verification and regression tracking.

## Concern H: Demos, Docs, and Onboarding

Scope: `README.md`, examples, docs, screenshots/tutorials

- [x] Core docs and examples exist.
- [x] Update README to match current runtime-heavy test behavior and flags.
- [x] Restore/polish 3D demo parity and HUD components.
- [x] Refresh docs/screenshots/tutorials around download/runtime health workflows.

Sub-agent split:
- Demo-Scenes: examples and in-engine demo parity.
- Docs-Onboarding: quickstart accuracy and release-facing docs.

## Concern I: Voxel World Simulator Integration

Scope: `addons/local_agents/simulation/*`, `addons/local_agents/scenes/simulation/controllers/*`, `addons/local_agents/examples/WorldGenVoxelDemo.*`, shader assets

Implemented (feature inventory):
- [x] Voxel terrain generation uses deterministic 3D noise and block-layer materialization (`voxel_world.columns`, `voxel_world.block_rows`).
- [x] Generated terrain includes multiple soil/resource block categories and per-column top RGBA data for physically-based solar absorption.
- [x] Deterministic flow-map bake and hydrology consumption are unified through `flow_map.rows`.
- [x] Weather, erosion, and solar are all snapshot-driven systems with explicit configure/step/current/import contracts.
- [x] Freeze-thaw erosion and landslide events modify terrain elevation and voxel column surfaces over time.
- [x] Chunked async terrain rebuild path applies only dirty chunks when erosion updates changed tiles.
- [x] Environment rendering consumes weather/surface/solar textures in GPU shaders for terrain, water, cloud shadowing, and river flow.
- [x] World simulation controller path and world-gen demo path both drive weather + solar state into `EnvironmentController`.
- [x] Demo environment now enables volumetric fog + SDFGI with day/night sun animation for lighting continuity.

Native integration execution checklist:
- [ ] Canonical source: execute Concern I against [VOXEL_NATIVE_INTEGRATION_PLAN.md](VOXEL_NATIVE_INTEGRATION_PLAN.md) and keep this concern synchronized when phase scope changes.
- [ ] Enforce day-one hybrid storage (`dense + sparse`) in native `FieldRegistry` contracts; remove script-side canonical storage for shared simulation fields.
- [ ] Treat Vulkan compute as required baseline for native simulation compute paths; block feature completion if Vulkan path is missing.
- [ ] Preserve D3D12 backend compatibility where Godot exposes equivalent compute/render behavior; track compatibility gaps as explicit blockers.
- [ ] Use epsilon-bounded parity (not bitwise parity) as the deterministic validation contract across CPU/GPU/backend comparisons.
- [ ] Keep migration order fixed: hydrology + terrain/erosion first, smell/wind + ecology behavior layers second.
- [ ] Move full simulation ownership into native core; GDScript remains orchestration, configuration, and debug/HUD snapshot consumption only.
- [ ] Start with a native-defined simulation graph (native-first topology); avoid script-defined graph execution for integrated domains.
- [x] February 13, 2026: Added deterministic headless-native voxel op contract coverage for operation ordering counters, fallback path selection metadata, and changed-region payload shape (`test_native_voxel_op_contracts.gd`).
- [ ] Add deterministic native generalized-physics stage contract coverage for mechanics/pressure/thermal/reaction/destruction summary fields and per-domain stage counts.
- [ ] Add deterministic conservation diagnostics contract coverage ensuring per-stage (`count`, `mass_proxy_delta_sum`, `energy_proxy_delta_sum`) and overall (`stage_count`, `mass_proxy_delta_total`, `energy_proxy_delta_total`) fields are always present.
- [ ] Remaining gap: move changed-region payloads from dictionary rows (`changed_region`, `changed_regions`) to typed `Resource` contracts before native edit engine exits Phase 2.
- [ ] Remaining gap: validate native voxel op ordering/fallback contracts against non-stub GPU kernels once compute-stage registration is implemented.

Phase 1: Native infrastructure and ownership boundaries
- [ ] Add native `sim/` scaffolding for `FieldRegistry`, `Scheduler`, `ComputeManager`, and graph runtime registration in `addons/local_agents/gdextensions/localagents/`.
- [ ] Introduce script-facing runtime facade/adapters that delegate field access, cadence/locality scheduling, and dispatch lifecycle to native services.
- [ ] Migrate shared environment state contracts to typed resources/handles where still dictionary-backed in active paths.
- [ ] Wire capability checks and actionable fail-fast errors for required native runtime dependencies (no compatibility shim paths).
- [ ] Add Phase 1 parity gates for existing smell/wind/terrain deterministic tests and keep behavior equivalent within epsilon tolerances.

Phase 2: Hydrology + terrain/environment core migration first
- [ ] Port hydrology, erosion/destruction, weather, and solar heavy update loops to native kernels/graph stages.
- [ ] Add native combustion/reaction stage with pressure + temperature + fuel + oxygen gating and couple resulting heat/damage budgets into unified terrain destruction ops.
- [ ] Route terrain/environment spatial query hotspots through native query services and remove duplicate script-side scan caches.
- [ ] Prioritize GPU residency and shared buffer/pipeline ownership in native compute manager for these domains.
- [ ] Enforce canonical physics channel set in native field contracts: pressure, temperature, density, velocity, moisture, porosity, cohesion, hardness, phase, stress/strain, fuel, oxygen.
- [ ] Add integrated fixed-seed N-tick replay coverage for weather + hydrology + erosion + solar equivalence.
- [ ] Add deterministic unified material-flow parity gate with epsilon contract (`<= 1e-4`) for CPU/native snapshot comparisons.
- [ ] Add deterministic foveated throttling gate validating monotonic throttle scalars (`op_stride`, `voxel_scale`, `compute_budget_scale`) under far-camera/high-uniformity views.
- [ ] Add deterministic gate that fails Phase 2 completion if any generalized physics domain (`mechanics`, `pressure`, `thermal`, `reaction`, `destruction`) is missing from pipeline output summary contracts.
- [ ] Add deterministic gate that fails Phase 2 completion if conservation diagnostics omit per-stage or overall aggregate proxy totals.
- [ ] Exit Phase 2 only when script layers for these systems are adapter-only and no longer own numeric loops.

Phase 3: Smell/wind and ecology signal migration
- [ ] Convert `SmellFieldSystem.gd` and `WindFieldSystem.gd` into thin adapters over native execution stages.
- [ ] Move smell/wind locality gating and cadence orchestration into native scheduler/graph stages.
- [ ] Port strongest-signal, nearest-resource/danger, and top-k radius queries to native query APIs for ecology callers.
- [ ] Add targeted parity tests for smell/wind field evolution and native query results under fixed seeds.
- [ ] Exit Phase 3 only when smell/wind/ecology signal execution is native-owned and script logic is declarative orchestration.

Phase 4: Remove duplicate script logic and lock native-first flow
- [ ] Delete or reduce obsolete duplicated logic in `addons/local_agents/simulation/*ComputeBackend.gd`.
- [ ] Remove legacy cadence/voxel gating duplication from `EnvironmentTickScheduler.gd` and `VoxelProcessGateController.gd` after native scheduler takeover.
- [ ] Remove remaining transitional code paths that duplicate native execution in script systems.
- [ ] Update docs/tests to reflect native-first graph ownership and required Vulkan baseline with D3D12 compatibility note.
- [ ] Record completed migration and any breaking contract changes in this section and keep unchecked items for remaining work only.

Test/runtime optimization follow-up:
- [x] Add fast harness mode (`--fast`) and explicit core/runtime test filtering for local iteration.
- [x] Add bounded runtime sharding (`--workers=N`) for process-level parallelism when desired.
- [x] Add opt-in runtime GPU test mode (`--use-gpu`, `--gpu-layers=N`) while keeping deterministic CPU defaults.
- [x] Add runtime override knobs for context and max tokens in heavy tests (`--context-size`, `--max-tokens` and env vars).
- [x] Add voxel CPU-vs-GPU benchmark harness for pipeline comparison (`benchmark_voxel_pipeline.gd`) and document run commands.
- [x] Standardize deterministic replay CI timeout budgets: `120s` per shard by default, `180s` for GPU/mobile-oriented matrix jobs.

## Immediate Queue (Ready to Spawn)

- [x] Fix Piper voice fetch URLs and make dependency fetch resilient to missing optional voice assets.
- [x] Finish native build verification and confirm `scripts/check_extension.gd` passes with produced binaries.
- [x] Run full runtime-heavy tests with real model load/embed/generate and capture pass/fail baseline.
- [x] Add CI split jobs: `core-headless` and `runtime-heavy`.
- [x] Update README test section to align with current harness behavior.

## Breaking Changes

- [x] February 12, 2026: Migrated active ecology smell/wind runtime from hex-grid path to shared sparse voxel grid system (`VoxelGridSystem`, `SmellFieldSystem`, `WindFieldSystem`).
- [x] Legacy hex/grid config contracts are no longer part of the active ecology runtime path.
- [x] February 12, 2026: Path/flow traversal now keys routes by voxel coordinates via `SpatialFlowNetworkSystem` + `VoxelGridSystem`.
- [x] February 12, 2026: Environment generation now includes `voxel_world` terrain payload (`block_rows`, `columns`, block/resource type counts) generated via Godot `FastNoiseLite` and rendered by `EnvironmentController` as Minecraft-style block terrain.
- [x] February 12, 2026: Environment generation now bakes deterministic `flow_map` payloads (downhill links, accumulation, channel strength) and hydrology consumes baked flowmap rows directly for water network construction.
- [x] February 12, 2026: Environment rendering now consumes shader-side weather/surface/solar fields; demo and simulation controller paths both push solar state snapshots to environment rendering.

## Deferred / Decision Log

- [ ] Decide whether to keep SQLite-only graph architecture or introduce specialized graph backend.
- [x] Decide whisper backend policy (`whisper.cpp` vs `faster-whisper`) per platform tier.
- [x] Decide long-term packaging/versioning strategy for bundled native dependencies.

Policy decisions (recorded February 12, 2026):
- Whisper backend policy: default to `whisper.cpp` CLI/runtime integration for all supported desktop tiers (macOS/Linux/Windows) to preserve single-toolchain native distribution and headless determinism. Treat `faster-whisper` as optional future experimentation only, not a required runtime/backend path.
- Bundled dependency versioning strategy: keep build/runtime dependencies pinned in scripts/manifests, update them via focused additive commits, and validate each bump with headless core + runtime-heavy suites before merge. Runtime artifacts remain out of git history; only scripts/metadata and reproducible fetch/build logic are committed.
