# What to do next

Work down this list. An item is DELETED the moment it lands — this file is the remaining work, never a
record of what happened. `git log` is the record. Physics work is in `docs/PHYSICS_TODO.md`.

Nothing here is a claim about the state of the tree, because a claim rots and nobody notices. Check the
code, then act. Report what was deleted; report no number this substrate printed.

---

## 1. Give the simulation its own loop

The field steps from `VoxelWorld._physics_process`, so a sim step happens only when rendering yields a
physics tick. Everything in this item is that one coupling.

- Make the sim own its clock and a substep budget in simulated time. `Simulation.tscn` is the seam;
  presentation subscribes to the step instead of driving it.
- Delete the bank clamp in `MaterialFieldSphereStep3D.process`
  (`_f._step_accum = minf(_f._step_accum, STEP_DT * (MAX_STEPS_PER_FRAME + 1))`). It discards simulated
  time whenever a frame runs slow.
- Delete the path from `VoxelSettingsApplier`'s `la_field_cadence` to `_field_cadence()`. A graphics
  quality preset decides how often the field steps.
- Delete `MaterialFieldGeotherm3D` and `_step_geotherm()` — see item 3. While it exists it runs once per
  frame while `_gpu.step()` runs up to twice, so a two-step frame deposits one step's worth of radiogenic
  joules, and `_epoch_years()` reads `REAL_SECONDS_PER_SIM_SECOND`, so the watch speed sets the decay rate.
- Derive the kernel timestep from simulated time. `SIM_SECONDS_PER_STEP` is `STEP_DT` times
  `LASimClock.REAL_SECONDS_PER_SIM_SECOND` written out as a literal, and `check_step_quantum.sh` only
  checks that it is a literal.
- Delete `--fast` and `VoxelInputController._fast`. It buys steps per frame through `Engine.time_scale`.
  Its readers are `sim_run.sh`, `check_determinism.sh`, `check_conservation.sh`,
  `check_observer_independence.sh` and `physics_score.sh`; `--fast` in `run_all_tests.gd` is a different
  flag and stays.
- Collapse `LASimClock._elapsed`, `MaterialFieldSphereStep3D._sim_s` and `_offer_s`, and
  `EcologyService._eco_s` into the one step counter.
- Move `WeatherSystem` out of `RenderLayer.tscn`. Its wind feeds moisture transport, charge and lightning,
  so a run without rendering has different physics.
- Extend `check_framerate_independence.sh` to ban `_physics_process` in a sim module, and to scan
  `game/world/` for the `_process` integrators it misses. Mutation-test both ways.

## 2. Reduce on the device, not in the interpreter

Every whole-grid sum, count, minimum, maximum, binned mean and percentile in `sim/material` walks a
downloaded mirror in GDScript. `ReduceRecords` + `reduce.glsl` + `ReducePass` is the one machine for all of
them; each item below is a set of rows in that table.

- `FieldLedgerFold3D` — `amounts`, `_count_presence`, `_crust`, `_energy`.
- `MaterialFieldQueries3D` — every total, count and peak. Delete `_liquid_mirror`, `_ice_mirror`,
  `_vapour_mirror` and `_melt_mirror`: they materialise a product of two device buffers six to eight times
  per report. Point queries keep their mirrors.
- `MaterialFieldChannels3D`, `MaterialFieldAtmos3D.refresh_aggregates`, `MaterialShock3D.shock_cell_count`.
- `FieldPressureAudit3D`, `MaterialFieldMomentumLedger3D`, `MaterialFieldElementProbe3D`,
  `MaterialFieldH2OBudget3D`.
- `MaterialFieldReport3D.surface_climate` and `_open_temp_stats`, `MaterialFieldPhotoStats3D`,
  `MaterialFieldClimateSwing3D._site_stations`, `MaterialFieldGeotherm3D._gradient`.
- Delete the sampling heuristics that only exist because those walks are expensive:
  `CLIMATE_MAX_CELLS`, and `MaterialFieldQueries3D.wind`'s stride.
- Lower both ceilings in `docs/GDSCRIPT_LINES_CEILING` and `docs/CELL_LOOP_CEILING` in the same commit as
  each deletion.

## 3. Collapse the per-cell kernels into one dispatch

Eight passes are dispatched per step, each its own pipeline bind, uniform set and barrier. Three of them
bind no neighbour buffer at all, and each reads at its own index what the one before it wrote there:
`state_derive` writes `temp`, `vel_*`, `rho_cond`, `n_gas_m3` and the phase shares; `solid_derive` reads
`silicate_melt` and writes `solid`, `cement`, `regolith`, `grain`; `rotating_frame` reads `vel_*`,
`rho_cond` and `n_gas_m3` and writes `mom_*`. No neighbour read means no barrier is owed between them, so
they are one kernel making one pass over the cell.

Two more are duplicate writers of a channel inside one step, and both are per-cell source terms, which is
what a reaction record already is:

- `rotating_frame` writes `mom_*`; `transport`'s PGF and EDDY rows write `mom_*`.
- `charge_separate` writes `charge`; `transport`'s OHMIC row writes `charge` and stamps `discharge`.

`grain_state` reads neighbour velocity for the shear, so it owes a barrier after `vel_*` is written — its
home is the neighbour gather `transport` already does, not a dispatch of its own. `pressure` marches a
column and stays.

`MaterialFieldGeotherm3D` is the same shape one step further out — it is not even a kernel. `_rebuild()`
computes `silicate[c] * rho_rock * vol[c] * w_per_kg`, in which only `silicate[c]` varies per cell, then
compacts a list and hands joules to the sparse inject queue from GDScript on the gravity solve's cadence.
Radiogenic heating is not a different kind of thermal behaviour: it is a volumetric source, heat appearing
in proportion to the rock a cell holds, and it is one term in the kernel beside the rest. Keep
`LARadiogenicDecay`, which is the real physics of a decaying nuclide store; delete the module, the list, the
queue round trip and the separate cadence.

The target is four dispatches: derive, pressure, transport, reactions.

## 4. Solve gravity on the device

`FieldGravity.solve` is red-black Gauss-Seidel in GDScript: eight sweeps, two colours, every cell, a
six-neighbour gather and a six-slot boundary scan in the innermost loop, then three more full sweeps for
`_measure`, `_residual` and `_gradient`. Its source term `FieldDensity3D.of` is a per-channel per-cell loop
calling the EOS. Two dispatches per sweep, one per colour, is the same recurrence — Jacobi is not, and
would be a different answer. Deletes `FieldGravity.gd`, `FieldDensity3D.gd`, most of
`MaterialFieldGravity3D.gd` and `MaterialSphereGPU3D._upload_gravity`.

## 5. Delete the second radiative model

`MaterialFieldEnergyBudget3D` and `RadiativeColumn` re-solve the RADIATE row of `transport.glsl` on the CPU
over 64 sampled columns. Have the row accumulate its own per-cell absorbed and emitted watts, sum those,
and delete both files with `K_SURFACE_FILL_MIN`, `K_ICE_ALBEDO_GAIN` and `SAMPLE_COLUMNS`.
`tests/test_radiative_transfer.gd` drives `RadiativeColumn` directly and is repaired forward, never by
restoring it.

## 6. Move the lightning column march into the kernel

`MaterialCharge3D._scan` walks the whole air column above every ground cell every step. It belongs in
`charge_separate.glsl`, publishing a strike list. Same march, same `RREA_THRESHOLD_V_M`.

## 7. Move what the device cannot take into the GDExtension

GDScript keeps bindings. `gdextensions/localagents/` already builds; a class is a `.cpp`/`.hpp` pair, one
`SRC` line and one `register_class`.

- The tables: `Substances.gd`, `AbsorptionBands.gd`, `PhysicalConstants.gd`. Move
  `check_physical_constants.sh`, `check_model_parameters.sh` and `gen_shared_constants.py` in the same
  commit — a gate left parsing a deleted file is a gate that cannot fail.
- The seed-time serial work: `MaterialFieldLakes3D`'s priority flood, `MaterialFieldSolidCache3D`'s SDF
  spot check and file hashing, `MaterialFieldRegolith3D.compute`'s burial march, `FieldEnthalpySeed3D`'s
  per-cell mixture walk and its dynamic `f.get("_" + name)` lookup.
- The driver: `MaterialSphereGPU3D.gd` and `MaterialField3D.gd`. Last, after the pass seam settles.

## 8. Give `scent` a row in `Channels.gd` or delete its readers

It has no row, so the transport set cannot carry it, and it cannot stay half-present.

## 9. Make `_read_channels`'s SLOW block read `slow_channels()`

It hardcodes `["silicate", "fert"]` and `["biomass", "cement", ...]`, so `slow_channels()` is a view nothing
consumes and `porosity` never gets its coarse readback.

## 10. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in one of fourteen uniform-set
builders, held equal by nothing. Build `sim/material/Bindings.gd` on `Channels.gd`'s shape — a
`static func rows()`, never a `const Dictionary` built from another script's constants — and one gate
absorbing the hand-written binding stanzas. Mutation-test it both ways.

## 11. Make `lint` distinguish "could not run" from "violated"

It is fail-fast and collapses every gate's exit code to 1, so the exit-2 contract asserted in about ten gate
headers and in `lint.yml` is not observable. Fix the harness, not the gates.

## 12. Fix the conservation ceiling's units

`check()` compares a per-step rate against a single-sample round-off floor, and round-off does not
accumulate linearly. Compare the magnitude, not the magnitude over elapsed. Take it after item 2, because
against the current substrate it fires on every substance and drives every run to the violation exit code.

## 13. Find why a run costs render frames

`--run-frames=N` ends in `LocalAgentDemoHarness._tick_run`, counted in physics frames, and a 64-frame run
does not reach it. `TIME_PHYSICS_PROCESS` and `TIME_PROCESS` together account for a small part of the frame
period, so the rest is engine work no script callback owns. Start at godot_voxel's main-thread apply and the
physics server. Item 1 may dissolve this.

## 14. Two constants that are not what they name

- `AMBIENT_O2_DENSITY_KG_M3` is air at a different temperature from `AIR_DENSITY_KG_M3`, and it is the unit
  definition of the `o2`, `co2` and `n2` channels, so correcting it rescales every gas total.
- One radiogenic rate covers every rock and there is only one rock. Continental crust is enriched about
  fifty times over depleted mantle, so a second rock substance with its own abundance is what makes crust
  and mantle differ. The rate is also present-day and this body has no age.

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
