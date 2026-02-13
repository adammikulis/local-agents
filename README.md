# Local Agents (Godot)

Current project focus is a deterministic 3D simulation vertical slice with ecology, mammals, and inspectable chemical smell fields.

## Current Scope

- `PlantRabbitField` scene as the active sandbox.
- Edible plants as small thin green capsules with staged growth and flowering.
- Rabbits as white spheres that forage, flee, eat plants, digest seeds, and reseed via poop.
- Mammal smell behavior generalized via profile resources (rabbits and villagers share the same contract, with different sensitivities).
- Smell and wind simulated on a shared sparse voxel field (clean break from active hex runtime path).
- Click selection + inspector panel + spawn UI (targeted spawn and random spawn).
- Camera controls for simulation editing (orbit/pan/zoom + right-click pan).
- Debug overlays for smell, wind, and temperature with translucent voxel rendering.

## Core Runtime Model

### Shared Voxel Infrastructure

- `addons/local_agents/simulation/VoxelGridSystem.gd`
- Used by:
  - `SmellFieldSystem`
  - `WindFieldSystem`
  - `EcologyController` edible indexing/debug views

### Chemistry-Driven Smell

Plants and mammals emit chemical mixtures, not generic `food`/`danger` tags.

Examples currently modeled:
- Plant/flower compounds: `hexanal`, `cis_3_hexenol`, `linalool`, `benzyl_acetate`, `phenylacetaldehyde`, `geraniol`, `methyl_salicylate`.
- Taste/defense compounds: `sugars`, `tannins`, `alkaloids`.
- Mammal/waste compounds: `ammonia`, `butyric_acid`, `2_heptanone`.

Mammals convert these into behavior using weighted sensitivity profiles (`MammalProfileResource`).

### Wind and Decay

- Smell advects with wind direction/intensity when enabled.
- Smell decays over time.
- Rain increases decay.
- Wind field evolves spatially from base wind + terrain/temperature effects.

## Field Controls

Inside `PlantRabbitField`:

- `LMB`: select actor / place spawn (when spawn mode active)
- `Esc` or `RMB`: cancel spawn mode back to select
- Spawn mode auto-resets to select after placing one entity
- Mouse wheel: zoom
- `MMB drag`: orbit
- `Shift + MMB drag`: pan
- `RMB drag`: pan

Bottom HUD supports:
- `Select`
- `Spawn Plant`
- `Spawn Rabbit`
- `Spawn Random` with user-set counts

Right HUD shows inspector payload for selected entities.

## Debug Views

Debug overlay roots:
- `SmellDebug`
- `WindDebug`
- `TemperatureDebug`

Rendering style:
- Smell: translucent chemical voxel overlays.
- Temperature: translucent blue-to-red voxel spectrum.
- Wind: translucent directional vector markers.

## Key Scenes and Scripts

- Scene: `addons/local_agents/scenes/simulation/PlantRabbitField.tscn`
- Scene: `addons/local_agents/scenes/demos/VoxelWorldDemo.tscn` (seed + sliders + visible baked flowmap arrows)
- Controller: `addons/local_agents/scenes/simulation/controllers/PlantRabbitField.gd`
- Ecology orchestration: `addons/local_agents/scenes/simulation/controllers/EcologyController.gd`
- Plant actor: `addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.gd`
- Rabbit actor: `addons/local_agents/scenes/simulation/actors/RabbitSphere.gd`
- Villager actor: `addons/local_agents/scenes/simulation/actors/VillagerCapsule.gd`

## Voxel Simulator Features

### World Generation

- FastNoiseLite-based 3D voxel terrain generation with deterministic seeds.
- Minecraft-style stratified block stacks: topsoil/subsoil/stone/water with caves.
- Multiple terrain/resource block types in generated columns and block rows (soil variants + ore blocks).
- Deterministic baked flow maps (downhill direction, accumulation, channel strength).

### Runtime Simulation

- Weather simulation on tile fields with wind advection, humidity, cloud cover, rain, fog, orographic lift, and rain shadow.
- Erosion simulation with rainfall/flow transport, freeze-thaw crack expansion, frost damage carryover, and landslide events.
- Solar exposure simulation with per-tile sunlight, absorption, reflection, UV dose, heat load, and plant growth factor.
- Air-column heating in wind simulation from solar forcing (not only surface heating).
- Surface albedo derived from generated top block RGBA data (no hardcoded reflectance constants).

### Rendering and GPU Shaders

- Chunked terrain rendering via `MultiMeshInstance3D` for voxel blocks.
- GPU water flow shading with weather + solar field texture sampling.
- GPU terrain weather shading with wetness/snow/erosion + solar field texture sampling.
- GPU river-flow overlay shader driven by baked flow-map rows.
- GPU cloud layers: animated cloud plane + volumetric cloud shell.
- GPU rain post-processing shader and lightning flash propagation to weather materials.
- Volumetric fog + automatic day/night sun animation, integrated with global lighting and SDFGI-enabled demo environment.

### Unified Demo and Controls

- Single canonical scene: `VoxelWorldDemo` (project main scene).
- Terrain controls include dimensions, sea level, surface base/range, noise frequency/octaves/lacunarity/gain, smoothing, and cave threshold.
- Flow-map visualizer controls (show/hide, threshold, stride) with animated flow arrows.
- Timelapse-style simulation controls (play/pause/fast-forward/rewind/fork) and state restore.
- Live stats for weather/erosion/solar metrics in demo HUD/status labels.
- Integrated runtime stack in one scene: worldgen + weather/erosion/solar + settlement/culture/ecology controllers + debug overlays.

## Run

```bash
godot --path . --editor
```

Project is configured to launch `VoxelWorldDemo` as the main scene.

Headless smoke boot:

```bash
godot --headless --no-window --path . addons/local_agents/scenes/simulation/PlantRabbitField.tscn --quit
```

World generation demo:

```bash
godot --path . addons/local_agents/scenes/demos/VoxelWorldDemo.tscn
```

## Tests

Core harness:

```bash
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd --skip-heavy
```

Fast local harness (reduced core set, skips runtime-heavy by default):

```bash
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd --fast --skip-heavy
```

Bounded runtime-heavy harness (each heavy test runs in its own process with per-test timeout):

```bash
godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd
```

CI timeout policy for deterministic replay/runtime shards:
- Default shard budget: `120` seconds.
- GPU/mobile-oriented shard budget: `180` seconds.

Optional explicit GPU/mobile run:

```bash
godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --use-gpu --timeout-sec=180
```

Run a subset with `--tests` (comma-separated, full path or filename):

```bash
godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout-sec=120 --tests=test_simulation_villager_cognition.gd,test_agent_runtime_heavy.gd
```

Useful runtime test flags:
- `--workers=<N>`: run bounded runtime tests in parallel processes.
- `--fast`: select a reduced runtime-heavy subset.
- `--use-gpu --gpu-layers=<N>`: opt into GPU layer offload for runtime tests.
- `--context-size=<N> --max-tokens=<N>`: override runtime model load context and token limits in heavy tests.

CPU vs GPU voxel benchmark:

```bash
# CPU-only simulation pipeline timing
godot --headless --no-window -s addons/local_agents/tests/benchmark_voxel_pipeline.gd -- --mode=cpu --iterations=3 --ticks=96 --width=64 --height=64 --world-height=40

# GPU render-path timing (run with rendering, not headless)
godot --path . -s addons/local_agents/tests/benchmark_voxel_pipeline.gd -- --mode=gpu --iterations=3 --gpu-frames=120 --width=64 --height=64 --world-height=40
```

Notes:
- Current terrain noise generation is CPU-side; GPU benchmark covers shader/render upload/update loops.
- Compare `cpu.mean_ms` vs `gpu.total.mean_ms` and `gpu.avg_frame.mean_ms` from JSON output.

Targeted deterministic checks include:
- `addons/local_agents/tests/test_smell_field_system.gd`
- `addons/local_agents/tests/test_wind_field_system.gd`

## Notes

- Runtime is intentionally scene-first and resource-driven.
- Required systems should fail fast rather than silently fallback.
- `ARCHITECTURE_PLAN.md` tracks breaking changes and migration status.
