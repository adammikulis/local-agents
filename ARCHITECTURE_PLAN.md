# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.

## Operating Rules

- [x] Use concern-based workstreams instead of role roster ownership.
- [x] Keep `AGENTS.md` as the canonical engineering rules file.
- [x] Prefer additive changes and small, reviewable diffs.
- [x] Signal up and call down (mediator orchestration) for cross-system flows.
- [x] Record breaking API/schema changes in this file before merge.
- [x] Keep memory/graph implementation out of this execution stream when separately owned.

## Wave Protocol

- [x] Planning for each wave starts with a planner sub-agent that defines scope, owners, and acceptance criteria.
- [x] Implementation and validation are split into parallel sub-agent streams where responsibilities can be partitioned safely.
- [x] Main thread tracks deconflict/merge and drives the `ARCHITECTURE_PLAN.md -> execution -> verification -> commit` loop.
- [x] Stale/finished sub-agents are proactively closed and replaced as needed.

## Concern A: Runtime and GDExtension Stability

Scope: `addons/local_agents/gdextensions/localagents/`, `addons/local_agents/runtime/`, `addons/local_agents/agents/`

Completed milestones:
- [x] Added lazy runtime initialization with `LocalAgentsExtensionLoader` and placeholder panel activation.
- [x] Added preflight binary checks before extension startup plus runtime `Agent`/`AgentNode` safety guards.
- [x] Added fresh-machine runtime initialization validation after dependency/build scripts.
- [x] Added structured editor/test runtime health visibility (`extension loaded`, `model loaded`, `runtime binaries`) and `AgentRuntime` JSON grammar/options coverage.

## Concern B: Model Download and Asset Pipeline

Scope: `controllers/ModelDownloadService.gd`, `controllers/DownloadController.gd`, `api/DownloadClient.gd`, `src/ModelDownloadManager.cpp`, `scripts/fetch_dependencies.sh`, `scripts/fetch_runtimes.sh`

Completed milestones:
- [x] Runtime and GDScript download pipeline is present (`ModelDownloadManager` + `LocalAgentsDownloadClient`) with shared UI/headless orchestration and runtime progress/log/finished signaling.
- [x] Fixed dependency fetch path resolution (`fetch_dependencies.sh` repo-root anchor) and improved Piper artifact handling for stale/missing URLs.
- [x] Added checksum and manifest verification for model/voice artifacts with fallback/continue behavior for unavailable artifacts.

## Concern C: Chat, Controller Boundaries, and Scene Architecture

Scope: `controllers/ChatController.gd`, `agent_manager/AgentManager.gd`, `editor/*`, `configuration/ui/*`

Completed milestones:
- [x] Chat, Download, and Configuration panels are composed into a stable workflow with explicit runtime-state badges (runtime loaded/model loaded/speech ready).
- [x] Runtime-safe null-guard and flow separation work completed for model/config apply paths (`runtime-only` vs `editor-only` concerns).
- [x] Controller decomposition has advanced toward mediator + focused services for conversation/session/history boundaries.

## Concern D: Memory and Graph Capabilities

Scope: `controllers/ConversationStore.gd`, `docs/NETWORK_GRAPH.md`, future graph/memory tabs

Completed milestones:
- [x] Conversation persistence and search scaffolding exists via `NetworkGraph`.
- [ ] Finalize schema for memories/edges/episodes/embeddings and indices.
- [ ] Add embedding write pipeline and robust recall APIs (query, top-k, pagination/streaming).
- [ ] Add migration/maintenance tools (purge/export/repair).
- [ ] Implement editor Memory and Graph inspection tabs.

## Concern E: Speech and Transcription

Scope: `runtime/audio/SpeechService.gd`, `agents/Agent.gd`, native speech/transcription runtime hooks

Completed milestones:
- [x] Async speech/transcription runtime hooks are integrated end-to-end with async agent speech playback callbacks.
- [x] Added deterministic smoke testing for success/failure paths and improved voice asset reporting for missing/mismatched assets.

## Concern F: Test Strategy and CI Gating

Scope: `addons/local_agents/tests/*`, CI pipeline setup

Completed milestones:
- [x] Test harness is in place for headless plus runtime-heavy suites (`run_all_tests.gd`, `test_model_helper.gd`) with explicit runtime paths and auto-model acquisition.
- [x] CI policy is finalized for explicit loud failure on acquisition/inference errors, with separate core/runtime jobs and artifact/log collection on download/runtime failures.

## Concern G: Cross-Platform Build and Packaging

Scope: build scripts, release packaging, binary layout

Completed milestones:
- [x] macOS build now bundles local extension dependencies and llama tools.
- [x] Linux/Windows parity was added for bundled binaries and runtime tools.
- [x] `build_all.sh` and per-platform reproducible packaging are in place.
- [x] Release checks include binary size/performance regression gates.

## Concern H: Demos, Docs, and Onboarding

Scope: `README.md`, examples, docs, screenshots/tutorials

Completed milestones:
- [x] Core docs/examples are in place with README updates reflecting runtime-heavy test behavior and flags.
- [x] 3D demo parity and HUD components have been restored/polished.
- [x] Tutorials/docs/screenshots refreshed around download and runtime health workflows.

Planned entries:
- [ ] P0 (Owners: Documentation lane, Runtime Simulation lane, Validation/Test-Infrastructure lane): Consolidate simulation runtime by hard-cutting legacy `WorldSimulatorApp` stack, enforcing `WorldSimulation` as the single voxel runtime path, and moving feature-set selection to in-runtime demo profiles/toggles.
  - Acceptance criteria: Docs define `WorldSimulation` as the only supported runtime path for simulation demos and remove/replace all `WorldSimulatorApp` setup guidance; legacy `WorldSimulatorApp` launch/config wiring is marked removed with no compatibility route documented.
  - Acceptance criteria: Docs specify the in-runtime demo profile/toggle model (for example destruction-only, full-systems, perf/stress) and require profile switching without runtime-stack swaps.
  - Acceptance criteria: Ownership + rollout notes include deterministic validation expectations for each demo profile/toggle set and explicitly map validation commands/suites to profile behaviors.
  - Risks: Legacy scene/tooling references may still assume `WorldSimulatorApp`, creating partial migrations and broken onboarding flows until all references are cut.
  - Risks: Profile/toggle combinatorics can introduce unvalidated runtime states unless profile boundaries and required defaults are constrained.
  - Risks: Hard cutover may temporarily break local scripts or contributor workflows that still bootstrap through legacy runtime entry points.
- [ ] P0 (Owner: Documentation lane): Replace rigid-brick target wall guidance with pure voxel-engine target wall + projectile-impact voxel destruction path in default `WorldSimulation`.
  - Acceptance criteria: Docs specify default `WorldSimulation` setup for voxel-only target walls, projectile impact flow that emits voxel destruction edits on hit, and a deterministic launcher test scenario with repeatable destruction expectations.
  - Risks: Voxel resolution/material tuning may introduce non-repeatable destruction profiles; coupling projectile impact and voxel-edit timing may cause flaky benchmark outcomes if determinism constraints are underspecified.
- [ ] P0 (Owner: Documentation lane): Add `voxel-destruction-only demo mode` for default `WorldSimulation` that disables non-essential smell/ecology/society/weather/economy loops while preserving launcher startup and voxel wall destruction flow.
  - Acceptance criteria: Docs define the default demo-mode configuration with smell/ecology/society/weather/economy loops disabled, confirm launcher boot remains enabled, and document deterministic projectile-to-voxel-wall destruction behavior.
  - Risks: Hidden dependencies on disabled loops may break startup/HUD assumptions; incomplete loop shutdown may leave background timers/signals active and reduce determinism.


## Concern I: Voxel Physics Engine Upgrades (Native-First)

Scope: `addons/local_agents/gdextensions/localagents/*`, `addons/local_agents/simulation/*`, `addons/local_agents/tests/*native*`, `addons/local_agents/scenes/simulation/controllers/*`

Tracking policy:
- [x] `ARCHITECTURE_PLAN.md` is the only live status tracker for this workstream.
- [x] Keep all new status updates in this section only (no duplicate checklist tracking in other plan docs).

Physics-server-first integration policy (policy-lock: 2026-02-13, immutable):
- [x] Treat Godot `PhysicsServer3D` (Jolt-backed standard runtime) as the required rigid-body/contact/collision backend for this workstream.
- [x] Keep custom native physics focused on voxel continuum fields (transport/thermal/reaction/failure), not general rigid-body solving.
- [x] Do not start a full custom physics server replacement unless a documented `PhysicsServer3D` blocker is confirmed in this plan.
- [x] Publish and maintain a clear ownership matrix.
- [x] `PhysicsServer3D` owns broadphase/narrowphase, contact manifolds, constraints, and body integration.
- [x] Local native voxel core owns field PDE updates, fracture criteria, and voxel edit emission.
- [x] Bridge layer owns deterministic bidirectional coupling between physics-server contacts and voxel source terms.

Current state baseline (completed):
Completed milestones:
- [x] Native stage scaffold now exists for `mechanics`, `pressure`, `thermal`, `reaction`, `destruction`.
- [x] Canonical bridge input normalization and pressure-dependent reaction/combustion gating are in place.
- [x] Deterministic stage-presence and core contract tests are present, including deterministic voxel-edit contract coverage (`test_native_voxel_op_contracts.gd`) and generalized-physics payload coverage for boundary/porous/shock/phase/friction terms (`test_native_general_physics_contracts.gd`) on February 13, 2026.

### Wave A: Field Model + Conservative Core Solvers

Next Wave Scope (in-progress) - February 13, 2026:
Completed milestones:
- [x] February 13, 2026: Landed native field handles API and execution diagnostics in pipeline.
- [x] February 13, 2026: Added field-handle-aware stage input plumbing and invariants/source-contract coupling gates in pipeline execution.

Data model and state layer:
- [ ] Move hot-path simulation from per-step scalar dictionaries to typed native field handles.
- [x] February 13, 2026: Added canonical native field registry schema for:
- `mass_density`, `momentum_x/y/z`, `pressure`, `temperature`, `internal_energy`.
- `phase_fraction_solid/liquid/gas`, `porosity`, `permeability`.
- `cohesion`, `friction_static`, `friction_dynamic`, `yield_strength`, `damage`.
- `fuel`, `oxidizer`, `reaction_progress`, `latent_energy_reservoir`.
- [x] Add strict units/range metadata and runtime validation for field channels. (Accepted 2026-02-13: implemented in `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp`; validated by `addons/local_agents/tests/test_native_field_handle_registry_contracts.gd`, `addons/local_agents/tests/test_field_registry_config_resource.gd`.)
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
- [x] February 14, 2026: Inject physics-server contact impulses and obstacle velocities into mechanics source terms each step (via existing `run_mechanics_stage` inputs).
- [x] February 14, 2026: Feed voxel-derived resistance/fracture feedback into physics-server responses through explicit bridge outputs (`pipeline["physics_server_feedback"]` + root `physics_server_feedback`).

### Wave A completion digest (condensed)
- [x] 2026-02-13-14: Field-handle continuity, alias-parity, and bridge-facing failure feedback are now stable (`schema`/marker diagnostics, deterministic `resistance` + `resistance_raw`, and handle-first/handle-fallback coupling behavior).

Wave A validation gates:
Completed milestones:
- [x] February 13, 2026: Added deterministic bounded mass/energy drift invariants and `pressure -> mechanics`, `reaction -> thermal`, `damage -> voxel ops` source-contract tests.
- [x] P1, 2026-02-13: Wired `run_field_buffer_evolution(...).updated_fields` into next-step `execute_step` continuity while preserving existing summary metrics and acceptance expectations:
    - next `execute_step` invocation consumes persisted `field_buffers` (`mass`, `pressure`, `temperature`, `velocity`, `density`, `neighbor_topology`) from prior `updated_fields`, while retaining field-handle diagnostic payloads and all existing summary keys.
- [x] P0 (Owner: Scope-A: C++ Stage Math Lane, Completed February 13, 2026): Ensure stage execution is fully native handle-driven.
  - Dependency: Wave A baseline continuity and handle-resolution work.
  - Last touched: 2026-02-13.
  - Acceptance criteria: Stage execution path reads resolved field-handle buffers for all hot fields before scalar fallback paths.
  - Test anchors: `test_native_general_physics_wave_a_runtime.gd`.
  - Completion summary: Completed by hardening handle diagnostics around missing/invalid native field-handle paths and asserting reason-coded fallback behavior in `test_native_general_physics_wave_a_runtime.gd`.
- [x] February 13, 2026: Landed Wave A stage-coupling marker and scalar payload wiring (`pressure->mechanics`, `reaction->thermal`, `damage->voxel`) for deterministic validation.
- [x] February 13, 2026: Added Wave A stage-coupling source-contract tests for `pressure->mechanics`, `reaction->thermal`, and `damage->voxel` transitions in `test_native_general_physics_contracts.gd`.
- [x] February 13, 2026: Added deterministic bridge-contract tests for physics-server contact ingestion and voxel response emission payloads.
- [x] February 13, 2026: Added low-level physics-server contact coupling schema through bridge canonical inputs and normalization (`NativeComputeBridge.gd`), plus deterministic source-contract coverage (`test_native_general_physics_contracts.gd`, `test_native_combustion_pressure_contracts.gd`).
- [x] February 13, 2026: Added optional physics-contact payload forwarding through environment stage dispatch paths.

Current status note (progress snapshot):
- Completed this cycle:
  - `run_mechanics_stage`, `run_pressure_stage`, `run_thermal_stage`, `run_reaction_stage`, and `run_destruction_stage` now prefer native field-handle buffers when valid handles are present.
  - `field_handle` diagnostics are emitted with explicit fallback reason codes.
- Completed:
  - Continuity-carry and compatibility-fallback parity checks are closed under native-handle and compatibility modes.
- Blocked/why:
  - No active blockers.
- Next action:
  - Prioritize Wave A+ P0 closeout for handle-native hot paths and layout foundations first, then move directly into Wave B reaction/failure foundation work (reaction coupling + failure criteria coupling).

#### Wave A+ / Execution

Completed milestones:
- [x] February 13, 2026: Added neighborhood ordering invariance contract coverage for liquid-transport aggregation in `test_native_general_physics_wave_a_runtime.gd`.
- [x] P0, Scope-A: C++ Stage Math Lane: Handle-backed scalar resolution and diagnostics are implemented for hot-stage math, with explicit fallback reasons.
- [x] P0, Scope-A: C++ Stage Math Lane: `run_field_buffer_evolution(...).updated_fields` and continuity buffers are chained back into subsequent `execute_step` calls.
- [x] P0, Scope-A: C++ Stage Math Lane: Stage math moved off scalar dictionaries as primary path for core fields and now prefers native handle buffers (`mass`, `velocity`, `density`, `pressure`, `temperature`) when available.

Wave A+ execution matrix:

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [x] Completed (February 13, 2026) | P1 | Scope-A: C++ Stage Math Lane | Stage math hot-field extraction complete | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineStages.cpp` | Group liquid transport updates by neighbor neighborhood with deterministic aggregation before additional vectorization work. | Neighborhood aggregation order is deterministic for liquid transport updates and covered by runtime invariance contract tests. | None | `test_native_general_physics_wave_a_runtime.gd` |
| [x] Completed | P1 | Scope-A: C++ Stage Math Lane | Native stage input wiring | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp` | Continuity payloads (`field_buffers`/`updated_fields`) are explicit stage input sources for `neighbor_topology`, `mass`, `density`, `pressure`, `temperature`, `velocity` when present. | Continuity payloads are used as the preferred source for hot-stage math. | None | `test_native_general_physics_wave_a_contracts.gd` |
| [x] Completed (February 13, 2026) | P2 | Scope-A: C++ Stage Math Lane | Handle-vs-scalar parity work started in Wave A+ | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp` | Alias/field-name normalization map is deterministic and identical between stage math and field-evolution resolution paths. | Canonical fixtures show identical alias-map outputs across both execution paths. | None | `test_native_general_physics_wave_a_runtime.gd` |
| [x] Completed | P1 | Scope-A: C++ Stage Math Lane | Scalar fallback controls active | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineStages.cpp` | Scalar fallback is explicit compatibility-only and reason-coded when field-handle inputs are unavailable. | Hot stages resolve native handles first; compatibility fallback is allowed only with explicit reason codes. | None | `test_native_general_physics_wave_a_runtime.gd`, `test_native_voxel_op_contracts.gd` |
| [x] Completed (February 13, 2026) | P1 | Scope-A: C++ Stage Math Lane | Stage execution hot-path profiling baseline established | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp` | Cache field-handle lookup per stage execution to cap lookup overhead and reduce churn. | Handle lookup counts are deterministic and do not increase versus baseline under stable workloads. | None | `test_native_general_physics_wave_a_runtime.gd` |

#### Wave A+ / Next Execution

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [ ] Not started | P0 | Scope-A: C++ Stage Math Lane | Wave A completion gates and field-handle diagnostics are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineStages.cpp` | Remove remaining per-step scalar dictionary snapshots from hot simulation loops and require typed native fields for core transport/thermo/mechanical states. | Hot-stage execution paths for supported builds read native handle buffers first and never use scalar snapshots as fallback precedence. | Outstanding compatibility-only controllers may still trigger legacy dictionaries unless scoped out. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_wave_a_contracts.gd`, `test_native_field_handle_registry_contracts.gd` |
| [ ] Not started | P1 | Scope-A: Native Layout Lane | Wave A+ stage handles and field registry contracts are in place | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/FieldEvolution.cpp` | Implement SoA metadata, sparse chunk indexing, and deterministic chunk-ordering interfaces for field evolution and neighbor topology. | Deterministic chunk scans and stable sparse-index behavior are validated by deterministic fixture-based tests. | Serialization/migration support for preexisting field layouts is missing. | `test_native_field_handle_registry_contracts.gd`, `test_field_registry_config_resource.gd` |
| [ ] Not started | P1 | Scope-A: Simulation Foundations Lane | Wave A+ closeout requires reaction scaffolding | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp` | Add first-wave reaction channel scaffolding for oxidizer transport plus pressure/temperature-gated reaction source terms. | Deterministic reaction updates include oxidizer, pressure, and temperature coupling for one material profile without violating conservation envelopes. | Missing stoichiometry tables and profile metadata for full Material-API coverage. | `test_native_general_physics_contracts.gd` |
| [ ] Not started | P2 | Scope-B: Simulation Foundations Lane | Failure feedback bridge exists from Wave B foundations | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp` | Add stress-invariant failure branch path and porosity/permeability coupling through existing destruction pipeline contracts. | Failure signals are deterministic and bounded; feedback into porosity/permeability reduces or increases local resistance predictably. | Material profiles and scheduler coupling for branch transitions are not yet complete. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |

#### Wave B / Wave C: continuation

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [ ] Not started | P0 | Scope-B: Simulation Chemistry Lane | Wave A+ continuity and field diagnostics are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp` | Add reaction schema/stochiometry resources and wire oxidizer transport with pressure/temperature coupling into reaction rate updates for one migration-safe material profile. | Reaction execution uses typed stoichiometry and explicit oxidizer-pressure-temperature gating with deterministic outputs in native stages. | Strongly typed reaction resources are required before this row can be accepted. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Chemistry Lane | Reaction schema/stochiometry coupling row is implemented | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/tests/test_native_general_physics_contracts.gd` | Add reaction mass/energy closure checks with bounded tolerances and explicit drift reporting. | Deterministic mass+energy closure diagnostics are present per step and must remain within configured tolerances. | Reaction energetics and heat-capacity assumptions require finalization by material profile owners. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P0 | Scope-B: Simulation Destruction Lane | Reaction and field transport coupling is stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp` | Replace scalar damage path with failure invariants in native destruction branches. | Failure branching is stress-invariant, deterministic, and emits failure-invariant metadata instead of scalar damage accumulation. | Material thresholds and invariant profiles must be completed. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Destruction Lane | Failure invariants are in place for deterministic transitions | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp` | Add compaction and brittle fracture branches and couple both to porosity/permeability evolution. | Branch transition behavior is deterministic with bounded changes to porosity and permeability. | Scheduler coupling must account for branch-induced hot-spot transitions. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Scheduling Lane | Destruction/reaction staging and native feedback are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/` | Implement native scheduler LOD with starvation guards for active-region dispatch and stage progression. | Active scheduling guarantees bounded starvation windows and never starves non-empty active regions under steady demand. | Starvation window maxima and fallback path need explicit values and tests. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_wave_b_runtime.gd` |
| [ ] Not started | P0 | Scope-C: Query Surface Lane | Physics/native outputs are available for queryable fields | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.cpp` | Expose native query surface for pressure gradients, heat fronts, failure/ignition risk, flow direction, and top-k hazards/resources. | Typed query APIs expose deterministic outputs for all listed categories with documented pre/post-conditions. | Query schema must be finalized in one pass; no fallback-only compatibility behavior. | `test_native_query_contracts.gd` |
| [ ] Not started | P1 | Scope-C: Query Integration Lane | Query surface and contracts are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, `addons/local_agents/controllers/*` | Migrate one gameplay/AI consumer path to native query services. | The migrated path no longer reads raw scalar snapshots for any of the listed query categories. | Remaining consumers may keep temporary adapter layers until migration wave completes. | `test_query_migration_contracts.gd`, `test_native_general_physics_wave_a_runtime.gd` |
| [ ] Not started | P1 | Scope-D: Native Compute Lane | Scheduler and query rows above are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineGpu.cpp` | Add first compute-kernel stage with ping-pong buffers and barrier/fence correctness. | Kernel stage reproduces baseline key outputs with deterministic barrier synchronization and state transitions. | Requires explicit GPU precondition and required capability path. | `test_native_gpu_kernel_stage.gd`, `test_native_general_physics_wave_a_runtime.gd` |
| [ ] Not started | P2 | Scope-D: Native Compute Lane | Initial kernel stage and synchronization are implemented | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/godot/LocalAgentsExtension.cpp` | Add capability gating + CPU parity contract for GPU path enablement. | Runtime fails fast when required GPU capabilities are absent and enforces epsilon CPU parity for supported kernels. | Capability matrix and parity tolerances need explicit governance. | `test_cpu_gpu_parity_contracts.gd` |
| [ ] Not started | P2 | Scope-D: CI/Gating Lane | CPU parity contract is in place | 2026-02-14 | `.github/workflows/*`, `addons/local_agents/tests/*` | Add GPU-vs-CPU performance/parity CI gates with bounded regressions. | CI gate blocks on performance regression and parity failures, with deterministic replay and artifact evidence. | Runtime/perf baselines and tolerances require explicit calibration. | `benchmark_voxel_pipeline.gd`, `test_native_gpu_cpu_parity.gd` |

Immediate order recommendation:

1. P0 foundation: Reaction schema/stochiometry + oxidizer/pressure/temp coupling, then failure invariants replacing scalar damage.
2. P1 execution: Reaction mass/energy closure checks, compaction/brittle branches + porosity/permeability coupling, and native scheduler LOD with starvation guards.
3. Query bridge progression: Native query surface exposure first, then one consumer path migration.
4. Compute-first progression: First compute-kernel stage + ping-pong/barrier, then capability gating + CPU parity contract.
5. P2 hardening: GPU-vs-CPU performance/parity CI gates and policy enforcement.

Blocker clarifications:

- Material profile completeness: reaction stoichiometry, energetics, and failure thresholds must be present in typed material profiles before rows depending on them can complete.
- GPU capability precondition: all Wave C compute rows require explicit capability discovery; required features missing at runtime must fail fast and block proceed.
- [x] 2026-02-14: Approved blocker record `PhysicsServer3D-contact-divergence-v1` is active for the contact-divergence CI gate.
  - Scope: `PhysicsServer3D` remains the required authoritative rigid-body/contact source. Bridge adapters may normalize contact payloads only; any move to a custom rigid-body/contact logic path requires replacing this blocker record with a new explicit approval.
- Typed reaction/stoichiometry resources: reaction inputs must be consumed from typed resources (not ad-hoc dictionaries), including units and bounds metadata.
- Scheduler starvation bounds: starvation guards require explicit max-deferral bounds and deterministic fallback so no active workload can be permanently deferred.

#### Wave A+ / Validation

Completed milestones:
- [x] P1, Scope-C: Validation Lane: Deterministic migration safety for handle/scalar parity and bounded drift/source-contract checks is complete.
- [x] P0, Scope-C: Validation Lane: Deterministic baseline for field-evolution and stage summary-key stability under changed `field_handle` inputs is in place.
- [x] P1/P0, Scope-C: Validation Lane: Contact/voxel bridge contracts and baseline drift/transition gates are merged and covered deterministically.
- [x] February 13, 2026: Fallback coverage in `test_native_general_physics_wave_a_runtime.gd` now includes explicit handle-first and compatibility-branch assertions with reason-code checks.

Wave A+ validation matrix:

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [x] Completed | P1 | Scope-C: Validation Lane | Validation matrix in this section updated | 2026-02-13 | `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd` | Fallback branch coverage now includes all hot stages and `field_handle_mode` summary assertions. | Deterministic tests cover handle-first and explicit fallback branches for every hot stage. | None | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_wave_a_contracts.gd` |
| [x] Completed | P2 | Scope-C: Validation Lane | Handle-resolution behavior available from stage execution | 2026-02-13 | `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd` | Handle-miss/type-unusable fallback diagnostics now include field identifier, reason code, and fallback decision. | Miss/unusable diagnostics include field identifier, reason code, and fallback decision in deterministic logs. | None | `test_native_general_physics_wave_a_runtime.gd` |

#### Wave A+ / Data contracts

Compact contract stability (durable):
- `stage_field_input_diagnostics`: required hot-stage input diagnostic payload for per-stage resolution attempts (`ok`, `source`, `reason`, `field`, `field_alias`).
- `field_evolution.handle_resolution_diagnostics`: required payload for per-step handle resolution outcomes, including explicit misses and fallback reasons.
- `field_handle_mode`: required summary marker with values `field_handles` when handle mode is active, or explicit compatibility mode value.
- `field_evolution.updated_fields`: required key that remains present and deterministic across `execute_step` reentry.

Wave A+ contract matrix:

Completed milestones:
- [x] P0, Scope-A: C++ Stage Math Lane: Existing contract assertions now retain `stage_field_input_diagnostics` flow and deterministic updates to `run_field_buffer_evolution` contract payloads for `updated_fields`.

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [x] Completed (February 13, 2026) | P0 | Scope-A: C++ Stage Math Lane | Data-contract summary key set stabilized | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipeline.cpp` | `summary["field_handle_mode"]` is explicit and all existing `summary`/`conservation_diagnostics`/`field_evolution` keys stay stable unless new handle-aware keys are added. | `summary["field_handle_mode"]` is explicit and contract key sets are stable across handle/scalar modes. | None | `test_native_general_physics_wave_a_runtime.gd` |

#### Wave A+ Gates

- [x] Gate: handle-first hot-field resolution (Scope-A: C++ Stage Math Lane)
  - Status: Completed (2026-02-13).
  - Definition of Done: Hot stages consume field handles first; scalar paths are compatibility-only and reason-coded.
  - Test anchors: `test_native_general_physics_wave_a_runtime.gd`.
- [x] Gate: continuity carry contract (Scope-A: C++ Stage Math Lane)
  - Status: Completed (2026-02-13).
  - Definition of Done: `field_buffers` and `field_evolution.updated_fields` are carried deterministically through chained `execute_step` calls.
  - Test anchors: `test_native_general_physics_wave_a_contracts.gd`, `test_native_voxel_op_contracts.gd`.
- [x] Gate: compatibility fallback explicitness (Scope-C: Validation Lane)
  - Status: Completed (2026-02-13).
  - Definition of Done: Fallback activation can only occur with explicit field-level reason codes and emits compatible diagnostics.
  - Test anchors: `test_native_general_physics_wave_a_runtime.gd`.
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
- [x] February 14, 2026: Emit voxel edit operations from physically derived failure fields.
  - Status: Completed.
  - Definition of Done: `run_destruction_stage` emits explicit failure-status output, pipeline feedback now includes failure-source and voxel_emission contracts, and `LocalAgentsSimulationCore::apply_environment_stage` executes deterministic environment voxel emission based on active failure feedback.
  - Test anchors: `test_native_general_physics_contracts.gd`, `test_native_general_physics_wave_a_runtime.gd`.

#### Deterministic Cleave Wave 1 (implementation)

- Status: [ ] Not started
- Priority: P0
- Owners/Lane ownership: Scope-B: Simulation Destruction Lane (implementation), Scope-C: Validation Lane (determinism + contract gates), Documentation lane (plan/status tracking in this file)
- Acceptance criteria: Cleave decisions are derived from typed failure invariants and physics-server contact inputs only, cleave voxel-edit emission is deterministic across repeated seeded runs, and no compatibility scalar-only cleave branch remains on the primary path.
- Risks: PhysicsServer3D contact jitter/order variance can destabilize cleave thresholds, chunk-edge cleave propagation can drift without strict ordering, and dense-contact scenes may regress stage budget without bounded active-region scheduling.

#### Deterministic Failure Variation Wave 1 (fractal/noise-driven)

- Status: [ ] Not started
- Priority: P0
- Owners/Lane ownership: Scope-B: Simulation Destruction Lane (implementation), Scope-A: Native Layout Lane (deterministic noise/fractal field sourcing + chunk ordering), Scope-C: Validation Lane (seeded replay and contract determinism gates), Documentation lane (plan/status tracking in this file)
- Acceptance criteria: Failure variation is driven by deterministic seeded fractal/noise fields sampled from typed native field buffers, identical seed + identical inputs reproduce identical failure/voxel-edit outcomes across repeated runs, and replay contracts remain stable with no nondeterministic entropy/time-based inputs on the primary path.
- Risks: Cross-platform float/precision drift in fractal accumulation can desync replay, chunk traversal/sample-order differences can perturb threshold crossings, and unbounded noise frequency/amplitude can destabilize failure envelopes or violate scheduler budgets under dense-contact scenes.

#### FPS-Style Rigid-Body Launcher (camera-center aim + click fire)

- Priority: P1
- Owner lane: Scope-B: Simulation Foundations Lane (implementation), Scope-C: Validation Lane (deterministic/runtime contract checks), Documentation lane (plan/status tracking in this file)
- Acceptance criteria: Camera-forward center-screen raycast resolves a launch direction against world geometry, primary-click spawns/fires a rigid body with deterministic initial transform/impulse from that aim solution, and repeated seeded runs produce identical launch state for the same camera pose/input frame.
- Risks: Camera/physics tick order mismatch can cause one-frame aim divergence, spawn overlap with colliders can create unstable initial contacts, and high impulse magnitudes may destabilize contact stacks or regress runtime step budgets.

#### Projectile Contact Ingestion to Native Core

- Priority: P0
- Owner lane: Scope-A: Physics Bridge Lane (physics-server contact ingestion), Scope-C: Validation Lane (deterministic contact-contract checks), Documentation lane (plan/status tracking in this file)
- Acceptance criteria: Projectile contact manifolds from `PhysicsServer3D` are ingested into native bridge payloads each step with stable schema (`impulse`, `normal`, `contact_point`, `body_id`, `relative_velocity`), ordering is deterministic for identical seeded runs, and mechanics/destruction stages consume the ingested payload without scalar-only side channels.
- Risks: Contact ordering jitter across frames can destabilize deterministic replay, missing/partial manifold fields can silently degrade coupling fidelity, and dense projectile bursts may exceed per-step bridge budget without bounded ingestion caps.

Boundary and scheduling correctness:
- [x] Implement face-stencil boundary behavior (`open`, `inflow/outflow`, `reflective`, `no-slip`, `no-penetration`) — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`; tests: `test_native_general_physics_contracts.gd`.
- [x] Add moving-obstacle boundary handling and deterministic chunk-edge boundary tests. — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`; tests: `addons/local_agents/tests/test_native_general_physics_contracts.gd`, `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [ ] Move foveated/LOD scheduling fully native with conservative coarse/fine transitions and starvation guards.
- [x] Route dynamic obstacle boundaries from `PhysicsServer3D` contact body transforms/velocities rather than parallel custom obstacle solvers. — 2026-02-13. Obstacle boundary dynamics are now sourced from `PhysicsServer3D` contact body velocities, with deterministic aggregator and normalization paths wired through `addons/local_agents/gdextensions/localagents/src/godot/PhysicsServerContactBridge.gd`, `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, and `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineInternal.cpp`.

Wave B validation gates:
- [x] Add deterministic regression scenarios (impact, flood, fire, cooling, collapse, mixed-material transitions). — 2026-02-14. Runtime regression coverage added in `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [x] Add deterministic boundary consistency checks across chunk edges (active-region transition consistency remains follow-up). — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/UnifiedSimulationPipelineFieldEvolution.cpp` ("FieldEvolution.cpp"); tests: `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [x] Require coherent repeated-load terrain response without numerical explosion. — 2026-02-14. Repeated-load stability checks added in `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.

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
- [x] Approved blocker: PHYSICS_SERVER3D_CONTACT_DIVERGENCE
  - Scope: Temporary approved divergence for legacy contact sampling experiments in `test_physics_server_coupling_gate.gd` outside PhysicsServer3D bridge.
  - Owner: Scope-A/Scope-C joint review lane
  - Expires: 2026-03-31
  - Date: 2026-02-14

### Cross-Cutting Refactor Commitments

- [ ] Migrate remaining large numeric `.gd` loops to native by responsibility (orchestration, domain, render adapters, input, HUD).
- [ ] Owner: Scope-Refactor Lane (numeric migration); Timebox: 2-day pass per migration wave, with immediate split when any edited `.gd` file exceeds 600 lines.
- [ ] Keep files under 600-line CI limit while splitting by responsibility.
- [ ] Remove transitional compatibility aliases and duplicate execution paths after extraction.
- [ ] Record all breaking schema/API changes in this section with date stamps.

Test/runtime optimization follow-up:
Completed milestones:
- [x] Test/runtime harness optimization and determinism controls are in place, including fast mode/filtering (`--fast`), process sharding (`--workers=N`), and explicit CPU/GPU mode controls (`--use-gpu`, `--gpu-layers=N`).
- [x] Heavy-test and benchmark controls are available (`benchmark_voxel_pipeline.gd`, runtime override knobs for context/tokens), with reproducible local iteration behavior.
- [x] Deterministic replay timeouts are standardized (`120s` normal shards, `180s` GPU/mobile matrix jobs).

## Breaking Changes

Completed milestones:
- [x] February 12, 2026: Ecology runtime migration completed from legacy hex-grid paths to shared voxel-grid systems (`VoxelGridSystem`, `SmellFieldSystem`, `WindFieldSystem`), making hex/grid contracts non-authoritative for active runtime.
- [x] February 12, 2026: `SpatialFlowNetworkSystem` now drives route keying by voxel coordinates.
- [x] February 12, 2026: Procedural terrain/runtime stack now uses voxel-world generation and deterministic flow payloads (`flow_map`/`columns`/`block_rows`) for hydrology, rendering, and solar/weather propagation.

## Deferred / Decision Log

- [ ] [Owner: Scope-D: Memory/Graph Lane; Decision owner path: `controllers/ConversationStore.gd` -> `docs/NETWORK_GRAPH.md`] Decide whether to keep SQLite-only graph architecture or introduce specialized graph backend.
Completed policy records:
- [x] Whisper backend policy: `whisper.cpp` selected as default for desktop tiers; `faster-whisper` is optional future experimentation.
- [x] Bundled dependency strategy: keep native/runtime dependency pins in scripts/manifests and validate each bump with core/runtime suites before merge.

Policy decisions (recorded February 12, 2026):
- Whisper backend policy: default to `whisper.cpp` CLI/runtime integration for all supported desktop tiers (macOS/Linux/Windows) to preserve single-toolchain native distribution and headless determinism. Treat `faster-whisper` as optional future experimentation only, not a required runtime/backend path.
- Bundled dependency versioning strategy: keep build/runtime dependencies pinned in scripts/manifests, update them via focused additive commits, and validate each bump with headless core + runtime-heavy suites before merge. Runtime artifacts remain out of git history; only scripts/metadata and reproducible fetch/build logic are committed.
