# MaterialField 3D Upgrade — design plan

## Why
The MaterialField (heat, water, lava, vapor/cloud/fog, gravity) is **2.5D**: one column per XZ cell
holding a surface height + a stack of material *depths*. That was fine over heightmap terrain, but
the terrain is being upgraded to a true 3D SDF with **caves**. On 3D terrain a 2.5D field can't:
lava drain into a cave (a real lava tube), water pool in an underground cavern, a gas plume rise
through a shaft, heat radiate into a void. Fluids must live in a **3D volume** to interact with caves.

**This is the largest change in the sim.** It supersedes the 2.5D substrate wholesale (the 2.5D field
is a holdover once 3D terrain lands). Break it freely — no parallel 2.5D/3D fields.

## Hard dependency + sequencing
The 3D field needs a per-point **terrain solidity query** (`is_solid(x,y,z)` / SDF sample) to know
rock vs void — provided by the 3D-terrain (caves) work. So: **land caves first, then build the 3D
field on top of it.** Building it now against 2.5D terrain means re-integrating later (double work).

## Core decision: SPARSE/active 3D, not dense
Dense `dim³` is memory-prohibitive (100³ = 1M cells × many float layers = GBs; finer is worse). Use a
**sparse, active-set 3D field** — the direction `ARCHITECTURE_PLAN.md` already commits to
(sparse-brick residency, sleep-by-default, active-set scheduling):
- Space is bricked (e.g. 8³ or 16³ voxel bricks). A brick is **allocated only when it holds material
  or borders it** (near a fluid surface, an active cave with water/lava, a heat source, a gas plume).
- Empty rock and empty air are **not stored**. The vast majority of the world is one or the other.
- Bricks sleep when quiescent and wake on dirty/halo (a neighbour becomes active) — same active-set
  idea already used for the CA step budget.
- GPU-resident: bricks are SSBO pages; the compute kernels iterate the active brick list. The existing
  GPU CA (heat/atmosphere/liquid) already proves the SSBO + kernel pipeline; this generalizes it from
  a flat 2.5D array to a sparse 3D brick pool.

## The 3D rules (each is the 2.5D rule generalized to include a Y axis)
- **Heat**: conduction to 6 neighbours (not 4); convection = hot gas/air rises (buoyancy along +Y) and
  advects its heat — real thermals/plumes instead of the 2.5D approximation. Solar still enters at the
  top surface only.
- **Liquids (water/lava)**: flow to lower *3D* neighbours by head, and FALL through voids under gravity
  (a fluid over a cave opening pours in). Fills caverns bottom-up → underground lakes / lava pools.
- **Gases (vapor/smoke/steam)**: rise by buoyancy + diffuse in 3D; the atmosphere/water-cycle rules
  (condense→cloud/fog→rain) run in the upper bricks; smoke fills a cave and seeps out.
- **Gravity/granular**: loose material falls in 3D (already how debris physics works); ties into the
  emergent cave-collapse (fracture over a void → material drops into the cavity in 3D).
- Phase changes stay data-driven per material (freeze/melt/boil/solidify at T/P thresholds) — unchanged
  in spirit, now per 3D cell.

## Rendering
2.5D rendered water/lava as a welded heightfield surface. In 3D, extract the fluid **surface** per
brick (marching-cubes / a Transvoxel-style pass on the fluid density) so a cavern lake or a lava tube
renders as a real 3D surface; cloud/fog stay as their volumetric sheets (or become true volumetrics
later). Cooled lava keeps its smooth basalt surface. The heat texture becomes a 3D field the terrain
shader samples near the surface (incandescence unchanged at the surface).

## Migration (build beside, prove parity, then delete 2.5D)
1. On caves-3D terrain: add the `is_solid(x,y,z)` terrain query + the sparse brick pool + allocation
   rules. No behaviour yet.
2. Port heat to 3D (6-neighbour conduction + buoyant convection); prove it matches 2.5D on flat ground
   and now warms voids.
3. Port liquids to 3D (flow + fall-through-void); prove rivers/lakes parity on the surface AND that
   water/lava pour into and fill caves.
4. Port gases/atmosphere to 3D; keep the water cycle.
5. Move all kernels to GPU over the brick pool; keep a CPU reference as the headless oracle/fallback.
6. 3D fluid-surface extraction for rendering. Delete the 2.5D field.

## Risks / honest scope
Multi-phase, foundational, days of work. Main risks: memory/perf of the brick pool (mitigate with
aggressive sleeping + coarse bricks away from the camera), fluid-surface extraction cost, and keeping
the many consumers (`Creature`/`Fish` depth/temp queries, `EcologyService`, disasters, `VoxelWorld`
sea-level/spawns) working via the same query API (`temp_at`/`depth_at`/`is_water_at` become 3D-aware
but keep their signatures where possible). Commit before each phase; verify parity on the headless
harness before deleting the 2.5D field.
