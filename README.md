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
- **Unified material substrate (`LAMaterialField`):** a 2.5D cellular automaton that owns heat,
  liquid water, lava, vapor→cloud/fog→rain, gravity, and combustion. Springs feed rivers/lakes that
  drain to the ocean; evaporation off warm water forms clouds that rain back. The calm sea is a cheap
  static GPU **ocean plane**; the CA mesh renders only deviations and freshwater. GPU compute kernels
  (`material/kernels/*.glsl`) run the hot loops when a `RenderingDevice` is present, with the CPU step
  as the headless/no-GPU parity oracle.
- **Emergent ecology:** creatures forage, flee any larger hunter, hunt their configured prey, flock by
  imitation, get thirsty and drink from the water field, age and starve, and leave corpses that become
  carrion. Scavengers converge on kills by reading sight/smell/sound cues ("watch the vultures").
  Nesting species establish inherited home sites, so colonies/warrens cluster over generations.
- **Two-tier cognition:** fast local rules for the common case, with a sparingly-invoked LLM
  ("FunctionGemma", `cognition/`) for novel situations; useful habits are reinforced and inherited.
- **Emergent disasters:** meteors, volcanic eruptions, lightning, earthquakes, and floods inject
  stimuli into the shared field (craters, lava, seismic shake, wildfire that spreads to flammable
  neighbours and is broken by rivers / suppressed by rain).
- **Interaction:** spawn palette (icon buttons → click-to-place), click-to-select + inspector, fly
  camera, debug overlays, day/night cycle, weather (wind/rain), procedural audio.

## In progress

- **Dense 3D `MaterialField3D`** — the DENSE 3D successor to the 2.5D field (a temperature +
  per-material amount for every (x,y,z) cell) so fluids interact with caves: water pools in caverns,
  lava drains into tubes, gas rises shafts. Dense (a flat 3D array, not sparse bricks) because at the
  sim's 5-unit resolution the volume is only ~20 MB. Design rationale lives in the file header; the
  GPU migration plan is `GPU_FIELD_PLAN.md`.

## Key scenes and scripts

- Scene: `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn`
- Controller: `addons/local_agents/scenes/simulation/voxel/VoxelWorld.gd`
- Terrain: `.../voxel/terrain/VoxelTerrainService.gd`
- Material substrate: `.../voxel/material/MaterialField.gd` (+ `MaterialField3D.gd`, `OceanPlane.gd`,
  `Material{Heat,Liquid,Gravity,Combustion,Atmosphere,Render}.gd`, `MaterialGPU.gd`, `kernels/*.glsl`)
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

Headless smoke boot (prints `SMOKE_SUMMARY={...}` then quits):

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

For a headless scene-smoke of the active sim, boot `VoxelWorld.tscn` directly and check the
`SMOKE_SUMMARY` (the `agent_harness.sh smoke` command still targets the removed `WorldSimulation.tscn`
and needs repointing):

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
  silently falling back (the one legitimate CPU form is a headless/no-GPU parity oracle).
- Process and Godot rules are canonical in `CLAUDE.md` and `GODOT_BEST_PRACTICES.md`;
  `ARCHITECTURE_PLAN.md` tracks breaking changes and migration status.
