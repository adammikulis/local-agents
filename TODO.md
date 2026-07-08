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
- **Big-O is a first-class goal (CORE):** drive down *asymptotic* cost, then constants. (1) Prefer the
  better-scaling structure — spatial hash/tree/neighbour-table, O(K) test-particle passes, event/dirty-set
  updates — never a per-frame O(n²) or a blind full-grid sweep. (2) **Do less by RELEVANCE (adaptive LOD is
  mandatory):** offscreen / distant / un-zoomed / dormant / empty regions do less (coarser grid, staggered or
  skipped timesteps, frozen sim, culled draws, lower-LOD meshes, sleeping actors). Budget compute where the
  player looks. Composes with GPU-first + emergent; when in tension, cutting asymptotic/relevance cost wins.

## SOLAR-SYSTEM-FIRST (canonical architecture — decided 2026-07)
The world is **a solar system of bodies**, not one flat world. Structure everything around this spine now;
grow the content in stages. **Radial is the default everywhere; flat retires to git history (no flag, no
parallel mode).** Node spine:
- **`LASolarSystem`** (system root — repurpose `VoxelWorld`): owns the star, the bodies, and shared services
  (camera rig that can target any body, HUD, audio, the world-space gravity + free-particle buffer = orbits +
  ejecta). Runs the n-body integrator; wires the ACTIVE body's terrain/field/ecology to the shared controllers.
- **`LAStar`**: positioned light + gravity source; drives per-cell solar (`dot(cell_radial,sun_dir)`, `1/dist²`)
  → terminator. **`LAPlanetBody`**: ONE body in a LOCAL frame (transform = orbit position + spin) that OWNS its
  terrain (`build_planet`) · field (body-local) · ocean shell · actors · ecology; exposes `center/radius/
  sea_radius/up_at/altitude_at/surface_point/is_solid/carve` + `mass` + atmosphere-shell radius (frame-handoff
  boundary). Bodies move/rotate → their field/terrain/actors ride the transform.
- **Interim substrate (migration, NOT a parallel system):** each body keeps a `MaterialField3D` box grid as the
  working field until Phase B swaps it for the cubed-sphere `SphereGrid` substrate, then the box grid is
  DELETED. Not ripped out first: actors couple only to the field's **world-space 3D queries** (`temp_at`,
  `breathable_o2_at`, `is_submerged_at`, `is_solid`) which are substrate-agnostic and survive the swap — the
  only box-specific coupling is one instantiation line. Ripping it out first would pull the hardest work (the
  kernel port) before any visible planet and kill all field behaviour meanwhile.
- **Staging (visible result fast):** 1 static lit walkable body → body spins → orbits `LAStar` → 2nd body →
  camera travel between bodies. Multi-body ORCHESTRATION detail deferred until its bodies exist (not
  speculative — it's the committed end goal, built minimally + grown).

## Current state (1-liner)
Transitioning flat→SOLAR-SYSTEM: seam table (A0) + native sphere generator + `VoxelTerrainService.build_planet`
all PROVEN (`feature/sphere-spike`); next is the `LASolarSystem`/`LAStar`/`LAPlanetBody` node spine (retire
flat). Dense-3D GPU field (`MaterialField3D`, ~19 emergent processes) kept as the interim body-local substrate
until the Phase B cubed-sphere port. Centralized telemetry (`SIM_REPORT`); field CPU tails crushed. Then
genericize reactions + dissolve every scripted disaster (Phase C).

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
- [x] **A1 — visible planet** (COMPLETE on `feature/sphere-spike`):
  - [x] **Terrain crux PROVEN** (`c76dd9e`): `LASpherePlanetGenerator` = NATIVE `VoxelGeneratorGraph`
    `sdf=(length(p)-radius)-amp·fbm3d` (no heightmap, no box axes; solid-inside matches `is_solid<0`).
    `spike_planet.gd` → `PLANET_REPORT ok=true` (compiled, is_sphere 20-dir/0-miss, center_solid via
    generate_block, space_empty). `PlanetPreview.tscn` renders it: Transvoxel mesh + distance-LOD + lit planet
    with a natural directional-light terminator (`planet_preview.png`). Flat relic is small + isolated: ONLY
    `VoxelGeneratorImage`, `surface_height(x,z)` (down-ray), `carve_caves` (world-Y) assume `(x,z)→Y`;
    `sdf_at`/`is_solid`/`carve_sphere`/`fill_*`/`raycast_terrain` are world-space and SURVIVE.
  - [x] **`VoxelTerrainService` planet-capable** (`9cf2d63`): `build_planet` + radial queries (`up_at`,
    `surface_radius`, `surface_point`, `altitude_at`, shape-aware `is_ready_at`); `SERVICE_REPORT ok=true`,
    markers rest on the ground; island path structurally untouched (107fps windowed, no regression).
  - [ ] **Build the SOLAR-SYSTEM node spine** (the in-place refactor of `VoxelWorld`):
    - **`LAPlanetBody`** — extract terrain + field(body-local) + ocean + actors + ecology ownership out of
      `VoxelWorld` into a body node in a local frame; expose `center/radius/up_at/altitude_at/surface_point/
      is_solid/carve/mass`. Uses `build_planet`. Field = the interim box grid (unchanged internals).
    - **`LAStar`** — positioned light + gravity source + solar driver.
    - **`LASolarSystem`** — repurpose `VoxelWorld` into the system root: create `LAStar` + ONE `LAPlanetBody`;
      wire shared controllers (camera/HUD/audio/weather/disasters/brush/interaction) to the active body's
      services. Retire flat island + flat `OceanPlane` + flat fly-cam. (main_scene stays `VoxelWorld.tscn`.)
  - [x] **Spine boots the planet + FAN-OUT integrated** (`c6bbe65`): real `VoxelWorld` boots a LIVING planet —
    275 entities on the sphere, blue oceans / green continents / sandy radial coastlines, orbit camera, 96fps,
    zero errors. 7-agent parallel fan-out done, all via the terrain radial contract (gated by `is_planet`):
    Ecology radial spawn (surface_point + tangent clusters + underwater shell); `Creature`/`Fish` tangent-plane
    steering + radial ground-snap/submersion; `Plant`/`Tree`/`Nest` radial up + surface snap; `VoxelCameraRig`
    orbit mode; `OceanPlane.setup_sphere` translucent sea shell; terrain shader climate keyed off radial
    altitude/up (coastlines ring the globe, no +Y-pole snow). Flat path preserved in every file.
  - [x] **Planet SPIN** (`726efcb`): body spins as one moving frame (terrain+actors ride it), camera in the
    system frame → day/night sweeps. Validated godot_voxel honors a rotated `VoxelLodTerrain`; `VoxelTool`
    queries (sdf_at/carve/fill) made world↔local rotation-safe. **Magma-core seed** (`a70c793`):
    `add_magma_source` at the centre (interim; Phase B makes it the innermost radial layers).
  - [x] **Planetary SKY + star-lit terminator** (`da9156f`): `set_space_mode` → dark space background + dark
    COLOR ambient (the flat atmosphere dome sourced ambient from itself, washing out the night side) + sun
    FIXED shining star→planet, clock frozen. Spinning planet turns under it → stark day/night terminator.
    155fps (no atmosphere dome). Star drives the light end-to-end now.
  - [x] **Cloud/fog/rain hidden in planet mode** (`c9a127a`): flat +Y-atmosphere sheets read as grey wisps
    against space → hidden until Phase B grows radial cloud/fog SHELLS. Clean planet in space, 97fps.
  - [x] **Surface-level playtest** (`c9a127a`, temporary close orbit): life sits on the ground with correct
    radial climate bands (grass / beach / lake) + curved coastline; camera reverted to whole-planet framing.
  - **A1 COMPLETE.** Deliverable met: walkable, lit, SPINNING planet in space — SDF sphere terrain, radial life
    (creatures/fish/plants/trees/nests), radial climate (oceans/coasts/snow), ocean shell, orbit camera,
    star-lit day/night terminator, magma-core seed. ~290 entities, ~100–155fps, flat world retired.
  - **Orbit-a-star is BLOCKED on Phase B** (deferred there, not A1): the interim field is an ORIGIN-centered
    box (not a child of the body), so spin (rotation about the centre) is fine but ORBIT (translating the body)
    would desync terrain from the field box. Needs the body-local field → do it in/after Phase B.
  - Deferred to **Phase B** (cubed-sphere body-local field — NOT worth throwaway box-grid work): per-cell solar
    field TERMINATOR (`heat3d_solar.glsl` reads `LAStar` sun_dir), real radial magma core / geothermal, radial
    water/rivers. Radial caves + scripted volcano → Phase C.
- Field's gravity-dependent processes parked until Phase B (box grid enclosing the body meanwhile). Deliverable
  SO FAR: walkable, lit planet with oceans/coasts/climate + life. Left: terminator, hot core, spin.

## Phase B — CUBED-SPHERE FIELD PORT + activity-bubbles + reaction engine + water-cycle unify.
**Investigation done (3 agents, 2026-07).** The field is a flat `PackedFloat32Array` per channel of length
`_cell_count`; the SphereGrid keeps that flat-array contract (`cell = surf*depth + r`). SURVIVES unchanged: the
query facade (`temp_at`/`breathable_o2_at`/`is_submerged_at`/… world-space sigs), the step scheduler (order /
GPU-CPU split / `_slow_tick` stagger / dirty-gating / cadenced readback), the channel set, ping-pong / dispatch
/ barriers / frame API (topology-agnostic), same-cell reactions, and the world-space SDF `carve/fill` calls.
- [ ] **B1 — grid layer + world↔cell + neighbour SSBO + ACTIVITY BUBBLES.**
  - CPU seam = 5 primitives in `MaterialField3D.gd` + `setup`: `_idx :379`, `_col_i :445`, `cell_world_pos :387`,
    `_in_bounds :383`, `_surface_iy :907` → reimplement over `LASphereGrid` (world_pos → gnomonic face+surf+
    radial layer; `_surface_iy` → outermost open radial layer along a surf column). `setup_sphere(sphere_grid)`
    allocs channels of length `cell_count = surf_count*depth`. Resolution target ~300K cells (res≈45/face,
    depth≈24) — tune vs perf.
  - GPU seam = `MaterialGPU3D._ensure_buffers` size classes (`"cell"`→`surf_count*depth`, `"col"`→`surf_count`,
    `"send"`→`cell_count*6`) + a NEW resident int32 `_buf_neighbours` (`cell_count*6`, slot order matching the
    water/lava/slump send convention: **0=inward/down, 1-4 lateral, 5=outward/up**) uploaded once, bound into
    every gather set; push-constants swap `dim_x/y/z`→`surf_count/depth` but KEEP `cell_count` + all physical
    scalars. Also upload per-cell `cell_radial` (for solar + gravity). Ping-pong/dispatch/barriers untouched.
  - **ACTIVITY BUBBLES (bake into the dispatch NOW — the planet's scaling lever, see CLAUDE.md):** per-tile (or
    per-cell) activity + sleep; step active tiles every frame, quiescent tiles rarely/never; a changed cell
    wakes its neighbour tiles (bubble grows); stimuli (inject_*/carve/impact) wake a region. GPU: active-tile
    list + indirect dispatch (O(active)), or v1 = per-tile sleep flag + kernel early-out. Compose with
    distance-relevance. This is what makes ~300K–4M planet cells affordable.
- [ ] **B2 — convert every kernel's gather to the table + radial gravity.** Replace `idx±{1,dim_x,layer}` +
  `if(ix>0)` with `int n = nbr[idx*6+dir]; if(n>=0)…`. Order: water CA first (down=slot0 inward), then
  slump/lava (same 6-slot send), dust/rain/buoyancy/wind (radial down/up), atmosphere transport, o2/co2/heat/
  shock/scent/fungus (mechanical swap). Column kernels (`heat3d_solar`, `gas_sky`, `scent_wind`, `snowice`,
  `fungus_fert`) `iy`-walk → follow slot5 (outward) to the boundary (`nbr==-1` = sky cell). **`heat3d_solar`:
  global `params.solar` scalar → per-cell `max(0,dot(cell_radial,sun_dir))` on every outward-boundary cell =
  the real terminator.** Retire the fake Coriolis. FAN OUT one subagent per kernel/group (shared neighbour-SSBO
  contract + a behavioural `SIM_REPORT` gate).
- [ ] **B3 — during the rewrite:** generic **DEFS reaction engine** for the ~9-11 clean same-cell reactions
  (evap/condense/boil/re-evap `MaterialAtmosphere3D`, combustion, fungus-decompose, photosynthesis, gas
  sky-exchange, lava sustain-heat) — `{reactants[(chan,coeff)], products[…], driver+threshold, rate, cap,
  target}`; KEEP special (cross-cell / SDF-editing): rain (cloud→ground column), meltwater, magma buoy, erosion
  advect, lava solidify/melt, magma pressure-melt, ice freeze/thaw, slump. **Unify the water cycle** into one
  conserved `_airwater` channel (fuse `_vapor`/`_cloud`/`_fog`, all owned by `MaterialAtmosphere3D`; cloud/fog/
  vapor derived from local T vs `sat(T)`; evap a true transfer `water-=e`; rise folds into buoyant wind `vel_y`,
  drop `VAPOR_RISE`). Deliverable: complete weather + volcanism + real radial magma/geothermal emerge on the
  planet; the interim box grid is DELETED; the planet can ORBIT (field is body-local).

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
