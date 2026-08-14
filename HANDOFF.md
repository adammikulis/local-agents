# What to do next

Work down this list. An item is DELETED the moment it lands — this file is the remaining work, never a
record of what happened. `git log` is the record. Physics work is in `docs/PHYSICS_TODO.md`; what costs
more than it should is in `docs/PERFORMANCE_TODO.md`.

Nothing here is a claim about the state of the tree, because a claim rots and nobody notices. Check the
code, then act. Report what was deleted; report no number this substrate printed.

---

## 1. Reduce the rest on the device

`ReduceRecords` + `reduce.glsl` + `ReducePass` is the machine; the ledger fold and twenty-one report
sweeps already use it. Left:

- `MaterialFieldReport3D.surface_climate` and `_open_temp_stats`, `MaterialFieldPhotoStats3D`,
  `MaterialFieldClimateSwing3D._site_stations`, `MaterialFieldGeotherm3D._gradient`.
- `FieldPressureAudit3D`, `MaterialFieldMomentumLedger3D`, `MaterialFieldElementProbe3D`,
  `MaterialFieldOrganic3D`.
- `CLIMATE_MAX_CELLS` and its stride delete with the climate scan.
- `FieldPassAttribution3D._sums` walks the halves it downloads at a checkpoint. ReducePass runs last, so
  it cannot answer "which pass moved it": that wants a reduce dispatch per checkpoint, not a row.
- Three shapes refused a row and say why: `sea_surface_stats` (a median needs a declared range nothing
  supplies), `lava_shell_diag` (five outputs over two gates), `rock_radial_profile` (a binned reduction
  plus a gravity march in one walk).
- `_liquid_mirror`, `_ice_mirror` and `_vapour_mirror` are each a per-cell product of two buffers the GPU
  already holds. Three `LAChannels.derived_buffers()` entries written by `StateDerivePass` delete all three
  loops with no reduce row at all; waiting for their five consumers to convert is a choice, not a blocker.

The ops these sweeps still need, so a lane adds them once rather than four times: `Mask.GROUND` / `Mask.AIR`
(open with solid at the gravity-below slot — `nbr_solid` already binds the neighbour table); `Op.COUNT_LT`;
a below-neighbour comparison, which covers `pressure_inversions`, `pressure_audited` AND the momentum
buoyancy book; a six-face gradient for the momentum PGF book; derived `speed`, `lat` and `alt` channels,
after which every latitude and altitude band is an ordinary row using the existing `gate_lo`/`gate_hi`.

Free today, no new op: `momentum_vec` is three `SUM` rows on `vel_*` with `aux: "air"`, weighted, OPEN;
`momentum_mass_kg` is one. **Coriolis then costs nothing** — it is linear in v, so it is
`spin × momentum_vec × -2Ω` on the CPU, and the per-cell accumulation is pure waste.

## 2. Collapse the per-cell kernels into one dispatch

Seven passes are dispatched per step. `MaterialFieldGeotherm3D` is the next one to go and it is not even a
kernel: `_rebuild()` computes `silicate[c] * rho_rock * vol[c] * w_per_kg`, in which only `silicate[c]`
varies per cell, then compacts a list and hands joules to the sparse inject queue from GDScript on the
gravity solve's cadence. Radiogenic heating is a volumetric source, heat appearing in proportion to the rock
a cell holds, and it is one term in the kernel beside the rest. Keep `LARadiogenicDecay`, which is the real
physics of a decaying nuclide store; delete the module, the list, the queue round trip and the separate
cadence.

`CellListPass` is the seventh, and it stays a pass until the compaction becomes a mode of `transport.glsl`:
`check_binding_collisions.sh` fails any pass naming two kernel paths, so it cannot simply be folded into
`TransportPass`. The compaction needs workgroup-shared memory and barriers in uniform control flow, which
`PASS_GRAIN` shows a transport mode can carry.

The target is six: gravity, derive, pressure, transport, reactions, reduce.

## 3. Give the RADIATE row a column, so radiation crosses more than one cell

In `transport.glsl`'s gather, `gained += in_amt * absorptivity` keeps a neighbour's emission in proportion
to this cell's own absorptivity and DROPS the rest: a photon the adjacent cell does not absorb never
reaches the one beyond it. The mean free path is one cell by construction, so the substrate has no
transmission, no outgoing longwave at the top of the atmosphere, and no way to price a CO2 doubling —
`solar_incident()` already marches a real slant path with `la_step`, and the longwave half needs the same
march. `BAND_COUNT` and `TEMP_COUNT` in `docs/MODEL_PARAMETERS.md` name that solver as what deletes them.

## 4. Move the lightning column march into the kernel

`MaterialCharge3D._scan` walks the whole air column above every ground cell every step. It belongs in
`transport.glsl`, whose OHMIC row already marches it in `column_field()`, publishing a strike list. Same
march, same `RREA_THRESHOLD_V_M`.

## 5. Move what the device cannot take into the GDExtension

GDScript keeps bindings. `gdextensions/localagents/` already builds; a class is a `.cpp`/`.hpp` pair, one
`SRC` line and one `register_class`.

- The tables: `Substances.gd`, `AbsorptionBands.gd`, `PhysicalConstants.gd`. Move
  `check_physical_constants.sh`, `check_model_parameters.sh` and `gen_shared_constants.py` in the same
  commit — a gate left parsing a deleted file is a gate that cannot fail.
- The seed-time serial work: `MaterialFieldLakes3D`'s priority flood, `MaterialFieldSolidCache3D`'s SDF
  spot check and file hashing, `MaterialFieldRegolith3D.compute`'s burial march, `FieldEnthalpySeed3D`'s
  per-cell mixture walk and its dynamic `f.get("_" + name)` lookup.
- The driver: `MaterialSphereGPU3D.gd` and `MaterialField3D.gd`. Last, after the pass seam settles.

## 6. Make `_read_channels`'s SLOW block read `slow_channels()`

It hardcodes `["silicate", "fert"]` and `["biomass", "cement", ...]`, so `slow_channels()` is a view nothing
consumes and `porosity` never gets its coarse readback.

## 7. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in one of fourteen uniform-set
builders. `check_binding_collisions.sh` check 4 already holds a pass to indices its kernel declares, so what
is unheld is narrower: that one index names the same BUFFER on both sides. Build `sim/material/Bindings.gd`
on `Channels.gd`'s shape — a `static func rows()`, never a `const Dictionary` built from another script's
constants — and one gate absorbing the hand-written binding stanzas. Mutation-test it both ways.

## 8. Make `lint` distinguish "could not run" from "violated"

Every gate runs and the failures are summarised, so the fail-fast half of this is already done. What remains:
the harness collapses every gate's exit code into `exit 1`, so the exit-2 contract asserted in about ten gate
headers and in `lint.yml` is not observable. Fix the harness, not the gates.

## 9. THE RUN NEVER FINISHES. TAKE THIS FIRST — nothing else here can be checked by running the planet.

No arm prints `SIM_REPORT`: not 3, 5, 8, 20 or 200 steps, and not at a raised `LA_RUN_TIMEOUT`. Every lane
this session gated on `lint` because of it. There are TWO defects, and they were separated by bisect.

**9a. The seed does not finish.** The log stops after `EVENT_TRACKER=`, before the first report. Bisect:
the run reaches `PRESSURE_BROKEN=` at the commit before the seed-order change and stops before it at the
merge that landed `solve_seed()`. So the suspect is `MaterialFieldSphereStep3D.seed_tick()`'s new order or
`LAMaterialFieldGravity3D.solve_seed()` itself.

`solve_seed()` calls `rd.submit()` and `rd.sync()` on the driver's device without touching
`LAMaterialSphereGPU3D._pending`, which is that flag's whole job — every other path guards on it, and
`_step_checkpointed()` re-establishes it deliberately after doing raw submits. Routing the seed solve
through a driver method that flushes first is the right shape and the device's owner should do it.
**Tried and it did NOT clear the hang, so the pairing is not the cause — do not stop there.**

**9b. Past the seed, the report sweeps stall it.** Before 9a existed, the run reached `PRESSURE_BROKEN` —
printed partway through `_heavy_block()` — and then went quiet in `_momentum.report()` or
`LAMaterialFieldLedger3D.report()`. Item 1 is that fix; the momentum ledger is the heaviest single sweep.

`_is_final_frame()` reading physics frames while the run ended on steps is FIXED. It made every physics
frame after the seed recompute the whole heavy block instead of every sixty-fourth, which made 9b far
worse and is why it looked like a hang. `LASimLoop` does not advance `_step` while a seed holder is
registered, so the two clocks diverge by the length of the seed.

A 1-step arm does complete, then exits 125 — `RUN_HUNG_AFTER_REPORT`, the exit path stalling after
`LA_RUN_COMPLETE` prints. Third defect, smallest, probably independent.

## 9b. Loose ends left by the lanes that found them

- `FieldAttributionRecords3D.SILENT_HEAT_PASSES` now lists only `"fungus"`, and there is no `FungusPass` in
  `PASS_SCRIPTS`. That instrument's silent-heat check names no live pass, so it cannot fire. Wire it to the
  surviving passes or delete it. Removing the constant outright breaks `check_parse_all` — it is read from
  inside its own file.
- `MaterialSurfaceSeed3D.seed_initial()` walked `below` before gravity existed, same as the regolith did.
  Moved, but litter and detritus have never seeded in any prior run, so any past reading of them is fiction.
- Check that `_is_final_frame()` actually fires for the VoxelWorld scene, not only the demo harness: if it
  does not, the closing report a run is judged on can be up to 64 frames old.
- `check_shaders_compile.sh`'s kernel floor is `docs/SHADER_FLOOR` and `write_ceilings.sh` lowers it. Do not
  bake a count back into the gate.
- `LAMineralStamp3D._scan` restarts at cell 0 every scan and breaks on a budget, so the low-index prefix is
  re-walked and high-index cells are starved. It needs a rolling cursor at minimum.
- `LASpatialIndex.rebuild_if_stale` rebuilds a whole group's dictionary every frame it is touched rather
  than tracking per-node cell changes, and `LASimReport.snapshot` deep-copies its events and gauges on every
  call. Both are constants, not asymptotes.

## 10. Two constants that are not what they name

- `AMBIENT_O2_DENSITY_KG_M3` is air at a different temperature from `AIR_DENSITY_KG_M3`, and it is the unit
  definition of the `o2`, `co2` and `n2` channels, so correcting it rescales every gas total.
- One radiogenic rate covers every rock and there is only one rock. Continental crust is enriched about
  fifty times over depleted mantle, so a second rock substance with its own abundance is what makes crust
  and mantle differ. The rate is also present-day and this body has no age.

## 11. Rebuild frost shattering from the phase boundary

`LAGeoRecords` has no `RM_DEFICIT_BELOW_THRESHOLD` record, no `FROST_*` constant survives, and the rate
model is declared in `ReactionDefs` and used by nothing. The mechanism is ice segregation, not expansion in
a sealed pore. Invert `LASubstances.melt_c_at`: the pressure ice exerts at undercooling dT is
`dH_fus * dT / (T_m * dv)` with `dv = 1/rho_ice - 1/rho_water`, every term already in the table, about
13.5 MPa per kelvin. Rock fractures where that passes its TENSILE strength, which is a measured property
`Substances.gd` should carry with its source. Bound the extent by the pore water available to freeze, and
let deep cold starve the mechanism out of the state rather than a cutoff. Observed damage peaks at -3 to
-10 C: if the law disagrees, that is the finding, not a thing to tune.

---

## How to run

`scripts/agent_harness.sh sim [--frames N] [--seed N] [--path DIR] [--fauna] [--full] [--raw]` — off-screen,
streamer off, re-imports when a kernel changed, and refuses to print if the run logged an engine error. Exit
codes are listed at the top of `scripts/run_sim_offscreen.sh`.

`scripts/agent_harness.sh lint` is what CI runs. `scripts/editor_scan.sh`, never a bare
`godot --headless --editor`: two concurrent scans segfault.

Make every worktree with `scripts/new_worktree.sh`, which symlinks the compiled `bin/`, imports the `.glsl`
kernels and editor-scans. Without the import the GPU field is dead and the report still looks fine.

A gate that passes with the feature disabled is not a gate. Mutation-test every gate you write, both ways.
