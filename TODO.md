# TODO / Roadmap — Voxel Ecosystem Sim

Master tracker for the from-scratch **godot_voxel ecosystem simulation** (project `main_scene`:
`VoxelWorld.tscn`). Full rationale for the roadmap below lives in the plan file + `SPHERICAL_PLANET_PLAN.md`.

## North-star (read CLAUDE.md + EMERGENCE.md first)
- **Dissolve, don't patch (THE CORE):** ONE physical substrate (`MaterialField3D`) — matter with
  pressure/temperature/phase/gravity/**momentum** + chemistry. Named phenomena — "volcano", "eruption",
  "lava-bomb", "tornado", "hurricane", "storm", "weather" — have **zero dedicated behavior code**; they EMERGE
  from the universal rules. When you meet a `*Volcano.gd` / `_is_erupting()` / burst timer / `BOMBS_PER_BURST`,
  push the universal rule into the substrate and **DELETE the special-case system.** Disaster actors are
  seeds/markers/visuals only. **Success = named-phenomenon code DELETED, not features added.**
- **3D always** (no 2.5D column holdovers) · **perf-first** (playable frame-rate is first-class) ·
  **GPU-GLSL-only: there are NO CPU oracles** (the GLSL kernels are the sole implementation; the CPU branches
  are an unmaintained headless fallback, never a parity contract) · **bias to action** (spike, don't pad).

## Current state (1-liner)
Flat island, dense-3D GPU field (`MaterialField3D`) with ~19 emergent per-cell processes; centralized
telemetry (`SIM_REPORT`); the field CPU step tails were crushed (magma 660×, fire 12×, charge 55%). Next: turn
the flat world into a cubed-sphere planet, then genericize reactions + dissolve every scripted disaster.

---

# ROADMAP

## Phase A — SPHERE FOUNDATION (visible planet). Grid-independent; land first.
- **TARGET = an OUTER-WILDS-SCALE solar system (~tens of km total; a body is 1-of-N moving, spinning worlds).**
  This scale is the SWEET SPOT and makes the design SIMPLER: fp32 covers the WHOLE system in one coordinate
  space (~cm precision at 100 km) → **NO fp64 build, NO floating-origin rebase, NO double-precision rebuild of
  `godot_voxel`/our GDExtension.** Everything lives in one world; bodies are just nodes at their positions.
  **Space between bodies is NOT a field** (thin bounded atmosphere shells; don't voxelize vacuum). The
  cubed-sphere is unchanged. Disciplines baked in from A1:
  - **(1) Field is body-LOCAL because bodies MOVE + ROTATE (the #1 rule).** Each body's `SphereGrid`+
    `MaterialField` is simulated in body-local space; the body's `Transform3D` (position + orientation, stepped
    each frame by the orbital/spin integrator) places it in the shared world. Creatures/water/clouds simulate
    locally — oblivious to the planet's motion — and render THROUGH the transform. This is exactly what lets you
    stand on a spinning planet with its ocean and air rotating with you (Outer Wilds' whole identity). Not a
    precision hack here — it's the moving-rigid-frame model.
  - **(2) Sun is a POSITIONED body** — per-cell solar = `dot(cell_radial, normalize(sun_pos-body_center))` ×
    `1/dist²`, not a baked global `sun_dir` (and you literally watch it move).
  - **(3) Two gravity scales, separate:** per-cell radial gravity INSIDE each field (on-planet) vs. a
    world-space point-mass integrator for the bodies + free actors (player, ejecta). **DECIDED: emergent
    real-time n-body gravity** — orbits EMERGE from the same momentum+gravity substrate (dissolve-don't-patch
    applied to celestial mechanics), no scripted paths. Kepler rails are the FALLBACK ONLY if perf is
    unacceptable — not the default.
  - **GRAVITY = TWO INTEGRATORS, NOT ONE (keeps it ~O(K), not O(n²) as projectiles/asteroids multiply):**
    - **Attractors** (star + planets + moons, ~10): full direct-sum **velocity-Verlet** (symplectic → orbits
      don't decay; seed near-circular velocities `v≈√(GM/r)⊥r` so it's stable without rails). Mutual O(M²)≈100
      pairs — trivial, CPU or a tiny kernel. **Softening** `g=GM·r/(|r|²+ε²)^{3/2}` to kill close-approach
      singularities (prevents forced tiny timesteps).
    - **Everything else = a GPU TEST-PARTICLE buffer** (pos, vel, mass, state∈{bound,free,landed}): projectiles/
      ejecta/asteroids/debris FEEL gravity but don't EXERT it (a pebble can't perturb a planet, nor each other)
      → cost is O(K·M), and with **dominant-attractor / sphere-of-influence** (only the strongest body's pull,
      KSP-style) it drops to **O(K)**, one compute invocation per particle. Same buffer as the Phase C ejecta
      system → gravity + inter-body travel + impact all fall out of one structure.
    - **Keep M small:** mass-threshold **promotion** — an asteroid big enough joins the attractor set; pebbles
      never do. **Bound K structurally:** landed ejecta re-deposits as field mass + despawns, escaped ejecta
      culled past a boundary radius, debris merges into what it hits (already the Phase C re-deposit plan) →
      K is bounded by lifetime, not by launch volume. Optional **block/individual timesteps** (only the fast
      close-encounter bin steps every frame). **Barnes-Hut octree = escalation path, likely never needed**
      (only if thousands of MUTUALLY-massive bodies ever appear).
  - **Reference-frame handoff = the ejecta primitive at scale.** A test particle is `bound` to a body's local
    frame (on/near surface, moving with it) or `free` in world space (in transit); handoff at the
    atmosphere-shell radius (enter → rebind to that planet's local frame; `landed` → re-deposit + despawn). A
    lava bomb with enough momentum leaves local frame → world-space projectile under multi-body gravity → lands
    on ANOTHER planet. Outer Wilds' comet-debris / sand-pillar behaviour falls out of Phase C for free.
  - Additive later (no sphere change): only-active/near-planet full-rate field (distant ones coarse/frozen),
    system-scale camera/LOD.
- [x] **A0 — spike the cubed-sphere seam table** (DONE, `feature/sphere-spike` 6f19512): `LASphereGrid` builds
  6 gnomonic faces × res² × depth radial layers + the per-cell 6-neighbour+radial index table; seams stitched
  geometrically (nearest surface dir past the edge — no hand-coded 24 edge/8 corner cases). `spike_sphere.gd`
  proved it BEHAVIOURALLY: `SPIKE_REPORT ok=true`, closed+symmetric, `min_adj_dot=0.986` (no seam teleport),
  seam diffusion smooth (`max_grad=0.068`, `mass_err=0.0`), radial convection monotone. `SphereGrid.gd` is the
  keeper (Phase B's neighbour SSBO); the harness is throwaway.
- [ ] **A1 — visible planet:** heightmap→**SDF voxel sphere** (`VoxelTerrainService`: radial coast falloff,
  `sea_level`→`sea_radius`, `surface_height`→inward radial cast, `carve_caves` `-Y`→radial). Radial "up" for
  `Creature`/`Fish`/`Plant`/`Tree`/`Nest` snap+heading+`look_at` (tangent-plane locomotion). `VoxelCameraRig`→
  orbit-the-planet. `VoxelSkyCycle`→spin under the sun + **per-cell solar** (`heat3d_solar.glsl`:
  `max(0,dot(cell_radial,sun_dir))` with `sun_dir=normalize(sun_pos-body_center)`, `1/dist²` intensity — sun is
  a positioned body, NOT a baked vector) → terminator + latitude bands feed treeline/snow/comfort. **Magma
  core** = innermost radial layers pinned hot → radial geothermal gradient. `OceanPlane`→spherical sea shell.
- Field's gravity-dependent processes parked until Phase B. Deliverable: walkable rotating lit planet, day/
  night terminator, latitude climate, hot core, breathing life.

## Phase B — CUBED-SPHERE FIELD PORT + reaction engine + water-cycle unify (one converged kernel rewrite).
- [ ] **B1 — grid layer:** neighbour-index SSBO + per-face/radial buffer layout (rework `MaterialGPU3D`
  `_PAIR_FIELDS`/`_SINGLE_BUFS`: `col`→per-face radial ray, `area`→`6·face_res²`; `send` 6-slots→6 face-
  neighbours with seam wrap replacing the `if(ix>0)` boundary flux-drops).
- [ ] **B2 — convert every kernel's gather to the table + radial gravity** (water CA first — down = radially-
  lower neighbour; then buoyancy+Coriolis [retire the fake term], lava, slump/dust, atmosphere, gas). Fan out
  one subagent per kernel/module.
- [ ] **B3 — during the rewrite:** replace bespoke reactions with a generic **DEFS reaction engine**
  (`{reactants[(chan,coeff)], products[…], driver+threshold, rate(const-frac|bilinear|excess-over-thr),
  reactant-cap, product-target}`; ~11 reactions — combustion/fungus/photosynthesis/condense/snow/sky are clean,
  SDF-editing lava/ice/magma + cross-cell rain/fungus-fert stay special), and **unify the water cycle** into
  one conserved `_airwater` channel (cloud/fog/vapor derived from local T vs `sat(T)`; evap a true transfer
  `water-=e`; rise folds into buoyant wind `vel_y`, drop `VAPOR_RISE`). Deliverable: complete weather +
  volcanism emerge on the planet.

## Phase C — DISSOLVE named phenomena + emergent rendering (volcano first, then fan out).
- [ ] **C0 — keystone primitive: pressure/vorticity/kinetic → MOMENTUM on matter** in the substrate: ejecta
  parcels (lava/rock launched when overpressure beats confinement, arc under radial gravity, re-deposit heat+
  lava/sediment) + a wind/vortex force that ADVECTS creatures/debris/sediment (replaces every geometric
  `throw()`). Build once → all the flings/bombs dissolve.
- [ ] **C1 — generalize the render seam:** discrete-event callbacks `on_ejecta`/`on_impact` mirroring
  `MaterialCharge3D.on_bolt` + `set_lightning_visual` (`LightningStrike` is the visual-only reference); ONE
  field-driven **volumetric FX renderer** sampling a 3D density (start with the already-simulated-but-unrendered
  `dust_at`, + cloud/vorticity) → GPU particles (generalize `RainLayer`). Funnels/spirals/ash/glow render FROM
  field state.
- [ ] **C2 — Volcano FIRST (the pattern):** delete `_is_erupting`/`_bomb_cd`/`BOMBS_PER_BURST`/`_launch_bombs`;
  ejecta from C0, glow/ash from C1; actor → seed + visual callback.
- [ ] **C3 — fan out one subagent per actor:** Tornado (vorticity→force replaces `_fling_wildlife`), Hurricane
  (pressure→force + emergent embedded severe-wx, delete `_maybe_breed`/`_stir_wildlife`), Thunderstorm (delete
  `_maybe_strike` — charge already fires bolts), Earthquake (crustal stress-release wave replaces the timer
  burst-emitter), Meteor (kinetic-impact → ejecta momentum + crater-as-sediment). Already-dissolved (reference):
  Lightning, Landslide, Flood, Weather/Rain. Deliverable: disaster behavior code DELETED (measure: lines).

## Cross-cutting — file-splitting + subagent orchestration (prerequisite + ongoing)
- [ ] Split remaining large files so each unit is an independently-ownable file (max parallel subagents, no
  write conflicts): `MaterialField3D.gd` (~1285: setup/sampling · step-orchestration · queries facade · report),
  `MaterialGPU3D.gd` (~1232: resource-mgmt vs dispatch), `VoxelWorld.gd` (~730: disaster auto-flags · water-seed
  · fps probe), `SpawnPaletteHud.gd` (758), `EcologyService.gd` (613), `Fish.gd` (~600). Split BEFORE the phase
  that touches them.
- Orchestration: each phase decomposes per-unit (per kernel / actor / reaction / file); a coordinator subagent
  per workstream launches worker subagents per unit (subagents can spawn subagents), each owning one file with
  a shared contract (neighbour table / ejecta primitive / DEFS record) + a behavioural `SIM_REPORT` gate.

## Perf follow-up (any time)
- [ ] Charge tail's ~3.6ms floor → GPU-side charge hot-cell list (its own module).

---

## Where everything lives
- **Root:** `VoxelWorld.gd`/`.tscn` (main_scene). **Terrain:** `terrain/VoxelTerrainService.gd`
  (`VoxelLodTerrain`, heightmap→sphere in Phase A; `sdf_at`/`is_solid`/`carve_sphere`/`carve_caves` survive).
- **THE substrate:** `material/MaterialField3D.gd` — dense-3D GPU field; per-force modules
  `Material{Heat,Water,Lava,Atmosphere,Wind,Combustion,Slump,Erosion,SnowIce,Dust,Scent,Magma,Charge,Shock,Gas,
  Fungus}3D` + `MaterialGPU3D`(+Geo/Push) + `kernels3d/*3d.glsl` (authoritative; no CPU oracle to maintain).
  Facades/render: `MaterialField{Queries,Inject,Render}3D`, `MaterialHeatTexture3D`, `OceanPlane`, `CloudLayer`,
  `RainLayer`. Telemetry: `world/SimReport.gd` + `world/SimReportSources.gd` (`SIM_REPORT` snapshot).
- **Actors:** `actors/{Creature,Plant,Tree,Rock,Corpse,Food,Fish,Nest}` + creature helpers `actors/creature/`
  (leadership/metabolism/flocking/think/senses/nesting/ragdoll); disasters `actors/{Meteor,Volcano,Earthquake,
  LightningStrike,Flood,Tornado,Thunderstorm,Hurricane}` (dissolving in Phase C).
- **Cognition:** `cognition/*` (fast rules + sparing LLM). **Data:** `data/species/**/*.json`. **UI:** `ui/*`.
  **Camera:** `VoxelCameraRig.gd`. **Design:** `EMERGENCE.md`.

## How to run / verify
- **Windowed (exercises the GPU + screenshots):**
  `LA_NO_STREAMER=1 godot --rendering-driver metal --path . addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=<png> --shoot-frames=N`
  — `--overview` wide vista; `--time=<0..1>`; disaster triggers `--auto-{meteor,volcano,lightning,tornado,
  thunderstorm,hurricane}`; `--auto-select`. (`--run-frames`/`--shoot` auto-move the window off-screen.)
- **Headless/behavioural smoke:** `LA_NO_STREAMER=1 godot --rendering-driver metal --path . …/VoxelWorld.tscn -- --run-frames=N`
  → one `SIM_REPORT={...}` line (events{deaths…} + gauges{fps,physics_ms,field_ms,leaders,min_hydration,…} +
  field/population/cognition sections). Acceptance is BEHAVIOURAL (aggregates sane, no NaN/runaway, fps good) —
  **no CPU↔GPU parity gate.**
- **Lint/tests:** `scripts/agent_harness.sh <lint|fast|bounded|extension>`. **Gotcha:** a NEW `.gd` `class_name`
  registers only after `godot --headless --editor --quit-after 400`.

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
disaster actors are seeds/visuals; measure success by special-case code deleted. See `EMERGENCE.md`.
