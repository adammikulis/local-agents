# Changelog

All notable changes to this project are recorded here. The project is two things at once: a
reusable Godot addon for running local LLMs in-engine (the `LocalAgent` node and friends, under
`addons/local_agents/{agents,runtime,ui,examples}`), and the flagship game that demonstrates it —
a cubed-sphere planet simulation whose creatures and streamer are driven by those models, fully
offline. The sim library lives in `addons/local_agents/sim/`, the game shell in
`addons/local_agents/game/` (main scene `game/VoxelWorld.tscn`).

## Unreleased — 0.4.0-dev

Development branch `0.4-dev`, currently 292 commits past 0.3.1. **0.4 is the emergent planet**:
geology, hydrology, volcanism and climate, all falling out of the one field. Not yet released, and
the summary below is by theme rather than a settled release note.

- **The planet's physics became conservative.** One conserved H₂O budget across liquid, vapour,
  snow and soil water; the static sea dissolved (it had been minting water it never lost); a real
  aquifer / water-table channel (springs are modelled as a flux but do NOT yet run — the
  outflow loop spends its budget greedily in slot order and drains downward first); hydrostatic air mass; gravity and the star
  as real bodies; body-local spin, with the Coriolis direction corrected and the cubed-sphere
  neighbour table made slot-opposite reciprocal.
- **Biology went deep** — literal DNA heredity, chemical-affinity learning, digestion over time,
  per-creature courtship and gestation, sexed breeding, graded senescence, gut microbiome, fish
  cognition, emergent disease and heritable constitution.
- **Performance** — a compacted active-cell list with indirect dispatch, demand-gated readbacks,
  animation and physics-rate LOD for creatures. A camera-relevance LOD over the FIELD was tried and
  removed: it made the planet's physics depend on where the camera pointed, and measured slower than
  no gating at all.
- **The addon became a real library** — the `sim/` (library) vs `game/` (shell) split, the
  `LocalAgent*` public / `LA*` internal naming rule, inspector surfaces, a Setup tab, and a
  one-node `LASimWorld` facade.
- **The gates started actually gating.** Several checks had been passing on zero files for months
  because `rg` is absent on the CI runner; `scripts/lib_require.sh` now makes a gate that cannot
  run fail instead of pass, and CI calls the same `scripts/agent_harness.sh lint` a developer does.

## 0.3.1

Caretaker-game patch; macOS and Linux desktop builds. The 0.4 living-creatures work stayed on its
feature branch and is not in this release.

- **Performance:** distance-gated compute-bubble LOD for creatures plus coarse-cadence vegetation
  LOD — roughly 20 fps to 100+.
- **Fixes:** spawn-puff freeze; audio-on-launch and streamer now default-off and lazy; radial-up
  lightning; size-scaled meteor charge; surface-tangent brush and selection rings; the Linux
  extension build (GCC `sqlite3_int64`→`Variant`); Linux export dependencies (versioned sonames,
  and the unbuilt `libggml-blas` dropped).
- **UX:** globe drag-rotate and invert toggles, Ctrl+scroll brush sizing, geosync arc-down zoom,
  crust→mantle→magma geology glow, meteor barrage, control-by-spawning campaign start.
- **Known gap, still open:** CI compiles `localagents.windows.dll` but does not collect its
  llama/ggml runtime DLLs, so no Windows package can be assembled yet.

## 0.3.0

The headline: the simulation became a chemistry-based, cubed-sphere **planet**. The old flat/box
world and its CPU-oracle field modules were removed, and the substrate was re-founded on conserved
chemical substances whose phases and reactions are data — not code. The capstone is a scripted
volcano dissolved into physics: a seabed vent now builds an island on its own.

### Substrate / chemistry

- **One conserved H₂O substance.** Liquid, vapor, cloud, fog, snow, and ice are no longer separate
  channels — they are phases of a single conserved water quantity, and which phase a cell is in is
  derived from local temperature versus saturation, not stored or scripted. The separate
  vapor/cloud/fog channels were fused into one `_airwater` channel; snow/ice were folded into the
  same substance with freeze/melt and `sat(T)` deposition as transitions.
- **Generic data-driven reaction engine (`MaterialReactions3D.gd`).** Same-cell chemistry is now a
  table of reaction records — reactants, products, driver + threshold, rate, cap, target — rather
  than bespoke kernels. Gas sky-exchange, fungus decomposition, photosynthesis/respiration, and
  freeze/melt were all dissolved into records. Adding a reaction is now a data record, not a new
  kernel (`kernels3d/reactions_sphere3d.glsl` executes them on the GPU).
- **Biomass substance → emergent vegetation.** Photosynthesis deposits a `biomass` field in each
  column's sky-exposed shell cell; vegetation and forests gate on the real per-column productivity
  the chemistry produces. The old hand-placed plant CPU logic dissolved.
- **Unified rock / mineral (`rock_fill`).** Rock and mineral collapsed into one fractional
  `rock_fill` amount with a **derived** solid state and a conservation ledger (`mineral_total`);
  `add_lava` conserves mass across phase changes. A `MineralStamp3D` grows terrain by stamping the
  SDF where `rock_fill` crosses 0.5 — so accreted rock becomes walkable ground.
- **Conservation ledger + dissolved dust-loft.** Mass is tracked across phase transitions; the old
  `dust_loft` kernel was dissolved into a reaction record.

### Planet

- **The cubed-sphere grid was the sole substrate for 0.3.** It has since been deleted in favour of the
  uniform Cartesian box, so this entry describes a shape the tree no longer has.
- **Emergent, verified planet physics:** star-lit solar terminator (per-cell
  `dot(cell_radial, sun_dir)`), geothermal core + heat conduction, a full
  sea → evaporation → cloud → rain water cycle, an emergent snow line, and the closed carbon/oxygen
  loop — all on the sphere.
- **Body-local, spinning planet in space** with a distance-LOD Transvoxel surface, an ocean shell,
  orbit camera, and a dark-space sky.

### Rendering

- **Unified GPU water-particle renderer (`WaterParticles.gd`).** A single system draws cloud, fog,
  rain, and snow, choosing appearance by the water phase of the cell it samples. The separate
  `RainLayer` and `CloudLayer` nodes were dissolved. Rain now falls toward the planet core (radial
  gravity), not screen-down, and cloud alpha is density-graded so clouds are visible on the globe.

### World / ecology

- **A living world (~750 actors at ~96 fps).** Creatures, fish, plants, rocks, and forest clusters
  scaled up (predators scale with prey; fish stocked via one `AQUATIC_STOCK_MULT` dial); far actors
  self-throttle on the existing distance-graded think LOD so frame-rate stays playable.
- **Emergent biomass-gated forests.** Forest clusters gate on the biomass field, so tree cover
  tracks real photosynthetic productivity and succeeds over a run (verified per-column biomass
  climbing ~0.09 → ~0.57) instead of a placement table.
- **Seabed vent builds an island (the dissolve-don't-patch capstone).** The scripted `Volcano.gd`
  eruption logic was dissolved: a seabed vent seeds hot pressurized magma, the water quenches and
  solidifies it into `rock_fill`, rock accumulates, and the `MineralStamp3D` SDF-growth turns the
  pile into terrain — an open-ocean basin becomes a glowing volcanic island above sea level, with
  no dedicated eruption code. (`--auto-seavolcano` demo prints `SEAVOLCANO={...}` proof.)

### Local agents / streamer

- **Species-named, natural commentary.** The local-LLM streamer/commentator was rebuilt to emit
  concrete, named beats (species, location, the hunter's actual prey) and feed the small model one
  enriched beat at a time — killing the repetitive fragment/template parroting.
- Creature cognition and the streamer both run on **local LLMs, fully offline**.

### Tooling / UX

- Split `VoxelWorld` and `MaterialField3D` into focused controllers for parallel ownership.
- `--auto-seavolcano` harness hook (seeds a seabed vent, frames a lit close-up, prints proof);
  `--time=<0..1>` day-time screenshots; behavioural `SIM_REPORT` remains the headless smoke gate.

### Cleanup / refactor (the big breaking change)

- **The flat/box world is gone — the planet is the sole world.** Deleted: 21 retired
  CPU-oracle + box-GPU field modules (~7,300 lines), 32 dead box `*3d.glsl` kernels (~3,000 lines),
  the dead box `_physics_process` step branch, and the flat/2.5D code paths across terrain, ocean,
  camera, and actors (~11,000+ lines removed in total). There are no CPU oracles: the GLSL kernels
  are the sole implementation, verified behaviourally, not against a CPU parity harness.
- Throwaway A0/A1 sphere spike harnesses and the obsolete `PlanetPreview` were removed.

### Known issues

- On windowed Metal/MoltenVK (macOS), a `recursive_mutex` abort can fire during **teardown on exit**,
  after the run has completed and printed its report — it is harmless (the simulation has already
  finished) and pre-dates 0.3 (the old box path aborts identically on the same environment). It may
  not be present on your platform, and a separate fix is in flight; ignore it if it appears at
  shutdown.
- One-step coupling-fidelity lag on a few cross-pass channels (o2/co2/fire/fungus applied in place;
  snow meltwater into the live water) is accepted under the performance-over-parity policy.
- Full field readback for scent/fungus/erosion is partial (needs CPU→GPU injection round-trips), so
  those channels can read low in `SIM_REPORT`.
