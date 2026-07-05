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

## Pending / in-progress
- [ ] **Finish `:=` sweep** (IN PROGRESS via subagent when this was written). The interrupted sweep
      left ~11 voxel files still using `:=` (VoxelCameraRig, TrackSystem, RockMeshFactory,
      SpawnPaletteHud, Corpse, Rock, Tree, Plant, ThrownRock, VoxelTerrainService, EcologyService).
      The lint gate FAILS until done. Verify: `bash scripts/check_no_inferred_typing.sh` == OK.
- [ ] **Water: rivers & lakes (hybrid CA field + splashes)** — user chose this approach.
      `WaterFieldSystem.gd` may exist (a subagent was building it when the session stopped — CHECK if
      it's complete/parses; it is NOT wired into VoxelWorld yet). Needs: CA water flowing downhill →
      lakes/rivers, smooth water surface mesh, `splash()` rigidbody droplets, fed by weather rain,
      wired into VoxelWorld. Intended as a shared field substrate that scent could later ride on.
- [ ] **Poop → scent + colonization.** `Poop.gd` exists (deposits strong species scent → predators
      track prey by droppings) but is NOT wired: Creatures don't drop it yet, and its `wants_seed`
      signal isn't connected. Wire: Creature drops Poop periodically (inject `_scent` + species);
      EcologyService connects `wants_seed` → grow a plant (dung fertilizes = plant colonization).
- [ ] **Plant/fungus colonization spread** and **trees fall when ground destroyed** (Tree has a
      `topple(dir)` method ready — call it when terrain under a tree is carved). Landslides disturb plants.
- [ ] **Full break cleanup (task #9):** the OLD homegrown voxel/terrain/destruction stack is inert
      (main_scene switched) but still on disk. Delete per the plan: old `WorldSimulation.tscn` + its
      controllers, `TerrainRenderer`, `SimulationVoxelTerrainMutator`, voxel-edit dispatch, and the
      native `VoxelEditEngine/GpuExecutor/DispatchBridge/Orchestration/NativeVoxelTerrainMutator`
      (rebuild `localagents`; repoint/retire the native voxel-op contract tests). KEEP the LLM/agent
      (llama.cpp) parts of `localagents` — that's the repo's original purpose.
- [ ] **Refactor `Creature.gd`** (~500 lines — energy/hunting/flocking/senses/inspector all in one)
      into focused modules. User flagged the single-file size.
- [ ] Camera default sometimes frames a hillside up close — tune default/spawn framing.

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
