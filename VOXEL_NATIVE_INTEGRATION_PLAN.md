# Voxel Native Core Integration Plan

Date: February 13, 2026
Owner: Simulation Runtime
Status: Draft for decision

## Status Note
Progress tracking for active implementation has moved to `ARCHITECTURE_PLAN.md` under Concern I (Wave A/B/C checkboxes). This document is background/reference only.

## Objective

Integrate all voxel/tile simulation domains into a single native simulation core (GDExtension) so GDScript remains orchestration/UI only. This covers smell, wind, weather, hydrology, erosion/destruction, solar, water simulation, ecology signals, and shared spatial query services.

## Current State Summary (repo-specific)

- Voxel/tile simulation is implemented primarily in GDScript systems under `addons/local_agents/simulation/`.
- Numeric hotspots are in per-system loops in:
  - `addons/local_agents/simulation/SmellFieldSystem.gd`
  - `addons/local_agents/simulation/WindFieldSystem.gd`
  - `addons/local_agents/simulation/WeatherSystem.gd`
  - `addons/local_agents/simulation/HydrologySystem.gd`
  - `addons/local_agents/simulation/ErosionSystem.gd`
  - `addons/local_agents/simulation/SolarExposureSystem.gd`
- GPU compute exists but is fragmented into bespoke backends:
  - `addons/local_agents/simulation/SmellComputeBackend.gd`
  - `addons/local_agents/simulation/WindComputeBackend.gd`
  - `addons/local_agents/simulation/WeatherComputeBackend.gd`
  - `addons/local_agents/simulation/HydrologyComputeBackend.gd`
  - `addons/local_agents/simulation/ErosionComputeBackend.gd`
  - `addons/local_agents/simulation/SolarComputeBackend.gd`
- Scheduler/cadence logic is duplicated across environment systems and controllers:
  - `addons/local_agents/scenes/simulation/app/controllers/EnvironmentTickScheduler.gd`
  - `addons/local_agents/scenes/simulation/controllers/ecology/VoxelProcessGateController.gd`
  - local cadence helpers inside environment systems.
- Orchestration/UI layers are already mostly adapter-friendly:
  - `addons/local_agents/scenes/simulation/app/WorldSimulatorAppSimulationModule.gd`
  - `addons/local_agents/scenes/simulation/controllers/PerformanceTelemetryServer.gd`
  - `addons/local_agents/simulation/controller/SimulationSnapshotController.gd`

## Target Architecture

## 1) Native Simulation Core (GDExtension)

New native module under `addons/local_agents/gdextensions/localagents/` owns:
- Dense/sparse voxel/tile storage
- System graph execution/scheduling
- Compute dispatch and capability checks
- Query and telemetry services

GDScript systems become thin adapters with no heavy numeric loops.

## 2) Native System Graph

Node-style graph for domain stages:
- Weather
- Hydrology
- Erosion/destruction
- Solar
- Smell
- Wind
- Ecology signal layers

Shared graph primitives:
- Locality masks
- Dynamic cadence
- Dependency ordering
- Dirty-region propagation

## 3) Script Layer (orchestration only)

GDScript responsibilities:
- Config/resources
- Signal wiring
- Scene/user event ingestion
- HUD/debug presentation

Explicitly removed from GDScript:
- Full-grid voxel/tile sweeps
- Per-cell stencil numerics
- Query-heavy scanning loops

## Native Core Components (build in this order)

## A. Unified Field/Buffer Registry (highest ROI)

Purpose: single source of truth for all tile + voxel fields.

Add native types (new):
- `addons/local_agents/gdextensions/localagents/include/sim/FieldRegistry.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/FieldLayout.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/FieldChannel.hpp`
- `addons/local_agents/gdextensions/localagents/src/sim/FieldRegistry.cpp`

Add script-side config resources (new):
- `addons/local_agents/configuration/parameters/simulation/FieldRegistryConfigResource.gd`
- `addons/local_agents/configuration/parameters/simulation/FieldChannelConfigResource.gd`

Migration targets:
- Replace ad-hoc layer dictionaries in `SmellFieldSystem.gd`, `WindFieldSystem.gd`, `WeatherSystem.gd`, `HydrologySystem.gd`, `ErosionSystem.gd`, `SolarExposureSystem.gd` with field handles.
- Replace `voxel_world` dictionary fragments in volcanic/environment paths with typed field descriptors.

Exit criteria:
- Every simulation system reads/writes fields by stable IDs and typed channels.
- No per-system private canonical storage for shared environment data.

## B. Locality + Cadence Scheduler

Purpose: one scheduler policy for all systems.

Add native types (new):
- `addons/local_agents/gdextensions/localagents/include/sim/Scheduler.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/LocalityMask.hpp`
- `addons/local_agents/gdextensions/localagents/src/sim/Scheduler.cpp`

Script adapters to simplify/delete:
- `addons/local_agents/scenes/simulation/app/controllers/EnvironmentTickScheduler.gd`
- `addons/local_agents/scenes/simulation/controllers/ecology/VoxelProcessGateController.gd`
- local `_cadence_for_activity`/`_should_step_*` helpers in environment systems.

Exit criteria:
- Active-region masks and cadence are centralized.
- Global/per-system enable switches controlled from one API.
- Dirty-region propagation emitted by scheduler graph stage.

## C. GPU Compute Pipeline Manager

Purpose: unify shader/pipeline/buffer lifecycle and dispatch.

Add native types (new):
- `addons/local_agents/gdextensions/localagents/include/sim/ComputeManager.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/ComputePipelineCache.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/BufferPool.hpp`
- `addons/local_agents/gdextensions/localagents/src/sim/ComputeManager.cpp`

Migration targets:
- Collapse per-system backend boilerplate currently in `*ComputeBackend.gd` to shared native dispatch surfaces.
- Keep shader sources under `addons/local_agents/scenes/simulation/shaders/` but route loading/caching through the native manager.

Exit criteria:
- One pipeline cache and buffer lifecycle manager used by all sim domains.
- Async dispatch + fences managed centrally.
- CPU fallback policy internal to native core, no script-side duplicate fallback flows.

## D. Stencil/Neighborhood Ops Library

Purpose: shared kernels and CPU equivalents.

Add native ops (new):
- `advection`, `diffusion`, `decay`, `gradient`, `laplacian`, `erosion/deposition` primitives
- Files under `addons/local_agents/gdextensions/localagents/include/sim/ops/` and `src/sim/ops/`

Migration targets:
- Hydrology + erosion/destruction + solar + weather first (environmental core priority)
- Then smell/wind and ecology signal layers

Exit criteria:
- Domain systems compose primitives; no duplicated per-domain stencil loops.

## E. Spatial Query Service

Purpose: shared fast read API for agents/ecology/AI.

Add native types (new):
- `addons/local_agents/gdextensions/localagents/include/sim/QueryService.hpp`
- `addons/local_agents/gdextensions/localagents/src/sim/QueryService.cpp`

Required queries:
- Strongest weighted signal
- Nearest resource/danger
- Top-k candidates in radius

Migration targets:
- First replace terrain/water/environment query loops used by climate and terrain systems.
- Then replace smell/wind query caches and repeated scan loops in simulation and ecology callers.

Exit criteria:
- Query APIs consumed by controllers/systems without direct field scans in GDScript.

## F. Telemetry + Debug Snapshot Service

Purpose: standard metrics and HUD/debug sampling.

Add native types (new):
- `addons/local_agents/gdextensions/localagents/include/sim/SimProfiler.hpp`
- `addons/local_agents/gdextensions/localagents/include/sim/DebugSnapshotService.hpp`
- `addons/local_agents/gdextensions/localagents/src/sim/SimProfiler.cpp`

Migration targets:
- `addons/local_agents/scenes/simulation/controllers/PerformanceTelemetryServer.gd`
- `addons/local_agents/simulation/controller/SimulationSnapshotController.gd`

Exit criteria:
- Per-system and per-stage timings exposed via one contract.
- HUD sampling path consumes standardized snapshot rows.

## Composition Model (not inheritance)

System interface in native core:
- `SystemRuntime` with explicit lifecycle: `configure`, `prepare`, `step`, `flush`, `export_debug`

Injected shared services:
- FieldRegistry
- Scheduler
- ComputeManager
- SimProfiler
- QueryService

Rule:
- Domain systems only contain domain math/logic.
- No duplicated plumbing per system.

## Phased Migration Plan

## Phase 1: Infra only (no feature rewrites)

Scope:
- Build FieldRegistry, Scheduler, ComputeManager skeletons in GDExtension.
- Add script adapters so existing systems call native services for storage/cadence/dispatch management.

File-level work:
- Add `sim/` native subtree in `addons/local_agents/gdextensions/localagents/include/` and `src/`.
- Update `addons/local_agents/gdextensions/localagents/CMakeLists.txt`.
- Register classes in `addons/local_agents/gdextensions/localagents/src/LocalAgentsRegister.cpp`.
- Add minimal bridge wrappers in `addons/local_agents/simulation/controller/SimulationRuntimeFacade.gd`.

Parity gates:
- `addons/local_agents/tests/test_smell_field_system.gd`
- `addons/local_agents/tests/test_wind_field_system.gd`
- `addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd`

Done when:
- Existing behavior unchanged, but field/scheduler/compute service ownership moved to native.

## Phase 2: Hydrology + terrain kernels first

Scope:
- Port hydrology + erosion/destruction + weather/solar update graph and terrain query paths first.

File-level work:
- Convert heavy loops in `addons/local_agents/simulation/HydrologySystem.gd` to native calls.
- Convert heavy loops in `addons/local_agents/simulation/ErosionSystem.gd` to native calls.
- Convert heavy loops in `addons/local_agents/simulation/WeatherSystem.gd` and `addons/local_agents/simulation/SolarExposureSystem.gd` to native calls.
- Route terrain/environment spatial queries to native QueryService.

Parity gates:
- Existing deterministic terrain/environment tests including `addons/local_agents/tests/test_simulation_voxel_terrain_generation.gd`.
- Add integrated N-tick replay test for weather+hydrology+erosion+solar equivalence (fixed seed).
- Run `addons/local_agents/tests/benchmark_voxel_pipeline.gd` with CPU/GPU comparisons.

Done when:
- Hydrology/weather/erosion/solar tick paths contain orchestration only.
- Terrain/environment query scan caches are removed from script layer.

## Phase 3: Smell/wind and ecology signal migration

Scope:
- Port smell, wind, and remaining ecology signal layers to graph nodes after environment core is native.

File-level work:
- Convert `SmellFieldSystem.gd` and `WindFieldSystem.gd` into adapter-only wrappers.
- Move ecology/local smell-wind gating from `VoxelProcessGateController.gd` to native scheduler services.
- Route smell/wind query surfaces through native QueryService.

Parity gates:
- Existing smell/wind deterministic tests.
- Add targeted parity tests for strongest weighted signal and top-k signal queries.

Done when:
- Smell/wind/ecology signal execution graph runs in native core.
- Script files remain declarative and thin.

## Phase 4: Remove duplicate script logic

Scope:
- Delete old loops, per-system scheduler helpers, and bespoke compute backend glue.

File-level removals/refactors:
- Reduce or remove duplicated code paths in:
  - `addons/local_agents/simulation/*ComputeBackend.gd`
  - `addons/local_agents/scenes/simulation/app/controllers/EnvironmentTickScheduler.gd`
  - `addons/local_agents/scenes/simulation/controllers/ecology/VoxelProcessGateController.gd`

Done when:
- No duplicated numeric/scheduler logic remains in GDScript for integrated domains.
- Docs/tests updated with native-first flow.

## Implementation Constraints

- Break old API shapes when needed; do not keep compatibility shims.
- Keep files under 600 lines; split by responsibility.
- Use typed resources/contracts instead of dictionary payloads for shared runtime state.
- Keep headless determinism for parity tests.
- Keep GPU-first data residency (SoA buffers, compact active-region lists, minimize readback).

## Delivery Workstreams

## Workstream 1: Native core scaffolding

- Build `sim/` native module structure and registration.
- Add CMake targets and class bindings.
- Provide minimal script-callable bridge.

## Workstream 2: Unified data contracts

- Introduce field/channel config resources.
- Replace shared dictionary payloads with typed handles.

## Workstream 3: Scheduler unification

- Port cadence/locality to native.
- Remove duplicated cadence helpers.

## Workstream 4: Compute unification

- Centralize buffer/pipeline/fence management.
- Migrate per-system backend code to one dispatch manager.

## Workstream 5: Domain migration

- Migrate weather/hydrology/erosion/solar + terrain destruction first.
- Migrate smell/wind/query second.
- Defer animal/plant/ecology behavior layers until environmental core migration is stable.

## Workstream 6: Telemetry/tests/docs

- Surface native stage timings into existing HUD telemetry flow.
- Expand deterministic replay/parity tests.
- Update `ARCHITECTURE_PLAN.md` and `README.md` once decisions below are confirmed.

## Decisions (Confirmed February 13, 2026)

1. Storage model: hybrid dense+sparse from day one.
2. Compute baseline: Vulkan compute is required; support mobile targets with compatible rendering configuration (disable unsupported heavy effects like GI where required). D3D12 backend compatibility should be preserved where Godot exposes it.
3. Determinism: epsilon-bounded parity is acceptable for cross-backend validation.
4. Phase ordering: prioritize hydrology + terrain destruction/erosion earlier; defer animal/plant/ecology behavior layers until after core environmental migration.
5. Ownership: move full simulation ownership into native core; script layer consumes read-only snapshots/adapters.
6. Graph topology: start with native-defined graph for performance.

## CI Runtime Budget (Confirmed February 13, 2026)

1. Default deterministic replay budget: 120 seconds per shard.
2. GPU/mobile-oriented matrix jobs budget: 180 seconds per shard.

## Immediate Next Action

- Before implementation starts, launch a planning sub-agent to define scope, owners, and acceptance criteria, then convert this finalized plan into an execution checklist in `ARCHITECTURE_PLAN.md` Concern I with concrete task checkboxes and begin Phase 1 implementation.
