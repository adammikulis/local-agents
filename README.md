# Local Agents (Godot)

A Godot 4.7 addon that pairs a local LLM/agent runtime (llama.cpp-backed GDExtension) with a
from-scratch **godot_voxel ecosystem simulation** used as the active showcase. The current focus is
that simulation: a native voxel **island** ringed by an **ocean**, populated by creatures whose
believable behavior *emerges* from simple local rules (see
`addons/local_agents/scenes/simulation/voxel/EMERGENCE.md`).

## Current Scope

- **Active scene / main scene:** `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn`
  (`project.godot` → `run/main_scene`).
- **Terrain:** a native `VoxelLodTerrain` (Transvoxel) whose surface is a baked **island heightmap**
  (`VoxelGeneratorImage`) rising out of an **ocean**, with radial **coast/beach** ramps and **3D
  caves** carved in. Rock-vs-void is queried via `is_solid(pos)` / `sdf_at(pos)`; destruction is
  `carve_sphere(pos, r)`.
- **THE ONE material substrate (`LAMaterialField3D`):** a single dense 3D cellular field that owns
  every world force as a stepped module — heat, liquid water, lava, vapor→cloud/fog→rain, gravity,
  combustion, granular slump, erosion, snow/ice, wind-lofted dust, scent + soil fertility, deep magma,
  atmospheric charge, and shock waves. Springs feed rivers/lakes that drain to the ocean; evaporation
  off warm water forms clouds that rain back; because every process shares the same cells they compose
  for free (scent rides the real wind and washes out in the rain, a lightning bolt ignites real fuel).
  Being dense-3D, fluids interact with caves (water pools in caverns, lava drains into tubes). The calm
  sea is a cheap static GPU **ocean plane**; the CA mesh renders only deviations and freshwater. GPU
  compute kernels (`material/kernels3d/*.glsl`, driven by `MaterialGPU3D.gd`) run the hot loops when a
  `RenderingDevice` is present, with the CPU step as the headless/no-GPU fallback. (This dense 3D
  field superseded and replaced the retired 2.5D `MaterialField`.)
- **Emergent ecology:** creatures forage, flee any larger hunter, hunt their configured prey, flock by
  imitation, get thirsty and drink from the water field, age and starve, and leave corpses that become
  carrion. Scavengers converge on kills by reading sight/smell/sound cues ("watch the vultures").
  Nesting species establish inherited home sites, so colonies/warrens cluster over generations.
- **Two-tier cognition:** fast local rules for the common case, with a sparingly-invoked LLM
  ("FunctionGemma", `cognition/`) for novel situations; useful habits are reinforced and inherited.
- **Emergent disasters (features of the one field, not scripted actors):** volcanoes where a deep
  magma source bores its own conduit and erupts; storms where a Coriolis term spins pressure lows up
  into tornadoes/hurricanes; lightning where charge builds in convective updrafts and bolts to ground
  (igniting real wildfire); earthquakes as a propagating shock wave; plus meteors, floods, erosion
  (canyons/deltas), snow/ice, and dust storms. Wildfire spreads to flammable neighbours downwind and is
  broken by rivers / suppressed by rain. **Named phenomena have no dedicated code** — "volcano", "eruption",
  "storm", "lava bomb" are just words for what the one substrate's physics (pressure, temperature, phase,
  gravity, momentum) does; a volcano is what happens when the planet's hot core pressurizes lava under weak
  crust, and a lava bomb is matter given momentum by a pressure release. Disaster "actors" are seeds / markers
  / visuals only — they own no behavior; the direction is to dissolve them into the substrate entirely.
- **Interaction:** spawn palette (icon buttons → click-to-place), click-to-select + inspector, fly
  camera, debug overlays, day/night cycle, weather (wind/rain), procedural audio.

## In progress

- **Water-cycle unification.** The dense `MaterialField3D` is authoritative, and its per-cell processes
  (heat, water, wind, atmosphere, lava, fire, slump, erosion, snow/ice, dust, scent, magma, charge,
  shock) run as GPU compute kernels (`material/kernels3d/*.glsl` via `MaterialGPU3D.gd`), with the CPU
  step as the headless/no-GPU fallback. Still open: folding the atmosphere's vapor rise into the wind's
  buoyant advection so the whole water cycle is one conserved flow (see `TODO.md`).

## Key scenes and scripts

- Scene: `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn`
- Controller: `addons/local_agents/scenes/simulation/voxel/VoxelWorld.gd`
- Terrain: `.../voxel/terrain/VoxelTerrainService.gd`
- Material substrate: `.../voxel/material/MaterialField3D.gd` (+ per-force modules
  `Material{Heat,Lava,Atmosphere,Wind,Combustion,Slump,Erosion,SnowIce,Dust,Scent,Magma,Charge,Shock}3D.gd`,
  `MaterialFieldQueries3D.gd`, `MaterialFieldInject3D.gd`, `MaterialFieldRender3D.gd`, `OceanPlane.gd`,
  `MaterialGPU3D.gd`, `kernels3d/*.glsl`)
- Ecology: `.../voxel/ecology/EcologyService.gd`
- Cognition: `.../voxel/cognition/*.gd`
- Actors + disasters: `.../voxel/actors/*.gd`
- Species data: `.../voxel/data/species/**/*.json`

## Run

Launch the main scene (windowed):

```bash
godot --path .
```

`project.godot` is configured to launch `VoxelWorld.tscn` as the main scene.

The scene self-harnesses. Windowed screenshots and scripted events:

```bash
# screenshot after N frames
godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=/tmp/shot.png --shoot-frames=320
# wide whole-island vista; time of day 0..1; disaster triggers
godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=/tmp/shot.png --overview --time=0.5
godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=/tmp/shot.png --auto-meteor    # also --auto-volcano, --auto-lightning
```

Headless smoke boot (prints `SIM_REPORT={...}` then quits):

```bash
godot --headless res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --run-frames=300
```

> A NEW `.gd` `class_name` or `.gdextension` only registers after an editor scan — run
> `godot --headless --editor --quit-after 400` once, else new classes report MISSING.

## Tests

The unified harness wraps the canonical runners, tees a log, and prints one
`AGENT_HARNESS_RESULT={...}` line:

```bash
scripts/agent_harness.sh fast       # fast test sweep (run_all_tests.gd --fast)
scripts/agent_harness.sh all        # full suite (run_all_tests.gd --timeout=120)
scripts/agent_harness.sh bounded    # bounded runtime-heavy suite (run_runtime_tests_bounded.gd)
scripts/agent_harness.sh extension  # validate the GDExtension
scripts/agent_harness.sh lint       # no-direct-refcounted gate + no-`:=` typing gate (+ advisory checks)
```

For a headless scene-smoke of the active sim, boot `VoxelWorld.tscn` directly and check the one
`SIM_REPORT={...}` line (the central telemetry snapshot: field + population + cognition + death events +
peak-tracked behaviour gauges + perf — emitted by `LASimReport`; it replaced the old `SMOKE_SUMMARY`
/`PERF_MONITORS`/`BEHAVIOUR_PEAKS` lines). The `agent_harness.sh smoke` command still targets the removed
`WorldSimulation.tscn` and needs repointing:

```bash
godot --headless res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --run-frames=300
```

Run one `test_*.gd` module through the canonical helper (never launch a `test_*.gd` directly — that is
banned by `scripts/check_no_direct_refcounted_invocation.sh`):

```bash
scripts/run_single_test.sh test_agent_integration.gd
scripts/run_single_test.sh test_agent_integration.gd --timeout=180
```

Equivalent direct harness invocation (always via a `run_*.gd` runner with `-s`):

```bash
godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_agent_integration.gd --timeout=120
```

## Notes

- Runtime is scene-first and resource-driven; prefer voxel-native simulation/collision/destruction as
  the default path and keep `RigidBody3D` minimal and exception-based.
- Simulation-authoritative compute targets GPU/native; required GPU capability fails fast rather than
  silently falling back (the one legitimate CPU form is a headless/no-GPU fallback, not a bit-exact contract).
- Process and Godot rules are canonical in `CLAUDE.md` and `GODOT_BEST_PRACTICES.md`;
  `ARCHITECTURE_PLAN.md` tracks breaking changes and migration status.
