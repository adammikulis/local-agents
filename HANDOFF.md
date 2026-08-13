# What to do next

Work down this list. An item is DELETED the moment it lands — this file is the remaining work, never a
record of what happened. `git log` is the record. Physics work is in `docs/PHYSICS_TODO.md`.

Nothing here is a claim about the state of the tree, because a claim rots and nobody notices. Check the
code, then act. Report what was deleted; report no number this substrate printed.

---

## 1. Finish what the gravity solve left

`MaterialField3D.solve_gravity()` returns `LAMaterialFieldGravity3D.step()`, whose whole body is `_bind()`
then `return false`. Delete the method, both call sites in `MaterialFieldSphereStep3D` — they are in
`seed_tick()` and `step()`, not `process` — and `mark_gravity_dirty()`, which loses its only caller with
the unreachable branch. Nothing depends on `step()` having primed the bind: `solves()`, `mean_g()` and
`down_at()` each call `_bind()` themselves.

**There is no aquifer.** `seed_tick()` runs `_compute_regolith()` before `activate()`, so `_gpu` is null,
`down_at()` returns `Vector3.ZERO`, and `LAFieldGeometry.burial_steps()` returns -1 for every solid cell.
The second loop skips every one, so `regolith`, `grain` and `porosity` stay zero and the water table is
never primed — and `darcy_resistance()` in `transport.glsl` reads `porosity <= 0.0` as `1.0e30`, so the
Darcy row is inert. `_seed_sea()` is a pure radius test and `MaterialFieldLakes3D.seed()` keys on
`radius_of()`; neither reads gravity, so the regolith is the only casualty.

`activate()` moves after `sample_solidity()` and before `_compute_regolith()`. It only CONSTRUCTS `_gpu` —
`down_at()` stays zero until the gravity buffer is drained — so a gravity-only dispatch has to run between
them. Not a full `step()`: `activate()` already sets `_ready_sim`, so a plain step would run
`_step_geotherm()` and burn simulated time, against `seed_tick()`'s contract that none has passed and
against `MaterialFieldSeal3D`'s SEEDING line. Acceptance: `porosity` non-zero after seed.

## 2. Reduce the rest on the device

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

## 3. Collapse the per-cell kernels into one dispatch

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

## 4. Delete the second radiative model

`MaterialFieldEnergyBudget3D` and `RadiativeColumn` re-solve the RADIATE row of `transport.glsl` on the CPU
over 64 sampled columns. Have the row accumulate its own per-cell absorbed and emitted watts, sum those,
and delete both files with `K_SURFACE_FILL_MIN`, `K_ICE_ALBEDO_GAIN` and `SAMPLE_COLUMNS`.
`tests/test_radiative_transfer.gd` drives `RadiativeColumn` directly and is repaired forward, never by
restoring it.

## 5. Move the lightning column march into the kernel

`MaterialCharge3D._scan` walks the whole air column above every ground cell every step. It belongs in
`transport.glsl`, whose OHMIC row already marches it in `column_field()`, publishing a strike list. Same
march, same `RREA_THRESHOLD_V_M`.

## 6. Move what the device cannot take into the GDExtension

GDScript keeps bindings. `gdextensions/localagents/` already builds; a class is a `.cpp`/`.hpp` pair, one
`SRC` line and one `register_class`.

- The tables: `Substances.gd`, `AbsorptionBands.gd`, `PhysicalConstants.gd`. Move
  `check_physical_constants.sh`, `check_model_parameters.sh` and `gen_shared_constants.py` in the same
  commit — a gate left parsing a deleted file is a gate that cannot fail.
- The seed-time serial work: `MaterialFieldLakes3D`'s priority flood, `MaterialFieldSolidCache3D`'s SDF
  spot check and file hashing, `MaterialFieldRegolith3D.compute`'s burial march, `FieldEnthalpySeed3D`'s
  per-cell mixture walk and its dynamic `f.get("_" + name)` lookup.
- The driver: `MaterialSphereGPU3D.gd` and `MaterialField3D.gd`. Last, after the pass seam settles.

## 7. Make `_read_channels`'s SLOW block read `slow_channels()`

It hardcodes `["silicate", "fert"]` and `["biomass", "cement", ...]`, so `slow_channels()` is a view nothing
consumes and `porosity` never gets its coarse readback.

## 8. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in one of fourteen uniform-set
builders. `check_binding_collisions.sh` check 4 already holds a pass to indices its kernel declares, so what
is unheld is narrower: that one index names the same BUFFER on both sides. Build `sim/material/Bindings.gd`
on `Channels.gd`'s shape — a `static func rows()`, never a `const Dictionary` built from another script's
constants — and one gate absorbing the hand-written binding stanzas. Mutation-test it both ways.

## 9. Make `lint` distinguish "could not run" from "violated"

Every gate runs and the failures are summarised, so the fail-fast half of this is already done. What remains:
the harness collapses every gate's exit code into `exit 1`, so the exit-2 contract asserted in about ten gate
headers and in `lint.yml` is not observable. Fix the harness, not the gates.

## 10. Find why a run costs render frames

`--run-frames=N` is simulated steps now and a 200-step run does not reach the end. Steps 0-6 complete in
tens of milliseconds, then step 7 blocks for about ten seconds and the process goes silent. `TIME_PHYSICS_PROCESS` and `TIME_PROCESS` together account for a small part of the frame
period, so the rest is engine work no script callback owns. Start at godot_voxel's main-thread apply and the
physics server. Item 1 may dissolve this.

## 11. Two constants that are not what they name

- `AMBIENT_O2_DENSITY_KG_M3` is air at a different temperature from `AIR_DENSITY_KG_M3`, and it is the unit
  definition of the `o2`, `co2` and `n2` channels, so correcting it rescales every gas total.
- One radiogenic rate covers every rock and there is only one rock. Continental crust is enriched about
  fifty times over depleted mantle, so a second rock substance with its own abundance is what makes crust
  and mantle differ. The rate is also present-day and this body has no age.

## 12. Rebuild frost shattering from the phase boundary

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
