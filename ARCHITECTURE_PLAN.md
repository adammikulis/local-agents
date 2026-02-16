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

## Ordered Wave Sequence (Planning lane update 2026-02-16)

- [ ] Wave 0 (`P0`): Full native/GPU destruction authority migration.
  - Priority and owner lanes:
    - `P0`: Planning lane owns scope lock, fallback inventory, and phase gate definitions.
    - `P0`: Runtime Simulation lane owns removal of GDScript simulation-authority branches (keep orchestration only).
    - `P0`: Native Compute lane owns native contract completion and GPU-required execution enforcement.
    - `P0`: Validation/Test-Infrastructure lane owns gate evidence and fallback-forbidden assertions.
    - `P1`: Documentation lane owns migration log, runbook updates, and invariant wording synchronization.
  - Explicit mandate:
    - Simulation-authoritative execution is native + GPU only.
    - GDScript and CPU paths are orchestration/adapters only and must not become success-authoritative simulation fallbacks.
    - Any missing required native/GPU capability is a hard failure, never a degraded success path.
  - File-size preconditions (must be satisfied before implementation edits):
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` is currently near hard cap at ~992 lines; treat as split-required before adding new logic.
    - No wave task may increase `NativeComputeBridge.gd` above 1000 lines; move non-call-site logic into focused helpers/modules first.
    - If any planned delta touches `NativeComputeBridge.gd`, run a pre-edit extraction lane (or equivalent helper split) before behavior changes.
  - Invariants (must hold before exit):
    - `INV-NATIVE-001`: All voxel mutation, destruction, and simulation hot stages execute through native contracts.
    - `INV-GPU-001`: Required GPU capabilities are present for active runtime; otherwise startup/stage exits with explicit failure (`GPU_REQUIRED` / `gpu_unavailable`).
    - `INV-FALLBACK-001`: No CPU-success or GDScript-success fallback branch exists for primary simulation outcomes.
    - `INV-CONTRACT-001`: Native dispatch/mutation failures are explicit and typed; silent no-op success is forbidden.
    - `INV-VALIDATION-001`: "works/ready" claims require non-headless evidence first, then full headless sweeps on the same tree.
  - Phased execution and acceptance gates:
    - Phase A (Inventory + lock):
      - Produce exact fallback inventory (file + branch + reason) for active simulation hot paths.
      - Gate A acceptance: inventory is complete, owner-assigned, and no unresolved fallback branch remains untracked.
    - Phase B (Contract hardening):
      - Add/align typed native dispatch result taxonomy and fail-fast reason codes at all simulation boundaries.
      - Gate B acceptance: every hot-stage call-site returns explicit typed failure when native/GPU preconditions fail.
    - Phase C (Primary-path cutover):
      - Route all authoritative simulation mutations/destruction through native/GPU path only.
      - Gate C acceptance: contract tests prove canonical native path authority; fallback path assertions removed or converted to forbidden checks.
    - Phase D (Fallback removal + error policy enforcement):
      - Remove/deactivate remaining CPU/GDScript success fallback branches in simulation hot paths.
      - Gate D acceptance: static + runtime checks show zero reachable CPU-success fallback path for simulation-authoritative outcomes.
    - Phase E (Verification + closeout):
      - Run required validation order and capture artifacts for non-headless + headless suites.
      - Gate E acceptance: all mandatory commands pass on latest tree; docs + breaking change notes updated.
  - Concrete migration checklist:
    - [ ] Enumerate all simulation-authoritative branches currently executable outside native/GPU path.
    - [ ] Tag each branch as remove/replace/delegate and assign owner lane + target wave.
    - [ ] Lock typed error taxonomy for native-required and GPU-required failures.
    - [ ] Convert any "fallback success" branch to explicit fail-fast outcome with diagnostics.
    - [ ] Ensure runtime orchestrators only delegate to native contracts for mutation/destruction decisions.
    - [ ] Add or update tests to assert `backend_used` is native/GPU on primary simulation paths.
    - [ ] Add or update tests to assert missing native/GPU requirements fail with explicit typed reasons.
    - [ ] Execute mandatory validation sequence and attach evidence before status claims.
  - Acceptance criteria:
    - Destruction/mutation authority is native/GPU only across active runtime hot paths.
    - No CPU-success or GDScript-success fallback branch remains reachable for simulation-authoritative outcomes.
    - Native/GPU precondition failures emit explicit typed reason codes (`GPU_REQUIRED`/`gpu_unavailable`, `NATIVE_REQUIRED`/`native_unavailable`).
    - Validation evidence is recorded in required order on the same tree.
  - Required validation order:
    - Non-headless launch first (real display path) to verify startup and active runtime path on GPU-backed execution.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] Wave 1 (`P0`): Hard-fail mutation-deadline invariant + destruction reliability continuation.
  - Owner lanes:
    - Planning lane: invariant contract (`MAX_PROJECTILE_MUTATION_FRAMES`) and merge checkpoints.
    - Runtime Simulation lane: projectile hit metadata emission/handoff (`projectile_id`, `hit_frame`, `deadline_frame`).
    - Native Compute lane: deadline enforcement and explicit `PROJECTILE_MUTATION_DEADLINE_EXCEEDED` emission.
    - Validation/Test-Infrastructure lane: bounded-frame contract and reliability regression matrix.
    - Documentation lane (`P1`): migration + invariant notes after verification.
  - Acceptance criteria:
    - Valid destructible-hit projectiles mutate within bound or emit explicit deadline error (no silent no-op).
    - Destruction reliability remains deterministic across repeated seeded runs.
    - No active fallback path bypasses mutation decisioning.
  - Risks:
    - Frame-counter ownership drift between launcher/bridge/native can cause false deadline misses.
    - Reliability fixes can mask queue backpressure if observability is incomplete.
  - Required validation order:
    - Non-headless launch first (real display path) to confirm startup + FPS projectile destruction behavior.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [~] Wave 2 (`P0`): Collapse mutator to one canonical op path.
  - Status (2026-02-16): Planning lane scope finalized for canonical single mutation path; implementation and validation lanes pending execution.
  - Owner lanes:
    - Planning lane: canonical op lifecycle contract + exact fallback-removal inventory.
    - Runtime Simulation lane: remove duplicate mutator branch dependencies from runtime/test callers.
    - Native Compute lane: keep one authoritative op-apply pass and explicit no-op/error taxonomy.
    - Validation/Test-Infrastructure lane: canonical no-op taxonomy + removed-branch regression coverage.
    - Documentation lane (`P1`): contract wording and migration notes after evidence lands.
  - Concrete scope (canonical single mutation path):
    - Canonical mutation authority in `apply_native_voxel_stage_delta`: `native_ops := _extract_native_op_payloads(payload)` then one `apply_native_voxel_ops_payload` invocation tagged `native_ops_payload_primary`.
    - If canonical `native_ops` is empty, return explicit typed no-op/error (`native_voxel_op_payload_missing`) without attempting alternate mutation generation/apply branches.
    - Preserve `mutation_path`/`mutation_path_state` contract shape, but constrain successful mutation path to canonical primary ops path only.
  - Exact removals (redundant fallback branches and related callers):
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`: remove pre-op contact fallback branch `_apply_contact_confirmed_direct_fallback(..., _PATH_CONTACT_FALLBACK_PRE_OPS)`.
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`: remove changed-region surface-delta fallback branch tagged `_PATH_CHANGED_REGION_FALLBACK`.
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`: remove direct-impact synthetic op fallback apply pass (`_build_direct_impact_voxel_ops` as alternate source + second `apply_native_voxel_ops_payload` tagged `_PATH_DIRECT_IMPACT_OP_FALLBACK`).
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`: remove post-op contact fallback branch `_apply_contact_confirmed_direct_fallback(..., _PATH_CONTACT_FALLBACK_POST_OPS)`.
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`: delete now-unused path constants and helper-only fallback plumbing tied exclusively to those removed branches (`_PATH_CONTACT_FALLBACK_PRE_OPS`, `_PATH_CHANGED_REGION_FALLBACK`, `_PATH_DIRECT_IMPACT_OP_FALLBACK`, `_PATH_CONTACT_FALLBACK_POST_OPS`, plus `_apply_contact_confirmed_direct_fallback` if no remaining caller).
    - `addons/local_agents/tests/test_fps_fire_contact_mutation_runtime_path.gd`: remove acceptance of fallback mutation paths; require canonical `mutation_path == "native_ops_payload_primary"` for success.
    - `addons/local_agents/tests/test_projectile_direct_impact_mutation_guarantee.gd`: remove fallback-path expectations and assert canonical path / explicit typed no-op behavior only.
  - Acceptance criteria:
    - Exactly one successful mutation path remains: `mutation_path == "native_ops_payload_primary"` with `mutation_path_state == "success"`.
    - Runtime no longer applies mutation via contact/changed-region/direct-impact fallback branches.
    - Empty/missing canonical op payloads return explicit typed failure (`native_voxel_op_payload_missing`) and never silently mutate via alternate branches.
    - `failure_paths`/diagnostics no longer reference removed fallback path tags.
  - Risks:
    - Existing tests and runtime observers currently expecting fallback mutation paths will fail until migrated atomically.
    - Removal of synthetic/direct-contact fallback mutation may expose upstream payload production gaps (more explicit no-op failures).
    - If helper cleanup is incomplete, dead constants/helpers can leave misleading diagnostics or partial branch reachability.
  - Required validation order:
    - Non-headless launch first (real display path): fire FPS projectiles at destructible targets and confirm mutation only occurs through canonical native op path; verify no parser/runtime scene errors.
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_fps_fire_contact_mutation_runtime_path.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_projectile_direct_impact_mutation_guarantee.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [~] Wave 3 (`P1`): Split `WorldSimulation` dispatch/destruction orchestration.
  - Status (2026-02-16): Planning lane in progress; extraction boundaries and owner mapping finalized for implementation handoff.
  - Owner lanes:
    - Planning lane: decomposition sequence, coupling-risk map, and file-size guardrail (`WorldSimulation.gd` must trend toward wiring-only and below 900-line precondition target).
    - Runtime Simulation lane: execute helper/controller extraction and migrate call-sites in atomic slices.
    - Validation/Test-Infrastructure lane: prove no behavior drift in dispatch/destruction orchestration and signal lifecycle wiring.
    - Documentation lane (`P1`): record split map, migration notes, and post-merge ownership boundaries.
  - Concrete extraction plan (dispatch/destruction complexity reduction):
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` (owner: Runtime Simulation lane):
      - Keep as composition root only: `_ready()` wiring, dependency injection, and per-frame delegation.
      - Remove inlined projectile dispatch/destruction branching logic; delegate to helper controllers.
    - `addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd` (new, owner: Runtime Simulation lane):
      - Own frame-level dispatch orchestration currently in `WorldSimulation` (`process-step gating`, `native stage trigger`, `result handoff routing`).
      - Expose one typed entrypoint from `WorldSimulation` for per-frame dispatch (`run_dispatch_frame(delta, context)`).
    - `addons/local_agents/scenes/simulation/controllers/world/WorldDestructionOrchestrator.gd` (new, owner: Runtime Simulation lane):
      - Own projectile-contact to mutation orchestration (`contact intake`, `destruction request shaping`, `mutation outcome routing`).
      - Isolate destruction-specific signals/events so `WorldSimulation` only subscribes/forwards.
    - `addons/local_agents/scenes/simulation/controllers/world/WorldDispatchContracts.gd` (new typed helper `Resource`/contract module, owner: Runtime Simulation lane):
      - Define typed runtime payload rows shared between dispatch and destruction controllers to reduce dictionary churn.
      - Centralize contract normalization so validation and runtime use one schema source.
    - `addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd` and `addons/local_agents/tests/test_native_voxel_op_contracts.gd` (owner: Validation/Test-Infrastructure lane):
      - Update/extend assertions to validate helper-owned orchestration paths and unchanged mutation/error contract behavior.
  - Migration sequence (implementation order):
    - Phase 1: add `WorldDispatchContracts.gd` and `WorldDispatchController.gd` with adapter calls from `WorldSimulation` while preserving behavior.
    - Phase 2: extract destruction routing into `WorldDestructionOrchestrator.gd`, rewire signals in `_ready()`, and remove duplicated inlined branches.
    - Phase 3: prune dead inlined helpers/constants in `WorldSimulation.gd`; keep composition-only call sites.
  - Acceptance criteria:
    - `WorldSimulation.gd` functions as composition/wiring surface only; dispatch/destruction branch ownership moves to dedicated helpers.
    - New helper/controller ownership is explicit and stable (`WorldDispatchController`, `WorldDestructionOrchestrator`, shared typed contract module).
    - No behavior drift in projectile/destruction flow: canonical mutation path and explicit failure/no-op taxonomy remain unchanged.
    - Signal lifecycle is explicit (`connect` in `_ready`, `disconnect` on teardown for non-trivial lifecycles) with no duplicate emissions.
    - File-size objective met: `WorldSimulation.gd` reduced from current cap pressure and not increased by this wave.
  - Risks:
    - Signal rewiring mistakes can create dropped dispatch events or duplicate destruction emissions.
    - Temporary dual-path routing during migration can mask contract regressions if old branches are not removed atomically.
    - Typed contract extraction can break callers still passing legacy dictionary shapes.
    - Split sequencing errors can leave `WorldSimulation` partially coupled to helper internals.
  - Required validation order:
    - Non-headless launch first (real display path): run FPS projectile firing against destructible targets and verify startup + runtime scene stability with helper-owned dispatch/destruction routing.
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] Wave 4 (`P1`): Reduce dictionary contract churn in bridge/mutator.
  - Owner lanes:
    - Planning lane: typed-boundary schema map.
    - Runtime Simulation lane: normalize typed rows/resources at bridge boundaries.
    - Native Compute lane: align native payload readers with normalized schema.
    - Validation/Test-Infrastructure lane: schema parity and malformed-payload behavior tests.
    - Documentation lane (`P1`): schema/migration notes.
  - Acceptance criteria:
    - Bridge/mutator hot-path dictionary shape churn is replaced with stable typed boundary access.
    - Malformed payloads fail explicitly with structured reasons.
  - Risks:
    - Schema drift between GDScript and native.
    - Large call-site migration increasing short-term integration risk.
  - Required validation order:
    - Non-headless launch first.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [~] Wave 5 (`P2`): Unify destruction diagnostics source.
  - Status (2026-02-16): Planning lane scope/ownership locked for single-source destruction diagnostics; implementation and validation lanes pending execution.
  - Owner lanes:
    - Planning lane: single-source destruction diagnostics contract and consumer migration order.
    - Runtime Simulation lane: remove parallel GDScript-side destruction/projectile diagnostic emitters and consume canonical snapshot only.
    - Native Compute lane: sole producer ownership for destruction diagnostics snapshot and reason-code taxonomy.
    - Validation/Test-Infrastructure lane: consumer contract assertions and deprecated-key regression checks.
    - Documentation lane (`P1`): diagnostics key semantics, deprecation timeline, and migration notes.
  - Scope (single-source ownership + contracts):
    - Single-source owner: `Native Compute lane` owns destruction diagnostics production end-to-end (`LocalAgentsSimulationCore` stage outputs and bridge-facing snapshot assembly); runtime lanes are read-only consumers.
    - Canonical contract surface is one destruction diagnostics snapshot channel per tick with stable keys:
      - `hits_queued`
      - `contacts_dispatched`
      - `plans_planned`
      - `ops_applied`
      - `changed_tiles`
      - `last_drop_reason`
    - Required consumer contract: HUD/perf overlay, runtime log emitters, and tests must read only the canonical snapshot and must not derive or overwrite parallel counters from local controller state.
    - Required consumer contract: all missing-data cases must be explicit typed diagnostics (`diagnostics_unavailable` with reason code), never silent zero-fill that can mask pipeline failures.
    - Required consumer contract: deprecated destruction diagnostics keys are removed from active reads after migration and guarded by regression tests to prevent reintroduction.
  - Acceptance criteria:
    - Destruction diagnostics values originate from one authoritative native-owned snapshot path.
    - HUD/log/test consumers read the same contract keys and no longer read competing fields.
    - Deprecated diagnostics keys are either absent or explicitly mapped in one adapter with a scheduled removal gate.
  - Risks:
    - Temporary observability blind spots during source cutover.
    - Consumers still bound to deprecated keys.
    - Snapshot schema drift between native output and runtime adapters can create false-negative diagnostics.
  - Required validation order:
    - Non-headless launch first.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] Wave 6 (`P2`): Parse/teardown hygiene issues.
  - Owner lanes:
    - Planning lane: parser/teardown defect inventory and priority order.
    - Runtime Simulation lane: `_ready`/`_exit_tree` and signal connect/disconnect hygiene fixes.
    - Validation/Test-Infrastructure lane: teardown/restart repeatability tests and parser smoke checks.
    - Documentation lane (`P1`): preventative-pattern log updates if new avoidable failures are found.
  - Acceptance criteria:
    - No recurring parse errors from known anti-patterns on launch.
    - Teardown/reload cycles do not leak stale connections or worker lifecycle artifacts.
  - Risks:
    - Cleanup ordering changes can break latent assumptions in controller startup.
    - Teardown bugs may only reproduce under repeated launches.
  - Required validation order:
    - Non-headless launch first.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

### Wave 1 Concrete Ownership and Test Plan

- File ownership:
  - Runtime Simulation lane:
    - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd`
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd`
  - Native Compute lane:
    - `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`
    - `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp`
    - `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`
    - `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp`
    - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp`
  - Validation/Test-Infrastructure lane:
    - `addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd`
    - `addons/local_agents/tests/test_native_voxel_op_contracts.gd`
    - `addons/local_agents/tests/test_fps_launcher_contact_rows.gd`
    - `addons/local_agents/tests/test_voxel_chunk_collision_parity_contracts.gd`

- Test plan (required order):
  - Non-headless first: launch runtime through real display path; fire FPS projectiles at destructible voxel targets; verify mutation-within-bound or explicit deadline error payload.
  - Focused contracts:
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_fps_launcher_contact_rows.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_voxel_chunk_collision_parity_contracts.gd --timeout=120`
  - Full sweep gates:
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

## Current Wave (execution started 2026-02-16)

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Performance simplification wave - projectile + native voxel pipeline allocation/copy reduction.
  - Scope (simplification-first, no behavior fallback expansion):
    - Remove duplicated projectile/contact payload copies between FPS launcher, bridge buffering, and native ingestion boundaries.
    - Collapse redundant fallback passes in projectile-to-destruction routing so one authoritative pass handles mutation planning.
    - Reduce per-frame allocations and avoid recursive rebuild patterns on hot projectile/destruction paths.
    - Replace repeated deep dictionary traversals with normalized typed row/resource contracts at handoff boundaries.
  - P-band and lane ownership:
    - `P0`: Planning lane owns simplification contract, decomposition, and merge/deconflict checkpoints.
    - `P0`: Runtime Simulation lane owns launcher/bridge payload normalization and duplicate-copy removal in GDScript hot path.
    - `P0`: Native Compute lane owns fallback-pass collapse and allocation/traversal simplification in native stage execution.
    - `P0`: Validation/Test-Infrastructure lane owns perf-regression contract checks and deterministic runtime verification.
    - `P1`: Documentation lane owns migration notes and process wording sync after validation evidence lands.
  - Concrete file-level decomposition (implementation lanes):
    - Runtime Simulation lane:
      - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd` (emit canonical typed projectile/contact payload once per hit; remove duplicate intermediate copy steps).
      - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` (single authoritative handoff buffer and typed field extraction; remove redundant fallback translation passes).
      - `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd` (keep one dispatch pass for projectile/native sync and remove duplicate per-frame routing loops).
    - Native Compute lane:
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp` (single-pass projectile contact ingestion and mutation planning inputs).
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp` (typed payload/queue contract updates for copy-free pass-through).
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp` (collapse redundant fallback execution passes and avoid recursive mutation staging).
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp` (stage contract alignment for single-pass execution).
      - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp` (remove repeated deep dictionary-style traversal patterns in failure/destruction planning inputs).
  - Concrete file-level decomposition (validation + documentation lanes):
    - Validation/Test-Infrastructure lane:
      - `addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd` (assert no duplicated route side effects and stable destruction outcomes).
      - `addons/local_agents/tests/test_native_voxel_op_contracts.gd` (single-pass mutation/no-op contract with explicit reason taxonomy).
      - `addons/local_agents/tests/benchmark_voxel_pipeline.gd` (allocation/copy regression budget checks for projectile/native voxel path).
      - `addons/local_agents/tests/run_all_tests.gd` and `addons/local_agents/tests/run_runtime_tests_bounded.gd` (coverage anchors only; canonical invocation unchanged).
    - Documentation lane:
      - `ARCHITECTURE_PLAN.md` (wave status, acceptance evidence, risk tracking, and rollback notes if needed).
      - `README.md` and `GODOT_BEST_PRACTICES.md` (only if command/process wording changes).
  - Acceptance criteria:
    - Projectile impact payload is materialized once per hit and consumed through one authoritative bridge-to-native route without duplicate copy buffers.
    - Redundant fallback mutation passes are removed; active runtime behavior uses one deterministic mutation planning pass.
    - Per-frame hot path shows reduced transient allocations and no recursive mutation routing on projectile destruction updates.
    - Deep dictionary traversal on projectile/destruction hot path is replaced by normalized typed contract access at boundaries.
    - Existing voxel-destruction behavior and explicit error emission contracts remain intact (no silent no-op regressions).
  - Risks:
    - Over-aggressive copy elimination can expose shared-mutation aliasing bugs if ownership/lifetime boundaries are not explicit.
    - Fallback-pass collapse can remove latent safety behavior if hidden call-sites still depend on old branches.
    - Typed contract tightening can break older payload producers until all call-sites are migrated atomically.
    - Perf assertions can flake if benchmark scene/setup and frame budget sampling are not stabilized.
  - Required validation order (mandatory sequence):
    - Non-headless launch first (real display/video path): run FPS projectile impacts against destructible voxels, confirm no parser/runtime scene errors and stable destruction behavior after simplification.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/benchmark_voxel_pipeline.gd -- --timeout=120`

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Breaking wave - direct, reliable FPS projectile destruction with bounded-frame voxel mutation invariant.
  - Scope (breaking, direct-path authority):
    - Make FPS projectile impact -> native destruction -> voxel mutation a single authoritative path with no legacy rigidbody/sample fallback route.
    - Require deterministic handoff from FPS impact payloads into native destruction planning in the same simulation ownership chain.
    - Remove or disconnect legacy branches that allow projectile impacts to complete without a voxel mutation decision.
  - Hard invariant (must hold):
    - For every valid FPS projectile hit on a destructible voxel target, voxel mutation must be observed within a bounded number of simulation frames (`MAX_PROJECTILE_MUTATION_FRAMES`).
    - If mutation is not observed within bound, runtime must emit an explicit structured error (`PROJECTILE_MUTATION_DEADLINE_EXCEEDED`) with projectile id, hit frame, deadline frame, and contact summary (no silent no-op).
  - P-band and lane ownership:
    - `P0`: Planning lane owns contract decomposition, bounded-frame invariant definition, and merge/deconflict checkpoints.
    - `P0`: Runtime Simulation lane owns FPS projectile event emission, impact normalization, and bridge handoff wiring.
    - `P0`: Native Compute lane owns queue consumption, destruction decisioning, and bounded-frame invariant enforcement at native stage boundaries.
    - `P0`: Validation/Test-Infrastructure lane owns deterministic bounded-frame contract coverage plus regression matrix execution.
    - `P1`: Documentation lane owns migration notes and process wording sync after verification evidence lands.
  - Concrete file-level decomposition (implementation lanes):
    - Runtime Simulation lane:
      - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd` (authoritative projectile-hit payload normalization and id/deadline metadata emission).
      - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` (bridge contract fields for projectile mutation deadline tracking and explicit failure propagation).
      - `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` (fire-mode gating stability only; no new destruction authority).
      - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` (wiring-only updates; keep orchestration minimal and helper-first if growth risk appears).
    - Native Compute lane:
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp`
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp`
      - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp` (mutation deadline miss taxonomy and explicit error payload path).
  - Concrete file-level decomposition (validation lanes):
    - Validation/Test-Infrastructure lane:
      - `addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd` (bounded-frame mutation success contract).
      - `addons/local_agents/tests/test_native_voxel_op_contracts.gd` (explicit failure contract for mutation deadline exceedance).
      - `addons/local_agents/tests/test_fps_launcher_contact_rows.gd` (projectile id/hit-frame/deadline-frame schema coverage).
      - `addons/local_agents/tests/test_voxel_chunk_collision_parity_contracts.gd` (deterministic collision-to-mutation parity under repeated seeded runs).
      - `addons/local_agents/tests/run_all_tests.gd` (coverage anchor only; invocation remains canonical).
      - `addons/local_agents/tests/run_runtime_tests_bounded.gd` (coverage anchor only; invocation remains canonical).
    - Documentation lane:
      - `ARCHITECTURE_PLAN.md` (wave status, acceptance evidence, and risk tracking).
      - `README.md` and `GODOT_BEST_PRACTICES.md` (only if command/process or contract wording changes).
  - Acceptance criteria:
    - Valid FPS projectile hits on destructible voxel targets always produce voxel mutation within `MAX_PROJECTILE_MUTATION_FRAMES`.
    - Mutation-deadline misses always emit explicit `PROJECTILE_MUTATION_DEADLINE_EXCEEDED` errors with required structured context.
    - No authoritative runtime path remains where projectile hit processing can succeed silently without mutation decision output.
    - Legacy rigidbody/sample fallback paths for projectile destruction are removed or fully disconnected from active runtime behavior.
    - GPU-required hard-fail semantics remain intact (`GPU_REQUIRED`/`gpu_unavailable`) with no degraded non-GPU branch.
  - Risks:
    - Frame-bound invariant can flake if frame/tick ownership differs between launcher, bridge, and native stage without one canonical frame counter contract.
    - Schema drift in projectile metadata (`projectile_id`, `hit_frame`, `deadline_frame`) can produce false deadline failures or hidden no-op mutations.
    - Forcing explicit error emission on deadline misses can increase surfaced failures quickly if queue backpressure is not bounded.
    - `WorldSimulation.gd` orchestration edits can violate file-size/coupling limits unless helper-first discipline is maintained.
  - Required validation order (mandatory sequence):
    - Non-headless launch first (real display/video path): enter FPS mode, fire at destructible voxel target, verify mutation occurs within bound or explicit deadline error is surfaced; confirm no parser/runtime scene errors.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Breaking wave - replace FPS `RigidBody3D` projectile path with dense hard voxel-chunk projectiles.
  - Scope (breaking, voxel-native authoritative path):
    - Remove `RigidBody3D` as the primary FPS projectile representation and replace fire/spawn flow with deterministic dense hard voxel-chunk projectile instances.
    - Keep destruction authoritative in native voxel pipeline; projectile impacts must emit canonical contact/destruction intents without rigidbody-dependent sampling paths.
    - Delete/retire legacy rigidbody projectile scene/script wiring after voxel-chunk path is live (no compatibility shim layer).
  - P-band and lane ownership:
    - `P0`: Planning lane owns decomposition, dependency map, and merge/deconflict checkpoints before implementation starts.
    - `P0`: Runtime Simulation lane owns FPS input/fire orchestration and projectile lifecycle migration to voxel-chunk representations.
    - `P0`: Native Compute lane owns dense chunk projectile ingestion/collision/destruction contract in native stage execution.
    - `P0`: Validation/Test-Infrastructure lane owns harness updates and explicit runtime/contract regression coverage.
    - `P1`: Documentation lane owns migration notes and command/process docs synchronization after validation evidence lands.
  - Concrete implementation decomposition (files):
    - Runtime Simulation lane:
      - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd` (remove rigidbody spawn/contact queue ownership, route fire events to voxel-chunk projectile service).
      - `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` (keep mode-gated fire triggers stable during launcher migration).
      - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` (wiring only; avoid growth and split to helpers if call-site churn increases).
      - `addons/local_agents/scenes/simulation/actors/FpsLauncherProjectile.gd` and `addons/local_agents/scenes/simulation/actors/FpsLauncherProjectile.tscn` (deprecate/remove rigidbody actor path once replacement is integrated).
    - Native Compute lane:
      - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` (new/updated dispatch payload for dense hard voxel-chunk projectile events).
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp`
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp`
    - Validation/Test-Infrastructure lane:
      - `addons/local_agents/tests/test_projectile_voxel_destruction_runtime_path.gd`
      - `addons/local_agents/tests/test_fps_launcher_contact_rows.gd` (migrate expectations from rigidbody contact rows to voxel-chunk projectile contract).
      - `addons/local_agents/tests/test_voxel_chunk_collision_parity_contracts.gd`
      - `addons/local_agents/tests/run_all_tests.gd` and `addons/local_agents/tests/run_runtime_tests_bounded.gd` (coverage anchors only; keep canonical invocation unchanged).
    - Documentation lane:
      - `ARCHITECTURE_PLAN.md`, `README.md`, `GODOT_BEST_PRACTICES.md` (breaking migration notes and validation/process wording updates only when behavior/commands change).
  - Acceptance criteria:
    - FPS fire path no longer instantiates `RigidBody3D` projectiles on the authoritative runtime route.
    - Dense hard voxel-chunk projectiles produce deterministic collision/destruction intents on destructible voxel targets.
    - Native destruction pipeline remains authoritative and receives projectile events without rigidbody sampling/bridge fallback paths.
    - Legacy rigidbody projectile files/routes are removed or fully disconnected from active runtime behavior.
    - GPU-required semantics remain hard-fail (`GPU_REQUIRED`) with no degraded non-GPU path added.
  - Risks:
    - Runtime/native schema drift during migration can cause silent no-op destruction if event contracts are not version-locked and tested together.
    - Dense projectile representation can increase per-tick cost and memory pressure unless chunk density bounds and lifetimes are explicit.
    - Partial removal of rigidbody routes can leave dual-path behavior and non-deterministic impact ordering.
    - `WorldSimulation.gd` call-site growth risk near size cap requires helper-first extraction if edits expand orchestration surface.
  - Required validation sequence (mandatory order):
    - Non-headless launch first (real display/video path): enter FPS mode, fire into destructible voxel target, confirm dense voxel-chunk projectiles spawn and destruct immediately with no parser/runtime scene errors.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Breaking migration wave - projectile destruction pipeline authoritative queue + contract hardening.
  - Scope (breaking, contract-first):
    - Native-owned impact queue is authoritative for projectile destruction intent ingestion and consumption.
    - Native destruction stage is forced whenever the impact queue is non-empty; stage execution is decoupled from render pulse cadence.
    - Canonical mutation contract is mandatory per destruction tick: emit concrete ops or an explicit structured no-op reason (no silent empty apply).
    - Remove legacy sample/clear brittle handoff paths that can drop queued impacts between bridge and native stage boundaries.
    - Add observability counters spanning queue ingestion, queue consumption, and mutation application (`queue_received`, `queue_consumed`, `ops_applied`, `noop_with_reason`).
  - P-band and lane ownership:
    - `P0`: Runtime Simulation lane + Native Compute lane implement contract and stage authority changes.
    - `P0`: Validation/Test-Infrastructure lane owns regression coverage and required command matrix execution.
    - `P1`: Documentation lane updates migration notes and contract text after implementation and validation evidence lands.
  - Concrete file ownership decomposition (implementation/validation lanes):
    - Runtime Simulation lane:
      - `addons/local_agents/simulation/controller/NativeComputeBridge.gd`
      - `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd`
      - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd` (only if contact payload normalization is required for canonical queue contract)
    - Native Compute lane:
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp`
      - `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`
      - `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp`
      - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp`
    - Validation/Test-Infrastructure lane:
      - `addons/local_agents/tests/test_native_voxel_op_contracts.gd`
      - `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd` (or a new focused projectile queue contract test)
      - `addons/local_agents/tests/run_all_tests.gd` (coverage anchor only; invocation remains canonical)
      - `addons/local_agents/tests/run_runtime_tests_bounded.gd` (coverage anchor only; invocation remains canonical)
    - Documentation lane:
      - `ARCHITECTURE_PLAN.md` (breaking migration status + acceptance evidence)
      - `GODOT_BEST_PRACTICES.md` and `README.md` (only if command/process wording or contract claims change)
  - Acceptance criteria:
    - Projectile impact ingestion writes only to native-owned queue state; no parallel legacy buffer is authoritative.
    - If queue depth is greater than zero, native destruction stage runs in that tick regardless of render pulse cadence.
    - Destruction mutation result contract is explicit every tick: either non-empty ops or explicit `no_op_reason` taxonomy (for example `queue_empty`, `invalid_contact_schema`, `below_threshold`).
    - Legacy sample/clear handoff paths are removed from active runtime route; no dual-write or dual-clear behavior remains.
    - Observability counters report monotonic queue lifecycle transitions (`queue_received >= queue_consumed >= ops_applied + noop_with_reason`) and are surfaced through existing diagnostics/telemetry pathway.
  - Risk calls:
    - Queue ownership migration can introduce duplicate-consume or lost-impact bugs if bridge/native clear semantics are not cut over atomically.
    - Forcing destruction stage on non-empty queue can increase stage frequency and expose hidden ordering/perf regressions without bounded metrics.
    - Canonical no-op taxonomy can drift between GDScript and native if reason enums are not shared and contract-tested.
    - Removing brittle legacy handoff code can break stale callers unless all old paths are deleted/rewired in the same wave.
  - Required validation sequence (mandatory order):
    - Non-headless launch first (real display/video path): fire FPS projectiles into destructible voxel target, confirm queue-driven destruction triggers immediately and no parser/runtime scene errors occur.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Hotfix wave - FPS-launched projectiles still do not destroy voxels.
  - Scope (bounded, contract-first):
    - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd`: verify and normalize FPS projectile contact payload fields (position, normal, impulse, relative velocity/speed, collider metadata) before bridge handoff.
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd`: ensure per-pulse `physics_contacts` sync (`clear_physics_contacts` then `ingest_physics_contacts`) and hard-fail status on contact-ingest contract mismatch.
    - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp` (+ related native contact-mapping helper if required): align contact schema consumption with launcher/bridge payload contract used by failure-emission voxel destruction planning.
    - `addons/local_agents/tests/test_native_voxel_op_contracts.gd` and/or focused FPS projectile destruction contract test under `addons/local_agents/tests/`: assert that FPS projectile contacts produce deterministic voxel destruction intents and do not silently no-op.
  - File-size preconditions:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` remains excluded (at hard cap); do not route this hotfix through world-orchestration growth.
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` is near split threshold; keep delta minimal and split helper logic immediately if projected size crosses limits.
  - Acceptance criteria:
    - FPS-launched projectile impacts generate non-empty normalized contact rows on valid voxel-target hits.
    - Normalized contact rows reach native failure-emission planning on every environment pulse; stale contacts are cleared when no impacts are present.
    - Native failure-emission planner produces voxel destruction operations for valid FPS projectile impacts with no silent contract downgrade.
    - Contract failures are surfaced explicitly (`contract_mismatch`/dispatch failure taxonomy), preserving GPU-required hard-fail behavior.
  - Risks:
    - Schema drift between launcher payload, bridge normalization, and native planner contact readers can cause persistent no-op destruction.
    - Over-fixing in `WorldSimulation.gd` would violate file-size/coupling constraints and delay the hotfix.
    - Partial validation (headless-only) can miss runtime event-wiring regressions in FPS input/impact flow.
  - Required validation sequence (mandatory order):
    - Non-headless launch first (real display/video path): enter FPS mode, fire at destructible voxel wall, confirm impact produces immediate destruction and no parser/runtime scene errors.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P1 (Owners: Planning lane, Runtime Simulation lane, HUD/UI lane, Validation/Test-Infrastructure lane, Documentation lane): Stabilize FPS observability contract and FPS movement frame-of-reference contract.
  - Scope:
    - `addons/local_agents/scenes/simulation/controllers/PerformanceTelemetryServer.gd`: keep `fps` sourcing canonical (`Performance.TIME_FPS`) and make update cadence/field contract explicit for downstream HUD formatting.
    - `addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd`: keep FPS text formatting canonical (`FPS`, computed `ms`, memory/object/draw metrics, backend flags) and avoid duplicate/competing FPS formatters.
    - `addons/local_agents/scenes/simulation/ui/hud/SimulationHudPerformancePanelController.gd` + `addons/local_agents/scenes/simulation/ui/SimulationHud.gd`: keep single-sink `PerfLabel` update path and ensure no side-path writes bypass presenter formatting.
    - `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` + `addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd`: lock movement frame-of-reference as camera-relative planar basis (`forward/right` projected to XZ) with explicit per-frame stepping ownership.
  - File-size preconditions:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` is at the 1000-line cap and must not be expanded; prefer helper/controller edits under `controllers/world/` and `ui/`.
    - In-scope FPS/movement helper files are currently below 900 lines and can absorb scoped edits without forced pre-split.
  - Acceptance criteria:
    - FPS HUD value follows one canonical path: telemetry emit -> presenter format -> HUD performance panel label update.
    - FPS label semantics remain stable (`FPS N (X ms)` derived from telemetry `fps`) with no conflicting parallel formatter.
    - FPS movement frame of reference is explicitly defined and preserved: `W/S` and `A/D` resolve against camera basis projected to horizontal plane (`y = 0`), with normalized diagonal movement.
    - Per-frame FPS movement stepping remains owned by input controller frame callback -> camera controller `step_fps(delta)` and stays mode-gated.
  - Risks:
    - Mixed timing semantics (telemetry refresh interval vs movement per-frame delta) can cause apparent mismatch between displayed FPS and locomotion feel if not documented.
    - Future edits may accidentally reintroduce pitch-coupled vertical movement unless planar projection is contract-guarded.
    - `WorldSimulation.gd` cap pressure can trigger accidental scope expansion unless orchestration changes stay minimal.
  - Validation sequence (required order):
    - Non-headless launch first (real display/video path): verify FPS label updates while toggling FPS mode and moving camera; confirm no parse/runtime scene errors.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`
  - Lane B implementation slice (2026-02-16):
    - `P1` Runtime Simulation + HUD/UI ownership:
      - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd`
      - `addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd`
      - `addons/local_agents/scenes/simulation/ui/SimulationHud.gd`
      - `addons/local_agents/scenes/simulation/ui/hud/SimulationHudPerformancePanelController.gd` (no behavior change expected; compatibility verification only)
    - Acceptance addendum:
      - Expose runtime destruction pipeline diagnostics in the top-right performance block: `hits_queued`, `contacts_dispatched`, `plans_planned`, `ops_applied`, `changed_tiles`, `last_drop_reason`.
      - Maintain existing HUD render/update path and existing backend flags format compatibility.
    - File-size guardrail:
      - `WorldSimulation.gd` is above split threshold; extract helper-first diagnostics logic to avoid crossing 1000-line hard limit.

- [ ] P0 (Owners: Runtime Simulation lane B, Native Compute lane, Validation/Test-Infrastructure lane): Make FPS projectile contacts reliably drive voxel destruction through native failure-emission orchestration.
  - Scope:
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd`: synchronize normalized `physics_contacts` rows into native core contact buffers on every environment-stage pulse (`clear_physics_contacts` + `ingest_physics_contacts`) and fail loudly on sync contract errors.
    - `addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd`: only adjust row schema if required after bridge normalization audit.
    - `addons/local_agents/gdextensions/localagents/src/SimulationFailureEmissionPlanner.cpp` and related helpers only if contact-field contract mismatch remains after bridge sync/normalization.
    - Focused tests under `addons/local_agents/tests/` for projectile-contact destruction contract coverage.
  - File-size preconditions:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` is at the 1000-line cap and is excluded from this wave unless unavoidable.
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` is near the 1000-line cap; keep delta minimal and split immediately if projected size would exceed 1000 lines.
  - Acceptance criteria:
    - FPS launcher projectile contact rows are normalized into the schema expected by native failure-emission planning (`contact_impulse` + velocity/speed fields).
    - Contact rows reach native core orchestration every pulse when present and are cleared when absent (no stale-contact masking).
    - Contract sync failures are surfaced as explicit dispatch errors; no silent success on failed contact sync.
    - Existing GPU-required semantics remain unchanged (`gpu_required`/`gpu_unavailable` hard-fail behavior preserved).
  - Validation sequence (required order):
    - Non-headless launch first (real display/video path).
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0/P1/P2 (Owners: Runtime Simulation lane, HUD/UI lane, Validation/Test-Infrastructure lane, Documentation lane): Add explicit camera/FPS fire mode toggle in `WorldSimulation` and compose input mode handling via a dedicated helper.
  - P0 Scope:
    - Add `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` and move direct input-routing/editing logic from `WorldSimulation.gd` into it before behavior edits.
    - Default `WorldSimulation` interaction state is camera mode.
    - Add `F` toggle to switch between camera mode and FPS/Fire mode.
    - Ensure 2nd `F` press returns to camera mode.
  - P1 Scope:
    - Add a visible mode label in `SimulationHud` and keep it synced with input mode transitions.
    - Add explicit gating so space and left-click trigger fire only when FPS mode is active and not over HUD.
    - Keep normal camera orbit/pan/zoom behavior intact in camera mode.
  - P2 Scope:
    - Add manual/harness checks for mode switching and no-fire-in-camera mode under HUD-occluded pointer cases.
    - Update behavior documentation where FPS/space/left-click controls are described.
  - File-size preconditions:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` is 1035 lines before this wave; pre-split plan is to extract direct input handling into `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` and keep this file under 1000-line ceiling after extraction.
    - Keep this file below the 900-line hard-stop threshold by continuing to migrate input/mode routing helpers if this wave grows near that boundary.
  - Acceptance criteria:
    - `F` toggles modes deterministically; pressing again exits FPS mode.
    - `Space` and left-click fire only work in FPS mode.
    - Cursor over any active HUD control blocks firing.
    - `Mode: Camera` / `Mode: FPS` is visible and updates on mode transitions.
    - `WorldSimulation` edits include helper split before direct input/mode behavior changes.

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Validation/Test-Infrastructure lane, Documentation lane): Add FPS-entry mouse capture with standard forward/back/strafe + mouse look controls.
  - Scope (exact file/method targets):
    - `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd`: extend `configure(...)`, `toggle_fps_mode()`, `_handle_key_input(...)`, `_handle_camera_motion(...)`, `_handle_mouse_button(...)` to explicitly transition mouse mode on FPS entry/exit and route camera motion by mode.
    - `addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd`: extend `handle_mouse_motion(...)` and add dedicated FPS-oriented methods (for example mode enter/exit sync + per-frame movement step) to support yaw/pitch mouse look and WASD planar locomotion.
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd`: update `_ready()` wiring and `_process(delta)` to drive FPS movement every frame and keep launcher/camera interactions mode-aware.
    - `project.godot` (if action-map driven approach is selected): add/normalize explicit FPS movement actions for forward/back/left/right; otherwise keep key polling localized in camera controller with no project input-map churn.
  - File-size preconditions:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` is at 1000 lines (hard cap); extract FPS wiring helpers to `addons/local_agents/scenes/simulation/controllers/world/` before any delta that would increase file length.
    - `addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd` (205 lines) and `addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd` (142 lines) are below split thresholds and are preferred edit targets for this wave.
  - Acceptance criteria:
    - Entering FPS mode captures mouse (`Input.MOUSE_MODE_CAPTURED`) and immediately enables free mouse look without requiring Ctrl/MMB/RMB modifiers.
    - Exiting FPS mode restores visible pointer (`Input.MOUSE_MODE_VISIBLE`) and restores existing orbit/pan/zoom camera behavior.
    - `W/S` moves forward/back relative to camera yaw; `A/D` strafes left/right; diagonal movement is normalized.
    - FPS firing behavior stays gated by mode + HUD blocking checks, with no regressions to spawn-mode click behavior.
    - No regressions in launcher center-ray firing (`_try_fire_from_screen_center`) while moving/looking in FPS mode.
  - Risks:
    - Input-routing overlap can cause double-application (orbit + mouselook in the same event path) unless mode branches are strict.
    - Captured-mouse lifecycle can get stuck on scene focus changes unless entry/exit paths are centralized and idempotent.
    - World-space movement tied to camera pitch can introduce unwanted vertical drift unless horizontal projection is enforced for locomotion vectors.
  - Validation sequence (required order):
    - Non-headless launch first (real display/video path): verify FPS entry captures cursor, mouselook responds immediately, and `W/A/S/D` movement is directional and reversible.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0/P1 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Wave D - move remaining CPU simulation hot paths to native/GPU execution.
  - Highest-impact CPU GDScript still active (investigated February 15, 2026):
    - `addons/local_agents/simulation/SimulationControllerRuntimeHelpers.gd` (`run_resource_pipeline`): per-tick/per-household/per-member resource, transport, and market loops are still GDScript-authoritative.
    - `addons/local_agents/simulation/SpatialFlowNetworkSystem.gd` (`evaluate_route`, `_route_terrain_profile`, `_route_edge_keys`): route sampling and terrain/flow scoring are still CPU GDScript loops called inside the resource pipeline.
    - `addons/local_agents/simulation/StructureLifecycleSystem.gd` (`step_lifecycle`): expansion/abandonment/path-extension/camp decisions still run in GDScript when native path is unavailable; native hook exists but is currently stubbed (`addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp` `step_structure_lifecycle`).
    - `addons/local_agents/simulation/SimulationControllerCoreLoopHelpers.gd` (`_build_local_activity_map`): per-tick locality/contact aggregation remains in GDScript.
  - File-size preconditions (before implementation wave starts):
    - In-scope files are below 900 lines (`SimulationRuntimeFacade.gd` 726, `SimulationControllerCoreLoopHelpers.gd` 651, `LocalAgentsSimulationCore.cpp` 565), so this wave can start without mandatory pre-split.
    - If planned deltas push any in-scope file above 900 lines, split immediately; never allow any source/config file to exceed 1000 lines.
  - Concrete implementation decomposition (explicit files and bounded scope):
    - P0-A (bounded deliverable for next implementation turn): Make structure lifecycle truly native-backed and remove stub behavior.
      - Files: `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`, `addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationCore.hpp`, `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd`, `addons/local_agents/tests/test_native_general_physics_contracts.gd` (or new focused native-structure-lifecycle contract test), `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd` (runtime assertion hook).
      - Bound: parity for `expanded`/`abandoned` contract outputs and deterministic ordering only; no household-ledger/resource-pipeline migration in this slice.
    - P0-B: Move route-evaluation hot loop from GDScript to native/GPU contract path.
      - Files: `addons/local_agents/simulation/SimulationControllerRuntimeHelpers.gd`, `addons/local_agents/simulation/SimulationControllerOpsHelpers.gd`, `addons/local_agents/simulation/SpatialFlowNetworkSystem.gd`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`, `addons/local_agents/gdextensions/localagents/include/LocalAgentsEnvironmentStageExecutor.hpp`.
      - Bound: native batch route metrics (`delivery_efficiency`, `avg_path_strength`, `eta_ticks`, terrain penalties) consumed by GDScript orchestration; keep economic ledger ownership unchanged in this slice.
    - P1-C: Nativeize locality/contact activity aggregation currently in `_build_local_activity_map`.
      - Files: `addons/local_agents/simulation/SimulationControllerCoreLoopHelpers.gd`, `addons/local_agents/simulation/controller/NativeComputeBridge.gd`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsSimulationCore.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsEnvironmentStageExecutor.cpp`.
      - Bound: replace GDScript activity-map construction with native-produced activity/uniformity metrics; no behavior changes to cognition cadence/queue logic.
  - Acceptance criteria:
    - P0-A: `step_structure_lifecycle` returns deterministic non-stub lifecycle outputs under native mode; runtime uses those outputs as authoritative and preserves existing event schema.
    - P0-B: route evaluation for resource transport no longer executes per-sample terrain loops in GDScript on the primary path; native contract returns deterministic route metrics consumed by existing pipeline.
    - P1-C: `_build_local_activity_map` is no longer the primary runtime path for locality/contact aggregation when native core is enabled.
    - No CPU-success fallback is introduced for GPU-required voxel transform paths while migrating these systems.
  - Risks:
    - Migrating structure decisions can drift semantics if GDScript and native thresholds diverge without fixture parity tests.
    - Route-scoring migration can regress determinism if sample order or float rounding is not fixed across native/GDScript boundaries.
    - Over-scoping resource-pipeline migration can destabilize ledger invariants; keep economic ownership in GDScript until route/native metrics are stable.
  - Validation sequence (required order):
    - Non-headless launch first (real display/video path) to catch parser/runtime scene errors early.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [ ] P0 (Owners: Planning lane, Runtime Simulation lane, Native Compute lane, HUD/UI lane, Validation/Test-Infrastructure lane, Documentation lane): Align target-wall profile controls, runtime mutator behavior, and GPU backend metadata surfaces before implementation starts.
  - Scope:
    - `addons/local_agents/configuration/parameters/simulation/TargetWallProfileResource.gd`
    - `addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd`
    - `addons/local_agents/scenes/simulation/ui/hud/SimulationHudGraphicsPanelController.gd`
    - `addons/local_agents/simulation/controller/SimulationVoxelTerrainMutator.gd`
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd`
    - Runtime GPU backend metadata bridges: `addons/local_agents/simulation/controller/NativeComputeBridge.gd`, `addons/local_agents/simulation/controller/NativeComputeBridgeEnvironmentDispatchStatus.gd`, `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd`, `addons/local_agents/simulation/controller/SimulationSnapshotController.gd`, `addons/local_agents/scenes/simulation/controllers/PerformanceTelemetryServer.gd`, `addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd`
  - File-size preconditions (must enforce before code edits):
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` is 996 lines; split/extract is mandatory before any change that could increase file size.
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd` is 966 lines; split/extract is mandatory before any change that could increase file size.
  - Acceptance criteria:
    - Target-wall profile fields exposed in resources/UI are either wired into wall stamping semantics or explicitly removed from runtime/config/UI to eliminate dead controls.
    - GPU backend metadata (`backend_used`, `dispatch_reason`, `dispatch_contract_status`, pass/material/emitter descriptor fields) remains canonical from bridge dispatch through snapshot/runtime telemetry/HUD formatting without lossy remapping.
    - Runtime GPU-required semantics remain hard-fail (`GPU_REQUIRED`) with explicit structured metadata preserved for diagnostics.
    - Ownership split is explicit: runtime mutator semantics, dispatch/contract bridge semantics, and HUD/telemetry presentation are implemented and validated in separate lanes.
  - Risks:
    - Dead UI controls (`pillar_height_scale`, `pillar_density_scale`) can mislead tuning and create non-deterministic expectations.
    - Backend metadata normalization drift across bridge/facade/snapshot/HUD can mask GPU contract failures.
    - Large-file pressure in `WorldSimulation.gd`/`NativeComputeBridge.gd` can block safe implementation unless split first.
  - Validation sequence (required order):
    - Non-headless launch first (real display/video path) to catch parser/runtime scene errors early.
    - `godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`

- [x] P0 (Owners: Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane, Documentation lane): Complete simulation-path hardening before next implementation wave starts.
  - Acceptance criteria:
    - All required contracts for the next hot-path are explicit in this file and mapped to test anchors.
    - Required dependencies and file-size split preconditions are documented before code changes begin.
    - No CPU-success fallback remains documented for primary GPU-native simulation execution.
  - Risks:
    - Missing dependency preconditions can block implementation start.
    - GPU capability variance may force additional scoped split/refactor work.
    - Contract scope drift can desynchronize execution and verification owners.
  - Closeout notes: Runtime test split and parser hardening are complete for this wave. `addons/local_agents/tests/run_single_test.gd` parses successfully with canonical invocation patterns on current Godot stable, and remaining diffs are limited to the new runtime split files (`addons/local_agents/gdextensions/localagents/include/sim/VoxelEditGpuExecutor.hpp`, `addons/local_agents/gdextensions/localagents/src/sim/VoxelEditGpuExecutor.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsComputeManager.cpp`, `addons/local_agents/scenes/simulation/shaders/VoxelEditStageCompute.glsl`, `addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp`).

- [x] P1 (Owners: Simulation Foundations lane, Scope-A: Native Layout lane, Documentation lane): Add deterministic replay and observability guardrails tied to the next wave’s implementation scope.
  - Acceptance criteria:
    - Determinism requirements, seed/replay assumptions, and pass/fail observability are updated before implementation edits.
    - Validation matrix is updated with canonical harness commands for the wave’s affected contracts.
    - Ownership and ownership handoff points are recorded for any new helper/extractor modules.
  - Risks:
    - Replay assumptions may lag behind implementation changes without continuous updates.
    - Insufficient observability can hide deterministic regressions until late-stage validation.
    - Overly broad acceptance criteria can create delayed merges and avoidable rework.
  - Closeout notes: Thirdparty dependency and runtime split fixes are closed for this wave; parse checks pass, and remaining diffs are the new runtime split files listed in the P0 closeout notes.

## Unified GPU Voxel Transform Direction (active)

- One unified voxel transform system is the only supported simulation path (no separate erosion/weather/etc systems).
- All active voxels/chunks execute via GPU shader passes (compute/fragment as required by pass type).
- GPU is required for transform execution; unavailable GPU path is a hard fail with explicit contract status.
- No CPU-success fallback is allowed for transform execution.
- Condense/spread/split/spawn-style behaviors are represented as generic voxel transform ops under shared pass descriptors.
- Base Godot physics compatibility is required: `PhysicsServer3D`/`RigidBody3D` may provide contact and impulse inputs, but never simulation-authoritative voxel transform state.
- `RigidBody3D` usage is reduced to exception-based interaction surfaces (projectiles/props/player interaction), not ownership of destruction or voxel evolution logic.
- Precision policy is `fp32` by default for transform fields and shader passes.
- Precision is profile-driven and switchable to `fp64` for large-world deployments (`precision_profile=fp64`) on compatible builds/hardware, with identical pass contracts and no CPU fallback path.

Unified GPU voxel performance architecture:
- Active-set scheduling is mandatory: chunks/voxels are sleeping by default and wake only on local delta, halo-neighbor delta, or external impulse/contact.
- Two-tier wake logic is required: coarse chunk wake pass first, then fine voxel wake pass inside woken chunks.
- Dirty-region + halo invalidation is required: only dirty regions plus configured halo are eligible for transform passes.
- Sparse brick residency is required for transform storage and dispatch; dense full-world traversal is non-authoritative.
- GPU stream compaction is required for active worklists before expensive kernels.
- Multi-rate pass scheduling is required: fast impulse/stress passes every tick, slower diffusion/settling passes on deterministic cadence.
- Pass fusion is allowed only when it reduces bandwidth without breaking determinism or contract observability.
- Field quantization is policy-driven: integer/bit-packed metadata where possible, `fp32` default for numeric transforms, explicit opt-in for lower/higher precision profiles.
- Deterministic dispatch order is mandatory across wake, compaction, pass execution, and reductions.
- Legacy named runtime systems (`erosion`, `weather`, and equivalent concept-specific transform systems) are removed immediately as of February 15, 2026; generic transform ops are the only supported path.
- No compatibility adapters are allowed for removed named systems unless explicitly recorded as a dated blocker in this file.
- Requests or configs that reference removed named legacy stages must fail with `unsupported_legacy_stage`; remapping to generic passes is not allowed implicitly.

Locked architecture decisions (recorded February 15, 2026):
- Runtime target bootstrap contract:
  - Default `WorldSimulation` runtime setup must call `configure_environment(...)` then `stamp_default_voxel_target_wall(...)` to seed destructible target columns in the active environment snapshot.
  - Default fracture-prone column material profile is canonical `rock`; runtime/config aliases like `stone` and `gravel` resolve to `rock`.
  - Unified transform execution remains GPU-required for runtime target setup and follow-on simulation ticks; no CPU-success fallback path is allowed.
- Canonical voxel state schema:
  - Required baseline fields: `occupancy`, `material_id`, `material_profile_id`, `material_phase_id`, `mass`, `temperature`, `moisture`, `stress`, `damage`, `velocity`, `phase`, `flags`.
  - Material identity is required and explicit for every active voxel (`material_id`, `material_profile_id`, `material_phase_id`); missing identity fields are contract-invalid.
  - Default precision profile: `fp32` for numeric transform fields; packed integer/bitfield encoding for ids and flags.
  - Optional profile: `fp64` via `precision_profile=fp64` for large-world stability on compatible builds/hardware; pass contracts remain unchanged.
  - Ownership model: every pass declares read/write sets explicitly; writes are single-owner per pass boundary with deterministic handoff via defined barriers.
- Pass DAG + determinism contract:
  - Pass order is fixed per tick by canonical DAG; runtime cannot reorder passes dynamically.
  - Barrier points and reduction contracts are explicit in dispatch descriptors.
  - Tie-breaking rules are stable and index-based to preserve seeded replay determinism.
- Active-set lifecycle contract:
  - Wake triggers: local state delta, halo-neighbor delta, external contact/impulse, or explicit runtime event injection.
  - Wake flow: chunk-level wake evaluation first, voxel-level refinement second.
  - Required controls: `halo_radius`, `wake_hysteresis_ticks`, and `max_wake_latency_ticks`.
- GPU memory model:
  - Sparse brick/chunk residency is authoritative for transform execution.
  - Required metadata includes active residency maps, brick indirection tables, and compacted active-work indices.
  - Buffer pools and fragmentation controls are required and must be observable in diagnostics.
  - Large-world strategy uses streamed brick residency windows; full dense-world allocation is non-authoritative.
- Kernel interface standard:
  - Every kernel pass uses a typed descriptor containing `kernel_pass`, read/write field bindings, barrier mode, precision profile, and scheduling class.
  - Unknown/incomplete descriptors must hard fail with explicit contract status.
- Failure policy:
  - Missing required GPU capability is a hard fail, never a CPU-success fallback.
  - Required failure taxonomy: `gpu_required`, `gpu_unavailable`, `contract_mismatch`, `descriptor_invalid`, `dispatch_failed`, `readback_invalid`, `unsupported_legacy_stage`.
  - Runtime/UI surfaces failure status directly without silent downgrade behavior.
- Migration cut lines:
  - P0 cutoff date: February 15, 2026 for removing named legacy transform systems from active runtime paths.
  - P1 cutoff date: February 22, 2026 for removing residual named-system contracts/config aliases from native/runtime interfaces.
  - P2 cutoff date: March 1, 2026 for CI hard-gates that fail any legacy named-system code path or CPU transform execution path.
  - Physics boundary lock (effective immediately): Godot physics contact ingestion is an input contract only; voxel transform outputs cannot be authored by rigid-body/physics fallback paths.

Required performance/determinism budgets (must be explicit per profile):
- `max_wake_latency_ticks`: maximum allowed ticks between wake trigger and active voxel participation.
- `max_active_voxel_ratio_normal`: maximum active voxel ratio during normal workloads.
- `max_active_voxel_ratio_stress`: maximum active voxel ratio during stress workloads.
- `max_ms_per_stage`: per-pass latency budget in milliseconds.
- `max_ms_per_tick`: end-to-end simulation tick budget in milliseconds.
- `max_gpu_mem_mb`: maximum GPU memory budget for residency/work buffers.
- `determinism_tolerance_fp32`: bounded replay drift tolerance for `fp32` profile.
- `determinism_tolerance_fp64`: bounded replay drift tolerance for `fp64` profile when enabled.

Required control/tuning surface (configuration-first, no code-path forks):
- Scheduling controls: `tick_interval`, `phase_offset`, `rate_class`, `max_stage_iterations`.
- Active-set controls: `halo_radius`, `wake_hysteresis_ticks`, `wake_threshold`, `sleep_threshold`.
- Compaction controls: `compaction_interval`, `min_compaction_density`, `worklist_capacity`.
- Residency controls: `brick_size`, `resident_brick_budget`, `stream_window_radius`, `eviction_policy`.
- Precision controls: `precision_profile` (`fp32` default, `fp64` optional), per-pass precision overrides where contract-approved.
- Fusion controls: `fusion_group`, `fusion_enabled`, `max_fused_passes`.
- Readback/sync controls: `readback_interval`, `max_readback_bytes_per_tick`, `sync_mode`.
- Diagnostics controls: `contract_trace_level`, `perf_telemetry_enabled`, `determinism_audit_enabled`.

## Migration Plan (active phases)

- [ ] P0 (Owners: Runtime Simulation lane, Native Compute lane, Documentation lane, Validation/Test-Infrastructure lane): Lock architecture and remove contradictory paths.
  - Acceptance criteria:
    - Active plan text documents a single unified voxel transform path and removes independent subsystem-loop guidance.
    - `headless_gpu_dispatch_contract` includes hard-fail states (`gpu_required`, `gpu_unavailable`, `contract_mismatch`) and rejects CPU-success fallback.
    - Runtime guidance requires shader-pass execution across active voxel/chunk sets.
    - Precision contract is explicit: `fp32` default profile with switchable `fp64` profile semantics documented before implementation cutover.
    - Legacy named transform systems are removed from active runtime paths with no adapter layer.
  - Risks:
    - Legacy terminology may reintroduce split-system assumptions.
    - Capability reporting gaps may mask true GPU-unavailable failures.
    - Immediate removal can break stale local workflows until all entrypoints/config docs are updated in the same wave.
- [ ] P1 (Owners: Native Compute lane, Runtime Simulation lane, Documentation lane, Validation/Test-Infrastructure lane): Unify op schema and pass descriptors.
  - Acceptance criteria:
    - Generic op schema covers condense/spread/split/spawn behaviors with shared payload fields and deterministic pass descriptors.
    - `VoxelEditEngine` remains orchestration-only; `VoxelEditGpuExecutor` owns pass resolution and dispatch metadata.
    - Dispatch contracts remain deterministic with `kernel_pass`, `dispatched`, `backend_used`, and `dispatch_reason`.
    - Active-set lifecycle contract is implemented (`wake_reason`, `sleep_state`, `wake_hysteresis_ticks`, `halo_radius`) and consumed by GPU scheduling.
    - Sparse-brick + stream-compaction path is authoritative for active transform worklists.
    - Multi-rate pass descriptors are explicit and deterministic (`rate_class`, `tick_interval`, `phase_offset`) with no ad-hoc controller timing.
    - Canonical voxel state schema and per-pass read/write ownership declarations are implemented and validated in contract tests.
    - Physics integration contract is explicit: contact/impulse ingestion from `PhysicsServer3D` is deterministic input-only, with no rigid-body-owned voxel mutation path.
  - Risks:
    - Engine/executor/shader schema drift can break determinism.
    - Weak descriptor validation can allow ambiguous dispatch behavior.
    - Wake/sleep threshold tuning can cause thrash or latency spikes without strict deterministic caps.
- [ ] P2 (Owners: Validation/Test-Infrastructure lane, CI/Gating lane, Documentation lane): Enforce and gate.
  - Acceptance criteria:
    - CI fails when CPU fallback paths exist in transform execution.
    - Runtime validation asserts shader-pass coverage across active voxel/chunk sets for generic ops.
    - CI/runtime gates assert deterministic active-set behavior (wake/sleep transitions, halo invalidation, compaction ordering) under repeated seeded runs.
    - CI/runtime gates assert precision-profile conformance (`fp32` baseline, `fp64` profile where enabled) with bounded drift budgets per contract.
    - CI fails if any named legacy transform-system entrypoint/contract path remains.
    - CI/runtime gates enforce numeric budgets (`max_wake_latency_ticks`, active-ratio caps, per-stage/tick ms budgets, GPU memory caps) with profile-specific thresholds.
    - CI/runtime gates verify control-surface plumbing (all required controls are externally configurable and reflected in dispatch contracts/diagnostics).
    - Readiness/\"works\" claims require both headless harness evidence and at least one non-headless real video-path launch validation on the current tree.
    - This section is treated as canonical for migration sequencing and acceptance criteria.
  - Risks:
    - Coverage gaps can miss chunk/pass-sequencing regressions.
    - Drift between docs and CI policy can weaken enforcement.
    - Precision-profile drift can introduce non-reproducible outcomes across hardware tiers.

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
- [ ] P0 (Owners: Documentation lane, Validation/Test-Infrastructure lane): Wave 1 - Permanently guard against direct `godot -s addons/local_agents/tests/test_*.gd` invocation by enforcing single-test harness entrypoint usage everywhere.
  - Acceptance criteria: Docs and command templates require `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://... --timeout=120` for per-test runs and explicitly forbid direct `-s addons/local_agents/tests/test_*.gd`.
  - Acceptance criteria: Validation commands are documented as `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120` and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_field_handle_registry_contracts.gd --timeout=120`.
  - Risks: Contributors may continue using stale direct-invocation habits unless all docs/examples and review checklists are updated in the same wave.
- [ ] P1 (Owners: Documentation lane, Native Compute lane, Simulation Destruction lane, Validation/Test-Infrastructure lane): Wave 2 - Continue C++/GPU voxel engine and destruction-readiness implementation with explicit ownership, deterministic gating, and fail-fast dependency posture.
  - Acceptance criteria: Ownership matrix and wave scope define GPU voxel dispatch, destruction-stage handshake (`LocalAgentsSimulationCore -> failure emission plan -> VoxelEditEngine`), and required no-fallback dependency behavior.
  - Acceptance criteria: Validation commands include `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --suite=native_voxel` and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`.
  - Risks: GPU capability gaps, handshake boundary drift, and deterministic ordering regressions can delay readiness or create flaky destruction/HUD behavior.
- [ ] P1 (Owners: Validation/Test-Infrastructure lane): Restore headless single-test harness compatibility with Godot 4.6 by removing hard type references that no longer parse and preserving deterministic `run_test` pass/fail signaling.
  - Acceptance criteria: `addons/local_agents/tests/run_single_test.gd` parses on current Godot stable and exits non-zero on harness/script failures.
  - Acceptance criteria: Harness still awaits asynchronous `run_test` flows where returned value is awaitable and does not regress synchronous boolean test handling.
  - Acceptance criteria: Validation commands using `godot --headless --no-window --script addons/local_agents/tests/run_single_test.gd -- --test=res://...` produce trustworthy pass/fail status for targeted tests.
  - Risks: Overly broad awaitable detection could misclassify arbitrary objects and stall tests; keep detection narrowly scoped.
- [ ] P0 (Owners: Documentation lane, Validation/Test-Infrastructure lane): Add canonical per-test harness entrypoint guard so tests are always launched via SceneTree script mode and never as direct `MainLoop`/scene invocation.
  - Acceptance criteria: Docs define `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://... --timeout=120` as the canonical per-test invocation and explicitly require the `--` separator.
  - Acceptance criteria: Docs explicitly mark `godot --headless --no-window addons/local_agents/tests/run_single_test.gd` and `godot --headless --no-window -s addons/local_agents/tests/test_*.gd` as invalid forms that trigger `doesn't inherit from SceneTree or MainLoop`-class entrypoint errors.
  - Acceptance criteria: Validation commands include `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120` and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_field_handle_registry_contracts.gd --timeout=120`.
- [ ] P0 (Owners: Documentation lane, Runtime Simulation lane, Validation/Test-Infrastructure lane): Consolidate simulation runtime by hard-cutting legacy `WorldSimulatorApp` stack, enforcing `WorldSimulation` as the single voxel runtime path, and moving feature-set selection to in-runtime demo profiles/toggles.
  - Acceptance criteria: Docs define `WorldSimulation` as the only supported runtime path for simulation demos and remove/replace all `WorldSimulatorApp` setup guidance; legacy `WorldSimulatorApp` launch/config wiring is marked removed with no compatibility route documented.
  - Acceptance criteria: Docs specify the in-runtime demo profile/toggle model as generic-op presets (for example destruction-only, full-transform, perf/stress) and require profile switching without runtime-stack swaps.
  - Acceptance criteria: Ownership + rollout notes include deterministic validation expectations for each demo profile/toggle set and explicitly map validation commands/suites to profile behaviors.
  - Risks: Legacy scene/tooling references may still assume `WorldSimulatorApp`, creating partial migrations and broken onboarding flows until all references are cut.
  - Risks: Profile/toggle combinatorics can introduce unvalidated runtime states unless profile boundaries and required defaults are constrained.
  - Risks: Hard cutover may temporarily break local scripts or contributor workflows that still bootstrap through legacy runtime entry points.
- [ ] P0 (Owners: Documentation lane, Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane): Remove legacy simulation-pipeline naming from docs and contracts; standardize on `CoreSimulationPipeline`.
  - Acceptance criteria: `ARCHITECTURE_PLAN.md` and referenced doc guidance use `CoreSimulationPipeline` (and stage-specific names) as canonical naming, with legacy pre-rename terminology removed.
  - Acceptance criteria: Canonical validation commands are `scripts/check_max_file_length.sh`, `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_general_physics_wave_a_contracts.gd --timeout=120`, and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_general_physics_contracts.gd --timeout=120`.
- [ ] P1 (Owners: Runtime Simulation lane, Native Compute lane, Documentation lane, Validation/Test-Infrastructure lane): Split `LocalAgentsSimulationCore` orchestration from `CoreSimulationPipeline` stage execution boundaries.
  - Acceptance criteria: Stage ownership is explicit (`LocalAgentsSimulationCore` orchestrates inputs/outputs; `CoreSimulationPipeline` owns deterministic stage execution) with no duplicated stage logic across boundaries.
  - Acceptance criteria: Canonical validation commands are `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd --timeout=120`, `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_general_physics_wave_a_contracts.gd --timeout=120`, and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`.
- [ ] P1 (Owners: Runtime Simulation lane, Native Compute lane, Validation/Test-Infrastructure lane): Align unified voxel-transform parameter contracts and shader interfaces so kernel launch order and tile counts are deterministic and fail-fast safe.
  - Acceptance criteria: Backend `PackedFloat32Array` layouts for params and shader `std430` structs are verified by code-level review and shared regression tests or runtime assertions.
  - Acceptance criteria: Stage toggles (`set_compute_enabled` + native dispatch enablement) are applied consistently for compute-capable stages at startup and per-tick preference sync.
  - Acceptance criteria: Invalid RID frees are detectable with debug logging rather than silent partial frees when configure/dispatch is re-entered.
- [ ] P0 (Owners: Documentation lane, Runtime Simulation lane, Native Compute lane, Simulation Destruction lane, Validation/Test-Infrastructure lane): GPU-only voxel destruction demo readiness with scope limited to GPU-only voxel dispatch, destruction-stage handshake via `LocalAgentsSimulationCore -> failure emission plan -> VoxelEditEngine`, file-size split constraints for in-scope files above 540 lines, and deterministic demo/HUD signal behavior.
  - Acceptance criteria: Demo readiness docs require GPU-only voxel dispatch for destruction flows with no CPU-success fallback path documented for the primary demo path.
  - Acceptance criteria: Docs define the destruction-stage handshake contract as `LocalAgentsSimulationCore -> failure emission plan -> VoxelEditEngine` with explicit stage ownership and fail-fast behavior for missing handshake links.
  - Acceptance criteria: Scope notes require pre-edit file-size checks and mandatory helper/module splits before implementation for any in-scope source/config file at or above 540 lines.
  - Acceptance criteria: Demo/HUD signal behavior is documented as deterministic, with explicit signal ordering/ownership expectations for repeated seeded runs.
  - Risks: GPU dispatch capability or kernel readiness gaps can block demo path bring-up and force schedule churn.
  - Risks: Handshake boundary drift between `LocalAgentsSimulationCore`, failure emission planning, and `VoxelEditEngine` can cause silent destruction-stage disconnects.
  - Risks: Enforcing >540-line split constraints can expand refactor scope mid-wave and delay direct demo-readiness tasks.
  - Risks: Non-deterministic demo/HUD signal ordering can create flaky validation and inconsistent operator-facing behavior.
- [ ] P0 (Owner: Documentation lane): Replace rigid-brick target wall guidance with pure voxel-engine target wall + projectile-impact voxel destruction path in default `WorldSimulation`.
  - Acceptance criteria: Docs specify default `WorldSimulation` setup for voxel-only target walls, projectile impact flow that emits voxel destruction edits on hit, and a deterministic launcher test scenario with repeatable destruction expectations.
  - Risks: Voxel resolution/material tuning may introduce non-repeatable destruction profiles; coupling projectile impact and voxel-edit timing may cause flaky benchmark outcomes if determinism constraints are underspecified.
- [ ] P0 (Owner: Documentation lane): Add `voxel-destruction-only demo mode` for default `WorldSimulation` using unified generic voxel ops while preserving launcher startup and voxel wall destruction flow.
  - Acceptance criteria: Docs define the default demo-mode configuration as constrained generic-op presets (not subsystem loop toggles), confirm launcher boot remains enabled, and document deterministic projectile-to-voxel-wall destruction behavior.
  - Risks: Hidden dependencies on removed behavior-specific paths may break startup/HUD assumptions; incomplete profile constraints may leave non-demo transforms active and reduce determinism.
- [ ] P0 (Owners: Native Compute lane, Documentation lane, Validation/Test-Infrastructure lane): Enforce file-size split precondition for field-input resolution before GPU-only implementation continuation.
  - Acceptance criteria: `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineFieldInputResolution.cpp` is reduced below 540 lines by extracting scalar candidate/alias resolution helpers into focused `src/sim` + `include/sim` modules with behavior parity.
  - Acceptance criteria: Caller-facing APIs remain stable while build wiring includes the extracted helper translation unit(s) without changing compile assumptions.
  - Acceptance criteria: Validation passes for `./scripts/run_single_test.sh test_native_voxel_op_contracts.gd --timeout=120`, `./scripts/run_single_test.sh test_native_general_physics_failure_emission_contracts.gd --timeout=120`, and `scripts/check_max_file_length.sh`.
  - Risks: Helper extraction can accidentally drift diagnostic key strings or fallback-mode behavior if resolver ordering changes.
 
## Migration Plan (from prior output)

- `Priority: P0`
  - Owners:
    - Runtime Simulation lane
    - Native Compute lane
    - Documentation lane
    - Validation/Test-Infrastructure lane
  - Dependencies:
    - Canonical harness and command docs updated in this file.
    - Field-size preconditions enforced under 900 lines for edited files.
  - Acceptance criteria:
    - `WorldSimulation` is the default runtime path; references to legacy `WorldSimulatorApp` are removed from migration-relevant docs.
    - `VoxelEditEngine` and call-sites execute through a single GPU-only pass-dispatch contract with explicit fail-fast behavior.
    - Dispatch summaries include `kernel_pass`, `dispatched`, `backend_used`, `dispatch_reason`, and explicit hard-fail reasons when contracts cannot be satisfied.
  - File targets:
    - `addons/local_agents/gdextensions/localagents/include/sim/VoxelEditGpuExecutor.hpp`
    - `addons/local_agents/gdextensions/localagents/src/sim/VoxelEditGpuExecutor.cpp`
    - `addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp`
    - `addons/local_agents/gdextensions/localagents/src/LocalAgentsComputeManager.cpp`
    - `addons/local_agents/scenes/simulation/shaders/VoxelEditStageCompute.glsl`
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd`
    - `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd`
    - `addons/local_agents/simulation/controller/NativeComputeBridge.gd`
    - `addons/local_agents/tests/run_single_test.gd`
    - `addons/local_agents/tests/run_runtime_tests_bounded.gd`

- `Priority: P1`
  - Owners:
    - Simulation Foundations lane
    - Native Layout lane
    - Validation/Test-Infrastructure lane
    - Documentation lane
  - Dependencies:
    - P0 migration contract acceptance.
    - Stable field registry and bridge contract behavior in existing Wave A test baselines.
  - Acceptance criteria:
    - Hot stages run through unified generic voxel transform ops with typed field bindings and deterministic pass descriptors.
    - No CPU/scalar-success fallback path is allowed on the primary path.
    - Demo profile toggles are deterministic generic-op presets and do not require runtime-stack swaps.
  - File targets:
    - `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`
    - `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`
    - `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineStages.cpp`
    - `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineFieldEvolution.cpp`
    - `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineGpu.cpp`
    - `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp`
    - `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`
    - `addons/local_agents/tests/test_native_general_physics_wave_a_contracts.gd`
    - `addons/local_agents/tests/test_native_voxel_op_contracts.gd`
    - `addons/local_agents/tests/test_field_registry_config_resource.gd`

- `Priority: P2`
  - Owners:
    - Query Integration lane
    - CI/Gating lane
    - Documentation lane
  - Dependencies:
    - P1 stage/field migrations are complete.
    - Deterministic replay and replay seeds are stable on expanded contract coverage.
  - Acceptance criteria:
    - One gameplay/AI path is migrated to native query services without raw scalar snapshot consumers.
    - GPU-vs-CPU parity and performance gates are introduced for migrated hot paths.
    - This plan remains aligned with `README.md` and `ARCHITECTURE_PLAN.md` execution order.
  - File targets:
    - `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`
    - `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.cpp`
    - `addons/local_agents/controllers/AgentController.gd`
    - `addons/local_agents/tests/test_query_migration_contracts.gd`
    - `addons/local_agents/tests/benchmark_voxel_pipeline.gd`
    - `scripts/check_max_file_length.sh`
    - `README.md`

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
| [x] Completed (February 13, 2026) | P1 | Scope-A: C++ Stage Math Lane | Stage math hot-field extraction complete | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineStages.cpp` | Group liquid transport updates by neighbor neighborhood with deterministic aggregation before additional vectorization work. | Neighborhood aggregation order is deterministic for liquid transport updates and covered by runtime invariance contract tests. | None | `test_native_general_physics_wave_a_runtime.gd` |
| [x] Completed | P1 | Scope-A: C++ Stage Math Lane | Native stage input wiring | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp` | Continuity payloads (`field_buffers`/`updated_fields`) are explicit stage input sources for `neighbor_topology`, `mass`, `density`, `pressure`, `temperature`, `velocity` when present. | Continuity payloads are used as the preferred source for hot-stage math. | None | `test_native_general_physics_wave_a_contracts.gd` |
| [x] Completed (February 13, 2026) | P2 | Scope-A: C++ Stage Math Lane | Handle-vs-scalar parity work started in Wave A+ | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp` | Alias/field-name normalization map is deterministic and identical between stage math and field-evolution resolution paths. | Canonical fixtures show identical alias-map outputs across both execution paths. | None | `test_native_general_physics_wave_a_runtime.gd` |
| [x] Completed | P1 | Scope-A: C++ Stage Math Lane | Scalar fallback controls active | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineStages.cpp` | Scalar fallback is explicit compatibility-only and reason-coded when field-handle inputs are unavailable. | Hot stages resolve native handles first; compatibility fallback is allowed only with explicit reason codes. | None | `test_native_general_physics_wave_a_runtime.gd`, `test_native_voxel_op_contracts.gd` |
| [x] Completed (February 13, 2026) | P1 | Scope-A: C++ Stage Math Lane | Stage execution hot-path profiling baseline established | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp` | Cache field-handle lookup per stage execution to cap lookup overhead and reduce churn. | Handle lookup counts are deterministic and do not increase versus baseline under stable workloads. | None | `test_native_general_physics_wave_a_runtime.gd` |

#### Wave A+ / Next Execution

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [ ] Not started | P0 | Scope-A: C++ Stage Math Lane | Wave A completion gates and field-handle diagnostics are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineStages.cpp` | Remove remaining per-step scalar dictionary snapshots from hot simulation loops and require typed native fields for core transport/thermo/mechanical states. | Hot-stage execution paths for supported builds read native handle buffers first and never use scalar snapshots as fallback precedence. | Outstanding compatibility-only controllers may still trigger legacy dictionaries unless scoped out. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_wave_a_contracts.gd`, `test_native_field_handle_registry_contracts.gd` |
| [ ] Not started | P1 | Scope-A: Native Layout Lane | Wave A+ stage handles and field registry contracts are in place | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/FieldEvolution.cpp` | Implement SoA metadata, sparse chunk indexing, and deterministic chunk-ordering interfaces for field evolution and neighbor topology. | Deterministic chunk scans and stable sparse-index behavior are validated by deterministic fixture-based tests. | Serialization/migration support for preexisting field layouts is missing. | `test_native_field_handle_registry_contracts.gd`, `test_field_registry_config_resource.gd` |
| [ ] Not started | P1 | Scope-A: Simulation Foundations Lane | Wave A+ closeout requires reaction scaffolding | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp` | Add first-wave reaction channel scaffolding for oxidizer transport plus pressure/temperature-gated reaction source terms. | Deterministic reaction updates include oxidizer, pressure, and temperature coupling for one material profile without violating conservation envelopes. | Missing stoichiometry tables and profile metadata for full Material-API coverage. | `test_native_general_physics_contracts.gd` |
| [ ] Not started | P2 | Scope-B: Simulation Foundations Lane | Failure feedback bridge exists from Wave B foundations | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp` | Add stress-invariant failure branch path and porosity/permeability coupling through existing destruction pipeline contracts. | Failure signals are deterministic and bounded; feedback into porosity/permeability reduces or increases local resistance predictably. | Material profiles and scheduler coupling for branch transitions are not yet complete. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |

#### Wave B / Wave C: continuation

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [ ] Not started | P0 | Scope-B: Simulation Chemistry Lane | Wave A+ continuity and field diagnostics are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp` | Add reaction schema/stochiometry resources and wire oxidizer transport with pressure/temperature coupling into reaction rate updates for one migration-safe material profile. | Reaction execution uses typed stoichiometry and explicit oxidizer-pressure-temperature gating with deterministic outputs in native stages. | Strongly typed reaction resources are required before this row can be accepted. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Chemistry Lane | Reaction schema/stochiometry coupling row is implemented | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/tests/test_native_general_physics_contracts.gd` | Add reaction mass/energy closure checks with bounded tolerances and explicit drift reporting. | Deterministic mass+energy closure diagnostics are present per step and must remain within configured tolerances. | Reaction energetics and heat-capacity assumptions require finalization by material profile owners. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P0 | Scope-B: Simulation Destruction Lane | Reaction and field transport coupling is stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp` | Replace scalar damage path with failure invariants in native destruction branches. | Failure branching is stress-invariant, deterministic, and emits failure-invariant metadata instead of scalar damage accumulation. | Material thresholds and invariant profiles must be completed. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Destruction Lane | Failure invariants are in place for deterministic transitions | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp` | Add compaction and brittle fracture branches and couple both to porosity/permeability evolution. | Branch transition behavior is deterministic with bounded changes to porosity and permeability. | Scheduler coupling must account for branch-induced hot-spot transitions. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_contracts.gd` |
| [ ] Not started | P1 | Scope-B: Simulation Scheduling Lane | Destruction/reaction staging and native feedback are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/` | Implement native scheduler LOD with starvation guards for active-region dispatch and stage progression. | Active scheduling guarantees bounded starvation windows and never starves non-empty active regions under steady demand. | Starvation window maxima and fallback path need explicit values and tests. | `test_native_general_physics_wave_a_runtime.gd`, `test_native_general_physics_wave_b_runtime.gd` |
| [ ] Not started | P0 | Scope-C: Query Surface Lane | Physics/native outputs are available for queryable fields | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.cpp` | Expose native query surface for pressure gradients, heat fronts, failure/ignition risk, flow direction, and top-k hazards/resources. | Typed query APIs expose deterministic outputs for all listed categories with documented pre/post-conditions. | Query schema must be finalized in one pass; no fallback-only compatibility behavior. | `test_native_query_contracts.gd` |
| [ ] Not started | P1 | Scope-C: Query Integration Lane | Query surface and contracts are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, `addons/local_agents/controllers/*` | Migrate one gameplay/AI consumer path to native query services. | The migrated path no longer reads raw scalar snapshots for any of the listed query categories. | Remaining consumers may keep temporary adapter layers until migration wave completes. | `test_query_migration_contracts.gd`, `test_native_general_physics_wave_a_runtime.gd` |
| [ ] Not started | P1 | Scope-D: Native Compute Lane | Scheduler and query rows above are stable | 2026-02-14 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`, `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineGpu.cpp` | Add first compute-kernel stage with ping-pong buffers and barrier/fence correctness. | Kernel stage reproduces baseline key outputs with deterministic barrier synchronization and state transitions. | Requires explicit GPU precondition and required capability path. | `test_native_gpu_kernel_stage.gd`, `test_native_general_physics_wave_a_runtime.gd` |
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
- `transform_snapshot`: required per-step generic transform snapshot payload (stage-agnostic) with deterministic carry-forward fields.
- `transform_diagnostics`: required per-step generic diagnostics payload covering handle resolution outcomes, explicit misses, fallback reasons, and source selection.
- `field_handle_mode`: required summary marker with values `field_handles` when handle mode is active, or explicit compatibility mode value.
- `transform_snapshot.updated_fields`: required key that remains present and deterministic across `execute_step` reentry.
- Legacy stage-specific contract keys (including `stage_field_input_diagnostics`) are unsupported for active runtime authority and must not be reintroduced.

Wave A+ contract matrix:

Completed milestones:
- [x] P0, Scope-A: C++ Stage Math Lane: Existing contract assertions now retain `transform_diagnostics` flow and deterministic updates to `transform_snapshot.updated_fields`.

| Status | Priority | Owner | Dependency | Last touched | Scope Files | Definition of Done | Acceptance criteria | Blockers | Test anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [x] Completed (February 13, 2026) | P0 | Scope-A: C++ Stage Math Lane | Data-contract summary key set stabilized | 2026-02-13 | `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipeline.cpp` | `summary["field_handle_mode"]` is explicit and all existing `summary`/`conservation_diagnostics`/`field_evolution` keys stay stable unless new handle-aware keys are added. | `summary["field_handle_mode"]` is explicit and contract key sets are stable across handle/scalar modes. | None | `test_native_general_physics_wave_a_runtime.gd` |

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
- [x] February 14, 2026: Emit voxel edit operations from physically derived failure fields through preset-based emitters.
  - Status: Completed.
  - Definition of Done: `run_destruction_stage` emits explicit failure-status output, pipeline feedback includes failure-source plus preset-based emitter contract fields (`emitter_preset_id`, `emitter_material_identity`), and `LocalAgentsSimulationCore::apply_environment_stage` executes deterministic environment voxel emission based on active failure feedback.
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
- 2026-02-15 execution slice (P0, Runtime Simulation lane owner): wire `WorldSimulation._process_native_voxel_rate` payload so FPS launcher projectile contact rows sampled in `_process` are forwarded as `physics_contacts` to `execute_native_voxel_stage` (`voxel_transform_step`) and therefore available to native physics failure emission input normalization.
- Acceptance criteria for this slice: when projectile contacts are sampled in the same frame, dispatched native voxel-stage payloads include `physics_contacts` rows without introducing any CPU fallback/degraded path.

Boundary and scheduling correctness:
- [x] Implement face-stencil boundary behavior (`open`, `inflow/outflow`, `reflective`, `no-slip`, `no-penetration`) — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`; tests: `test_native_general_physics_contracts.gd`.
- [x] Add moving-obstacle boundary handling and deterministic chunk-edge boundary tests. — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`; tests: `addons/local_agents/tests/test_native_general_physics_contracts.gd`, `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [ ] Move foveated/LOD scheduling fully native with conservative coarse/fine transitions and starvation guards.
- [x] Route dynamic obstacle boundaries from `PhysicsServer3D` contact body transforms/velocities rather than parallel custom obstacle solvers. — 2026-02-13. Obstacle boundary dynamics are now sourced from `PhysicsServer3D` contact body velocities, with deterministic aggregator and normalization paths wired through `addons/local_agents/gdextensions/localagents/src/godot/PhysicsServerContactBridge.gd`, `addons/local_agents/gdextensions/localagents/src/godot/NativeComputeBridge.gd`, and `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineInternal.cpp`.

Wave B validation gates:
- [x] Add deterministic regression scenarios (impact, flood, fire, cooling, collapse, mixed-material transitions). — 2026-02-14. Runtime regression coverage added in `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [x] Add deterministic boundary consistency checks across chunk edges (active-region transition consistency remains follow-up). — 2026-02-13. Scope: `addons/local_agents/gdextensions/localagents/src/sim/CoreSimulationPipelineFieldEvolution.cpp` ("FieldEvolution.cpp"); tests: `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.
- [x] Require coherent repeated-load terrain response without numerical explosion. — 2026-02-14. Repeated-load stability checks added in `addons/local_agents/tests/test_native_general_physics_wave_a_runtime.gd`.

### Wave 1: Voxel Kernel Pass Abstraction (GPU-only transition hardening)

- [ ] Not started (P0)
- Owners/Lane ownership:
  - Runtime Simulation lane (controller contract and contract surfacing)
  - Native Compute lane (pass abstraction, shader entrypoint/buffer binding maps, and executor behavior)
  - Documentation lane (contract docs + runbook updates)
  - Validation/Test-Infrastructure lane (contract and harness gates)
- Definition of done:
  - `VoxelEditStageCompute.glsl` is treated as a multi-pass compute surface behind a typed executor map (logical `kernel_pass` -> dispatch descriptor), not by ad-hoc controller-side branching.
  - `VoxelEditGpuExecutor` is the single resolver for pass->shader/pipeline/binding metadata and enforces fail-fast when requested pass metadata is incomplete.
  - All voxel edit entrypoints remain hot-path deterministic under repeated seeded runs.
- Required acceptance criteria:
  - `execute_voxel_stage` payloads expose a canonical `kernel_pass` token plus pass input fields (for example radius/shape/noise metadata), and acceptors reject unknown/missing pass metadata with explicit error codes.
  - `VoxelEditEngine` remains an orchestration shim: no inline shader/pipeline selection logic and no pass-specific fallback semantics in the call-site layer.
  - `headless_gpu_dispatch_contract` includes per-pass dispatch fields (`kernel_pass`, `dispatched`, `backend_used`, `dispatch_reason`) and never reports successful execution when GPU pass mapping is unresolved.
  - Pass descriptors carry performance semantics (`rate_class`, `fusion_group`, `active_set_policy`, `precision_profile`) and reject incomplete descriptors.
  - Active-set scheduling contracts are emitted/validated per pass (`wake_reason`, `active_chunk_count`, `active_voxel_count`, `sleep_transition_count`) for deterministic replay observability.
  - Precision defaults to `fp32`; `fp64` profile is feature-flagged and contract-compatible without controller-side branching.
  - Validation commands include:
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_dispatch_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`
  - Controller-side follow-up before wave complete:
    - `addons/local_agents/scenes/simulation/controllers/WorldSimulation.gd` must treat voxel stage results as opaque dispatch contracts and avoid pass-specific heuristics.
    - `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd` and `addons/local_agents/simulation/controller/NativeComputeBridge.gd` must keep pass-selection authority out of orchestration and validate `kernel_pass` + dispatch contract fields only.

### Wave C: GPU-First Runtime + Query Migration + CI Gates

GPU-first implementation:
- [ ] P0 (Owners: Runtime Simulation lane, Native Compute lane, Documentation lane, Validation/Test-Infrastructure lane): Start wave for headless GPU dispatch contract + staged pipeline GPU-first migration before merge.
  - Dependency: Requires completion of current VoxelEditEngine split/composition hardening and a stable `CoreSimulationPipeline` stage boundary contract before any broader GPU-only feature expansion.
  - Ownership split: Runtime Simulation lane owns stage sequencing + contract schema, Native Compute lane owns GPU dispatch execution + capability enforcement, Documentation lane owns canonical plan/runbook updates, Validation/Test-Infrastructure lane owns contract test harness maintenance.
  - Acceptance criteria:
    - Add deterministic `headless_gpu_dispatch_contract` output from simulation entrypoints exposing per-stage dispatch decisions and explicit fail-fast reason codes when GPU requirement is unmet (`gpu_required`, `gpu_unavailable`, `contract_mismatch`).
    - Enforce staged migration in `CoreSimulationPipeline`: each native hot stage only progresses when its GPU dispatch contract is satisfied; no CPU-success fallback is allowed on the primary path.
    - Headless paths must remain authoritative for contract validation, and any missing capability or contract mismatch must terminate with a structured hard-fail status.
  - Test hooks:
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_dispatch_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_general_physics_wave_a_contracts.gd --timeout=120`
    - `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --suite=native_voxel --timeout=120`
- [ ] P0 (Owners: Runtime Simulation lane, Native Compute lane, Documentation lane, Validation/Test-Infrastructure lane): Immediate full GPU migration of voxel hot path in `VoxelEditEngine` with fail-fast-only execution policy.
  - Policy lock: `VoxelEditEngine` must not expose a CPU success execution path; if required GPU backend/capabilities are unavailable, return fail-fast error only.
  - File targets: new helper/backend/shader + shim split in `addons/local_agents/gdextensions/localagents/include/sim/VoxelEditGpuExecutor.hpp`, `addons/local_agents/gdextensions/localagents/src/sim/VoxelEditGpuExecutor.cpp`, `addons/local_agents/gdextensions/localagents/src/LocalAgentsComputeManager.cpp`, `addons/local_agents/scenes/simulation/shaders/VoxelEditStageCompute.glsl`, and `addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp` (call-site shim/orchestration only).
  - File-size split requirement: `addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp` is already above the 540-line precondition (currently 849 lines), so helper extraction is mandatory before implementation and resulting files must stay under the 600-line hard cap.
  - Acceptance criteria: Voxel hot-path stage execution is dispatched on real GPU compute kernels, readback is implemented for required downstream sync/contract fields, and validation confirms no CPU-success stage execution path remains in `VoxelEditEngine`.
- [ ] P0/P1 (Owners: Native Compute lane, Runtime Simulation lane, Documentation lane, Validation/Test-Infrastructure lane): `VoxelEditEngine` decomposition split wave (must complete before additional GPU-only hardening waves).
  - Acceptance criteria (P0): Decompose `addons/local_agents/gdextensions/localagents/src/VoxelEditEngine.cpp` into orchestration-only call-site shim plus extracted helper/executor modules so every resulting source/config file remains under the 600-line hard cap.
  - Acceptance criteria (P1): Post-split call graph and GPU-only/fail-fast behavior remain unchanged for voxel edit execution contracts, with no reintroduced CPU-success path in `VoxelEditEngine`.
  - Validation commands (canonical harness): `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120`; `godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120`.
- [ ] P0 (Owners: Native Compute lane, Runtime Simulation lane, Documentation lane, Validation/Test-Infrastructure lane): Shader utilization wave - cache/reuse GPU shader and pipeline resources to remove per-dispatch recreation in voxel edit hot paths.
  - Acceptance criteria: `LocalAgentsComputeManager`/`VoxelEditGpuExecutor` cache and reuse shader/pipeline resources across dispatches, and hot-path dispatch no longer recreates shader or pipeline objects per operation.
  - Acceptance criteria: Validation commands include `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120` and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_voxel_chunk_collision_parity_contracts.gd --timeout=120`.
- [ ] P1 (Owners: Native Compute lane, Runtime Simulation lane, Documentation lane, Validation/Test-Infrastructure lane): Expand `VoxelEditStageCompute.glsl` + executor op packing to consume radius/shape/noise metadata for voxel edits.
  - Acceptance criteria: Packed op payload includes radius, shape selector, and deterministic noise metadata, and compute shader dispatch uses those fields directly to control edit footprint and falloff behavior.
  - Acceptance criteria: Validation commands include `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_native_voxel_op_contracts.gd --timeout=120` and `godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd --timeout=120`.
- [ ] Implement compute kernels for all hot stages and keep core fields resident on GPU.
- [ ] Add ping-pong buffers, barrier/fence correctness, and sparse active-region dispatch.
- [ ] Implement active-set sleep/wake scheduler and deterministic dirty-halo invalidation on GPU worklists.
- [ ] Implement sparse-brick residency + GPU stream compaction for active voxel/chunk sets.
- [ ] Implement deterministic multi-rate pass scheduling and bounded pass fusion policy.
- [ ] Standardize precision profiles with `fp32` default and switchable `fp64` execution profile for large-world scenarios.
- [ ] Add configuration-first tuning surface for scheduler, active-set, compaction, residency, precision, fusion, and readback controls with deterministic contract visibility.
- [ ] Add backend capability gating and mobile quality tiers.
- [ ] Remove any remaining non-`VoxelEditEngine` CPU fallback paths; GPU-required transform execution must fail fast when GPU contracts are unmet.
- [ ] Remove legacy named transform-system runtime paths immediately; no adapter bridge is permitted on primary or secondary execution paths.
- [ ] Keep physics-server sync/readback deltas minimal and bounded (no full-scene per-frame bridge copies).

Query/gameplay integration:
- [ ] Expose native query APIs for pressure gradients, heat fronts, failure/ignition risk, flow direction, and top-k hazards/resources.
- [ ] Migrate gameplay/AI consumers to native query services.
- [ ] Keep script ownership to orchestration/UI only.
- [ ] Expose unified query surfaces that combine voxel risk fields with physics-server collision/contact state.

CI confidence and production gates:
- [ ] Add GPU-required contract conformance suites and backend matrix coverage.
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
- [x] February 12, 2026: Procedural terrain/runtime stack now uses voxel-world generation and deterministic flow payloads (`flow_map`/`columns`/`block_rows`) for generic transport/render coupling; named weather/hydrology/erosion/solar stages are non-authoritative legacy terms.

## Deferred / Decision Log

- [ ] [Owner: Scope-D: Memory/Graph Lane; Decision owner path: `controllers/ConversationStore.gd` -> `docs/NETWORK_GRAPH.md`] Decide whether to keep SQLite-only graph architecture or introduce specialized graph backend.
Completed policy records:
- [x] Whisper backend policy: `whisper.cpp` selected as default for desktop tiers; `faster-whisper` is optional future experimentation.
- [x] Bundled dependency strategy: keep native/runtime dependency pins in scripts/manifests and validate each bump with core/runtime suites before merge.

Policy decisions (recorded February 12, 2026):
- Whisper backend policy: default to `whisper.cpp` CLI/runtime integration for all supported desktop tiers (macOS/Linux/Windows) to preserve single-toolchain native distribution and headless determinism. Treat `faster-whisper` as optional future experimentation only, not a required runtime/backend path.
- Bundled dependency versioning strategy: keep build/runtime dependencies pinned in scripts/manifests, update them via focused additive commits, and validate each bump with headless core + runtime-heavy suites before merge. Runtime artifacts remain out of git history; only scripts/metadata and reproducible fetch/build logic are committed.
