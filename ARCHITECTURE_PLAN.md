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

## Concern I: Voxel Physics Engine Upgrades (Native-First)

Scope: `addons/local_agents/gdextensions/localagents/*`, `addons/local_agents/simulation/*`, `addons/local_agents/tests/*native*`, `addons/local_agents/scenes/simulation/controllers/*`

Tracking policy:
- [x] `ARCHITECTURE_PLAN.md` is the only live status tracker for this workstream.
- [ ] Keep all new status updates in this section only (no duplicate checklist tracking in other plan docs).

Physics-server-first integration policy:
- [ ] Treat Godot `PhysicsServer3D` (Jolt-backed standard runtime) as the required rigid-body/contact/collision backend for this workstream.
- [ ] Keep custom native physics focused on voxel continuum fields (transport/thermal/reaction/failure), not general rigid-body solving.
- [ ] Do not start a full custom physics server replacement unless a documented `PhysicsServer3D` blocker is confirmed in this plan.
- [ ] Publish and maintain a clear ownership matrix:
- [ ] `PhysicsServer3D` owns broadphase/narrowphase, contact manifolds, constraints, and body integration.
- [ ] Local native voxel core owns field PDE updates, fracture criteria, and voxel edit emission.
- [ ] Bridge layer owns deterministic bidirectional coupling between physics-server contacts and voxel source terms.

Current state baseline (completed):
- [x] Native stage scaffold exists for `mechanics`, `pressure`, `thermal`, `reaction`, `destruction`.
- [x] Canonical physics input normalization exists in bridge payloads (pressure/temperature/density/velocity/stress-strain and related channels).
- [x] Pressure-dependent reaction/combustion gating exists.
- [x] Deterministic source-contract tests exist for stage presence and core contract equations.
- [x] Voxel edit pipeline exists with adaptive/foveated knobs and CPU fallback metadata.
- [x] February 13, 2026: Added deterministic native voxel-op ordering/fallback/changed-region contract coverage (`test_native_voxel_op_contracts.gd`).
- [x] February 13, 2026: Extended deterministic generalized-physics contract coverage for boundary/porous/shock/phase/friction payload terms (`test_native_general_physics_contracts.gd`).

### Wave A: Field Model + Conservative Core Solvers

Next Wave Scope (in-progress) - February 13, 2026:
- [ ] Land native field handles API.
- [ ] Add field-handle execution diagnostics in pipeline.
- [ ] Add invariants and stage-coupling source-contract gates.

Data model and state layer:
- [ ] Move hot-path simulation from per-step scalar dictionaries to typed native field handles.
- [ ] Add canonical native field registry schema for:
- [ ] `mass_density`, `momentum_x/y/z`, `pressure`, `temperature`, `internal_energy`.
- [ ] `phase_fraction_solid/liquid/gas`, `porosity`, `permeability`.
- [ ] `cohesion`, `friction_static`, `friction_dynamic`, `yield_strength`, `damage`.
- [ ] `fuel`, `oxidizer`, `reaction_progress`, `latent_energy_reservoir`.
- [ ] Add strict units/range metadata and runtime validation for field channels.
- [ ] Add SoA layout metadata + sparse chunk indexing + deterministic chunk ordering.
- [ ] Replace dictionary snapshots for hot paths with typed native handles.
- [x] February 13, 2026: Defined bridge-canonical physics contact coupling fields (`contact_impulse`, `contact_normal`, `contact_point`, `body_velocity`, `body_id`, `rigid_obstacle_mask`).

Mechanics / pressure / thermal evolution:
- [ ] Add finite-volume-style multi-cell coupling for mechanics momentum updates.
- [ ] Add conservative neighbor flux computation between adjacent cells.
- [ ] Add continuity updates with conservative density/mass flux accounting.
- [ ] Couple pressure to density/temperature through explicit EOS profiles.
- [ ] Replace single-cell thermal terms with neighbor conduction plus advection coupling.
- [ ] Add latent heat accounting coupled to phase-fraction transitions and bounds.
- [ ] Inject physics-server contact impulses and obstacle velocities into mechanics source terms each step.
- [ ] Feed voxel-derived resistance/fracture feedback into physics-server responses through explicit bridge outputs.

Wave A validation gates:
- [ ] Add deterministic invariants tests for bounded mass/energy drift per step.
- [ ] Add stage-coupling tests for `pressure -> mechanics`, `reaction -> thermal`, `damage -> voxel ops`.
- [ ] Ensure each stage reads/writes native field handles (script layer remains orchestration/visualization only).
- [ ] February 13, 2026: Landed Wave A stage-coupling marker and scalar payload wiring (`pressure->mechanics`, `reaction->thermal`, `damage->voxel`) for deterministic validation; broader cross-stage invariants tests still in progress.
- [x] February 13, 2026: Added deterministic bridge-contract tests for physics-server contact ingestion and voxel response emission payloads.
- [x] February 13, 2026: Added low-level physics-server contact coupling schema through bridge canonical inputs and normalization (`NativeComputeBridge.gd`), plus deterministic source-contract coverage (`test_native_general_physics_contracts.gd`, `test_native_combustion_pressure_contracts.gd`).
- [x] February 13, 2026: Added optional physics-contact payload forwarding through environment stage dispatch paths.

### Wave B: Reaction, Failure, Boundaries, and Scheduler Coupling

Reaction and chemistry:
- [ ] Implement multi-reaction channels with stoichiometry tables and material/phase-dependent kinetics.
- [ ] Couple oxidizer transport, pressure, and temperature into reaction kinetics.
- [ ] Couple reaction heat and byproducts back into thermal and mass/composition fields.
- [ ] Enforce reaction mass/energy budget closure tolerances.

Fracture/failure and destruction coupling:
- [ ] Replace scalar damage with stress-invariant criteria (Mohr-Coulomb or Drucker-Prager-lite profiles).
- [ ] Add plastic compaction and brittle fracture branches via material profiles (data-driven, no code forks).
- [ ] Couple damage to porosity/permeability evolution.
- [ ] Emit voxel edit operations from physically derived failure fields.

Boundary and scheduling correctness:
- [ ] Implement face-stencil boundary behavior (`open`, `inflow/outflow`, `reflective`, `no-slip`, `no-penetration`).
- [ ] Add moving-obstacle boundary handling and deterministic chunk-edge boundary tests.
- [ ] Move foveated/LOD scheduling fully native with conservative coarse/fine transitions and starvation guards.
- [ ] Route dynamic obstacle boundaries from `PhysicsServer3D` body transforms/velocities rather than parallel custom obstacle solvers.

Wave B validation gates:
- [ ] Add deterministic regression scenarios (impact, flood, fire, cooling, collapse, mixed-material transitions).
- [ ] Add deterministic boundary consistency checks across chunk edges and active-region transitions.
- [ ] Require coherent repeated-load terrain response without numerical explosion.

### Wave C: GPU-First Runtime + Query Migration + CI Gates

GPU-first implementation:
- [ ] Implement compute kernels for all hot stages and keep core fields resident on GPU.
- [ ] Add ping-pong buffers, barrier/fence correctness, and sparse active-region dispatch.
- [ ] Add backend capability gating and mobile quality tiers.
- [ ] Keep CPU fallback behaviorally aligned to epsilon contracts.
- [ ] Keep physics-server sync/readback deltas minimal and bounded (no full-scene per-frame bridge copies).

Query/gameplay integration:
- [ ] Expose native query APIs for pressure gradients, heat fronts, failure/ignition risk, flow direction, and top-k hazards/resources.
- [ ] Migrate gameplay/AI consumers to native query services.
- [ ] Keep script ownership to orchestration/UI only.
- [ ] Expose unified query surfaces that combine voxel risk fields with physics-server collision/contact state.

CI confidence and production gates:
- [ ] Add GPU-vs-CPU epsilon parity suites and backend matrix coverage.
- [ ] Add performance gates (`ms/stage`, bandwidth, active-cell throughput).
- [ ] Gate completion on contracts + invariants + parity + perf checks passing in CI.
- [ ] Add physics-server-coupled regression scenarios (impact-settling, pile collapse, fracture under repeated contacts) with deterministic replay checks.
- [ ] Add gate that fails completion if rigid-body/contact logic diverges into a custom physics-server path without explicit approved blocker entry.

### Cross-Cutting Refactor Commitments

- [ ] Migrate remaining large numeric `.gd` loops to native by responsibility (orchestration, domain, render adapters, input, HUD).
- [ ] Keep files under 600-line CI limit while splitting by responsibility.
- [ ] Remove transitional compatibility aliases and duplicate execution paths after extraction.
- [ ] Record all breaking schema/API changes in this section with date stamps.

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
