# Local Agents Architecture Plan

This plan is organized by engineering concern so work can be split into focused sub-agents.
It is the single live status tracker for architecture and migration work. Record breaking
API/schema changes here before merge.

Canonical process rules live in `AGENTS.md` and `GODOT_BEST_PRACTICES.md`. The native voxel
target model and migration intent are detailed in `docs/NATIVE_SIM_UNIFICATION_PLAN.md`.

**North-star (see CLAUDE.md + EMERGENCE.md): named phenomena have ZERO dedicated code.** One physical
substrate (matter + pressure/temp/phase/gravity/momentum + chemistry); "volcano/eruption/storm/lava-bomb/
geyser" are outcomes of the universal rules, not systems. Architecture direction: **dissolve** any
named-phenomenon system (a `*Volcano.gd`, an `_is_erupting()`, a burst timer) into the substrate and DELETE
it — disaster actors are seeds/markers/visuals only. Success = special-case code removed, not added.

## Operating Rules

**`CLAUDE.md` holds them. This file keeps exactly one, because it is about this file:**

- **Record breaking API/schema changes here before merge**, with what a consumer has to do about it.

*(Consolidated 2026-08-09. Eleven rules stood here, every one of them also in `CLAUDE.md` — and a third
copy is a third thing to drift, which one of them already had: it stated the file-size gate as
"`MAX_FILE_LINES=1000` soft limit ... warn-only, does not fail CI". The real gate is soft 1300 / hard 1500
and the hard limit FAILS the build. A rule that is confidently wrong is worse than no rule.)*

## Unified GPU Voxel Transform Direction

One unified voxel transform system is the only supported simulation path (no separate
erosion/weather/hydrology/solar systems — those are only preset/config labels). Summary of the
locked invariants (full model in `docs/NATIVE_SIM_UNIFICATION_PLAN.md`):

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
and CI-gate) is tracked below and in `docs/NATIVE_SIM_UNIFICATION_PLAN.md`.

## Active project: godot_voxel ecosystem sim (0.4 — the emergent planet)

The live scene is the from-scratch **godot_voxel ecosystem showcase** at
`addons/local_agents/game/VoxelWorld.tscn` (the project `main_scene`); current
state, layout, and run/verify commands are in `HANDOFF.md`.

As of **0.3** the world is a **chemistry-based cubed-sphere planet**, not a flat island. Terrain is an
SDF sphere (`length(p)-radius - amp·fbm`) with radial `is_solid(pos)`/`sdf_at(pos)`/`up_at`/`altitude_at`
queries. The single simulation substrate is `material/MaterialField3D.gd`, laid over the gnomonic
cubed-sphere grid `LASphereGrid` (a precomputed seam/neighbour table stitches the six cube faces).
Every per-cell process runs as a GPU compute kernel (`material/kernels3d/*_sphere3d.glsl`, driven by
`MaterialSphereGPU3D.gd` and its ordered `material/sphere_passes/*` plugin modules) — there are **no
CPU oracles**; the GLSL kernels are the sole implementation, verified behaviourally.

The substrate is founded on **conserved chemical substances**, not per-phenomenon channels: one
conserved H₂O substance (liquid/vapor/cloud/fog/snow/ice are phases derived from temperature vs
saturation), a `biomass` substance, and a fractional `rock_fill` with a derived solid. Transitions between
substances are **data records** in a generic reaction engine (`material/MaterialReactions3D.gd`) rather than
bespoke code, and every record is checked at load and in CI against one declaration of what each channel is
made OF (`material/reactions/ReactionBalance.gd`).

**The rock has a chemistry as of 2026-08-08.** Three mineral species — silicate CaSiO₃, silica SiO₂,
carbonate CaCO₃ — replace the lumped mineral mass `M`. Every pre-existing mineral phase (`rock_fill`, `lava`,
`sediment`, `dust`, `susp`) is silicate, because they all exchange mass at 1:1 and a transfer may not change
composition; the two new channels exist because the Urey reaction CaSiO₃ + CO₂ → CaCO₃ + SiO₂ has two
products that are not silicate. That reaction is the planet's silicate-weathering carbon sink, and its
reverse at metamorphic temperature (`DECARBONATION_TEMP_C`, derived as ΔH/ΔS) is the volcanic return leg.
**`mineral_total` is no longer the mineral conservation ledger** — it is a unit sum over three different
substances now, so the strict gauge is `lith_element_Ca` / `lith_element_Si`, and the lithosphere's element
book is kept separate from the atmosphere's (`lith_element_*` vs `element_*`) because crustal oxygen is four
orders of magnitude larger and would erase the atmospheric signal.

**Retired:** the old `WorldSimulation`/`PlantRabbitField`/`VoxelWorldDemo` gameplay stack was deleted,
and the **native C++ voxel/sim sources were dropped** — the `localagents` GDExtension now ships only
the llama.cpp/LLM agent runtime. The "Unified GPU Voxel Transform" / projectile-voxel-destruction
material below (and the enforceable destruction wave) describes that **removed** native subsystem; it
is retained as historical native/GPU-first policy and design intent, not as a current live path.

## Current live work and the 0.4 roadmap

**`HANDOFF.md` owns both, and this file deliberately does not.** *(Consolidated 2026-08-09. Two sections
stood here — "Current Live Work" and "0.4 roadmap (deferred — forward-looking)" — restating the queue
HANDOFF exists to be. Two forward-looking lists is one more than can be kept true, and this was the stale
one: its header still called the active project "0.3 — chemistry planet" while 0.4 had been the integration
branch for weeks.)*

**The division:** `HANDOFF.md` is what is LEFT, and an item is deleted the moment it lands. This file is
what SHIPPED and why — breaking changes, the decision log, subsystem status, and what is settled. `CLAUDE.md`
is how to work; `GODOT_BEST_PRACTICES.md` is Godot and runtime knowledge plus the error log.

## Mature Subsystem Status (Concerns A–I)

### Concern A: Runtime and GDExtension Stability
Scope: `addons/local_agents/gdextensions/localagents/`, `runtime/`, `agents/`.
Done: lazy runtime init (`LocalAgentExtensionLoader`) + placeholder panel, preflight binary
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

**CLOSED, and its 50 lines are deleted rather than kept "for context".** The stack it governed was removed;
git is the record. *(Deleted 2026-08-09 — a closed wave in a live design document reads as live work.)*

## What is settled — do not rebuild these

*(Moved from `HANDOFF.md` 2026-08-09: it is a record of what SHIPPED and holds, which is this
file's job, not a map of what is left, which is that one's. It is also the most dangerous list
in either document — work AVOIDS what is on it — so an entry that stops being true has to come
off. `REPOSE_TAN` did, on 2026-08-08: the value was right and the application was not.)*

The H₂O ledger's inclusion rule; the DEFS record engine's std430 layout; the neighbour/tangent tables;
~~`REPOSE_TAN = 0.70`~~ — **it was on this list and it was not sound.** The value is right (tan 35°, the
repose angle of dry granular material, now sourced in `LAPhysical` and gate-bound) but it was APPLIED as a
mass difference against a tangent, which asserts cells are cubes. On the cubed sphere the aspect runs
1.07–4.08, so sediment stood at 33° at the shell floor and 9.8° at the top. Fixed via `LASphereGrid.link_arc`; the soil budget's per-leg identity (`kernel_residual` exactly 0.0); the erosion
transport law (no fitted constant — load moves in the same proportions as the water carrying it); the
geotherm as a seeded initial condition with a derived vertical scale; the aquifer's `k_rel`/`RESIDUAL`
capillary retention; the saturation curve from August-Roche-Magnus; Kozeny-Carman conductivity from porosity;
weathering as ice expansion and Arrhenius dissolution; lithification on real lithostatic pressure; and
metabolism as the substrate's own respiration reaction with mass-scaling emergent rather than typed.

---


## Breaking Changes

- **2026-08-09 (0.4): combustion is a reaction record; `fire_sphere3d.glsl` is deleted.**
  - **Record schema.** The reaction record grew 128 → **144 bytes** (`LAReactionDefs.RECORD_BYTES`) for
    three fields physics forced: `enthalpy_j_m3` (heat per unit of extent, divided by the cell's own heat
    capacity — it cannot be a TEMP product because the balance gate rightly refuses one), `quench_slot` /
    `quench_min` (the supply a reaction goes out BEFORE exhausting — the flammability limit), and
    `t_ceiling_k` (the temperature a rate law stops applying at, moved off the ARRHENIUS branch where it was
    hardcoded to water's boiling point, i.e. a fact about WATER applied to every Arrhenius record there will
    ever be). Any serialised table from an older build is the wrong stride and must be rebuilt; there are no
    persisted record tables, so nothing on disk is affected.
  - **Channel semantics.** `fire` changes meaning from a persistent 0..1 intensity with its own state
    machine to a per-step INSTRUMENT: the fraction of the cell's usable oxygen that combustion consumed,
    where usable means above the flammability limit. Its consumers (`fire_cells`, `fire_peak`, `is_burning`,
    `fungus_sphere3d`'s scorch test) keep their 0.02 thresholds and keep meaning what they meant. `FUEL`
    (slot 5) becomes a real reactable channel with `read_ch`/`add_ch` branches; it was declared in both
    enums with no branch in either, so it read 0 and its writes vanished.
  - **Deleted constants.** `LAPhysical.VEGETATION_IGNITION_C` and `FLAME_RADIATIVE_FRACTION` were that
    kernel's authorities and have no consumer. A solid fuel has no ignition point the way water has a
    freezing point; what is a property of the material is the activation energy of its pyrolysis, which
    lives with the material in `LASubstances`.

- **2026-08-08 (0.4): `LASubstances` is the SSOT for matter, and `PhysicalConstants.gd` is no longer it.**
  - **Where a material property lives.** Every material declares its own in ONE entry — formula, molar
    mass, density, specific heats by phase, phase boundaries, latent heats, conductivity, emissivity,
    albedo, kinetics. `LAReactionBalance.composition()` and `.mol_per_unit()` are VIEWS of it through one
    `SLOT_SUBSTANCE` map, not parallel tables. `PhysicalConstants.gd` keeps only what is NOT a property of
    a substance: gravity, the solar constant, Stefan-Boltzmann.
  - **Channel units.** Organic matter gained a real density (dry wood, 500 kg/m³), so one unit of the
    organic channels is **1951× more substance** than it was when the unit had been inferred from the fire
    kernel's `burned = min(fuel, o2)`. Every cross-substance coefficient in R15/R19/R20 moved by that
    factor, and **`element_*` changed scale**: nothing measured before `557a34b` is comparable on those
    keys. The bio RATE constants were fitted against the old stoichiometry and are still owed a derivation.
  - **Phase is derived, not stored** (`enthalpy_to_state`). No channel collapse has happened yet — `water`,
    `moisture` and `snow` are still three channels — but the table is what they collapse onto, and it is
    what makes latent heat structural rather than a number six records can disagree about.

- **2026-08-08 (0.4): the lumped mineral species `M` is gone, and the field gained two channels.**
  - **Save/field schema.** `carbonate` and `silica` join `LAMaterialSphereGPU3D.SINGLE_CHANNELS`, so
    `snapshot_channels()` writes two more arrays and `restore_channels()` reads them. Restore is
    forward/backward tolerant by construction (unknown keys are ignored, missing keys leave the
    zero-initialised buffer), so an OLD save loads into a new build and starts with no weathering products —
    which is the physically correct state for a planet that has not weathered yet. A NEW save loaded by an
    old build silently drops the two channels. There are no downstream consumers.
  - **Reaction-record schema.** `LAReactionBalance.composition()` no longer declares an `M` substance; the
    element set is C, N, H, O, **Ca, Si**, all atoms. `mol_per_unit()` gives every mineral phase a real molar
    basis instead of `1.0`. Any record written against the old table that puts mineral on one side and atoms
    on the other now has to balance rather than being refused — the M-mixing rejection block is deleted, and
    its own comment named this commit as its removal condition. Slots `CARBONATE = 24` and `SILICA = 25` are
    added; they are the first slots whose numbers do NOT alias their kernel bindings (28 and 29), because the
    alias range ran out at 26.
  - **Gauge contract.** `mineral_total` / `mineral_run_drift_per_step` stop being a conservation claim and
    become a phase budget (they sum three substances now). The replacements are `lith_element_Ca` /
    `lith_element_Si` and their relative run-drifts. New keys: `carbonate_total`, `silica_total`,
    `carbonate_open`, `silica_open`, `carbonate_cells`, `lith_element_*`, `element_C_total`.

- **2026-07-29 (0.4): the addon became installable without reading its source.** A consumer previously
  had to hand-register an autoload, could not reach the model downloader without the native binary the
  downloader was needed to obtain, saw every type twice in Add Node, and configured the whole thing
  through about 25 `LA_*` environment variables. Everything below changed to fix that, and it is all
  source-incompatible. There are no downstream consumers, so nothing was kept in parallel.
  - **Directory layout split three ways.** `addons/local_agents/scenes/simulation/voxel/` is gone.
    `sim/` holds the reusable simulation library (material substrate, ecology, planet generation,
    actors, events, streamer). `game/` holds the Anima game shell (VoxelWorld and its controllers, HUD,
    menus, progression, save) and is deletable. All demos moved into one `examples/`. Roughly 182
    `scenes/simulation/voxel` path literals across 7 shell scripts and 7 docs were updated with it.
  - **Class names canonicalized.** The `LocalAgents<Thing>` prefix is retired: `LocalAgent<Thing>` is
    now a type a user instantiates or annotates against, `LA<Thing>` is a simulation internal. 58
    classes renamed across roughly 96 files. Public sim types were promoted out of the `LA*` namespace:
    `LASimWorld` to `LocalAgentSimWorld`, `LACreature` to `LocalAgentCreature`, `LALlmService` to
    `LocalAgentLlmService`, `LACognitionScheduler` to `LocalAgentCognitionScheduler`, `LATutorialStep`
    to `LocalAgentTutorialStep`. `Creature`'s 26 sibling modules stay `LA*`.
  - **Types removed.** `configuration/parameters/ModelParams` (its `.tres` wrote five properties the
    script did not declare, all silently dropped on load), `agents/Character.gd` and its `.tres` (no
    consumer), `runtime/RuntimeHealth.gd` (absorbed by `LocalAgentStatus`), `api/DownloadClient.gd` and
    the now-empty `api/` (the editor now uses the pure-GDScript `ui/ModelDownloadManager.gd`, which
    needs no native binary), and `addons/phantom_camera/` (122 files, zero references).
  - **`LocalAgent.configure()` resignatured** and now takes a `LocalAgentModelProfile` plus a
    `LocalAgentInferenceParams`. It replaces `inference_options` wholesale, which is why load-time knobs
    moved into a separate `load_options` dictionary: writing a profile into `inference_options` meant
    `configure()` silently discarded it, and model profiles were entirely inert as a result. Precedence
    is `load_options`, then `inference_options`, then per-call extras.
  - **`think()` / `think_async()` error codes changed.** They no longer return the undiagnostic
    `"agent_unavailable"`. They return the specific `LocalAgentStatus` blocker code plus a `detail`
    string. `system_prompt` is now injected as a system message at `history[0]` rather than passed in
    the options dictionary, which the native runtime never read.
  - **The editor plugin no longer calls `add_custom_type`.** Every one of those scripts already
    self-registers through `class_name`, so the aliases were the duplicate-entry bug. The plugin now
    registers the `AgentManager` autoload itself, in `_enter_tree` rather than on panel activation, so
    it exists with or without the native binary. The bottom panel is no longer gated on the extension.
  - **Tuning moved from environment variables to ProjectSettings**, resolved ProjectSetting, then env
    var, then default (`runtime/Settings.gd`), so existing `LA_*` variables keep working in CI. Debug
    and CI-only knobs (`LA_ABLATE`, the `LA_NO_*` kill switches, `LOCAL_AGENTS_TEST_*`) stay env-only.
  - **`addons/local_agents/tests/.gdignore` added**, so about 50 test scripts stop importing into a
    consumer's project. The harness invokes them by path, so it is unaffected.
  - New gates, all wired into `scripts/agent_harness.sh lint`: `check_library_only.sh` (the addon still
    parses with the game deleted and no zylann.voxel), `check_tool_safety.sh` (no `@tool` script writes
    serialized state in the editor), `check_demo_catalog.sh` (the demo catalogue matches disk).
    `scripts/check_dropin_scene.sh` is separate because it costs about 25s: it builds a consumer
    project from scratch and proves a scene with no script in it produces a reply from a local model.

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
