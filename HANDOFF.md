# What to do next

Work down this list. An item is DELETED the moment it lands — this file is the remaining work, never a
record of what happened. `git log` is the record. Physics work is in `docs/PHYSICS_TODO.md`; what costs
more than it should is in `docs/PERFORMANCE_TODO.md`.

Nothing here is a claim about the state of the tree, because a claim rots and nobody notices. Check the
code, then act. Report what was deleted; report no number this substrate printed.

**AN ITEM CARRIES A SYMPTOM AND THE COMMAND THAT REPRODUCES IT, NEVER A DIAGNOSIS.** A symptom holds until
it is fixed. An assertion about a cause rots in silence, reads as progress, and spends the next reader's day
on the file it named. If you know the cause you are close enough to fix it, so fix it.
`scripts/check_doc_prose.sh` fails the build on a tracker that names one.

---

## 1. Reduce the rest on the device

`ReduceRecords` + `reduce.glsl` + `ReducePass` is the machine; the ledger fold and twenty-one report
sweeps already use it. Left:

- `MaterialFieldReport3D.surface_climate`, `MaterialFieldPhotoStats3D`,
  `MaterialFieldClimateSwing3D._site_stations`.
- `FieldPressureAudit3D`, `MaterialFieldMomentumLedger3D`, `MaterialFieldElementProbe3D`,
  `MaterialFieldOrganic3D`.
- `CLIMATE_MAX_CELLS` and its stride delete with the climate scan.
- `FieldPassAttribution3D._sums` walks the halves it downloads at a checkpoint. ReducePass runs last, so
  it cannot answer "which pass moved it": that wants a reduce dispatch per checkpoint, not a row.
- Three shapes refused a row and say why: `sea_surface_stats` (a median needs a declared range nothing
  supplies), `lava_shell_diag` (five outputs over two gates), `rock_radial_profile` (a binned reduction
  plus a gravity march in one walk).
- `_liquid_mirror` is a per-cell product of two buffers the GPU already holds, rebuilt per drinking
  creature per tick. A derived buffer written by `StateDerivePass` deletes the loop with no reduce row at
  all; its four consumers convert with it, and `drink` stops writing its depletion into a throwaway copy.

The ops are BUILT — `Mask.GROUND`/`Mask.AIR`, `Op.COUNT_LT`, `enum Nbr` (below, above, six-face gradient)
and the derived `speed`/`lat`/`alt` channels — so a sweep converts without adding machinery, and every
latitude and altitude band is an ordinary row on the existing `gate_lo`/`gate_hi`.

Free today, no new op: `momentum_vec` is three `SUM` rows on `vel_*` with `aux: "air"`, weighted, OPEN;
`momentum_mass_kg` is one. **Coriolis then costs nothing** — it is linear in v, so it is
`spin × momentum_vec × -2Ω` on the CPU, and the per-cell accumulation is pure waste.

## 2. Collapse the per-cell kernels into one dispatch

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

**And the two halves of the spectrum are modelled at wildly different fidelity.** Longwave gets 109 HITRAN
bands over 9 temperature slices. Shortwave gets ONE fitted grey number: `SW_OPTICAL_DEPTH = 0.2597`, applied
to the total air column in `shortwave_absorbed_frac`, which asserts that N2 and O2 absorb sunlight and that
doubling CO2 does nothing to the incoming beam. It is back-derived from Earth's own balance, in the file
whose header forbids fitted constants. `LAAbsorptionBands` already carries per-band SOLAR WEIGHTS, so the
shortwave side can read the same table the longwave side does.

`LAPhysical.ATMOS_OPTICAL_DEPTH` (0.835) is that constant's longwave twin and has NO reader anywhere in the
tree — the band model replaced it and nobody deleted it. A fitted number left in the constants authority is
worse than a bare one, because the next reader assumes it is load-bearing. Delete it with its
`PHYSICS_RUBRIC.md` mention.

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

## 7. Build the binding registry

SSBO binding numbers are a bare integer in GLSL and a second bare integer in one of fourteen uniform-set
builders. `check_binding_collisions.sh` check 4 already holds a pass to indices its kernel declares, so what
is unheld is narrower: that one index names the same BUFFER on both sides. Build `sim/material/Bindings.gd`
on `Channels.gd`'s shape — a `static func rows()`, never a `const Dictionary` built from another script's
constants — and one gate absorbing the hand-written binding stanzas. Mutation-test it both ways.

## 9. An instrument that cannot fire, and two re-sweeps

- `FieldAttributionRecords3D.SILENT_HEAT_PASSES` now lists only `"fungus"`, and there is no `FungusPass` in
  `PASS_SCRIPTS` — while `PRODUCERS` still names one for a channel `Channels.gd` declares as a single
  buffer. That instrument's silent-heat check names no live pass, so it cannot fire. Wire it to the
  surviving passes or delete it. Removing the constant outright breaks `check_parse_all` — it is read from
  inside its own file.
- `check_shaders_compile.sh`'s kernel floor is `docs/SHADER_FLOOR` and `write_ceilings.sh` lowers it. Do not
  bake a count back into the gate.
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

## 12. `LAFieldGeometry.above` and `below` are not inverses, and `PRESSURE_BROKEN` still fires on it

`slot_toward` snaps the local vertical to one of six axes, so across the diagonal where the snap flips,
`above(below(c)) != c`. The pressure column, `air_above`, `ground` and `burial_steps` all march that
relation, and no column integral can be monotone along a `below` step its own `above` step does not undo.
One vertical relation, built once and inverse by construction, is what removes it.

**A RADIAL COORDINATE SYSTEM IS NOT THE ANSWER. This is the maintainer's DECISION, not a law.** It has been
tried twice: the cubed-sphere shell was replaced by the uniform Cartesian box on purpose, and a
true-radial-ray traversal built to remove this very snap measured WORSE, because with no structural relation
to the grid's own vertical step, ray divergence across a density contrast dominates. Fix the relation on the
Cartesian grid.

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
