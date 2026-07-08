# Spherical Planet — Scoped Plan (cubed-sphere, the accurate way)

**Goal:** turn the flat island into a small **voxel planet** so the sim gets *complete, accurate* weather — a
day/night **terminator** sweeping the surface, **latitude climate bands**, **seasons**, and **global
circulation / Coriolis** storms — none of which a flat plane can do (its Coriolis is a fake term, its
day/night is one global clock, its wind hits map edges instead of circulating).

## Grid choice — cubed-sphere. (Why NOT the cartesian-box shortcut.)

The tempting shortcut is to keep the current dense **cartesian** grid and just make gravity **radial** (a
sphere of rock in the box centre). It reuses the most code — and it is **wrong for accurate weather**:
- The grid axes are the **box's**, not the planet's → flow + circulation carry **box-orientation artifacts**
  (water flows preferentially along the cartesian axes/diagonals; jet streams + circulation cells distorted by
  the grid, not the geography). For *complete* weather this is disqualifying.
- The sphere cuts cartesian cells at arbitrary angles → a **staircase** surface → aliased coastlines/pooling.
- ~48% of a cubic box is corners (space) → lower effective resolution per cell.
- It makes the flow CAs **hackier, not cleaner**: radial "down" rarely aligns with a face, so flow must be
  split across 2–3 misaligned neighbours by projection — which *is* the source of the artifacts above.

**Cubed-sphere** (6 gnomonic cube faces on the sphere, each a 2D grid, extruded into **radial layers** =
crust + atmosphere shell) is the climate-model standard, and it is both more accurate AND cleaner for us:
- **RADIAL is a grid axis** → "down" = the next-inner radial layer; the water/lava/slump/buoyancy CAs stay
  **axis-aligned and clean** — just relabel today's `Y → radial`, no projection hack.
- **Surface-conforming** (constant-radius shell) → clean coastlines, no staircase.
- **~100% of cells** on the planet + atmosphere; accurate global circulation aligned to the sphere; only **8
  mild cube-corner singularities** (vs a lat-lon grid's 2 pole singularities).

The **arduous part** (the reason it's the "correct, hard" way): **face-seam neighbour machinery.** Within a
face it's a cartesian 4-neighbour (+ radial up/down); across a cube EDGE the neighbour is on another face with
a coordinate rotation, and the 8 cube CORNERS are mild singularities. Encode all of this **once** as a
precomputed per-cell **6-neighbour INDEX TABLE** (an SSBO built at setup). Then every kernel's gather changes
from `±1 / ±dx / ±layer` arithmetic to **"read my 6 neighbour indices from the table"** — a uniform, mechanical
change across all ~19 kernels, and the data-driven buffer table gains a per-face layout + the neighbour buffer.

*(Alternative: an icosahedral/geodesic grid — even more uniform, no cube-corner singularities, but
hexagonal/pentagonal neighbour counts complicate every kernel. Cubed-sphere is the pragmatic-correct choice.)*

**Perf:** a *small* planet is ~the current cell budget spent on a real spherical shell (no corner waste), so
resolution actually improves per cell vs the box shortcut. Not a scale explosion.

**IMPLEMENTATION IS GPU-GLSL-ONLY. There are no CPU oracles** — the GLSL kernels are the sole implementation.
The CPU `step_scene_only()` **tails** are scene-coupling (emit/scan/carve/regrow), not reference
reimplementations, and are largely grid-agnostic.

---

## Phase 0 — Spike (de-risk the SEAM machinery first, throwaway, ~2–3 days)

The seam neighbour table is the crux, so prove IT before porting anything.
- Build the cubed-sphere geometry + the precomputed 6-neighbour index table (faces, edges, corner cases).
- Port JUST the water + heat kernels to gather via the table, on a tiny planet, no creatures.
- Success = water **pools on the constant-radius surface** and flows to basins with **no box-axis pattern**;
  hot air **convects radially**; a **terminator** sweeps; a rough **circulation cell** forms. Validate the
  seam handling by checking a scalar field (e.g. a diffusing blob) crosses cube edges + corners smoothly with
  no discontinuity.
- If the seam table is right here, the rest is mechanical. This is where the risk lives — spend it here.

---

## Phase 1 — QUICK WIN: the visible planet, grid-independent (do in parallel with Phase 0, ~days)

None of this depends on the field's internal grid, so it lands early for a big visible payoff.
- **Terrain → godot_voxel voxel PLANET.** SDF sphere + noise (`VoxelGeneratorGraph`); `VoxelLodTerrain`
  supports planets natively. Gravity/up references become radial. *(terrain/VoxelTerrainService.gd + generator)*
- **Radial "up" for actors + camera.** Creatures snap to the surface radially (up = `normalize(pos − centre)`)
  and orient to the local normal; camera orbits / walks the sphere. *(Creature terrain-snap + movement,
  VoxelCameraRig, VoxelWorld pan bounds)*
- **Sun → hemisphere lighting + terminator + rotation.** Directional sun lights one hemisphere; spin the
  planet → the terminator sweeps → **per-location day/night** replaces the single global clock. *(VoxelSkyCycle
  + planet-spin)*
- **Latitude climate for free.** The heat kernel's SOLAR input scales by `sun · outward-normal` → hot equator,
  cold poles, feeding the treeline/snow/comfort systems with no new rule. Heat *conduction* is diffusion
  (grid-agnostic) → unchanged.
- **Spherical sea shell** (fixed-radius ocean) for a visible sea without the water CA (rivers/pooling = Phase 2).

**Milestone:** a walkable, rotating, lit little planet with a day/night terminator + latitude temperature bands
+ fire + breathing life — a strong showcase, and it de-risks locomotion/camera/rendering with zero kernel work.
Field's gravity-dependent processes (water/lava/slump flow, buoyant wind) stay parked (flat `−Y` or disabled)
until Phase 2.

---

## Phase 2 — ARDUOUS + ACCURATE: the cubed-sphere field (the real work)

1. **Grid + neighbour-index table** (from Phase 0, hardened) + **per-face / radial buffer layout** — rework
   the data-driven buffer table (`MaterialGPU3D._PAIR_FIELDS/_SINGLE_BUFS`) for the 6-face shell + the
   neighbour SSBO.
2. **Convert every kernel's neighbour gather to the table** — mechanical but touches all ~19
   (`kernels3d/*3d.glsl`): replace `±1/±dx/±layer` with the 6 table indices. Each kernel is its own module →
   **parallelizable across subagents** now that the field is split.
3. **Radial-native gravity** in the flow/buoyancy kernels (clean — radial is an axis):
   - **Water CA first** (the keystone; relabel `Y → radial`) → rivers run down the sphere to the sea, lakes
     pool in basins.
   - **Buoyant convection + Coriolis** (`heat3d_buoyancy` + `wind_pressure3d`/`wind_step3d`): hot rises
     radially, add `−2Ω×v` from the planet's spin → Hadley/Ferrel cells + trade winds + correctly-rotating
     cyclones (retire the fake Coriolis term).
   - **Lava flow, granular slump, sediment/dust** → radial downhill / angle of repose.
   - **Atmosphere vapor/cloud/fog** → radial precipitation (folds into the water-cycle unification, TODO #17).
   - **Seasons** → tilt the spin axis vs the sun's orbit; the latitude band shifts seasonally.
4. **Terrain solidity:** the field samples `is_solid(world_pos)` at each cubed-sphere cell's world position
   from the voxel planet (already how the field reads terrain — just new cell→world positions).

**Order:** grid+table → kernel-gather conversion → water → convection/Coriolis → lava/slump/dust → atmosphere
→ seasons. Verify each BEHAVIOURALLY via `SIM_REPORT` (water pools on the surface, `wet_cells` sane, circulation
cells form, storms track + return, no NaN/runaway) — no parity gate, no CPU oracle.

---

## Risks & notes
- **The seam neighbour table is THE crux** — cube edges (coordinate rotation) + 8 corner singularities. Get it
  right in Phase 0 before porting all kernels; a bug there corrupts everything, subtly.
- **Buffer-layout rework touches the recent GPU data-drive** — the per-face shell layout + neighbour SSBO
  replace the flat `idx = (iy*dim_z+iz)*dim_x+ix` scheme; the data-table structure survives, its contents change.
- **Multi-week, biggest-risk change in the project** — terrain, gravity, camera, locomotion, AND the field's
  index/neighbour layer + all kernels. Gate each phase behind a working milestone; do it NOW before more
  flat-assuming code accretes (the tech-debt argument), and lean on the per-process split for parallelism.
- GLSL-kernel-only (no CPU oracles). Record the cubed-sphere substrate change in `ARCHITECTURE_PLAN.md` before
  Phase 2 merges.
