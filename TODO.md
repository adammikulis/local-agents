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
  - **THE ONE material substrate:** `material/MaterialField3D.gd` (`LAMaterialField3D`) — the single
    DENSE 3D simulation field: a temperature + per-material amount for every (x,y,z) cell so fluids
    interact with caves (water pools in caverns, lava drains into tubes, gas rises shafts). "Dense"
    (a flat 3D array, not the sparse bricks the old plan speculated) because at 5-unit resolution the
    volume is only ~20 MB. The **2.5D `MaterialField.gd` is retired/deleted** — this is its wholesale
    successor. Every world force is a **module stepped on this one field** (each a CPU-oracle
    `RefCounted` on the `MaterialCombustion3D` pattern): `MaterialHeat3D`, `MaterialLava3D`,
    `MaterialAtmosphere3D` (vapor→cloud/fog→rain), `MaterialWind3D` (pressure-driven wind + Coriolis
    storm rotation), `MaterialCombustion3D` (fuel + fire), `MaterialSlump3D` (granular landslides),
    `MaterialErosion3D` (sediment transport → canyons/deltas), `MaterialSnowIce3D` (snowpack / ice /
    meltwater), `MaterialDust3D` (wind-lofted dust storms + dune migration), `MaterialScent3D`
    (stigmergy: airborne prey/predator/blood/food/alarm + soil fertility), `MaterialMagma3D` (deep
    magma source that bores its own conduit + erupts), `MaterialCharge3D` (convective charge → lightning
    bolts), `MaterialShock3D` (propagating sound/shock pressure wave). Query/helper modules:
    `MaterialFieldQueries3D`, `MaterialFieldInject3D` (splash/add_water_pooled/resample_terrain),
    `MaterialFieldRender3D`, `MaterialHeatTexture3D`, `Materials.gd`, `OceanPlane.gd` (a static GPU
    **ocean plane** for the calm sea — the CA mesh only renders deviations/freshwater), `CloudLayer.gd`,
    `RainLayer.gd`. Query API: `is_water_at`/`is_ocean_at`/`surface_y_at`/`depth_at`/`temp_at`/
    `salinity_at`, plus emergent-process reads `scent_gradient(pos, channel)`, `vorticity_at`/
    `updraft_at`, `magma_erupting()`, `emit_shock`/`shock_at`, `bolts_fired()`. GPU compute kernels in
    `material/kernels3d/*.glsl`, driven by `MaterialGPU3D.gd` when a `RenderingDevice` is available
    (the CPU step is the headless parity oracle).
  - Weather/fields: `WeatherSystem.gd` (wind), `TrackSystem.gd` (footprint decals). **`ScentField.gd`
    is retired** — scent is now the `MaterialScent3D` field channel.
  - Ecology: `ecology/EcologyService.gd` (`broadcast_seismic` now routes through the field's
    `emit_shock`/`shock_at` shock wave; `broadcast_scare` kept for acute startle).
  - Actors: `actors/{Creature,Plant,Tree,Rock,ThrownRock,Corpse,Food,Fish,Nest}.gd` plus
    disasters `actors/{Meteor,Volcano,Earthquake,LightningStrike,Flood,Tornado,Thunderstorm,Hurricane}.gd`
    and FX `actors/{FlameFX,HeatGlow}.gd`. Creature helpers under `actors/creature/`. **The `Poop.gd`
    node is retired** — waste is now a deposit into the `MaterialScent3D` fertility/scent channels.
    Disaster actors have shrunk to visuals that seed a source and READ the emergent field feature.
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
- Within the voxel scene, `WaterFieldSystem.gd` and `FireSystem.gd` were **folded into the material
  field** (water is now the unified CA; wildfire is the combustion pass). The **2.5D
  `MaterialField.gd`/`LAMaterialField`** was then superseded wholesale by the dense
  `MaterialField3D`/`LAMaterialField3D` and deleted. `ScentField.gd` and the `Poop.gd` node were
  folded into the `MaterialScent3D` field channel and deleted. No standalone water/fire/scent systems
  and no 2.5D field remain.

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
- **Emergent disasters are now field FEATURES**, not scripted actors puppeteering the field: meteor
  impacts (crater + shock wave + ignite forests), volcanoes (a deep `MaterialMagma3D` source bores its
  own conduit + erupts), storms (Coriolis rotation in the wind field spins up tornado/hurricane
  vortices), lightning (`MaterialCharge3D` builds charge in updrafts → bolt → wildfire + thunder),
  earthquakes (a propagating `MaterialShock3D` pressure wave → camera shake + scare), floods, plus
  erosion, snow/ice, and dust storms. Actors have shrunk to visuals that seed a source and read the
  emergent feature. Wildfire spreads to flammable neighbours downwind and is suppressed by rain /
  broken by rivers.

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
- **Scent + waste stigmergy** (#22, DONE) — `MaterialScent3D`: 5 airborne channels
  (prey/predator/blood/food/alarm) + a soil FERTILITY channel. Creatures lay musk DERIVED from
  size/diet/hunger/wounds/panic and drop feces/urine/blood; it diffuses, advects on the local wind,
  decays, and washes in rain; plants regrow where fertility peaks. Predators/scavengers read
  `scent_gradient(PREY/FOOD)`. Retired `ScentField.gd` + the `Poop.gd` node; V-key scent view is now a
  DebugOverlay gizmo.
- **Emergent volcano** (#23, DONE) — `MaterialMagma3D`: a deep hot magma SOURCE whose overpressure
  BORES ITS OWN CONDUIT up and erupts episodically. `Volcano.gd` shrank to seeding one
  `add_magma_source` + reading `magma_erupting()` for FX (deleted its scripted pressure state machine +
  `_carve_conduit`).
- **Emergent storms** (#24, DONE) — a CORIOLIS rotation term in `MaterialWind3D.step()` makes pressure
  lows SPIN → tornado/mesocyclone/hurricane vortices emerge; `vorticity_at`/`updraft_at` queries added.
  Tornado/Thunderstorm/Hurricane actors shrank to seed the low + READ the emergent vortex (no scripted
  strength envelope).
- **Emergent lightning** (#25, DONE) — `MaterialCharge3D`: charge builds in convective updrafts
  (`vel_y`×cloud×cold), breaks down to a bolt to the tallest ground → heat pulse (wildfire emerges via
  combustion) + scare + a visual-only bolt via callback. `LightningStrike.gd` shrank to visual/audio
  only; the old `rain>0.6` trigger was removed.
- **Extra emergent physics (DONE)** — `MaterialErosion3D` (water carries sediment → canyons/deltas,
  reuses the slump channel) · `MaterialSnowIce3D` (snowpack accretes cold / melts warm → meltwater;
  water freezes below 0 °C) · `MaterialDust3D` (wind lofts dry sediment → dust storms + dune migration) ·
  `MaterialShock3D` (a propagating sound/shock pressure wave that **REPLACED the point-based seismic
  ring** in `EcologyService` — camera shake + `broadcast_seismic` now route through `emit_shock`/
  `shock_at`; `broadcast_scare` kept for acute startle).
- **Energy-conserving heat + emergent treeline (DONE)** — `MaterialHeat3D` now treats temperature as
  bounded conserved energy: conduction/buoyancy move energy, a RADIATIVE sink bleeds hot dry plumes, a
  global clamp caps runaway, and a steep adiabatic LAPSE cools rising air. Summits get genuinely cold →
  snow accretes → the germination gate (`EcologyService._can_grow_here`, reads temp/snow) stops trees
  below the snow. The treeline DRAWS ITSELF; no scripted altitude. GPU parity `parity_gpu3d_energy.gd`.
- **Biosphere carbon/oxygen/nutrient loop (DONE, #3a/#3b/#3c)** — a real gas mix + closed carbon cycle:
  - **O₂ (`MaterialGas3D` + `MaterialCombustion3D`, #3a)** — oxygen is a transported channel combustion
    CONSUMES: fire suffocates in a sealed cave (draws down trapped O₂) and roars in open wind (replenished).
    fire3d.glsl binding 8 = `_o2`; GPU-resident `_buf_o2`.
  - **CO₂ + photosynthesis (`MaterialGas3D`, `Plant.gd`, #3b)** — burning emits CO₂ (`_co2`), a denser gas
    that advects but SETTLES into hollows + vents to open sky; plants in daylight FIX local CO₂ → O₂ +
    growth (a plant downwind of a fire scrubs the drift). fire3d.glsl binding 9 = `_co2`; GPU `_buf_co2`.
  - **Fungus decomposer (`MaterialFungus3D`, #3c)** — carcasses (`CreatureRagdoll`) + ash shed DETRITUS
    into the ground; fungus blooms where detritus meets damp shade, rots it → CO₂ + soil FERTILITY + O₂
    draw, spreads by spores, dies in drought/fire/frost. Fertility feeds plant-seeding, so **rot becomes
    regrowth**: animal → detritus → fungus → CO₂ + fertility → plants → O₂ → animals. CPU oracle
    authoritative (slow sparse process; `fungus3d.glsl` is a noted follow-on, not debt).

### Field step order (CPU oracle)
`water → erosion → heat → wind → atmosphere → snowice → lava → magma → slump → dust →
gas (O₂/CO₂ transport) → combustion → scent → fungus → charge → shock`.

### Field-residency + tuning follow-ups (GPU-porting the new passes)
- Still **CPU-oracle-first**: no new GLSL kernels for the emergent passes yet. GPU-PORT the wind/fire
  STEP kernels first (`fire3d.glsl`/wind are written but still step on the CPU oracle in the GPU path —
  a mechanical port to the resident `MaterialGPU3D.step()` seam), then port the new modules (erosion /
  snowice / dust / scent / magma / charge / shock).
- Subsume the atmosphere's fixed `VAPOR_RISE`/`CLOUD_RISE` into the wind's `vel_y` advection (buoyancy
  retune vs the cloud-health gate); localize the orographic upwind test to per-cell velocity.
- Phase-0 refactor already landed: extracted `MaterialFieldInject3D.gd` (splash/add_water_pooled/
  resample_terrain) + `MaterialHeatTexture3D.gd`; deleted dead `add_material`/`add_rain`.

## Performance (the frame budget)

Ground truth via Godot Performance monitors + the `PERF_MONITORS={...}` harness line (the per-module
field profiler mis-attributes GPU stalls — trust the monitors). World grid is 76×22×76 ≈ 127K cells,
~280 creature actors. Run perf with `LA_NO_STREAMER=1 godot --rendering-driver metal … -- --run-frames=N`
(windowed metal is the only path that exercises the GPU; `--run-frames`/`--shoot` auto-move the window
off-screen so it never pops in front of you).

### Done — 1 → 52 FPS (core sim, streamer off)
- gas `_share` inline + stagger the slow geological/bio CPU passes (erosion/snowice/magma/fungus at ¼
  cadence) → 1 → ~5 FPS.
- **GPU-ported** the dense per-cell CAs the same way fire/wind/charge/dust already were: gas O₂/CO₂
  transport, scent (5 airborne channels + fertility), shock wave — each a `kernels3d/*3d.glsl` compute
  pass, CPU keeps only the emit/scene tail + headless oracle. (Repo rule now: **per-cell field CAs go to
  GPU compute, not C++; break parity for perf** — see CLAUDE.md.)
- Creature **decision throttling** (`THINK_STRIDE`, instance-staggered; move every frame, decide every 3)
  + smooth-heading (ease toward the decided direction so throttled decisions aren't jerky). Small win
  (cognition was never the hotspot) but keeps 60Hz re-deciding off + fixes motion feel.
- `--no-streamer` / `LA_NO_STREAMER` toggle — **the single biggest cost was the streamer's local LLM**
  (Qwen3-1.7B on `llama-server`) sharing the Metal GPU: ~90ms/frame of contention. Off → 52 FPS; on → ~9.

### Done — ALL dense field CAs now GPU-resident (1 → ~63 FPS core / ~55 with streamer)
Every per-cell field process now runs as a `kernels3d/*3d.glsl` compute pass; the CPU keeps only the
headless oracle + genuine scene tails (SDF stamps, actor emit). Ported in waves: gas O₂/CO₂ · scent (5
airborne + fertility) · shock wave · fungus (grow/decompose/spread + fertility reduce) · erosion
(deposit + advect) · snowice (accrete/melt) · magma (buoyant overpressure). SDF/geometry stamps
(lava/ice/rock carve+fill) + combustion's ash/regrowth stay CPU by nature. New `MaterialGPU3DGeo.gd`
holds the geo dispatch to keep `MaterialGPU3D.gd` under the size limit. Final: no-streamer ~59-67 FPS,
with-streamer (live LLM commentary + avatar) ~54-57 FPS — from 1 FPS. Every wave verified: dispatch
active (not orphaned), fire parity PASS, behavior intact.

### TODO — push core ~63 → 100+ FPS (the field-CA-off ceiling was ~104)
HONEST STATE: on a clean system the sim is ~45 FPS no-streamer (vsync-paced), from ~1. Two dead ends were
ruled OUT by measurement, so don't repeat them:
- **Readback is NOT the bottleneck (~+7% only).** Cadencing/making channels resident (dust/fungus/vel
  resident; lava/shock dirty-gated — done) barely moves it: Apple-Silicon unified-memory downloads are
  cheap. The infamous "165 FPS" was the MONITOR VSYNC CAP hit by a BROKEN crude version (it clobbered
  scent/charge/detritus → far less active content → faster), not a real readback win. (`LA_UNCAP` env
  drops vsync for benchmarking; default keeps it — an uncapped Metal spin reports LOWER than paced.)
- **Render instancing is LOW-value** (shadows off cut draw calls 2678→569 with no fps gain).

The real cost at ~45 FPS: each 10 Hz field step does `_gpu.step()` (all ~20 compute passes ×
MAX_STEPS_PER_FRAME) + `submit()+sync()` (CPU blocks on ALL GPU passes) + the CPU scene tails — ~50-80ms
on step frames. Levers to 100+ (all with tradeoffs — get sign-off):
- **Async readback / sim-render decoupling** — don't `sync()` in the render loop; consume last frame's
  result, let render interpolate. Removes the per-step GPU stall (this is what the crude hack did, but
  correctly). Biggest, most architectural.
- **Cheaper GPU step** — fewer/fused passes, lower `MAX_STEPS_PER_FRAME`, or a coarser field grid.
- **o2/co2 (and more) fully resident** — they're GPU-authoritative on the GPU path but still round-tripped
  every frame; needs a careful one-time seed (or fire suffocates). Another small readback %.
- **Creature AI → C++/LOD** (~300 actors) — profile live; C++ territory per the rules, not GPU.

### Done — streamer 9 → ~30 FPS (the cost was NOT what we assumed)
Headless bisection found the streamer's ~90ms/frame was **mostly `SceneEnergyGraph`**, not the LLM: its
`_sample_energy()` calls `hot_cell_count()`/`lava_cell_count()` (full 127K-cell field scans) on a 10Hz
**wall-clock** gate — below 10 FPS that fires every frame (~75ms). Fixed with a hard `MIN_FRAME_GAP=30`
(the readout doesn't need 10Hz). Also throttled the `StreamerAvatar` SubViewport from `UPDATE_ALWAYS` to
UPDATE_ONCE re-armed every 3 frames (~20fps portrait), and defaulted the commentary LLM to CPU inference
(`n_gpu_layers=0`, env `LA_STREAMER_GPU_LAYERS`) so it can't starve the render GPU during generation.
Result: streamer ON with live commentary + avatar at ~28-30 FPS (was ~9); `--no-streamer` still gives the
full ~45 FPS core path.
- **Remaining ~30→45 gap** (streamer on vs off) is the overlay/voice/director + the avatar SubViewport's
  mere existence (own-World3D). Smaller, harder to isolate headlessly — needs Godot's live per-node
  profiler if worth chasing.

### Note — render instancing is LOW-value here (measured, deprioritized)
Draw calls are NOT the core-sim bottleneck: turning shadows off cut draw calls 2678→569 with **no FPS
gain**. The ~45 FPS core frame is GPU-fill/shader + variance bound, and the actors are only ~520 mesh
surfaces. MultiMesh-ing would be real work for ~no gain until entity counts grow a lot. Revisit only if
actor counts increase substantially.

## World dynamism & emergent presentation (FUTURE — after the perf pass; touches the field/render lanes)

Three connected directions the user wants, all in the emergent-everything spirit (behavior + visuals should
REFLECT the real field state, not be scripted/faked):

### 1. Off-camera / extended-range weather — storm fronts that blow in
Today `WeatherSystem` only drifts ONE uniform prevailing-wind vector; there are no travelling pressure
systems or air masses, so weather feels static except for actor-seeded disasters. The field domain already
extends to ±300u (a ring of simulated ocean/sky around the ~80-180u island), so weather ALREADY exists past
the island edge — we just don't generate dynamic synoptic features out there. Make it dynamic:
- Add **synoptic-scale forcing**: a few slowly-DRIFTING pressure highs/lows + warm-moist / cool-dry AIR
  MASSES that move across the domain with the large-scale flow, entering from the upwind edge (off-camera).
  Where a cool-dry mass meets a warm-moist one, the field's OWN wind/atmosphere physics forms the
  convergence line → cloud band → rain FRONT that then sweeps onto the island (orographic lift on the
  windward slopes for free). The front is emergent (where advecting masses meet), driven by a cheap
  large-scale input — NOT a scripted animation.
- **Extend the reach** without paying 4× GPU cost: prefer a MOVING INFLOW BOUNDARY on the upwind edge
  (inject the incoming air mass at the domain horizon so it "blows in from beyond") over enlarging the
  grid; OR run a larger-but-COARSER outer atmosphere that feeds the fine field's boundary (nested grid).
  Keep the island/terrain small. Home: extend `WeatherSystem` (pressure-center drift + air-mass advection)
  + an atmosphere boundary-injection path in `MaterialField3D`/`MaterialWind3D`.

### 2. Emergent visuals / particle design — fake less, render the real field
Make what's DRAWN reflect what the field is actually doing, replacing cosmetic stand-ins:
- **Field-driven GPU particles** (the core idea): a GPUParticles/MultiMesh system whose particles are
  SPAWNED + ADVECTED by the real field channels — rain spawned where cloud precipitates and falling with
  it; dust/sand/leaf/pollen/seed motes lofted + carried by the actual `_vel` wind; embers/sparks off fire
  riding wind + buoyancy; sea spray/foam off wave crests; snow where it's freezing. Particles READ the
  field (velocity/rain/dust/fire), so they move WITH the simulation instead of scripted emitters — "a
  particle is a tracer of the field." Ideally the advection runs on GPU reading the resident wind buffer.
- **Volumetric-ish clouds from the 3D `_cloud`/`_fog` field** instead of the flat `CloudLayer` sheet, so a
  cloud is dense where the field says so + a storm's cloud actually ROTATES with the field vorticity.
- **Retire cosmetic fakes** as each is replaced: the fixed cloud sheet, the hurricane's fixed `SPIN_SPEED`
  mesh rotation (→ cloud/particles spinning with real vorticity), scripted disaster FX (→ particles driven
  by the real injected heat/vapor/dust). Audit `CloudLayer`/`RainLayer`/disaster actors for stand-ins.

### 3. Hurricane fling → emergent (flagged earlier)
`Hurricane._stir_wildlife` applies a GEOMETRIC tangential swirl `throw()` to creatures (scaled by the
emergent `_strength`, but not the field wind literally carrying them). Make it emergent: let a vortex's
wind actually reach fling velocity + have creatures read/ride the field `_vel` (advected by the wind), so
"strong wind flings wildlife" falls out for FREE for any vortex (tornado/hurricane/downdraft) with no
per-storm swirl code. Needs the wind field tuned so a vortex can reach fling strength. (Same pattern would
make dust/particles/spray in #2 ride the same wind — one wind, everything moves with it.)

### Creatures + the field (design — can living creatures be part of `MaterialField3D`?)
- Individual creatures STAY agents — cognition, identity, memory, pathfinding, ragdoll death, and
  click-inspection can't be a diffusing scalar field. That individuality is the point.
- But COUPLE them to the field densely via STIGMERGY: creatures read field gradients (scent, food/
  fertility, heat, wind, fire, water) and write to it (scent, waste, trampling), so herd/predator-prey/
  foraging behavior emerges from the shared field rather than per-pair code. (The scent+waste work #22
  landed this — `MaterialScent3D`'s prey/predator/blood/food/alarm + fertility channels; remaining
  extension is more channels, e.g. trampled-ground.)
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
  SCRIPT ERROR). Beyond actors/cognition/nest stats the summary now reports the field-process keys:
  `wet_cells`, `heat_peak`/`heat_cells`, `lava_cells`, `slump_cells`/`peak_slump`, `cloud_cells`/
  `cloud_cover`/`fog_cover`, `wind`, `scent_cells`, `fertility_peak`, `magma_cells`, `erosion_cells`,
  `snow_cells`, `ice_cells`, `dust_cells`, `charge_peak`, `bolts`, `shock_cells`, `fires` (the old
  `poop` key was removed).
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
