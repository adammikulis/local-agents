# TODO / Next Steps

Working notes for the creature-ecosystem + voxel-terrain work. Grouped by priority.

## Done this session (verified)
- **Creature framework** (taxonomy-aligned): `AnimalActor` (CharacterBody3D: nav, gravity,
  jump/fly, smell emit+sense, diet, breeding) → `MammalActor` → `RabbitSphere` (lagomorph),
  `FoxActor` (canid), `VillagerCapsule` (human); `BirdActor` (bird, 3D flock). Kingdom bases
  `PlantActor` (EdiblePlantCapsule migrated) + `FungusActor` (stub).
- **Predator–prey + breeding**: foxes hunt rabbits by scent; breeding keeps populations
  stable (fox breeding gated on eating). Poop→seed dispersal works.
- **3D bird flock** (`BirdFlockController`, Reynolds boids) — looks good.
- **Nav**: `NavigationAgent3D` pathfinding for ground animals.
- **Voxel-terrain port** (WorldSimulation): native double-sided trimesh collision per chunk
  (replaces per-voxel boxes); per-chunk `NavigationRegion3D` that re-bakes only changed
  chunks on destruction; ecology auto-centers on the island land centroid; smell/wind grid
  center offset; creatures raycast-placed on the live surface. Finer voxels (map 56, noise
  0.078). Fixed main-scene lighting (was stuck at dim dawn → now noon, sun energy 2.6).
- **Repo cleanup**: ARCHITECTURE_PLAN 2171→~227 lines; two native-plan docs merged; dead
  CPU-executor C++ removed; CI file-length check → warn-only 1000; AGENTS.md/CLAUDE.md updated;
  cross-platform build workflow added.

## Remaining — ecology behaviors (highest value)
- [ ] **Fast spread / colonization** for plants + fungi (kudzu, vines, grass, mold, slimes) —
      organisms seed adjacent surface cells fast enough to look like they move. `FungusActor`
      needs a real colonization behavior; plants should be able to spread too (don't hard-code
      sessile).
- [ ] **Trees fall over** when cut/destabilized (tree actor + topple physics).
- [ ] **Landslides disturb plants** — terrain destruction under/near a plant dislodges/uproots it.

## Remaining — movement
- [ ] **2D ground flocking** for mammals (herd cohesion). Currently individual smell-driven
      forage/flee/hunt + nav; only birds truly flock.
- [ ] **Delete the dead boids controller** — `scenes/simulation/controllers/ecology/BoidsBehaviorController.gd`
      (1169 lines) is inert/unused; remove it and any references.

## Remaining — loose ends
- [ ] **Cross-platform binaries**: `.github/workflows/build-extension.yml` builds Linux/Windows
      `.so`/`.dll` in CI, but they haven't been built/committed (can't cross-compile on macOS).
- [ ] **Villager wiring**: `VillagerCapsule` is refactored but nothing spawns it — wire into a
      scene if villagers are wanted.
- [ ] **Contract dedup**: `WorldDispatchContracts.gd` still duplicates normalization the C++
      `LocalAgentsVoxelDispatchBridge` already does.

## Remaining — polish / verify
- [ ] **Verify voxel destruction on the new terrain** — the collision it rides on was replaced
      with the trimesh; confirm projectile/fire destruction + navmesh rebake still work end to
      end (FPS-destroy path; test-harness owned by another agent). Probes showed "mutation
      dispatch runtime unavailable" (likely GPU/native handshake in headless).
- [ ] **Camera framing** for the larger 56×56 map (default view is awkward).
- [ ] **Perf**: finer voxels dropped FPS ~164→74; tune resolution or meshing if needed.

## Notes
- Native rebuild: `make -C build_native localagents -j16` in
  `addons/local_agents/gdextensions/localagents/`, then copy `build_native/liblocalagents.macos.dylib`
  → `bin/localagents.macos.dylib` and `install_name_tool -add_rpath @loader_path`.
- Ecology runs in WorldSimulation because the `voxel_destruction_only` runtime profile now sets
  `ecology_system_enabled = true` (native `LocalAgentsWorldSimulationNativeUtils.cpp`).
