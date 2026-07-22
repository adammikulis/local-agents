# Native Simulation Unification Plan (GPU-Only Unified Voxel Pipeline)

## Status Note

**RETIRED / historical (2026-07):** the native C++ voxel/sim sources this plan targeted were dropped
from the `localagents` GDExtension (it now ships only the llama.cpp/LLM agent runtime), and the old
`WorldSimulation` voxel stack was deleted. The active simulation is the from-scratch godot_voxel
ecosystem sim (`scenes/simulation/voxel/VoxelWorld.tscn`, see `HANDOFF.md`), which runs in GDScript with
GPU compute for the material field (`material/MaterialGPU3D.gd` + `material/kernels3d/*.glsl`). This document is kept as the native/GPU-first
target model and design intent, not as a description of current code.

Active execution tracking is in `ARCHITECTURE_PLAN.md`. This document defines the native target model and migration intent.

## Objective

Converge all voxel evolution into one GPU-only transform pipeline in native C++ (`GDExtension`).

- No named high-level runtime systems (`weather`, `hydrology`, `erosion`, `solar`, etc.).
- Behavior differences are material coefficients, field state, and emitter presets.
- No CPU-success fallback for transform execution.

## Integration Scope (ownership split)

Native core under `addons/local_agents/gdextensions/localagents/` owns:
- Voxel field storage and residency metadata.
- Pass DAG scheduling and deterministic ordering.
- GPU dispatch and shader/pipeline/buffer lifecycle.
- Transform diagnostics and deterministic replay metadata.

GDScript controllers under `addons/local_agents/simulation/controller/` own:
- Contract shaping and validation.
- Scene/event ingestion.
- Runtime telemetry/HUD wiring.

GDScript is orchestration/UI only; it never owns transform math or mutation outcome decisions.

## Canonical Runtime Model

1. Unified voxel state schema
- Required identity: `material_id`, `material_profile_id`, `material_phase_id`.
- Required dynamics: `mass`, `temperature`, `moisture`, `stress`, `damage`, `velocity`, `phase`, `flags`.
- `fp32` is default precision profile.
- `fp64` is optional via `precision_profile=fp64` on compatible builds/hardware.

2. Unified transform operations
- Condense, spread, split, spawn, fracture, transport, reaction, and phase change are generic transform ops.
- Passes execute over active sets only (wake/sleep + dirty/halo invalidation).
- Fixed deterministic pass DAG and reduction rules per tick.

3. Material and emitter semantics
- Materials are explicit data profiles (not codepath categories).
- Emitters are data presets (`radiant_heat`, mass/energy injection, boundary forcing).
- "Sun", geothermal, volcanic, and atmospheric sources are preset configurations over the same emitter contract.

4. Pass descriptor contract
- Every pass uses a typed descriptor with pass id, read/write field sets, barriers, rate class, and precision profile.
- Deterministic ordering and stable index-based tie-breaking are mandatory.
- Unknown/incomplete descriptors hard-fail with explicit contract status.

5. GPU execution policy
- Compute/fragment shader passes are authoritative for voxel transforms.
- Missing required GPU capability is hard-fail (`gpu_required` / `gpu_unavailable`).
- Runtime cannot silently downgrade to CPU transform logic.
- Canonical failure taxonomy: `gpu_required`, `gpu_unavailable`, `contract_mismatch`, `descriptor_invalid`, `dispatch_failed`, `readback_invalid`, `memory_exhausted`, `unsupported_legacy_stage`. Runtime surfaces the canonical code directly with no silent downgrade.

## Migration Phases

### Phase 1: Contract lock
- Freeze canonical voxel schema, pass descriptor contract, and failure taxonomy.
- Remove legacy named-system dispatch contracts from active runtime path.

Exit criteria:
- Runtime/controller/native boundaries use only unified voxel transform contracts.
- No CPU fallback language or behavior remains in transform flow.

### Phase 2: Native execution convergence
- Route all transform stages through shared native dispatch and resource management.
- Normalize diagnostics and determinism metadata (`kernel_pass`, `dispatch_reason`, replay signatures).

Exit criteria:
- GDScript is orchestration-only for simulation transforms.
- All heavy voxel math executes in native GPU path.

### Phase 3: Legacy removal hard gate
- Remove residual named-system references from tests/docs/contracts.
- CI/runtime gates fail any CPU transform execution path or legacy stage entrypoint.

Exit criteria:
- Unified pipeline is the only production path.
- Legacy stage/config usage fails with explicit contract errors.

## Verification Gates

1. Determinism gate
- Fixed-seed replay remains bounded under profile-specific tolerances (`fp32` baseline, `fp64` optional).

2. Dispatch integrity gate
- Every transform tick exposes canonical dispatch metadata and canonical failure codes.

3. Active-set gate
- Wake/sleep/halo/compaction behavior remains deterministic and within configured latency budgets.

4. Validation evidence gate
- Headless harness sweeps pass.
- Non-headless launch on real video path succeeds before "works" claims.

## Notes on Naming

Terms like `sun`, `geothermal`, `volcanic`, `weather`, `hydrology`, and `erosion` are allowed only as
user-facing preset/config labels. They do not define separate runtime systems or execution paths — all
behavior differences are material coefficients, field state, and emitter presets over the same unified
transform pipeline.
