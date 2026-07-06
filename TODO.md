# TODO / Session State — Voxel Ecosystem Sim

Working notes for the **from-scratch godot_voxel ecosystem simulation**. This is the project's active
scene and supersedes the retired `WorldSimulation` / `PlantRabbitField` stack and the homegrown-voxel
native destruction engine (all deleted — see "Retired stacks" below).

## Where everything lives
- **Active scene (built entirely in code):** `addons/local_agents/scenes/simulation/voxel/`
  - Root: `VoxelWorld.gd` / `VoxelWorld.tscn` — **this is the project `main_scene`** (project.godot).
  - Terrain: `terrain/VoxelTerrainService.gd` (`LAVoxelTerrainService`) — a native `VoxelLodTerrain`
    (Transvoxel) whose surface is a baked **island heightmap** (`VoxelGeneratorImage`) rising out of an
    **ocean**, with radial **coast/beach** ramps and **3D caves** carved in. Query API: `sdf_at(pos)`,
    `is_solid(pos)` (rock-vs-void), `carve_sphere(pos, r)`, `carve_caves(seed)`, `sea_level()`,
    `island_radius()`. Shader: `shaders/VoxelTerrainTriplanar.gdshader`.
  - **Unified material substrate:** `material/MaterialField.gd` (`LAMaterialField`) — a 2.5D
    cellular-automaton field that owns heat, liquid water, lava, vapor→cloud/fog→rain, gravity, and
    combustion over a per-XZ-column grid (surface height + per-material depths). Springs → rivers/lakes
    → ocean; evaporation → clouds → rain. Query API: `is_water_at(x,z)`, `is_ocean_at(x,z)`,
    `surface_y_at(x,z)`, `depth_at(x,z)`, `temp_at(x,z)`, `salinity_at(x,z)`. Helpers:
    `MaterialHeat/Liquid/Gravity/Combustion/Atmosphere/Render.gd`, `Materials.gd`, `OceanPlane.gd`
    (a static GPU **ocean plane** for the calm sea — the CA mesh only renders deviations/freshwater),
    `CloudLayer.gd`. GPU compute kernels in `material/kernels/*.glsl` (heat/transport/flow/condense),
    driven by `MaterialGPU.gd` when a `RenderingDevice` is available (CPU step is the headless oracle).
  - **Dense 3D field (IN PROGRESS):** `material/MaterialField3D.gd` (`LAMaterialField3D`) — the DENSE
    3D successor to the 2.5D field: a temperature + per-material amount for every (x,y,z) cell so
    fluids interact with caves (water pools in caverns, lava drains into tubes, gas rises shafts).
    "Dense" (flat 3D array, not sparse bricks) because at 5-unit resolution the volume is ~20 MB.
    Design rationale is in the file header; GPU migration is planned in `GPU_FIELD_PLAN.md`.
  - Weather/fields: `WeatherSystem.gd` (wind), `ScentField.gd` (wind-advected, rain-washed scent),
    `TrackSystem.gd` (footprint decals).
  - Ecology: `ecology/EcologyService.gd`.
  - Actors: `actors/{Creature,Plant,Tree,Rock,ThrownRock,Corpse,Poop,Food,Fish,Nest}.gd` plus
    disasters `actors/{Meteor,Volcano,Earthquake,LightningStrike,Flood}.gd` and FX
    `actors/{FlameFX,HeatGlow}.gd`. Creature helpers under `actors/creature/`.
  - Cognition (fast rules + slow brain): `cognition/{Cognition,CognitionScheduler,ActionRegistry,
    Genome,SituationSignature,Vision,FunctionGemmaClient}.gd` — a two-tier mind where an LLM
    ("FunctionGemma") is called sparingly for novel situations and habits are reinforced/inherited.
  - Data: `data/SpeciesLibrary.gd`, `data/ActorModels.gd`, `data/species/**/*.json`
    (mammals/fox+rabbit, birds/bird+vulture, people/villager).
  - Model visuals: `mesh/ModelVisual.gd` renders glTF assets from `addons/local_agents/assets/models/`.
  - UI: `ui/{SpawnPaletteHud,DebugPanel,DebugOverlay,AudioMenuPanel}.gd`.
  - Camera: `VoxelCameraRig.gd` (fly camera + `frame_vista()`/`frame_overview()`).
  - Design doc: `EMERGENCE.md` (the emergent-everything principle — READ IT before extending behavior).
- **godot_voxel GDExtension:** `addons/zylann.voxel/` (precompiled). The compiled `localagents`
  extension `bin/` is a gitignored build artifact — symlink it into a fresh worktree (see CLAUDE.md).
- **Audio subsystem (parallel):** `addons/local_agents/audio/` (AudioDirector + synth presets) — the
  sim and disasters call into it for procedural SFX + generative music.

## Retired stacks (deleted, do not resurrect)
- The old **`WorldSimulation` / `PlantRabbitField` / `VoxelWorldDemo`** gameplay scenes and the
  homegrown voxel-grid runtime were deleted (`chore: delete the inert old WorldSimulation gameplay
  stack`, plus the editor Flow-tab uncoupling).
- The **native C++ voxel/sim sources were dropped** (`build(native): drop the voxel/sim C++ sources,
  keep the llama.cpp/LLM runtime`). The `localagents` GDExtension now ships only the LLM/agent runtime
  (AgentRuntime/AgentNode/NetworkGraph/ModelDownloadManager + llama.cpp). The sim runs in GDScript with
  GPU compute for the material field.
- Within the voxel scene, `WaterFieldSystem.gd` and `FireSystem.gd` were **folded into
  `LAMaterialField`** (water is now unified CA; wildfire is the combustion pass). No standalone
  water/fire systems remain.

## Emergent behavior currently in (see EMERGENCE.md)
- Predator/prey, fear, flocking driven by **properties + proximity**, not per-pair tables
  (flee-any-larger-hunter; hunting = chase your `preys_on`; boids imitation flocking).
- Terror as a **broadcast stimulus** (`broadcast_scare`) any creature can react to.
- Scavengers read cues across sight/smell/sound ("watch the vultures"): a corpse deposits decaying
  `carrion` scent; vultures follow the strongest food cue and circle; ground scavengers converge.
- **Nesting & natal philopatry:** a `nests` species establishes a home site, breeds there, offspring
  inherit it → colonies/rookeries/warrens cluster over generations; roost at night.
- Energy/hunger → starvation + aging death; corpses persist as carrion; thirst + drinking off the
  water field; day/night cycle (sun arc, sky/ambient shift, nocturnal foxes).
- **Emergent disasters** inject stimuli into the shared field: meteor impacts (crater + shockwave +
  ignite forests), volcano eruptions (lava into MaterialField + caldera), lightning strikes,
  earthquakes (seismic stimulus → camera shake), floods. Wildfire spreads to flammable neighbours and
  is suppressed by rain / broken by rivers.

## The one-substrate direction (north star)
**`MaterialField3D` is the single simulation substrate, and every "disaster"/weather/ecological force is
becoming an EMERGENT feature of it — not a scripted actor puppeteering the field.** Actors shrink to
visuals that track real field features. Always ask "can this roll into `MaterialField3D`?" first
(see CLAUDE.md → One-substrate default).

### Done — live field processes (CPU oracle ↔ GPU kernel parity)
- Water CA · heat/conduction/buoyancy · atmosphere (vapor→cloud/fog→rain, dewpoint, orographic) ·
  lava (flow + solidify) · **emergent 3D pressure-driven WIND** (`MaterialWind3D`: pressure from temp,
  wind down −∇p, terrain funneling, buoyant vertical, fronts) · **FIRE/combustion** (`MaterialCombustion3D`:
  fuel from vegetation, ignites from heat, spreads downwind on the wind field, ash regrowth) ·
  **granular LANDSLIDES** (`MaterialSlump3D`: disturbed terrain slumps to repose angle, re-solidifies).

### Remaining emergent roadmap (each rolled into the field; CPU↔GPU parity)
1. **Scent + waste as field channels** (#22) — retire `ScentField` (markers) + the `Poop` node. A small
   fixed set of scent-type channels (prey/predator-musk/blood/alarm/food); emission DERIVED + DYNAMIC
   from diet + recent meals + hunger + wounds + state; waste (feces + urine, diet-flavored) deposits a
   fertility/nutrient channel + scent; all diffuse + advect on the LOCAL wind + wash with rain. Plants
   grow from local field fertility. Make sure creatures produce waste (feces exists; add urine).
2. **Emergent volcanoes from lava pressure** (#23) — eruptions/upwelling/conduit-clearing fall out of
   lava having pressure that pushes up + melts rock; the `Volcano` actor just seeds a deep hot source.
3. **Emergent storms** (#24) — add a rotation (Coriolis-like) term so pressure lows spin. TORNADO =
   intense vortex, THUNDERSTORM = convective updraft cell (achievable). HURRICANE = a STRETCH goal to
   design toward (a seeded deep rotating warm-ocean low that leans on emergence). Actors → visuals.
4. **Emergent lightning** (#25) — a charge channel accumulates in convective updrafts (`vel_y`×cloud×cold);
   breakdown fires a bolt to the tallest ground → heat pulse (ignites wildfire) + thunder (scare) + reset.

### Field-residency + tuning follow-ups (from the wind/fire/slump landings)
- GPU-PORT the wind/fire/slump STEP kernels: `fire3d.glsl`/`slump3d.glsl`/wind are written but still step
  on the CPU oracle in the GPU path (mechanical port to the resident `MaterialGPU3D.step()` seam).
- Subsume the atmosphere's fixed `VAPOR_RISE`/`CLOUD_RISE` into the wind's `vel_y` advection (buoyancy
  retune vs the cloud-health gate); localize the orographic upwind test to per-cell velocity.

### Creatures + the field (design — can living creatures be part of `MaterialField3D`?)
- Individual creatures STAY agents — cognition, identity, memory, pathfinding, ragdoll death, and
  click-inspection can't be a diffusing scalar field. That individuality is the point.
- But COUPLE them to the field densely via STIGMERGY: creatures read field gradients (scent, food/
  fertility, heat, wind, fire, water) and write to it (scent, waste, trampling), so herd/predator-prey/
  foraging behavior emerges from the shared field rather than per-pair code. (Largely the scent+waste
  work #22, extended to more channels — fear, food, trampled-ground.)
- STRETCH — a background POPULATION-DENSITY / biomass field: off-screen / far fauna simulated as a
  reaction-diffusion ecology *layer* in the field (Lotka-Volterra-ish predator/prey densities), from
  which hero agents spawn at the edge of attention and into which they dissolve — a hybrid for scale,
  exactly like the cheap static ocean plane vs the CA. Individual cognition stays agent-side; the field
  carries the "sea of life" at population scale.

## How to run / verify
- **Windowed (screenshots):** the scene self-harnesses —
  `godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=<png> --shoot-frames=320`
  - `--overview` frames a wide whole-island vista; `--time=<0..1>` sets time of day.
  - Disaster triggers: `--auto-meteor`, `--auto-volcano`, `--auto-lightning`; `--auto-select` tests
    click-select.
- **Headless smoke:** `godot --headless res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --run-frames=300`
  — prints `SMOKE_SUMMARY={...}` then quits (expect `"spawned_initial":true, "ready":true`, no
  SCRIPT ERROR; the summary reports actors, wet/heat/lava/cloud cells, fires, nests, cognition stats).
- **Test suites / lint:** `scripts/agent_harness.sh <all|fast|bounded|extension|lint>` wraps the
  canonical `run_*.gd` runners and prints one `AGENT_HARNESS_RESULT={...}` line. Typing gate:
  `bash scripts/check_no_inferred_typing.sh` (must be OK — no `:=` in the voxel dir). NOTE: the
  harness's `smoke` subcommand still points at the removed `WorldSimulation.tscn` — use the direct
  `--run-frames` headless boot above for scene smoke until that is repointed.
- **Gotcha:** a NEW `.gd` `class_name` or a new `.gdextension` only registers after an editor scan —
  run `godot --headless --editor --quit-after 400` once, else classes report MISSING.

## Guiding principle
**emergent-everything** — behavior from simple local rules interacting, never hardcoded per-case.
Drive differences through config/properties (size, diet, traits), couple systems via stimuli
(`broadcast_scare`, heat/material injected into the shared field, scent deposits). See
`addons/local_agents/scenes/simulation/voxel/EMERGENCE.md`.
