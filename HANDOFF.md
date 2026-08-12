# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

**This file is the map of what is LEFT. It is not a history.** A finished item is deleted the moment it is
committed; git is the record of what was done. When an entry is FALSE, fix it in place and say what it
claimed, so nobody re-derives the same wrong conclusion.

**Physics work is NOT tracked here. It is tracked in `docs/PHYSICS_TODO.md`, which is the one list.** This
file holds the things that are not physics: how to run and measure, the staged roadmap, what is settled,
the open decisions, and where everything lives. If you find a physics defect, it goes in `PHYSICS_TODO.md`,
not here. This file duplicated that list for weeks and every copy rotted separately.

**KEEP THIS FILE AND `CLAUDE.md` CORRECT — THAT IS THE JOB, NOT A PERMISSION TO ASK FOR.** He cannot police
every line of two long documents; an agent that finds a wrong entry and asks permission has handed the work
back. Fix it, say what it claimed, and move on.

**Distrust the FRAMINGS here, not just the facts.** A previous version led with "every subsystem with a
conservation ledger conserves; every subsystem without one mints", and a full session was planned against
that sentence. Every factual claim in it was checkable. The framing was the problem — "minting" made
**creating matter from nothing** sound like an accounting discrepancy, so the plan it produced was to
measure the discrepancy better and to fix a shortage by adding another source. If a phrase here lets you
think about a physics violation without picturing the physics, replace the phrase.

---

## ▶ START HERE

**THE GOAL IS THE ACTUAL EARTH, to a chosen granularity.** Not a planet tuned to be pleasant. Every constant
is a measured property of real matter, every initial condition describes what the planet was made of, and
**temperature, atmosphere, ocean and habitability are OUTPUTS, never inputs.**

**0.4 is the PLANET. Creature work is 0.5** — not lower priority, premature. But **a defect you find is
FIXED, wherever it lives.** Nothing here licenses recording a broken thing instead of repairing it.

**Read `CLAUDE.md`'s first two rules before touching anything.** Delete what is wrong rather than preserving
it behind a flag, and get the maintainer's permission BEFORE writing any departure from real physics.

`sorting.py` at repo root is the maintainer's, untracked — leave it.

### State (2026-08-12) — `feature/live-breakages`

**THE TOP ITEM IS THE UNIT SYSTEM. THE SIMULATION IS NOT IN SI AND THE METRE WAS FITTED.**
`LAPhysical.METRES_PER_MODEL_UNIT = 168.6` is not derived — it is `R_d · 288.0 K / g / 50` to four parts in
a million. The 288.0 is the ISA standard SURFACE TEMPERATURE, so the length of a metre is defined in terms
of a temperature this project says must be an OUTPUT; and `R_d` comes from dry-air molar mass, built from
`AIR_MOLE_FRAC_O2 = 0.20946`, so the metre also depends on two billion years of photosynthesis. The prose
beside it claims "ten cells spanning three scale heights", which computes to 158.06 at the current grid, not
168.6. **The cost:** `PLANET_RADIUS = 500.0` model units is 84.3 km against Earth's 6371 km, while
`STANDARD_GRAVITY_M_S2 = 9.80665` is held — implying 75x Earth's mean density. The geometry and the physics
describe two different bodies, so gravity, hydrostatic pressure, the geotherm, Coriolis and the orbit cannot
all be right at once. **And there are TWO GRAVITIES:** `LAGravity.SURFACE_G = 55.0` ("matches old feel") for
actors and orbits, `STANDARD_GRAVITY_M_S2` for the field. Nothing reconciles them.

**THE ORDER IS FORCED: SI → one owner for the field state → pressure in every cell → enthalpy → moles.**
Phase depends on pressure and every pressure is `g · rho · length`, so migrating what a cell STORES while the
metre is fitted evaluates the phase ladder at pressures wrong by an unbounded factor — and it will not fail
loudly, it will produce a planet. The full plan, with a collision map, per-stage binary acceptance tests and
twelve named traps, is the migration plan produced 2026-08-12; its load-bearing correction is that **the EOS
table is NOT a prerequisite** — the inversion actually needed is the MIXTURE solve, and it is closed-form
(four breakpoints on this planet: water melt and boil, basalt solidus and liquidus), an O(4) sorted walk
that is cheaper than the `rc_of` it replaces.

**NOTHING ON THE PLANET REACHES 224 °C, SO ROCK CANNOT MELT.** `temp_max` 223.6 against basalt's 1200 °C
liquidus. Earlier readings of 810 and 1106 were artefacts of two defects now removed: the vent relabelled
bedrock as "lava" with no temperature change while the solidify leg froze it straight back and released
latent heat the melt leg never charged — a round trip CREATING the heat of fusion once per cycle — and
`MaterialFieldGeotherm3D` computed its boundary flux with a MODEL-unit length against per-metre constants,
168.6x twice over. Both phase legs now carry `GATE_BURIED` (both, or melt at depth is a one-way ratchet).
The open question is whether the geotherm delivers the right heat to the crust at all.

**`o2_total` RUNS AWAY: +1.3% at 60 frames, +77668% at 200, +363665% in another 200.** That is a growth
rate, not drift — the shape of a linear operator applied to its own output. It also contradicts
`PHYSICS_TODO`, which records oxygen FALLING by half and blames chemistry; that was measured through the
bare-fill-fraction pass probe, which is structurally incapable of seeing a volume-weighted transport defect.

**THE WORLD NOW HAS TWO PHASES IN CODE, NOT JUST IN INTENT (RULE 1c).** Matter and energy may be CREATED
while SEEDING and only MOVED or TRANSFORMED once SEALED. `LAMaterialFieldSeal3D.creation_allowed()` /
`note_creation()` decide it, `world_created` records what the planet was handed, `creation_after_seal` must
read empty, and `scripts/check_seed_phase.sh` (in `lint`) fails on a creation-class write that never asks and
on any whole-mirror `set_field()` upload. Two conservation violations reachable by environment variable —
`LA_MINT_PLANT_FOOD` and `LA_NO_BIOTA_DEBIT` — are deleted.

**THERE IS ONE DECLARATION OF WHAT A CHANNEL IS: `sim/material/Channels.gd`.** It was written down seven
times; the GPU's PAIR/SINGLE/SITUATIONAL/SLOW lists, `LAHeatCapacity`'s eight groups and
`LAReactionBalance`'s `SLOT_SUBSTANCE` / `INVENTORY_CHANNELS` / `LITHOSPHERE_CHANNELS` are all views of it
now, verified equal to the old lists before the switch. It immediately exposed two gaps: `org_h`/`org_o` were
allocated privately by `ReactionsPass._ensure()` and were invisible to the readback, to residency and to the
seal; and a DERIVED slot can still be matter (`SOIL_TOP` is water, `BEDROCK_BELOW` is silicate).

### Claims struck 2026-08-12 — do not re-derive these

- ~~"the atmosphere is leaking, `air` declines ~1.5%/step"~~ — **does not reproduce, and the instrument was
  blind to the real defect.** Before any fix the probe read 9573.176 → 9573.183 over 40 steps, flat to seven
  figures. `LA_PASS_PROBE` sums BARE FILL FRACTIONS, which a fraction-moving kernel conserves by
  construction; the quantity that was genuinely not conserved is the volume-weighted total and no probe
  measured it. There WAS a real air defect (raw fractions moved between cells of different volume, and each
  column re-settled conserving the sum of fractions rather than the mass) and it is fixed and gated.
- ~~"`molten_counts` / `fire_peak` / `fuel_total` are the instruments that lie"~~ — all three CLOSED.
  `molten_live` and `fire_live` carry provenance; `fuel_total` was deleted rather than unmasked, because
  `MaterialFieldElementInventory3D` already published the honest pair.
- ~~"`h2o_total` loses 22.6%"~~ — that was BURIAL. Three of its four legs were masked on `solid`. The honest
  drift is about +0.75%, a real source.
- ~~"the Darcy leg and sediment slump move temperature without moving heat"~~ — they moved NEITHER. Both
  carry enthalpy now, with per-kernel energy checks mutation-tested red in four separate ways.
- ~~"`mineral_total` is roughly conserved"~~ — it read ~0 because TWO ERRORS CANCELLED. Erosion pickup
  turned 1 unit of `rock_fill` into 1 unit of `susp`, creating mineral from nothing at 67% of the flux at
  40% porosity, and the gauge summed `rock_fill` bare and made the identical error on the other side.
- ~~"`erupt_source` injects mantle lava with no debit, booked as `mineral_minted`"~~ — false; it used the
  conserving queue, and `mineral_inject_minted` was always 0 from it.
- ~~"`enthalpy.glsli` is the GPU side of the phase ladder"~~ — it is included by ZERO kernels. It is correct
  dead code held equal to a live thing by a gate.
- ~~"`check_model_parameters.sh` is enforced"~~ — `CLAUDE.md` says so and **nothing calls it**.

### Claims struck earlier — do not re-derive these

Kept rather than deleted, because each one sent real work at a problem that did not exist.

- ~~"`--bare` CHANGES THE PHYSICS"~~ — the effect was real; the flag is gone. There are three scenes and two
  flags now (`--render`, `--ui`), and the seal fix removed the mechanism.
- ~~"`moisture` IS DEAD"~~ — FALSE. It reads `moisture_total` 2.7–20.3 and `cloud_cells` 9344–9840 in every
  arm measured. The claim rested on a comment saying the channel "was never in the GPU seed list", which is
  true and irrelevant: moisture starts at zero because it IS zero. What was actually happening is
  `bf710bd`'s finding — the shared tracer operator shed its downward flux into solid ground where nothing
  gathered it, so the vapour half of the water cycle drained as fast as it filled.
- ~~"`dust_total` reads 0"~~ — FALSE. It reads 2106–2300 in every arm measured.
- ~~"E1: THE AIRBORNE TRACERS CREATE MASS — four places left to look"~~ — CLOSED (`8cdc20bd`). It was not
  in the kernels at all. `LASphereGrid` uploaded a PERMUTED neighbour layout to the GPU while
  `link_partner` was built against the unpermuted one, so the two-pass gather read a slot that never
  answered. `neighbours_kernel_order()` is deleted. Every conservation figure recorded before that commit
  is dead, including the ones this file used to quote.
- ~~any `swing_diurnal_c` figure~~ — the instrument was aliased, sampling 2.0 times per rotation with 19
  alias events. It reads 6.0 samples and 0 alias events since `107b35f9`. The old numbers were not small
  measurements, they were not measurements.
- ~~"the planet's oxygen is roughly 37 000"~~ — that was the SEED, 1.0 per open cell, not a product. The
  true figure is 0.0 and nothing in the simulation has ever produced any.
- ~~The conservation DEBT TABLE~~ — every row of it is superseded. Re-measured on the unmodified tip
  `54f6e58`, `mineral_total` was **+149%**, not the recorded -0.0064%, and `o2_total` was positive where
  the table recorded -24.71%. The table was not fabricated — it was measured before the kernel collapse and
  nobody re-measured after — but no number in it survives, and E1 means the current ones do not either.
  `LAMaterialFieldConservation3D.DEBT` is the only place these live; do not keep a second copy here.
- ~~"the seal latches at field_step 9"~~ — it latches at 2, and no longer depends on renderer channel
  residency.
- ~~"three condition gates exist that no record uses"~~ — `GATE_SURFACE`, `GATE_OPEN_ABOVE` and
  `GATE_DAYLIGHT` are DELETED (`9ff2f97`), along with `DAYLIGHT_MIN`. `light_at()` stays: photosynthesis
  takes light as its rate DRIVER, not as a gate.
- ~~`opposite()`, and any instruction to compute a reverse link~~ — deleted; kernels use `link_partner`.
- ~~"`params.dt` is uploaded to `reactions_sphere3d.glsl` and never read, so every reaction rate is
  per-STEP"~~ — the first half was true and the upload is deleted; the second half was the wrong diagnosis.
  Five records already fold `real_seconds_per_step()` into their own `k`, so a kernel-side `dt` would
  double-count them. The real defect (two rate units in one table) is `PHYSICS_TODO.md` C3.
- ~~"`snow_cells` fell 1170 → 76 → 17 and nothing keeps snow on this planet"~~ — UNVERIFIED, not disproved.
  Every one of those figures predates the kernel-collapse bugs and the seal fix, so none of them measures
  the substrate that exists now. Re-measure before planning against it.
- ~~"`METRES_PER_MODEL_UNIT` and the geotherm's depth conceit are two live answers to how big this planet
  is"~~ — they are not in conflict. `MaterialFieldGeotherm3D._derive_gradient()` (`:208`) computes the
  exaggeration explicitly as `GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size)` and derives the
  gradient from it. The real defect is that the grid cannot RESOLVE the aquifer, which is `PHYSICS_TODO.md`
  D5.

Line-number citations in this file were re-checked on 2026-08-11 and most had rotted — the comment sweep
shifted every line in the kernels and `slump_sphere3d.glsl` no longer exists. **Cite an identifier, not a
line, unless the line is the point.** A grep resolves an identifier; nothing resolves a stale line number.

---

## HOW TO RUN AND MEASURE

**THE ONE RUN COMMAND IS `scripts/agent_harness.sh sim`** (it forwards to `scripts/sim_run.sh`). It runs the
standard arm off-screen with the streamer off, re-imports only when a kernel actually changed, and **counts
engine errors FIRST and refuses to print numbers if there are any**. Do not hand-write the wrapper
invocation again.

```
scripts/agent_harness.sh sim [--frames N] [--seed N] [--fast N] [--path DIR]
                             [--fauna] [--full] [--raw] [--report k1,k2] [--keep] [-- <scene args>]
```

Defaults: 200 frames, seed 4242, `--fast=8`, `--planet-only --no-fauna`. The conservation gate needs 600+
frames to audit at all. A 600-frame windowed run costs about 90 s and exits by printing `LA_RUN_COMPLETE`,
so looping three runs per arm is fine.

**Exit codes** (`sim_run.sh`): 0 clean · 2 usage · 3 stale shaders · 4 the run logged engine errors, numbers
withheld · 5 a UI node was built without `--ui` · 6 `GRID_INVALID` · 124 never reported · 125 hung after
reporting · **126 `CONSERVATION_VIOLATION`**.

**Never launch godot windowed directly** — it steals the maintainer's keyboard focus. `--fixed-fps 60` is an
ENGINE flag and goes BEFORE the `--`. Both are handled for you by the harness.

**In a fresh worktree, in this order, or your measurements are fiction:** use `scripts/new_worktree.sh`,
which does all three — symlink the GDExtension binaries (`addons/local_agents/gdextensions/localagents/bin`,
NOT a `bin/` at the repo root, which does not exist), then `godot --headless --path . --import`, then
`scripts/editor_scan.sh`. Never a bare `godot --headless --editor`; two concurrent scans segfault.
A long-lived checkout goes stale the moment someone else's kernel edit merges — `.glsl` kernels are imported
resources and nothing recompiles them outside the editor. The wrapper refuses to launch against a stale tree
(`STALE_SHADERS`, exit 3). Do not bypass it to "just get a number".

**Gates:** `scripts/agent_harness.sh lint` is what CI runs. It includes `check_max_file_length.sh`,
`check_physical_constants.sh`, `check_reaction_balance.sh`, `check_heat_capacity_ssot.sh`,
`check_enthalpy_ssot.sh`, `check_neighbour_slots.sh`, `check_comment_density.sh`, `check_no_inferred_typing.sh`,
`check_tool_safety.sh`, `check_public_surface.sh`, `check_demo_catalog.sh` and `check_library_only.sh`'s
force-load. `check_kernel_conservation.sh` is windowed and runs separately.

**Instruments.** `LA_SOIL_BUDGET=1` and `LA_MINERAL_PROFILE=1` sample outside the contended slot and can be
armed with anything. **Four probes share the driver's ONE `set_step_probe` slot and are mutually exclusive**,
in this declared precedence (`MaterialFieldSphereStep3D.gd:63-90`): `LA_MINERAL_BUDGET`, `LA_H2O_BUDGET`,
`LA_ENERGY_BUDGET`, then `LA_PASS_PROBE=<channel>` at lowest precedence. Arming more than one push-warns,
names every armed flag, and runs the first. `LA_PASS_PROBE` takes any channel name, so the next runaway is
attributable without writing a bespoke probe.

**Reading a run:**
- **Three runs per arm**, quoting `phenomena_kinds` (a dict, e.g. `{"impact": 20, "eruption": 1}`) and
  `bolts` — residual spread is discrete and disaster-driven. Compare at equal `field_sim_s`, never equal
  `--run-frames`.
- **Read the books out of `SIM_REPORT` rather than arguing from temperature:** `conservation`,
  `conservation_worst`, `conservation_violations`, `conservation_steps`, `conservation_failed`,
  `world_seed`, `world_seal_step`, `energy_run_drift` / `energy_stock_first`, `energy_residual` /
  `energy_booked`.
- **A global mean cannot answer a local question.** `temp_mean` is inflated by magma; use `temp_ground_p50`.
- **CHECK THE SIM IS ALIVE FIRST.** A silent load failure once printed a normal-looking `SIM_REPORT` with
  zero reaction records. An aggregate that is exactly `0.00`, or an order of magnitude off, is a broken
  pipeline until proven otherwise.
- **A gate that passes with the feature disabled is not a gate.** Build the disabled arm. This caught an
  inert 175-line module that had passed every check written for it.
- **At 43.2 s per field step, a 600-frame run is ~7 hours of planet time** — during which Earth gets about
  1 mm of rain. "Do rivers run" needs 4000+ frames, not a bigger constant.
- **A `const Dictionary` built from another script's constants can fail to compile at runtime**, and when it
  does the whole script exposes NO static methods — `LASubstances.table()` vanished that way while the
  editor scan reported 0 errors throughout. Use static funcs. (`c185203`.)

**`world_seed` IS THE SCOREBOARD.** Everything in it is something the substrate was TOLD rather than worked
out, and progress is entries being DELETED, each with the acceptance test that the thing it asserted now
emerges. The bar is a post-Theia seed: a molten body and a bulk composition, with ocean, atmosphere and
crust all OUTPUTS. `INITIAL_TEMP = 15.0` is asserted in `MaterialField3D.gd` and is NOT on the scoreboard,
so the one seed most worth deleting is the one nothing is scoring. Either note it into the manifest or stop
calling the manifest the whole scoreboard.

---

## INSTRUMENTS THAT LIE

All three entries that stood here are CLOSED and deleted: `molten_counts()` and `fire_peak()` now carry
provenance flags (`molten_live`, `fire_live`) so a zero says which zero it is, and `fuel_total` is gone
rather than unmasked — `MaterialFieldElementInventory3D` already published `fuel_all` and `fuel_open_total`
correctly, and a third key for the same number is what produced the false finding.

What replaced them, and it is worse than any of the three:

1. **`mass_live` CAN NEVER READ FALSE.** `MaterialFieldElementInventory3D` computes `has_fuel` from
   `legs.get("fuel", _f._fuel).size() == cell_count`, and `_f._fuel` is sized once in `_alloc_channels()`
   and never shrinks — so every leg reports live whether the probe delivered or not.
   `MaterialFieldMineralBudget3D` has the same bug. The root cause is that `request_probe` is ONE-SHOT:
   `MaterialSphereGPU3D` clears `_probe`, refills it from `_probe_want` alone, then empties `_probe_want`,
   so two consumers on different cadences starve each other. That is why every ledger carries a mirror
   fallback, and the fallback is what silences the flag. **The trap:** removing a fallback before fixing
   the root drops a phase out of `mineral_total`, which the conservation gate keys on at 2e-5, and fires
   `CONSERVATION_VIOLATION` for a provenance reason.

2. **`salinity_at()` models a mechanism reality does not have.** Salinity is computed from BASIN DEPTH
   (`SALT_FULL_DEPTH`, `BRACKISH_FLOOR`). Real ocean salinity is a conserved solute at ~35 g/kg and is
   very nearly uniform with depth. It needs a salt substance and a channel.

3. **`water_force_at()` is an invented drag law.** `downhill * 9.0 * depth * slope`, with the 9.0
   commented "tune vs flood feel" and a depth floor that invents a current in a cell that reads dry. It
   takes flow DIRECTION from the terrain gradient while the substrate carries a real velocity field the
   function never reads. Real drag is `0.5 * rho * C_d * A * v^2`.

## DO THIS NEXT — in priority order

**The order is FORCED, not preferred.** Every acceptance test below is a binary event, never a drift
percentage. Do not start a stage before its predecessor's test passes. The deconfliction map for fanning
out is the section after this one — read it before launching anything.

---

### P0 — THE SEAMS. Serialized, ONE owner, no fan-out. Everything else queues behind this.

You cannot parallelize a refactor of the file everything shares. **Freeze a commit first** and re-derive the
collision map against it.

| # | Do | Acceptance (binary) |
|---|---|---|
| P0.1 | ~~Channel SSOT~~ **DONE** — `sim/material/Channels.gd`; the GPU's four lists, `LAHeatCapacity`'s eight groups and `LAReactionBalance`'s three tables are views of it | delete a channel from `Channels.gd` → the balance gate and the kernel `#define` cross-check both go red |
| P0.2 | Split `MaterialSphereGPU3D.gd` (815 lines) into device / residency / pass-runner | lint green, `sim --frames 200` reaches `LA_RUN_COMPLETE` with 0 engine errors |
| P0.3 | Extract `MaterialField3D`'s ~34 mirror arrays into their own file | same |
| P0.4 | **Wire `check_model_parameters.sh` into `lint`. IT HAS NEVER RUN.** `CLAUDE.md` asserts it as enforcement and nothing calls it; 556 declared rows have never met the tree | add an undeclared kernel constant → lint fails. Expect ~56 real violations on first wiring; that is the finding |
| P0.5 | Split the conservation VERDICT from the provenance verdict | starve one probe leg → `CONSERVATION_UNMEASURED` and an exit code that is **not** 126 |
| P0.6 | **Nobody owns SSBO binding numbers.** Two lanes both claimed 42 on 2026-08-12 | a binding registry beside the channel one, gated |

---

### P1 — SI. The metre is fitted and the planet is 84 km wide with Earth gravity.

`METRES_PER_MODEL_UNIT` deleted, not re-derived. ONE scale, at the presentation layer only.
~39 conversion sites, two dead helpers, both scaling modules' scaling halves, `PLANET_SCALE` and its nine
dependants, and `check_model_unit_volume.sh` — a gate whose entire subject is the unit — all go.

- **Acceptance:** `grep -rn METRES_PER_MODEL_UNIT addons/local_agents/sim addons/local_agents/game` returns
  nothing, and lint is still green.
- **fp32 is smaller than it looks.** 0.5 m at Earth radius is 1.3e-6 of a cell. It matters in exactly two
  places: `cell_volume`'s difference of cubes (fix is algebraic — `dr·(r_out² + r_out·r_in + r_in²)`), and
  absolute heliocentric positions, which stay in GDScript doubles and never reach an SSBO.
- **Also here: there are TWO GRAVITIES.** `LAGravity.SURFACE_G = 55.0` ("matches old feel") and
  `STANDARD_GRAVITY_M_S2`. They die together.
- **Maintainer's call, does NOT block this stage:** Earth-sized, or a declared small body with `g = GM/R²`.

---

### P2 — ONE OWNER FOR THE FIELD STATE.

`request_probe` becomes a standing subscription; `take_probe` clears what it hands out; mirror fallbacks come
out; `set_field` is deleted and every CPU→device edit goes through the sparse queue, which books what it
moved. **Five whole-mirror uploads remain and `check_seed_phase.sh` holds them as a shrink-only ratchet —
each one converted lowers `MAX_MIRROR_UPLOADS` in the same commit.**

- **Acceptance:** `MIRROR_REWIND` cannot print, because its emitter no longer exists. Force a probe leg
  absent → `mass_live` reads **false**; today it can never read false.
- **Ordering is forced:** the subscription lands BEFORE the fallbacks come out, or a starved probe drops a
  phase out of `mineral_total` and fires `CONSERVATION_VIOLATION` for a provenance reason.

---

### P3 — PRESSURE IN EVERY CELL.

`wind_pressure` writes one flat surface pressure into everything below the atmosphere, so a 4 km ocean cell
and a mantle cell both read ~1e5 Pa. Harmless while temperature is stored; **decisive once enthalpy is,
because it selects the phase.** Half the machinery exists — `reactions_sphere3d.glsl` has `overburden()`.

- **Acceptance:** pressure is monotonically non-decreasing inward down every column, and a cell 4 km below
  the sea reads ≥ 4e7 Pa. Both fail today.

---

### P4 — ENTHALPY IS THE STATE. The largest single item; everything in the reaction engine gets easier after.

Add `h_j_m3`, build the closed-form mixture inverter, derive `temp` and phase, make `temp` read-only.
**The EOS table is NOT a prerequisite** — the inversion needed is the MIXTURE solve and it is closed-form:
four breakpoints on this planet (water melt/boil, basalt solidus/liquidus), an O(4) sorted walk, cheaper
than the `rc_of` it replaces.

- **Acceptance:** seed a column of liquid water at +2 °C, remove heat at a constant rate, and `temp` must
  **pin at 0.0** for exactly `m·L_fus / rate` steps. Latent heat becoming structural cannot be faked.
- **`rc_of` coming out is the acceptance test for the whole stage, not a step in it.** If it cannot come
  out, the root is not fixed — say so rather than restoring it.
- **Rename the buffer in the same commit that changes its unit** (`temp` → `h_j_m3`), so an unconverted
  kernel fails to COMPILE. That is the only mid-flight honesty that costs nothing.
- Deletes: `PhaseRecords.gd` entire, `snowice_sphere3d.glsl` entire, `atmos_precip`'s condensation branch,
  `rc_shared.glsli`, `HeatCapacity.gd`, its SSOT gate, 8 constants, and the `water`/`moisture`/`snow` and
  `rock_fill`/`lava` channel pairs.

---

### P5 — THE UNIT IS MOLES.

Channel amounts become mol/cell; `mol_per_unit` and `unit_ratio` delete; one applicator evaluates every
record against the same starting state, so `cap_slot` deletes too.

- **Acceptance:** permute the record order and `element_C_total` is bit-identical.
- **DO NOT read "conserve elements, derive species" literally.** Deriving species by equilibrium returns
  zero biomass and a CO₂ atmosphere and looks like a clean conservation result — a living cell is not at
  chemical equilibrium. The defect named is the UNIT. Gate `biomass_total > 0` in a `--full` arm.

---

### LIVE DEFECTS — fix whenever their file is free; none block the stages above

1. **`o2_total` runs away: +3.5e6% over 600 frames.** A growth rate, not drift.
2. **Nothing reaches 224 °C, so rock cannot melt** (liquidus is 1200). Is the geotherm delivering heat?
3. **`EcoSurfacePass` destroys carbon** — and `fungus_fert` credits `fert`, which carries no carbon, so
   that conversion destroys it by construction.
4. **`fuel` never moves** — identical to 14 digits over 247 steps, ~28% of the planet's carbon.
5. **`MaterialFieldEnergyLedger3D.gd:148`** computes `face = cell_size²` in model units — off by ~28 400.
6. **Two kernels do phase changes with zero latent heat** (`snowice`, `atmos_precip`) — resolves in P4.
7. **Six phenomenon actors pump their own ingredients in** — they become detectors. Blocked on 6.
8. **`rock_fill` has two definitions**; the mineral ledger holds the wrong one.

## HOW TO FAN OUT — the deconfliction map

**EVERY FILE-EDITING SUBAGENT GETS `isolation: "worktree"`. NO EXCEPTIONS, NO THRESHOLD.** Nine lanes were
run in one shared tree on 2026-08-12; four of them lost their acceptance runs to each other, two claimed the
same SSBO binding, and the planning agent watched its own citations rot mid-read. "Trivial" is a property of
the DIFF, never of how much typing you did — launching an agent is one tool call and thousands of lines.

**The order is: split the bottleneck, THEN fan out.** A unit is only safe to parallelise when it has exactly
one owner file. Below, ● = must edit, ○ = reads only.

### The five bottlenecks — every migration routes through these, so they are P0 and they are serial

| File | Why it collapses a fan-out |
|---|---|
| `MaterialSphereGPU3D.gd` (815 lines) | buffers, ping-pong, upload/download, residency, the probe, the pass list, dispatch, `set_field`. **15 of 19 migration units edit it.** Split into device / residency / pass-runner. |
| `MaterialField3D.gd` (1070) | declares the ~34 mirror arrays that three migrations re-type and one deletes. Extract the state. |
| `reactions_sphere3d.glsl` (497) | one kernel, cannot be split by channel. Owner-locked for all of P4's channel collapse and all of P5. |
| `MaterialFieldSphereStep3D.gd` | the 5 remaining whole-mirror uploads, the seeding block, `_apply_readback`. |
| `PhysicalConstants.gd` | every stage adds and removes constants. **Append-only for agents**, and the expression parser has NO parentheses — write `a * b / c` flat or the gate fails. |

`Channels.gd` **was** the sixth and is now fixed — the seven declaration sites are views of it.

### What can genuinely run in parallel, once P0 lands

| Wave | Units | One owner each | Safe because |
|---|---|---|---|
| **P1 SI** | 3 | GDScript call sites · the 6 kernels carrying the literal · grid geometry (`SphereGrid`, `CellVolume3D`, `FaceArea3D`, `cellvol/facearea.glsli`) | disjoint file sets |
| **P2 ownership** | 3, but ORDERED | subscription → fallbacks → `set_field` | ordering forced by the conservation gate (see P2) |
| **P3 pressure** | 1 | `wind_pressure_sphere3d.glsl` + a new overburden kernel | ‖ all of P2, disjoint |
| **P4 transport** | **9, the widest wave** | `gravity_flow` · `soil` · `tracer_transport` · `erosion_transport` · `erosion_pickup` · `plate_advect` · `atmos_rain` · `magma_buoy` · `wind_pressure` | one kernel + its pass each, after the `h` channel exists |
| **P4 thermal** | 4 | `heat_sphere3d` · `heat3d_solar` · `heat3d_buoyancy` · (lava_phase is deleted) | ‖ the transport wave |
| **P5 records** | 4 | `BioRecords` · `GeoRecords` · `CombustionRecords` · `LightningRecords` | after the applicator lands |

### What can NEVER be fanned out

- Anything touching a bottleneck before P0 splits it.
- **P4's channel collapse** — one owner across 13+13 kernels, `ReactionDefs`, `reactions_sphere3d.glsl` and
  `MaterialField3D`. The single largest indivisible unit in the plan.
- **P5's unit change** — same reason, over `Channels.gd` + the reaction kernel.
- Documentation. Two rounds maximum, then take it in-house; measured 2026-07-29, four doc fan-outs cost
  28 agents and ~3.4M tokens while the eight defects the coordinator then fixed by hand took ten tool calls.

### The contract each agent gets

Goal · the exact files to add/change/**delete** · the shared interface it must honour · a **binary**
acceptance gate (exact command, pass condition, "commit only if it passes, else report") · and the standing
instruction to **mutation-test every gate it writes**, because this repo has shipped gates that could only
pass. Tell it to cite identifiers, not line numbers. Tell it that "another lane owns that file" is never a
reason — if it needs a file, it says so and the coordinator sequences it.

**The coordinator integrates.** Worktree agents commit to their own branch; merging, conflict resolution and
the editor-scan/lint gate stay the main thread's. Check `git log <base>..<branch>` before merging — an
isolated agent can branch off a stale commit; salvage with cherry-pick (right base) or
`git diff | git apply --3way` (wrong base).

## HOW GOOD IS IT? — `PHYSICS_RUBRIC.md`

Six criteria, 0–4, with a dated score history; `scripts/physics_score.sh` computes criteria 1, 2 and 5 out
of `SIM_REPORT` and 3, 4 and 6 are hand-entered audit counts, so those are the ones to distrust. Opening
score 7/24 (2026-08-09). It records two hard couplings: seed minimality cannot pass 2 until energy is
booked, and matter conservation is gated on per-pass attribution existing. **The score has not been
recomputed since the kernel fixes; recompute before quoting it.**

---

## WHAT IS SETTLED — do not rebuild these

*(The most dangerous list in this file, because work AVOIDS what is on it — so an entry that stops being
true has to come OFF. `REPOSE_TAN` did: the value was right and the application was not. It was applied as
a mass difference against a tangent, which asserts cells are cubes; on the cubed sphere the aspect runs
1.07–4.08, so sediment stood at 33° at the shell floor and 9.8° at the top. Fixed via `LASphereGrid.link_arc`,
and the repose gate now lives in `gravity_flow_sphere3d.glsl` with the tangent supplied per row by
`WaterSlumpLavaPass` from `LAPhysical.REPOSE_TAN_DRY_GRANULAR`.)*

Each of these is one grep from being falsified if you doubt it. Identifiers, not line numbers.

- the H₂O ledger's inclusion rule — `MaterialFieldLedger3D.gd`;
- the DEFS record engine's std430 layout — `ReactionDefs.gd`, `RECORD_BYTES = 144`, documented in
  `serialize()`. Note the file has NO `Records` suffix, so the old `{ReactionDefs,Bio,Phase,Geo}Records.gd`
  glob named a file that does not exist;
- the neighbour / tangent / lateral-slot tables and `link_partner` — `sim/sphere/SphereGrid.gd`, gated by
  `check_neighbour_slots.sh` and by `LASphereGrid.validate()` at runtime;
- the soil budget's per-leg identity — `MaterialFieldSoilBudget3D.kernel_residual`, exactly 0.0;
- the erosion transport law — no fitted constant, load moves in the same proportions as the water carrying
  it (`erosion_transport_sphere3d.glsl`);
- the geotherm as a seeded initial condition with a DERIVED vertical scale — `MaterialFieldGeotherm3D`
  states the one conceit (depth is vertically exaggerated) and `_derive_gradient()` computes the
  exaggeration from `GROUNDWATER_CIRCULATION_M` rather than asserting it;
- ONE definition of a cell's volumetric heat capacity per side of the GPU boundary — `kernels3d/rc_shared.glsli`
  and `material/HeatCapacity.gd`, held equal by `check_heat_capacity_ssot.sh`, which gates the FORMULA
  rather than the values because the values were never what drifted;
- ONE definition of the enthalpy ladder per side — `kernels3d/enthalpy.glsli` and `LASubstances`, held equal
  by `check_enthalpy_ssot.sh`, which also checks the phase ladder appears in the same ORDER on both sides.
  The GLSL twin deliberately stops at gas; the high rungs need bisection (`PHYSICS_TODO.md` A2);
- the aquifer's `k_rel` / `RESIDUAL` capillary retention — `soil_sphere3d.glsl`;
- the saturation curve from August-Roche-Magnus; Kozeny-Carman conductivity from porosity;
- weathering as ice expansion and Arrhenius dissolution, and lithification on real lithostatic pressure
  against `LAPhysical.LITHIFICATION_PRESSURE_PA` — `GeoRecords.gd`;
- metabolism as the substrate's own respiration reaction, mass-scaling emergent rather than typed.

---

## OPEN DECISIONS

- **Memory/Graph lane: keep the SQLite-only graph architecture, or introduce a specialised graph backend?**
  (`controllers/ConversationStore.gd` → `docs/NETWORK_GRAPH.md`.) Nobody has picked a side and the status
  quo ships: `gdextensions/localagents/src/NetworkGraph.cpp` is the raw `sqlite3` C API, vector search is a
  hand-rolled VP-tree over the `embeddings` table, and four consumers share one
  `user://local_agents/network.sqlite3` (`ConversationStore.gd`, `graph/ProjectGraphService.gd`,
  `graph/BackstoryGraphService.gd`, `sim/ecology/BandChronicle.gd`). **What should decide it:** FTS5 is not
  compiled into this build, so full-text search over node data is unavailable today — establish whether
  that is a blocker before weighing a new backend, because enabling FTS5 is a build flag and a backend swap
  is not.

---

## 0.5 — THE LIVING CREATURES — PARKED

Does not begin until the planet is locked down. Plans: `docs/0.5_CREATURE_FEATURES.md`,
`docs/0.5_PARALLELIZATION_GUIDE.md`, `docs/ROADMAP_0.5.md`.

Two things to establish FIRST, because both are unmeasured rather than broken:

- **Whether the food web works has never been measured.** The two gauges previously cited cannot answer it:
  `biota_node_intake` reads 0.00 when predation WORKS (it is credited only on the fallback branch for prey
  with no body ledger, and every creature in the library has `draw_body_mass`), and `death/eaten` 0 is
  guaranteed by `--planet-only`, which spawns no animals at all. The predation path is present and
  reachable — `CreatureThink.gd:178,194` and `Fish.gd:844` call `prey.die("eaten")`. **It needs a
  fauna-enabled run, which nobody has done.**
- **Breeding has a global `pop_cap` ceiling and SPACE does not regulate it.** Food and energy do:
  `EcologyBreeding._spawn_cost()` refuses to spawn below `SPAWN_ENERGY_FLOOR` and charges
  `SPAWN_ENERGY_FRAC` of the parent's maximum, and the birth count is multiplied by a biomass food gate.
  The land and aquatic caps sit on top of those as hard ceilings. Space is the unregulated one.

## 0.6 — THE FULL SOLAR SYSTEM

Make the moving frame literal: migrate the GPU field to a body-local representation so the planet can
translate; planets, moons and sun as first-class bodies on real orbits; land on the moon; render the real
orbits; persist the orbital state.

---

## Where everything lives

- **Substrate:** `material/MaterialField3D.gd` (thin facade, **extract-only**) + `MaterialSphereGPU3D` ·
  `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) + `neighbours.glsli` / `rc_shared.glsli` /
  `enthalpy.glsli` · `MaterialReactions3D` (registry) + `material/reactions/` — six files: `ReactionDefs.gd`
  (the slot enum + record layout), `BioRecords.gd`, `PhaseRecords.gd`, `GeoRecords.gd`,
  `CombustionRecords.gd` and `ReactionBalance.gd` (the gate, which lives in this directory rather than
  beside `PhysicalConstants.gd`) · `material/Substances.gd` (`LASubstances`, the SSOT for matter) ·
  `material/PhysicalConstants.gd` (`LAPhysical`) · the budget/probe/inventory modules.
- **The grid:** `sim/sphere/SphereGrid.gd` — neighbours, lateral slots, `link_arc`, `link_partner`,
  `validate()`.
- **The books:** `material/MaterialFieldSeal3D.gd` (SEEDING → SEALED, and the `world_seed` manifest) ·
  `MaterialFieldConservation3D.gd` (the gate, and its `DEBT` table — the SSOT for how far off each substance
  is) · `MaterialFieldEnergyLedger3D.gd` (the stock, and the unbooked-terms work queue in its header) ·
  `MaterialFieldEnergyProbe3D.gd` / `MaterialFieldMineralProbe3D.gd` (per-pass attribution, heat and rock) ·
  `MaterialFieldPassProbe3D.gd` (`LA_PASS_PROBE`, any channel) ·
  `MaterialFieldElementInventory3D.gd` (moles, with `_all` mask-free twins and `mass_live` provenance).
- **Kernel tests:** `addons/local_agents/tests/KernelConservation.tscn` + `scripts/check_kernel_conservation.sh`.
- **Composition root:** `game/VoxelWorld.gd` (**extract-only**) + `game/world/*`; the three layer scenes are
  `game/Simulation.tscn`, `game/RenderLayer.tscn`, `game/UiLayer.tscn`.
- **Actors:** `sim/actors/*`, `creatures/**`; disasters are seeds/visuals only. **Cognition:** `creatures/cognition/*`.
- **Reusable addon:** `agents/` (LocalAgent + Agent3D) · `runtime/` · `examples/`.

## North-star

Not restated here. `CLAUDE.md` holds it, and a second copy is a second thing to drift.
