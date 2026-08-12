# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** A finished item is deleted the moment it is
committed; git is the record of what was done. When an entry is FALSE, fix it in place and say what it
claimed, so nobody re-derives the same wrong conclusion.

**Physics work is tracked in `docs/PHYSICS_TODO.md`.** This file holds what is not physics: how to run, the
branch state, the order of work, what is settled, and where things live.

**NO NUMBERS. RULE 1e.** Do not report a total, a drift, a percentage, a mean, a count or an absolute
reading — to the maintainer or in this file — until this list and `PHYSICS_TODO.md` are empty. Everything
this substrate emits is a property of the breakage, not of a planet. Report what was DELETED and what was
FIXED. A number that matters belongs in a gate.

---

## ▶ START HERE

**THE GOAL IS THE ACTUAL EARTH, to a chosen granularity.** Every constant is a measured property of real
matter, every initial condition describes what the planet was made of, and **temperature, atmosphere, ocean
and habitability are OUTPUTS, never inputs.**

**0.4 is the PLANET. Creature work is 0.5** — not lower priority, premature. But **a defect you find is
FIXED, wherever it lives.**

**Read `CLAUDE.md`'s rules 1 through 5 before touching anything.** Rules 2, 3, 4 and 5 were missing from
this branch until 2026-08-12 — they existed only on an unmerged branch, so the two rules that forbid arguing
from a caller list and from a red gate were not in front of anyone. They are in now.

### State

**Everything is on `feature/enthalpy`.** The branch does not parse and there is one reason left:
`LAHeatCapacity` is deleted and the field still stores `temp`. That conversion is task 7 below.

**The grid migration is done.** The Cartesian box is the only grid: `MaterialSphereGPU3D` takes an
`LAVoxelGrid`, gravity is the solved Poisson field read per cell, and `check_no_privileged_axis.sh` passes
— no slot means "up", no column is an array stride. `sim/sphere/` is deleted, and with it the seam-repair
graph matching, the tangent basis and its parallel transport, the radial shell stack and `link_partner`.
The grid is METRES, because the gravity solve is SI.

**`check_physical_constants.sh` is red on ONE line, on purpose.** `AMBIENT_O2_DENSITY_KG_M3` is now derived
from the air density and mole fractions this file already declares rather than stored a second time and 4%
adrift; `CO2_UNIT_DENSITY_KG_M3` moved with it, and `kernels3d/heat3d_solar_sphere3d.glsl` carries a
hand-copied `RHO_CO2_UNIT` that must be set to the authority's value. Clearing it is one literal.

**`LATransportRecords` and `LAFieldTotals` have no GDScript caller.** `max_fill` feeds a `transport.glsl`
push constant nothing fills; `substance_kg` is reached only from `scripts/check_sphere_grid.sh`. Wire or
delete — say which.


**Kernels: 24 to 10.** One `transport.glsl` plus a record table absorbed the seven gathers, then diffusion,
convection, conduction, radiation and momentum. What made them look different was the coordinate system:
a hardcoded "down" slot, a per-cell arc length for the lateral run, a donor/receiver volume ratio, and a
lookup for the reverse link. On a uniform grid all six faces ask one question and the opposite of `d` is
`d ^ 1`.

Two collapses worth not re-deriving:
- **Convective adjustment IS the angle of repose** — a flux across a face once the pair exceeds a threshold
  gradient. One threshold is a temperature, the other a mass.
- **Wind IS the momentum equation.** Momentum is six transport rows: three down the pressure gradient,
  which is the pressure-gradient force written as a flux, and three diffusing, which is eddy viscosity.
  Velocity is derived.

**Units.** The fitted metre, the held Earth gravity, `PLANET_SCALE` and `SURFACE_G` are gone; the body is
declared by radius and mean density and `g` is solved. A channel amount is MOLES, so a record's
coefficient is stoichiometry rather than a density ratio between two invented units.

---

## THE ONE TASK — ENTHALPY IS THE STATE

**Indivisible. One owner. It cannot be split by file or by channel, and a partial rename produces a planet
instead of an error.** Everything else queues behind it.

`temp` becomes `h_j_m3`. **Rename the buffer in the same commit that changes its unit**, so an unconverted
kernel fails to COMPILE rather than evaluating the phase ladder against the wrong quantity.

**The curve is already built on both sides and gated** — `LASubstances.enthalpy_at` / `enthalpy_to_state`,
`kernels3d/enthalpy.glsli`'s `la_state_to_enthalpy` / `la_enthalpy_to_state`, held equal by
`check_enthalpy_ssot.sh`, which also checks the phase ladder appears in the same ORDER on both sides. The
GLSL twin stops at gas; the high rungs need bisection (`PHYSICS_TODO.md` A2). This is wiring, not research.

**Every `LAHeatCapacity` consumer is a DELETION, not a rewrite.** With enthalpy stored there is no set of
channels that carry heat, because heat is no longer spread across channels:

| Consumer | Becomes |
|---|---|
| the group views, `channels()` unions (`Seal3D`, `FieldLedgerRecords3D`, `EnergyProbe3D`) | deleted — nothing needs the list |
| `field()` / `legs()` / `live_map()` capacity arrays (`FieldLedgerFold3D`, `EnergyLedger3D`) | deleted — the stock is the sum of `h * V` |
| `EnergyBudget3D`'s capacity report | deleted |
| `Inject3D`'s `capacity * volume * dT` | joules are `(h_target - h_now) * V` |
| `WaterSlumpLavaPass`'s per-row rc upload | deleted — transport carries `h` |
| the `heat` column in `Channels.gd` and `heat_group()` | deleted |

**Also deletes:** `PhaseRecords.gd` entire, `rc_shared.glsli` (done), `HeatCapacity.gd` (done), its SSOT gate
(done), and the `water`/`moisture`/`snow` and `rock_fill`/`lava` channel pairs — one substance each.

- **Acceptance, and it is binary:** seed a column of liquid water above freezing, remove heat at a constant
  rate, and `temp` must **pin at 0.0** for exactly the span `m * L_fus / rate` pays for. Latent heat becoming
  structural cannot be faked. If it does not pin, the conversion is not done.
- **`rc_of` coming out is the acceptance test for the whole stage, not a step in it.** It had 20 consumers.
  If it cannot come out, the root is not fixed — say so rather than restoring it.
- **A MOISTURE→WATER condensation record does not exist on either lineage.** Evaporation debits the latent
  heat of vaporisation in three records and the return leg paid nothing. Do not add a record and a capacity:
  once `h` is the state the return leg cannot be skipped, because there is no separate temperature to forget.

---

## WHAT IS LEFT

**G — the grid. Done.** The kernels run on `LAVoxelGrid`, gravity is solved, the axis gate passes,
`METRES_PER_MODEL_UNIT` / `PLANET_SCALE` / `SURFACE_G` / the held `STANDARD_GRAVITY_M_S2` are gone, and so
are `solid_angle`, `cell_vol`, `face_area`, `link_arc`, `link_partner`, the tangent basis and its parallel
transport, the shell table and the whole of `sim/sphere/`. *Left:* `BiomeTextureBaker` still calls
`shell_of` on a grid class that no longer exists.

**P — pressure. Done.** `kernels3d/pressure.glsl` marches along -g accumulating the cell's own bulk
density times the solved `|g|`. It replaced a kernel that gave a buried cell the weight of the AIR column
at ambient air density. *Acceptance still owed:* pressure monotonically non-decreasing inward, which needs
a run.

**M — moles. Half done.** `mol_per_unit` and `unit_ratio` are deleted and the reaction table is
stoichiometry. *Left:* one applicator evaluating every record against the same starting state, so
`cap_slot` deletes. *Acceptance:* permute the record order, element totals bit-identical. **Do not read
"conserve elements, derive species" literally** — deriving species by equilibrium returns zero biomass and
looks clean; a living cell is not at chemical equilibrium. The defect named is the UNIT.

**E — enthalpy. The one blocker left.** The field still stores `temp` and `LAHeatCapacity` is deleted, so
the branch does not parse. Needs the mixture inverter, then `temp` becomes `h_j_m3` in the commit that
changes its unit, then the latent-plateau gate.

---

## THE SEAMS — do these when their file is free

- ~~Two constants held equal by a comment against `heat3d_solar_sphere3d.glsl`.~~ **FALSE now**: that
  kernel is deleted and the RADIATE row has no `SURFACE_FILL_MIN` or `ICE_ALBEDO_GAIN` to match.
  `MaterialFieldEnergyBudget3D.K_SURFACE_FILL_MIN` / `K_ICE_ALBEDO_GAIN` are the only copies left and are
  matched by nothing — delete them with the CPU column oracle they serve.
- **A binding registry.** SSBO binding numbers have no owner: a bare integer in GLSL `layout(binding = N)`
  and a second bare integer in one of fourteen near-identical uniform-set builders, held equal by nothing.
  Two lanes once claimed the same number. `reactions_sphere3d.glsl` is the sole kernel binding 30–33 to
  different channels than the other eleven, and one lane had to renumber `org_h`/`org_o` mid-merge to make
  the file compile. Build `sim/material/Bindings.gd` on `Channels.gd`'s shape — a `static func rows()`, never
  a `const Dictionary` built from another script's constants — and one gate absorbing the hand-written
  binding stanzas in `check_shell_table.sh` and `check_face_area.sh`. **Mutation-test it both ways.**
- **A branch-integration gate.** This whole reconciliation existed because nothing checked branch state.
  Four pure-git checks, wired into `lint`: the dev branch must contain `main`; every local branch ahead of it
  must be listed in a tracked `docs/OPEN_BRANCHES` with a reason and a date; a branch more than ~15 commits
  ahead or ~7 days old fails; every worktree maps to a listed branch. Reconciling at five commits is minutes.
- **Split the conservation VERDICT from the provenance verdict, at the process boundary.** The GDScript half
  is done — `conservation_violated`, `conservation_unmeasured`, `conservation_starved` and
  `conservation_audited` are separate keys now. But `scripts/run_sim_offscreen.sh` greps only
  `CONSERVATION_VIOLATION=` to set its exit code, so **a starved leg still exits 0** — a clean-looking pass
  over a gate that never ran. Give `CONSERVATION_UNMEASURED=` its own code, ordered so a real violation still
  wins. *(Corrected 2026-08-12: this used to claim a starved leg "fires CONSERVATION_VIOLATION for a
  provenance reason". False. It fires nothing.)*
- **`lint` is fail-fast and collapses every gate's exit code to 1**, so "exit 2 means the gate could not run"
  — asserted in about ten gate headers and in `lint.yml` — **is not observable from the harness's exit code.**
  A gate that cannot run is indistinguishable from a violation. Fix the harness, not the gates.
- **The conservation ceiling has the wrong units.** `check()` compares a per-step rate against a
  single-sample round-off floor, and round-off does not accumulate linearly. The fix is one line — compare
  the magnitude, not the magnitude over elapsed — and it makes the gate tighter than either lineage on most
  substances. It was deliberately not taken inside a merge resolution because against the current substrate
  it fires on every substance and drives every run to the violation exit code, destroying the signal of every
  other gate. **Take it once the conversion lands.**
- **`scent` is an unowned hole.** `Channels.gd` has no scent row, so the transport set could not be built and
  the channel is gone, while the deposit/decay constants went with it. Either scent is a field channel with a
  row like every other, or it is deleted outright. It cannot stay half-present.
- **`_read_channels`'s SLOW block hardcodes its channel list**, so `slow_channels()` is a view nothing
  consumes and `porosity` never gets its coarse readback.
- **Two parallel cell-volume subsystems both survived** — `FieldTotals.gd` + `kernels3d/cell_geom.glsli`
  against `MaterialFieldCellVolume3D` + `MaterialFieldFaceArea3D` + `kernels3d/cellvol.glsli`. On a uniform
  box every cell has one volume, so one of them is pure ceremony. One has to die.
- **`AMBIENT_O2_DENSITY_KG_M3` is air at a different temperature from `AIR_DENSITY_KG_M3`**, which is now the
  cited ISA value. It is the unit definition of the `o2`/`co2`/`n2` channels, so correcting it re-scales
  every gas total — a maintainer call, not a merge resolution. The fix is one flat expression.
- **Five interior constants are now referenced by nothing** — `INNER_CORE_C`, `CORE_MANTLE_BOUNDARY_C`,
  `UPPER_MANTLE_C`, `GEOTHERMAL_GRADIENT_C_PER_M`, `GEOTHERMAL_GRADIENT_C_PER_KM`. They existed to seed and
  hold a prescribed geotherm, which is deleted. Delete the values too; `GEOTHERMAL_FLUX_W_M2` stays as the
  real-Earth figure the emergent surface flux is read against.
- **`RADIOGENIC_W_PER_KG` carries no citation comment**, and `docs/PHYSICS_AUDIT_2026-08-09.md` says it is
  the present-day value on a world meant to be young. It is now the only interior heat source, so it needs
  a source named beside it.

---

## DEAD OR LYING — delete, do not preserve

- **`tests/cmp_channels.gd` is already broken.** It reads `PAIR_CHANNELS` / `SINGLE_CHANNELS` /
  `SITUATIONAL_CHANNELS` / `SLOW_CHANNELS`, which became static functions.
- **`_bufs["face_area"]` is bound by zero passes and `facearea.glsli` is included by zero kernels.**
  Binding 42 is reserved-but-unconsumed — the surviving artefact of the two-lanes-one-number incident.
- **`_wnext` is dead** — a declaration and two allocation lines; no element is ever read or written.
  **`_snow`, `_susp` and `_porosity` are never allocated at all**, so on a CPU-only run every consumer's
  size guard silently skips them.
- **`_charge_woke` is written in two places and read nowhere.** The compute-bubble early-out it exists for
  was never wired.
- **`CreatureLod`'s `LA_NO_PHYS_LOD`** keeps a superseded LOD tier reachable — `MID_LOD_D2` and `FAR_LOD_D2`
  are read only inside that branch — and it gates on `OS.has_environment`, which is true for `env FOO=`.
- **`SimRng.rand_dir()` advances the generator three times and counts one draw**, so the determinism probe
  under-reports any divergence involving it.
- **`ReactionThermo.EXP_LIMIT` and `reactions_sphere3d.DG_EXP_LIMIT` are held equal by a comment.**
- **`EcoSurfacePass.SCENT_DECAY`-style array literals are invisible to the constants gate** — it examines
  only scalar `const` declarations, so a list of modelling choices passes unexamined. So do `var` and
  `@export` defaults, and `// LAPhysical.ANYTHING` acquits whether that symbol exists or not.
- **`deficit_cause` labels a per-genome thermal band failure as "starvation"** now that the band is
  heritable; the hyperthermia and hypothermia tests still compare against the envelope edges.
- **`lava_phase_sphere3d.glsl` wants each shell's own thickness, not the uniform grid spacing.** Its
  capacity term multiplies a per-volume quantity by a length, so the length must be metres; the shell table
  exists and the kernel does not read it.
- **`MOISTURE_DIFFUSE` differs from `EDDY_DIFFUSE`.** Eddy mixing is a property of the flow, not of what is
  suspended in it, so one parcel cannot stir vapour harder than it stirs oxygen. Neither value is derived,
  so picking one is a physics decision, not a merge resolution.
- **`world_ready()` is defined nowhere, so the ambient-disaster readiness gate has never once run.** The
  director guards on `has_method("world_ready")`, which is false, so the guard is skipped and it can seed a
  tornado mid-terrain-generation. Both lineages' comments claim it routes through a life-independent spawn
  check. One forwarder on the composition root closes it.

## PHENOMENA THAT ARE STILL CAUSED RATHER THAN OBSERVED

A named phenomenon belongs in a detector that reads the field and says "this is happening". The tell is a
verb in a function name. These four survived the reconciliation because BOTH lineages had them, so no merge
could decide them:

- **`PlateTectonics._maybe_event`** calls into the disaster spawner on a fixed drumbeat with a rarity roll
  deciding whether a convergent margin gets a volcano. Melt should come from crustal thinning and the
  geotherm, with no boundary classifier and no dice.
- **`VoxelSettingsApplier._seed_ambient_disaster`** spawns thunderstorms, tornadoes, hurricanes and volcanoes
  weighted by a `climate_harshness` setting.
- **`Volcano`** injects no matter any more, and still emits a constant-magnitude tremor every tick whether or
  not anything is erupting. A detector would read the field's own state. `Earthquake` has the same shape.
- **`Flood.surge` / `_pump_cloudburst`**, and the same in the hurricane and thunderstorm actors. These at
  least debit the footprint's own water, so they move matter rather than create it — but a cloudburst is
  pumped rather than observed.

## DECLARED DEPARTURES — the maintainer's to keep or kill

- **`SystemOrbits.KNOCK_GAIN` multiplies the momentum an impact hands the orbit**, because a small body
  genuinely cannot move a planet and the code says so openly. It is a conservation-of-momentum violation
  carried by inheritance. `TIDE_AMP` in the same file is labelled a justified fake.

## Claims struck — do not re-derive these

- ~~"`org_h`/`org_o` are allocated privately by `ReactionsPass._ensure()` and invisible to readback,
  residency and the seal"~~ — stale. Both have mirrors, rows in `Channels.gd`, and are seeded; `_ensure` was
  a dead fallback and is gone. They remain WRITE-ONLY, absent from `_apply_readback`, which is the real half.
- ~~"`CLAUDE.md` says `MaterialField3D.gd` is 1309 lines"~~ — it was already under the soft limit before the
  reconciliation. The extract-only rule stands on its own; the number motivating it was stale.
- ~~"the H2O conservation book is three-quarters masked"~~ — both lineages fixed it independently. The fold
  computes a mask-free total for EVERY channel plus an open-cell twin. The masking defect that was still live
  sat on carbon, in the report, and is fixed.
- ~~"`agent_harness.sh sim` is the one run command"~~ — it was, but it ATE ITS FIRST ARGUMENT, so the long
  arm could not be run through it at all and a `--raw` request was silently discarded. Fixed.
- ~~any figure recorded in this file before 2026-08-12~~ — see RULE 1e. Deleted rather than restated.

---

## HOW TO RUN

**`scripts/agent_harness.sh sim [--frames N] [--seed N] [--fast N] [--path DIR] [--fauna] [--full] [--raw]`**
— off-screen, streamer off, re-imports when a kernel changed, counts engine errors FIRST and refuses to
print if there are any. Never launch godot windowed directly; it steals the keyboard. `--fixed-fps` is an
engine flag and goes before the `--`; the harness handles it.

**Exit codes:** 0 clean · 2 usage · 3 stale shaders · 4 engine errors, output withheld · 5 a UI node without
`--ui` · 6 grid invalid · 126 conservation violation. **A starved gate still exits 0 — see the seams.**

**`scripts/agent_harness.sh lint` is what CI runs**, and it now runs the union of both lineages' gates,
including `check_model_parameters.sh`, which had never once executed. Look for the force-load marker before
believing a run: an editor scan alone has passed a file with a hard parse error while a whole transport CA
silently did not run.

**In a fresh worktree, in this order, or your measurements are fiction:** `scripts/new_worktree.sh`, which
symlinks the GDExtension binaries, imports, and editor-scans. Never a bare `godot --headless --editor`; two
concurrent scans segfault. Every command routes through `ensure_worktree_ready.sh` now, which exits rather
than let an unprepared tree run.

**A gate that passes with the feature disabled is not a gate.** Build the disabled arm. **Mutation-test
every gate you write** — this repo has shipped gates that could only pass, four never wired into lint at all
and three reporting success on zero files for months.

---

## WHAT IS SETTLED — do not rebuild these

*(The most dangerous list here, because work AVOIDS what is on it. An entry that stops being true comes OFF.)*

- the six-slot neighbour table, axis tags with `d ^ 1` as the reverse — `sim/voxel/VoxelGrid.gd`, gated by
  `check_neighbour_slots.sh` and by `validate()` at runtime;
- the DEFS record engine's std430 layout — `reactions/ReactionDefs.gd`;
- reaction DIRECTION from Gibbs free energy, and Saha ionisation with law-of-mass-action dissociation;
- the phase curve's low rungs: sublimation, the triple point, Clapeyron melting, supercritical — derived,
  not declared, so Hess's law cannot be violated;
- the erosion transport law — no fitted constant, load moves in the same proportions as its water;
- the aquifer's capillary retention, and Kozeny-Carman conductivity from porosity;
- weathering as ice expansion and Arrhenius dissolution; lithification on real lithostatic pressure;
- the two-phase seal — matter and energy may be CREATED while SEEDING and only MOVED once SEALED, gated by
  `check_seed_phase.sh`, whose whole-mirror upload ceiling is now zero because every such upload is gone;
- ONE declaration of what a channel is — `sim/material/Channels.gd`, with the GPU's residency lists as views.

---

## 0.5 — CREATURES · 0.6 — THE FULL SOLAR SYSTEM

Parked. `docs/0.5_CREATURE_FEATURES.md`, `docs/ROADMAP_0.5.md`. Two things to establish first, both
unmeasured rather than broken: whether the food web works has never been observed with fauna enabled, and
SPACE does not regulate breeding — food and energy do, with a global cap on top.

0.6 makes the moving frame literal: the planet translates, bodies orbit, the moon is landable. The Cartesian
grid is the prerequisite and it is now the trunk.

---

## Where everything lives

- **Substrate:** `material/MaterialField3D.gd` (**extract-only**) + `MaterialSphereGPU3D` ·
  `sphere_passes/*` on the `SpherePass` base · `kernels3d/*_sphere3d.glsl` (authoritative) +
  `neighbours.glsli` / `enthalpy.glsli` · `MaterialReactions3D` + `material/reactions/` ·
  `material/Substances.gd` (the SSOT for matter) · `material/PhysicalConstants.gd` (append-only for agents;
  its expression parser has NO parentheses).
- **The grid:** `sim/voxel/VoxelGrid.gd` + `LAFieldGravity`. There is no second one.
- **The books:** `MaterialFieldSeal3D.gd` · `MaterialFieldConservation3D.gd` · `FieldLedgerFold3D.gd` and
  `MaterialFieldLedger3D.gd` (one ledger, mask-free totals with open-cell twins).
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`; three layer scenes,
  `Simulation.tscn` / `RenderLayer.tscn` / `UiLayer.tscn`, sim headless by default and UI opt-in via `--ui`.
- **North-star:** `CLAUDE.md` holds it. A second copy is a second thing to drift.
