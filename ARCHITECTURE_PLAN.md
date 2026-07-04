# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.
It is the single live status tracker for architecture and migration work. Record breaking
API/schema changes here before merge.

Canonical process rules live in `AGENTS.md` and `GODOT_BEST_PRACTICES.md`. The native voxel
target model and migration intent are detailed in `NATIVE_SIM_UNIFICATION_PLAN.md`.

## Operating Rules

- Use concern-based workstreams; keep diffs small and reviewable.
- Signal up / call down (mediator orchestration) for cross-system flows.
- Record breaking API/schema changes in this file before merge.
- Every remaining non-native/non-GPU runtime path is a tracked transitional shim only, with an
  explicit `owner`, `removal trigger`, and `target wave`. Do not grow net-new shims.
- File-size discipline: `scripts/check_max_file_length.sh` reports first-party files over a
  `MAX_FILE_LINES=1000` **soft limit** as advisory warnings (warn-only, does not fail CI).
  Treat 1000 lines as a smell — split by responsibility before then; do not block work on it.

## Unified GPU Voxel Transform Direction

One unified voxel transform system is the only supported simulation path (no separate
erosion/weather/hydrology/solar systems — those are only preset/config labels). Summary of the
locked invariants (full model in `NATIVE_SIM_UNIFICATION_PLAN.md`):

- All active voxels/chunks execute via GPU shader passes; GPU is required. Missing GPU capability
  is a hard fail with an explicit typed status. No CPU-success fallback for transform execution.
- Condense/spread/split/spawn/fracture/transport/reaction/phase-change are generic transform ops
  under shared, typed pass descriptors with a fixed deterministic pass DAG per tick.
- Canonical voxel schema requires explicit material identity (`material_id`,
  `material_profile_id`, `material_phase_id`) plus dynamics fields; precision is `fp32` by
  default, switchable to `fp64` via `precision_profile=fp64` with identical pass contracts.
- Active-set scheduling is mandatory: sleep-by-default chunks/voxels, two-tier wake, dirty+halo
  invalidation, sparse-brick residency, GPU stream compaction, deterministic multi-rate passes.
- Godot `PhysicsServer3D`/`RigidBody3D` provide contact/impulse inputs only; they never own
  authoritative voxel transform state. `RigidBody3D` usage stays exception-based.
- Failure taxonomy: `gpu_required`, `gpu_unavailable`, `contract_mismatch`, `descriptor_invalid`,
  `dispatch_failed`, `readback_invalid`, `memory_exhausted`, `unsupported_legacy_stage`.
- Legacy named transform systems are removed; requests referencing them fail with
  `unsupported_legacy_stage` (no implicit remap, no compatibility adapters).

Migration sequencing (P0 lock architecture -> P1 unify op schema/pass descriptors -> P2 enforce
and CI-gate) is tracked below and in `NATIVE_SIM_UNIFICATION_PLAN.md`.

## Current Live Work

Active threads (details and acceptance criteria are captured per-lane in commits/PRs; git history
records superseded wave-by-wave inventories):

- Native/GPU + shader-first migration: move practical GDScript runtime logic to C++ GDExtension
  call surfaces and practical CPU work to GPU/shader paths; keep GDScript as thin
  forwarding/HUD orchestration only. Remaining CPU/GDS pieces are tracked transitional shims.
- Unified Shader-Max impact pipeline: one authoritative ingress schema + one native mutation path
  for initial projectile impact, debris impact, and re-impact. GPU owns contact reduction,
  durability/chip accumulation, and fracture spawn-entry generation; C++ is orchestration-only;
  GDS is binding-only. Typed reduction diagnostics (`input_rows`, `output_rows`, `reduction_stage`).
- Global solid-voxel destructibility: material-dependent hit durability driving removal thresholds,
  with observable partial-fracture states before terminal removal.
- GPU chip/durability metadata forwarding: preserve chip/durability fields through parser + GPU
  executor and forward into engine `execution`/`result` payloads so the native mutator consumes
  them directly instead of recomputing.
- Native fracture debris emission on authoritative mutation
  (`LocalAgentsFractureDebrisEmitter`), bounded by per-mutation/active caps, with runtime evidence.
- Voxel destruction orchestration consolidated into native `LocalAgentsVoxelDispatchBridge`
  (`impact contact -> C++ mutation -> apply result`); `WorldDispatchController` is a thin adapter.
- No-inference mutation rule: `mutation_applied` is true only when the native mutator returns
  `changed=true`; no synthetic/inferred success anywhere.
- Boids migration to shader-authoritative compute with a minimal native bridge
  (`LocalAgentsBoidsNativeBridge`) and typed fail-fast (`GPU_REQUIRED`/`NATIVE_REQUIRED`,
  `CPU_FALLBACK_FORBIDDEN`); no synthetic success on unsupported dispatch.
- Runtime Bindings thin-orchestration migration: native API owns per-frame queue/deadline/cadence
  decisions; GDScript forwards context and applies native contract outputs. Keep helper files
  under the soft size limit by extracting responsibilities before behavior growth.
- Native shutdown RID teardown ordering: release GPU RIDs while rendering APIs are still available;
  no `free_rid` from late thread-local teardown; no RID-leak warnings on shutdown.

Validation for player-facing destruction work is non-headless launch first, then headless sweeps
(`run_all_tests.gd`, `run_runtime_tests_bounded.gd`, destruction/fps-fire harnesses).

## Mature Subsystem Status (Concerns A–I)

### Concern A: Runtime and GDExtension Stability
Scope: `addons/local_agents/gdextensions/localagents/`, `runtime/`, `agents/`.
Done: lazy runtime init (`LocalAgentsExtensionLoader`) + placeholder panel, preflight binary
checks and `Agent`/`AgentNode` safety guards, fresh-machine init validation, structured
editor/test runtime health visibility.

### Concern B: Model Download and Asset Pipeline
Scope: download controllers/services, `ModelDownloadManager.cpp`, fetch scripts.
Done: runtime + GDScript download pipeline with shared UI/headless orchestration and
progress/log/finished signaling, fixed dependency fetch path resolution, checksum/manifest
verification for model/voice artifacts.

### Concern C: Chat, Controller Boundaries, and Scene Architecture
Scope: chat/agent-manager controllers, editor, configuration UI.
Done: chat/download/configuration panels composed with runtime-state badges, runtime-safe
null-guarding and runtime-vs-editor flow separation, controller decomposition toward
mediator + focused conversation/session/history services.

### Concern D: Memory and Graph Capabilities
Scope: `ConversationStore.gd`, `docs/NETWORK_GRAPH.md`, memory/graph tabs.
Done: conversation persistence + search scaffolding via `NetworkGraph`.
Pending: finalize memory/edge/episode/embedding schema + indices, embedding write pipeline and
recall APIs (query/top-k/pagination), migration/maintenance tooling, editor Memory/Graph tabs.

### Concern E: Speech and Transcription
Scope: `SpeechService.gd`, `Agent.gd`, native speech/transcription hooks.
Done: async speech/transcription hooks integrated end-to-end with async playback callbacks;
deterministic success/failure smoke tests and voice-asset reporting.

### Concern F: Test Strategy and CI Gating
Scope: `addons/local_agents/tests/*`, CI.
Done: headless + runtime-heavy harness (`run_all_tests.gd`, `test_model_helper.gd`) with
auto-model acquisition; CI policy for loud failure on acquisition/inference errors with separate
core/runtime jobs and artifact/log collection.

### Concern G: Cross-Platform Build and Packaging
Scope: build scripts, release packaging, binary layout.
Done: macOS/Linux/Windows bundled binaries + llama tools, `build_all.sh` + per-platform
reproducible packaging, release size/perf regression checks. A cross-platform CI build matrix
(`.github/workflows/build-extension.yml`) produces linux/windows/macos `bin/` artifacts.

### Concern H: Demos, Docs, and Onboarding
Scope: `README.md`, examples, docs, screenshots/tutorials.
Done: core docs/examples with runtime-heavy test behavior documented, 3D demo parity + HUD
polish, refreshed tutorials/screenshots around download and runtime-health workflows.
Pending doc guards: enforce single-test harness entrypoint everywhere (forbid direct
`godot -s addons/local_agents/tests/test_*.gd`), standardize on `WorldSimulation` +
`CoreSimulationPipeline` naming, document GPU-only destruction demo readiness.

### Concern I: Voxel Physics Engine Upgrades (Native-First)
Scope: `gdextensions/localagents/*`, `simulation/*`, native tests, world controllers.
Policy (locked 2026-02-13): Godot `PhysicsServer3D` (Jolt-backed) is the required
rigid-body/contact/collision backend; the native voxel core owns field PDEs, fracture criteria,
and voxel-edit emission; a bridge layer owns deterministic bidirectional coupling. No custom
rigid-body server unless a documented `PhysicsServer3D` blocker is recorded here.

- Wave A (complete): native field registry schema + units/range validation, handle-driven hot
  stages (`mechanics`/`pressure`/`thermal`/`reaction`/`destruction`) preferring native field
  handles with reason-coded compatibility fallback, continuity carry-forward across `execute_step`,
  physics-server contact ingestion + voxel response feedback, deterministic stage/boundary tests.
  Durable data contracts: `transform_snapshot`, `transform_diagnostics`, `field_handle_mode`.
- Wave B (in progress): multi-reaction channels with stoichiometry + oxidizer/pressure/temperature
  coupling and mass/energy closure; replace scalar damage with stress-invariant failure criteria
  (Mohr-Coulomb / Drucker-Prager-lite) plus plastic-compaction/brittle branches coupled to
  porosity/permeability; native LOD scheduler with starvation guards. Includes deterministic
  cleave and fractal/noise-driven failure variation, FPS-style rigid-body launcher, and projectile
  contact ingestion to the native core.
- Wave 1 / Wave C (planned/in progress): voxel kernel pass abstraction (`VoxelEditStageCompute.glsl`
  as a multi-pass surface behind `VoxelEditGpuExecutor` with typed `kernel_pass` descriptors);
  GPU-first runtime with `headless_gpu_dispatch_contract` fail-fast codes, compute kernels for hot
  stages with resident GPU fields, ping-pong/barriers, active-set sleep/wake + sparse-brick
  residency + stream compaction, multi-rate/fusion scheduling, shader/pipeline resource caching;
  native query surface (pressure gradients, heat fronts, failure/ignition risk, flow, top-k
  hazards) with one migrated gameplay/AI consumer; GPU-vs-CPU parity/perf CI gates.
- `VoxelEditEngine` stays orchestration-only (no inline shader/pipeline selection, no CPU-success
  path); pass resolution/dispatch lives in `VoxelEditGpuExecutor`. Split oversized source by
  responsibility per the soft size limit.
- Approved blocker `PhysicsServer3D-contact-divergence-v1` (2026-02-14): `PhysicsServer3D` remains
  the authoritative contact source; bridge adapters may only normalize contact payloads.

## Enforceable P0 Wave: WF-P0-SHADER-VOXEL-DESTRUCTION-2026-02-17

This block is the canonical enforceable-wave contract for the destruction path (retained as the
single authoritative wave record; superseded per-wave inventories live in git history).

- Priority: `P0`
- Owners:
  - Planning lane, Native Compute lane, Shader/Rendering lane, Runtime Bindings lane,
    Validation/Test-Infrastructure lane, Documentation lane.
- Scope:
  - Make projectile voxel destruction authority shader-first plus native C++ mutation execution.
  - Remove GDScript outcome interpretation on the projectile impact path.
  - Preserve direct chain authority only: `impact contact -> C++ mutation -> apply result`.
  - Keep remaining non-native/non-GPU path segments as transitional shims only.
- Acceptance criteria:
  - Every successful projectile impact records native mutation evidence and shader-backed metadata.
  - Missing GPU/native prerequisites hard-fail with typed reasons (`GPU_REQUIRED`/`gpu_unavailable`,
    `NATIVE_REQUIRED`/`native_unavailable`); no path reports success without native `changed=true`.
  - The transitional shim inventory below stays complete with `owner`, `removal trigger`,
    `target wave`, and `blocker` for each shim.
- Verification commands (run in order):
  1. `./scripts/run_fps_fire_destroy.sh --timeout=120 --test_mode_minimized=true`
  2. `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
  3. `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
  4. `scripts/run_single_test.sh test_projectile_voxel_destruction_runtime_path.gd --timeout=180`
  5. `scripts/run_single_test.sh test_native_orchestration_dispatch_runtime_contract.gd --timeout=180`
- Wave invariants: `INV-NATIVE-001`, `INV-GPU-001`, `INV-FALLBACK-001`, `INV-CONTRACT-001`,
  `INV-HANDSHAKE-001`, `INV-PROJECTILE-DIRECT-001`, `INV-NO-GDS-MULTIHOP-001`.
- Transitional shim inventory (required fields):
  - Shim: `addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd`
    - owner: Runtime Bindings lane
    - removal trigger: native dispatch bridge consumes normalized contact and mutation payloads end-to-end with no GDS mutation decisions.
    - target wave: `Wave 0F`
    - blocker: runtime telemetry parity must remain stable for existing harness assertions.
  - Shim: `addons/local_agents/scenes/simulation/controllers/world/WorldSimulation.gd` projectile dispatch adapter
    - owner: Runtime Simulation lane
    - removal trigger: per-frame projectile contact sampling and handoff fully delegated to the native contract payload builder.
    - target wave: `Wave 0E`
    - blocker: active launcher input hooks still attach through world controller glue.
  - Shim: `addons/local_agents/native/LocalAgentsVoxelDispatchBridge.gd` pre-dispatch CPU contact reduction
    - owner: Native Compute lane
    - removal trigger: staged GPU contact reduction hook is enabled by default and the CPU pre-reduction path is deleted.
    - target wave: `Wave 0T`
    - blocker: GPU reduction diagnostics contract is not yet wired into all runtime verification harnesses.

## Breaking Changes

- 2026-02-12: Ecology runtime migrated from legacy hex-grid paths to shared voxel-grid systems
  (`VoxelGridSystem`, `SmellFieldSystem`, `WindFieldSystem`); hex/grid contracts are non-authoritative.
- 2026-02-12: `SpatialFlowNetworkSystem` keys routes by voxel coordinates.
- 2026-02-12: Procedural terrain/runtime stack uses voxel-world generation and deterministic flow
  payloads (`flow_map`/`columns`/`block_rows`); named weather/hydrology/erosion/solar stages are
  non-authoritative legacy terms.

## Deferred / Decision Log

- Open (Memory/Graph lane): decide whether to keep SQLite-only graph architecture or introduce a
  specialized graph backend (`ConversationStore.gd` -> `docs/NETWORK_GRAPH.md`).
- Whisper backend policy (2026-02-12): default to `whisper.cpp` CLI/runtime for all supported
  desktop tiers to preserve single-toolchain native distribution and headless determinism;
  `faster-whisper` is optional future experimentation only, not a required runtime path.
- Bundled dependency strategy (2026-02-12): keep build/runtime dependencies pinned in
  scripts/manifests, update via focused additive commits, and validate each bump with headless
  core + runtime-heavy suites before merge. Runtime artifacts stay out of git history — only
  scripts/metadata and reproducible fetch/build logic are committed.
