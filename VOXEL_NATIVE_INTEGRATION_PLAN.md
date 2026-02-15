# Voxel Native Core Integration Plan

Date: February 15, 2026
Owner: Simulation Runtime
Status: Active reference (execution tracked in `ARCHITECTURE_PLAN.md`)

## Objective

Integrate voxel simulation into one native GPU pipeline where GDScript remains orchestration/UI only.

- Unified transform pipeline replaces domain-specific named systems.
- Material identity and phase are explicit per voxel.
- Emitters are generic presets, not architecture categories.
- No CPU-success fallback in transform execution.

## Integration Scope

Native core under `addons/local_agents/gdextensions/localagents/` owns:
- Voxel field storage and residency metadata.
- Pass DAG scheduling and deterministic ordering.
- GPU dispatch, shader/pipeline/buffer lifecycle.
- Transform diagnostics and deterministic replay metadata.

GDScript controllers under `addons/local_agents/simulation/controller/` own:
- Contract shaping and validation.
- Scene/event ingestion.
- Runtime telemetry/HUD wiring.

## Canonical Contracts

1. Voxel identity contract
- Required: `material_id`, `material_profile_id`, `material_phase_id`.
- Missing identity fields are contract-invalid for active transform payloads.

2. Dispatch/failure contract
- Canonical failures: `gpu_required`, `gpu_unavailable`, `contract_mismatch`, `descriptor_invalid`, `dispatch_failed`, `readback_invalid`, `memory_exhausted`, `unsupported_legacy_stage`.
- Runtime surfaces canonical code directly; no silent downgrade behavior.

3. Precision contract
- Default `fp32`.
- Optional `fp64` profile switch with same pass interfaces.

4. Pass descriptor contract
- Typed descriptor with pass id, read/write fields, barriers, rate class, and precision profile.
- Deterministic ordering and stable tie-breaking are mandatory.

## Implementation Waves

### Wave A (P0): Contract convergence
- Align native/runtime failure taxonomy with canonical codes.
- Enforce material identity propagation end-to-end.
- Remove contradictory CPU fallback and named-system references in planning docs.

Acceptance:
- Native and bridge surfaces emit canonical failures.
- `material_profile_id` and `material_phase_id` are propagated in runtime payload identity.

### Wave B (P1): Runtime decomposition + active-set hardening
- Continue extraction from large controller files into focused modules.
- Keep active-set lifecycle deterministic (wake/sleep/halo/compaction).
- Preserve GPU-first dispatch ownership in native executor.

Acceptance:
- No edited runtime file exceeds max line policy.
- Dispatch telemetry and determinism signals remain stable.

### Wave C (P2): Enforcement and gating
- CI/runtime gates reject legacy stage contracts and CPU transform paths.
- Validation matrix requires both headless harness evidence and non-headless launch evidence for readiness claims.

Acceptance:
- Contract and harness gates fail fast on legacy/cpu path regressions.
- Readiness claims are evidence-backed only.

## Notes on Naming

Terms like sun/geothermal/volcanic/weather are allowed only as user-facing presets/config labels. They do not define separate runtime systems or execution paths.
