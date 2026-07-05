# TODO / Session State — Voxel Ecosystem Sim

Working notes for the **from-scratch godot_voxel ecosystem simulation**. This supersedes the old
creature-ecosystem + homegrown-voxel-terrain work (that stack is now inert — see "Full break" below).

## Where everything lives
- **New scene (built entirely in code):** `addons/local_agents/scenes/simulation/voxel/`
  - Root: `VoxelWorld.gd` / `VoxelWorld.tscn` — **this is the project `main_scene`** (project.godot).
  - Terrain: `terrain/VoxelTerrainService.gd` + `shaders/VoxelTerrainTriplanar.gdshader`
  - Systems: `WeatherSystem.gd`, `ScentField.gd`, `TrackSystem.gd`, `WaterFieldSystem.gd` (see pending)
  - Ecology: `ecology/EcologyService.gd`
  - Actors: `actors/{Creature,Plant,Tree,Rock,ThrownRock,Corpse,Poop,Meteor}.gd`
  - Mesh util: `mesh/RockMeshFactory.gd` (natural boulders)
  - UI: `ui/SpawnPaletteHud.gd`
  - Camera: `VoxelCameraRig.gd`
  - Design doc: `EMERGENCE.md` (the emergent-everything principle — READ IT)
- **godot_voxel GDExtension:** `addons/zylann.voxel/` (v1.6x precompiled, macOS arm64 universal).
- **Audio subsystem (added in parallel):** `addons/local_agents/audio/` (AudioDirector) — VoxelWorld
  and Meteor/Creature call into it for SFX + generative music.

## Git / recovery
- All of this is committed and pushed on branch **`feature/voxel-ecosystem-sim`**
  (origin: github.com/adammikulis/local-agents). Commit `42a4d55`. That is the recovery point.
- **LESSON (important):** the voxel dir was untracked and a bulk-rewrite subagent ran on the SAME
  files I was live-editing → concurrent writes corrupted 4 files (interleaved lines, missing `func`
  headers). Repaired by rewriting them. **Never run a bulk-edit subagent on files you're also
  editing, and keep work committed so it's recoverable.**

## Done & verified (windowed screenshots + headless smoke)
- godot_voxel `VoxelLodTerrain` + Transvoxel smooth terrain (natural, not cubes) + triplanar
  height/slope shader. Large world (~600 view dist), 120–195 FPS, ~220 entities.
- **Off-camera destruction:** `full_load_mode_enabled` + bounded `voxel_bounds` so meteor carves
  apply anywhere (proven via SDF probe). Meteor = fiery fall → crater + dirt/rock debris colored to
  the surface hit + terror shockwave + audio boom.
- **Emergent ecology** (see EMERGENCE.md): energy/hunger → starvation + aging death; corpses persist
  as carrion for scavengers; flee-any-larger-hunter (rabbits flee foxes+humans, foxes flee humans);
  persistence hunting + thrown-rock hunting (humans grab ground rocks); species-tuned imitation
  flocking; terror broadcast; scent trails (wind-advected, rain-washed); footprint decals.
- Spawn palette (icon buttons → click-to-place), click-to-select + highlight ring + live inspector
  (energy bar, activity, age…). Fly camera (no ctrl-to-orbit). Spawn puffs. Weather (rain + wind).
- Natural boulder rocks (RockMeshFactory), forests (oak/pine clusters), plants visible on spawn.
- Project rule: **no `:=` inferred typing** — `scripts/check_no_inferred_typing.sh` (wired into
  `agent_harness.sh lint`), documented in GODOT_BEST_PRACTICES.md.

## Done this session (all verified: headless smoke diagnostics + windowed screenshots)
- [x] **`:=` sweep** — lint gate green (`bash scripts/check_no_inferred_typing.sh` == OK).
- [x] **Water: rivers & lakes** — `WaterFieldSystem` wired into VoxelWorld; rain (tuned low so it
      pools in basins instead of flooding) + persistent springs; meteor/thrown-rock splashes.
- [x] **Poop → scent + colonization** — creatures drop `Poop` on a digestion timer; `wants_seed`
      connects to `EcologyService.seed_plant_at` (dung fertilizes new plants).
- [x] **Trees topple when ground destroyed** — `damage_sphere` calls `topple(away)` in a blast.
- [x] **Thirst + drinking** (new) — `hydration` drains at per-species `thirst_rate`; creatures probe
      for the nearest wet cell and drink or die of dehydration (emergent watering holes).
- [x] **Day/night cycle** (new) — VoxelWorld owns all sky lighting (sun arc/energy, sky colors,
      ambient) on a time-of-day clock; weather rain dims on top; nocturnal foxes.
- [x] **Wildfire spread** (new) — `FireSystem`: meteors ignite forests, fire spreads to flammable
      neighbours, burns to ash that reseeds a plant; rain suppresses; rivers are firebreaks.
- [x] **Fish** (new) — `Fish.gd` water-bound schoolers spawn only where water pools; caught at shallows.
- [x] **Refactor `Creature.gd`** — 684→538 lines; senses/flocking/inspector extracted to
      `actors/creature/` static helpers (`LACreatureSenses/Flocking/Inspector`).
- [x] **Camera framing** — `frame_vista()` opens on the world at the true surface height.
- [x] **Full break cleanup (#9)** — old `WorldSimulation` stack deleted (scenes/simulation non-voxel,
      `addons/local_agents/simulation/`, config-sim resources, old tests, native voxel/sim C++);
      LLM editor plugin uncoupled from old sim (Flow tab removed); native `localagents` rebuilt
      (AgentRuntime/AgentNode/NetworkGraph/ModelDownloadManager + llama.cpp kept). Editor scan clean,
      voxel smoke passes, LLM native classes load.

## Pending / ideas
- Plant/fungus colonization spread beyond dung; landslides disturbing plants (stretch).

## How to run / verify
- Windowed (screenshots): the scene supports a self-harness —
  `godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=<png> --shoot-frames=320`
  Also `--auto-meteor` (drops+frames a crater) and `--auto-select` (tests click-select), `--run-frames=N`
  (headless smoke: prints `SMOKE_SUMMARY={...}` then quits).
- Headless smoke: `godot --headless res://.../voxel/VoxelWorld.tscn -- --run-frames=300`
  (expect `spawned_initial":true, "ready":true`, ~220 selectable, no SCRIPT ERROR).
- Lint: `bash scripts/check_no_inferred_typing.sh` (must be OK).
- **Gotcha:** a NEW `.gd` `class_name` or a new `.gdextension` only registers after an editor scan —
  run `godot --headless --editor --quit-after 400` once, else classes report MISSING.

## Guiding principle
**emergent-everything** — behavior from simple local rules interacting, never hardcoded per-case.
Drive differences through config/properties (size, diet, traits), couple systems via stimuli
(broadcast_scare, scent deposits). See `addons/local_agents/scenes/simulation/voxel/EMERGENCE.md`.
