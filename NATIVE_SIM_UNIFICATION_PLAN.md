# Native Simulation Unification Plan (GPU-First, CPU Fallback)

## Objective
Move full world simulation ownership to native C++ (`GDExtension`) and converge domain systems into a unified material model where transport + destruction are shared kernels, not siloed hydrology/erosion codepaths.

## Architecture Target
1. Native `MaterialState` fields
- Unified voxel/tile channels: phase, density, cohesion, porosity, hardness, moisture, temperature, pressure, velocity, sediment load, energy.
- Stored in centralized native field registry with typed channels and explicit layouts (SoA).

2. Native `TransportSolver`
- Shared advection/diffusion/seepage/deposition kernels.
- Water/lava/gas/sediment are material profiles (coefficients), not separate systems.

3. Native `DestructionSolver`
- Shared carve/fill/fracture/compaction ops from stress + transport + impact energy.
- Terrain erosion, landslides, and meteor impacts all emit the same voxel edit operation contracts.

4. Native `ReactionSolver`
- Thermal/phase/chemical transitions (e.g. melt/solidify, boiling/condense, reaction heat).

5. Unified runtime policy (foveated simulation)
- View/activity-aware cadence and resolution scaling:
  - `zoom_factor`
  - `camera_distance`
  - `uniformity_score`
  - `compute_budget_scale`
- Guarantees monotonic throttling for far/off-focus regions and no starvation.

## Immediate Work (In Progress)
- Shared material-flow native stage helper added:
  - `addons/local_agents/simulation/material_flow/MaterialFlowNativeStageHelpers.gd`
- Hydrology + erosion now consume shared view-policy payload fields for native stage dispatch.
- Native view metrics are propagated from world camera/controller through simulation tick orchestration.

## Phase Plan

### Phase 1: Contract Unification (now)
- Keep existing hydrology/erosion scripts as adapters.
- Standardize native stage payload + result schema across environment domains.
- Ensure all stage payloads carry unified policy fields.

Exit criteria:
- Hydrology + erosion + solar + weather use shared policy contract in native payloads.
- No bespoke payload field names per system for runtime policy.

### Phase 2: Native Solver Core
- Add native interfaces:
  - `ITransportSolver`
  - `IDestructionSolver`
- Implement `TransportSolverPipeline` in native compute manager path.
- Route terrain delta generation through destruction solver output -> voxel edit engine.

Exit criteria:
- Hydrology and erosion logic no longer own primary numeric loops in `.gd`.
- GDScript systems are orchestration adapters only.

### Phase 3: Domain Convergence
- Re-express “hydrology” and “erosion” as parameter sets over shared solvers.
- Add lava/impact profiles through same material and destruction ops.
- Migrate weather coupling to shared field channels (moisture, energy, pressure).

Exit criteria:
- Domain behavior differences represented as data/config, not forked solver implementations.

### Phase 4: GPU Residency + Mobile/D3D12 hardening
- Keep core fields resident on GPU.
- Use compact active-region lists + indirect dispatch where available.
- Ensure Vulkan-required compute path + validated D3D12 backend behavior.
- Maintain CPU fallback contract for unsupported/limited capabilities.

Exit criteria:
- Stable GPU-first execution on desktop and mobile profiles with feature gating.
- CPU fallback passes deterministic regression contracts.

## Verification Gates
1. Epsilon-bounded parity
- Deterministic replay compares unified vs legacy outputs while migration is active.
- Primary tolerances:
  - scalar field deltas (per tick) within defined epsilon
  - changed-region counts/trends within bounded error

2. Foveated throttling monotonicity
- Near/focus run must not be less detailed than far/peripheral run.
- Required monotonic checks:
  - `op_stride`
  - `voxel_scale`
  - `compute_budget_scale`

3. Determinism
- Fixed seed + fixed tick count replay must be stable for CPU path and policy decisions.

## Open Design Decisions (to confirm)
1. Material profile schema location
- Native-only config blob vs Godot `Resource` mirrored into native.

2. Solver scheduling granularity
- Tile-level cadence only vs mixed tile+voxel region cadence.

3. Query service ownership
- Keep agent query paths script-side temporarily vs immediate native migration.

## Current Principle
No new large numeric loops in `.gd`. All new heavy simulation behavior must land in native C++ with shared GPU-first pipelines and CPU fallback contracts.
