# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.
It is the single live status tracker for architecture and migration work. Record breaking
API/schema changes here before merge.

Canonical process rules live in `AGENTS.md` and `GODOT_BEST_PRACTICES.md`. The native voxel
target model and migration intent are detailed in `NATIVE_SIM_UNIFICATION_PLAN.md`.

**North-star (see CLAUDE.md + EMERGENCE.md): named phenomena have ZERO dedicated code.** One physical
substrate (matter + pressure/temp/phase/gravity/momentum + chemistry); "volcano/eruption/storm/lava-bomb/
geyser" are outcomes of the universal rules, not systems. Architecture direction: **dissolve** any
named-phenomenon system (a `*Volcano.gd`, an `_is_erupting()`, a burst timer) into the substrate and DELETE
it — disaster actors are seeds/markers/visuals only. Success = special-case code removed, not added.

## Operating Rules

- Use concern-based workstreams; keep diffs small and reviewable.
- Signal up / call down (mediator orchestration) for cross-system flows.
- Record breaking API/schema changes in this file before merge.
- No "transitional shims": we do not label non-native/non-GPU code as a temporary stopgap and park it
  on a debt list. Build native/GPU-first, or improve the code directly as ordinary code. A CPU
  implementation kept as a genuine headless/no-GPU **fallback** for a GPU kernel is legitimate and
  permanent — a first-class part of the design, not tracked as debt to retire. (Perf over parity: it is a
  fallback, not a bit-exact contract; verify GPU behaviourally.)
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

## Active project: godot_voxel ecosystem sim (0.3 — chemistry planet)

The live scene is the from-scratch **godot_voxel ecosystem showcase** at
`addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn` (the project `main_scene`); current
state, layout, and run/verify commands are in `TODO.md`.

As of **0.3** the world is a **chemistry-based cubed-sphere planet**, not a flat island. Terrain is an
SDF sphere (`length(p)-radius - amp·fbm`) with radial `is_solid(pos)`/`sdf_at(pos)`/`up_at`/`altitude_at`
queries. The single simulation substrate is `material/MaterialField3D.gd`, laid over the gnomonic
cubed-sphere grid `LASphereGrid` (a precomputed seam/neighbour table stitches the six cube faces).
Every per-cell process runs as a GPU compute kernel (`material/kernels3d/*_sphere3d.glsl`, driven by
`MaterialSphereGPU3D.gd` and its ordered `material/sphere_passes/*` plugin modules) — there are **no
CPU oracles**; the GLSL kernels are the sole implementation, verified behaviourally.

The substrate is founded on **conserved chemical substances**, not per-phenomenon channels: one
conserved H₂O substance (liquid/vapor/cloud/fog/snow/ice are phases derived from temperature vs
saturation), a `biomass` substance, and a unified fractional `rock_fill` with a derived solid + a
`mineral_total` conservation ledger. Transitions between substances are **data records** in a generic
reaction engine (`material/MaterialReactions3D.gd`) rather than bespoke code.

**Retired:** the old `WorldSimulation`/`PlantRabbitField`/`VoxelWorldDemo` gameplay stack was deleted,
and the **native C++ voxel/sim sources were dropped** — the `localagents` GDExtension now ships only
the llama.cpp/LLM agent runtime. The "Unified GPU Voxel Transform" / projectile-voxel-destruction
material below (and the enforceable destruction wave) describes that **removed** native subsystem; it
is retained as historical native/GPU-first policy and design intent, not as a current live path.

## Current Live Work

Active threads (details and acceptance criteria are captured per-lane in commits/PRs; git history
records superseded wave-by-wave inventories):

- Native/GPU + shader-first migration: move practical GDScript runtime logic to C++ GDExtension
  call surfaces and practical CPU work to GPU/shader paths; keep GDScript as thin
  forwarding/HUD orchestration only. Remaining CPU/GDS pieces are migration targets to build out
  native/GPU-first — not tracked as debt.
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
- Unified material substrate (`LAMaterialField`): a 2.5D cellular automaton over per-XZ columns that
  owns heat, liquid water, lava, the vapor→cloud/fog→rain cycle, gravity, and combustion. Water is
  unified here (springs → rivers/lakes → ocean; the calm sea is a cheap static GPU `LAOceanPlane` and
  the CA mesh renders only deviations/freshwater); query API `is_water_at`/`is_ocean_at`/`surface_y_at`/
  `depth_at`/`temp_at`/`salinity_at`. Evaporation off warm water → vapor → condenses (cool surface cells
  pool ground FOG, cooler-aloft cells form CLOUD) → thick cloud rains back and shades the sun; wind
  advects the airborne quantities while liquid flows by gravity (rendered by `LACloudLayer`). The hot
  loops run on `RenderingDevice` compute (`material/MaterialGPU3D.gd` + `material/kernels3d/*.glsl`); the
  CPU step is the permanent headless/no-GPU fallback (not a parity contract).
- Dense 3D material field (`LAMaterialField3D`, in progress): the DENSE 3D successor to the 2.5D field
  — a temperature + per-material amount for every (x,y,z) cell — so fluids interact with the terrain
  caves (water pools in caverns, lava drains into tubes, gas rises shafts) instead of being clamped to
  a surface column. Dense (flat 3D array, ~20 MB at 5-unit resolution) rather than sparse bricks. 3D
  water CA is validated in isolation; heat/atmosphere/lava passes and `VoxelWorld` integration remain.
  Design rationale is in the `MaterialField3D.gd` header.

Validation for player-facing destruction work is non-headless launch first, then headless sweeps
(`run_all_tests.gd`, `run_runtime_tests_bounded.gd`, destruction/fps-fire harnesses).

## 0.4 roadmap (deferred — forward-looking)

These are the next architecture moves, all deferred out of 0.3. Full context + acceptance notes live in
`TODO.md` (Phase C) and the design docs in-tree. Marked clearly as **not yet done**.

- **Event tracker + lightning-as-event.** A discrete-event layer (`on_ejecta`/`on_impact`/`on_bolt`
  style callbacks) so named moments surface for FX/telemetry/commentary without per-phenomenon code;
  lightning becomes the reference event (charge already fires bolts — the tracker just observes it).
- **Remaining disaster dissolutions.** Continue dissolve-don't-patch through Tornado (vorticity → force
  replaces `_fling_wildlife`), Hurricane, Thunderstorm, Earthquake, Meteor — measuring success in
  special-case code deleted. Volcano (0.3) is the pattern to follow.
- **Ejecta / meteor as a momentum primitive.** The keystone `C0` move: pressure/vorticity/kinetic →
  momentum on matter (ejecta parcels that arc under radial gravity and re-deposit heat + rock/sediment),
  plus the reference-frame handoff so a lava bomb can leave one body and land on another.
- **Composition-per-cell (metals / ores / salts).** A thin composition slice on top of the DEFS slot
  registry — build only when a metal/ore feature is wanted.
- **Mantle convection.** Real radial magma/geothermal circulation in the innermost layers (the current
  core is a seeded heat source).
- **Time-bubble tool.** A localized fast-forward / time-scale control for slow-emergent phenomena
  (island-building, forest succession, erosion) so geological time compresses to seconds.
- **Activity bubbles (scaling lever).** Per-tile activity/sleep + indirect dispatch so quiescent regions
  skip work — the primary lever for affording whole-planet (and eventually multi-body) fields.

The committed longer arc remains a **solar system of bodies** (Outer-Wilds scale): orbiting/spinning
bodies with body-local fields, an n-body attractor integrator + a GPU test-particle buffer for
ejecta/debris. See `TODO.md` (SOLAR-SYSTEM-FIRST) for the full plan.

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
  hazards) with one migrated gameplay/AI consumer; perf + behavioural-aggregate CI gates.
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
  - Any remaining non-native/non-GPU path segments are migration targets built out native/GPU-first, or
    legitimate CPU fallbacks — never parked as tolerated "shims."
- Acceptance criteria:
  - Every successful projectile impact records native mutation evidence and shader-backed metadata.
  - Missing GPU/native prerequisites hard-fail with typed reasons (`GPU_REQUIRED`/`gpu_unavailable`,
    `NATIVE_REQUIRED`/`native_unavailable`); no path reports success without native `changed=true`.
  - The legacy-adapter migration list below stays complete with `owner`, `done when`,
    `target wave`, and `blocker` for each entry.
- Verification commands (run in order):
  1. `./scripts/run_fps_fire_destroy.sh --timeout=120 --test_mode_minimized=true`
  2. `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
  3. `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
  4. `scripts/run_single_test.sh test_projectile_voxel_destruction_runtime_path.gd --timeout=180`
  5. `scripts/run_single_test.sh test_native_orchestration_dispatch_runtime_contract.gd --timeout=180`
- Wave invariants: `INV-NATIVE-001`, `INV-GPU-001`, `INV-FALLBACK-001`, `INV-CONTRACT-001`,
  `INV-HANDSHAKE-001`, `INV-PROJECTILE-DIRECT-001`, `INV-NO-GDS-MULTIHOP-001`.
- Legacy adapters being migrated to native/GPU-first (required fields):
  - Adapter: `addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd`
    - owner: Runtime Bindings lane
    - done when: native dispatch bridge consumes normalized contact and mutation payloads end-to-end with no GDS mutation decisions.
    - target wave: `Wave 0F`
    - blocker: runtime telemetry aggregates must stay behaviourally sane for existing harness assertions.
  - Adapter: `addons/local_agents/scenes/simulation/controllers/world/WorldSimulation.gd` projectile dispatch adapter
    - owner: Runtime Simulation lane
    - done when: per-frame projectile contact sampling and handoff fully delegated to the native contract payload builder.
    - target wave: `Wave 0E`
    - blocker: active launcher input hooks still attach through world controller glue.
  - Adapter: `addons/local_agents/native/LocalAgentsVoxelDispatchBridge.gd` pre-dispatch CPU contact reduction
    - owner: Native Compute lane
    - done when: staged GPU contact reduction hook is enabled by default and the CPU pre-reduction path is deleted.
    - target wave: `Wave 0T`
    - blocker: GPU reduction diagnostics contract is not yet wired into all runtime verification harnesses.

## Breaking Changes

- **2026-07 (0.3): flat/box world removed — the cubed-sphere planet is the sole world.** The
  origin-centered box `MaterialField3D` grid, its box GPU driver, the dead box `_physics_process` step
  branch, and the 21 CPU-oracle + box-GPU field modules were deleted, along with 32 dead box
  `*3d.glsl` kernels and the flat/2.5D code paths across terrain/ocean/camera/actors (~11,000+ lines
  removed). The field now lives on `LASphereGrid`; kernels are `*_sphere3d.glsl` only. There is no CPU
  parity oracle — verification is behavioural (`SIM_REPORT` aggregates), per the perf-over-parity rule.
- **2026-07 (0.3): substrate re-founded on conserved substances + data-driven reactions.** Separate
  vapor/cloud/fog channels were fused into one conserved `_airwater` channel and snow/ice folded into
  the same H₂O substance; a `biomass` substance and a unified fractional `rock_fill` (derived solid +
  `mineral_total` ledger) were added. Same-cell chemistry (gas sky-exchange, fungus decompose,
  photosynthesis/respiration, freeze/melt, dust-loft) moved into reaction **records** in
  `MaterialReactions3D.gd` — adding a reaction is a data record, not a kernel.
- **2026-07 (0.3): scripted `Volcano.gd` eruption logic dissolved.** A seabed vent builds an island
  emergently (magma → water-quench solidify → `rock_fill` accumulation → `MineralStamp3D` SDF growth);
  the actor is now seed + FX only.
- **2026-07 (0.3): render/actor consolidation.** `RainLayer`/`CloudLayer` dissolved into one
  `WaterParticles.gd` GPU renderer (phase-selected cloud/fog/rain/snow); `VoxelWorld` and
  `MaterialField3D` split into focused controllers; the throwaway A0/A1 spike harnesses and
  `PlanetPreview` removed.
- 2026-07: Active scene is the from-scratch godot_voxel ecosystem sim
  (`scenes/simulation/voxel/VoxelWorld.tscn`). The old `WorldSimulation`/`PlantRabbitField`/
  `VoxelWorldDemo` gameplay stack and the homegrown voxel-grid runtime were deleted; the LLM editor
  plugin was uncoupled from the old-sim Flow config.
- 2026-07: Native C++ voxel/sim sources dropped from the `localagents` GDExtension — it now ships only
  the llama.cpp/LLM agent runtime (AgentRuntime/AgentNode/NetworkGraph/ModelDownloadManager). The
  simulation runs in GDScript with GPU compute for the material field; the projectile-voxel-destruction
  native path and its tests/scripts (`run_destruction_tests.sh`, `benchmark_voxel_pipeline.gd`,
  `test_native_voxel_op_*`) are removed.
- 2026-07: In the voxel scene, `WaterFieldSystem.gd` and `FireSystem.gd` were folded into
  `LAMaterialField` (water is unified CA; wildfire is the combustion pass). No standalone water/fire
  systems remain.
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
