# PERFORMANCE TODO — the one list of what costs more than it should

**Big-O is a first-class design goal (`CLAUDE.md`), so this list is ordered by asymptotic cost, not by
effort.** Lower the asymptotic cost first, then the constants. An item leaves when it is implemented and
verified, never when it is worked around.

**No speedup here may change physics.** A rate, threshold or cadence chosen to make a frame cheaper is
forbidden. Several items below WOULD change results; each says so, and those need the maintainer.

**Measure against `field_readback_ms` / `field_dispatch_ms` / `field_sync_ms`, which the driver already
publishes — not against a wall clock.** Readback and dispatch are separate rows: take both before and
after, or a dispatch win reads as no win at all.

---
## 1a. EVERY COLUMN MARCH IS A PREFIX SUM. THIS IS THE LARGEST EXACT WIN AVAILABLE.

Two separate places march a line of cells per cell, each up to `MARCH_HOPS` hops: `column_field()` for the
charge column, and `longwave_incident()` for radiative transfer, which runs per FACE, so six times.

Both satisfy a recurrence — a cell's integral is its own term plus its neighbour's — so ONE sweep along
each line computes them all. **O(cells x depth) becomes O(cells), and the answer is identical.**
No approximation, no physics decision, no new constant. Do this before any of the constant-factor items
below it.

Two of the marches also feed values a CPU consumer reads, so shortening them shortens a readback as well as
a dispatch, which is the half that actually shows up (see the measurement note above).


## 1d. BOOK THE FLOWS TO MAKE A TOTAL CHEAP — AND NEVER DELETE THE REDUCTION THAT CHECKS IT

A channel's total is recomputed by a full reduction, while `transport.glsl`'s gather already has `gained`
and `lost` in hand. Accumulating the total from the fluxes is exact and turns a sweep into an add.

**THE TRAP, AND IT IS THE WHOLE REASON THIS ITEM IS DANGEROUS.** `stock - booked` IS the residual, and that
difference is the ONLY thing in the tree that can detect a leak. A booked total is what the books SAY;
the reduction is what the field actually HOLDS. Replace the second with the first and the two can never
disagree, so a leak stops being loud and becomes invisible — the books would balance perfectly while matter
drained away, and every conservation gate would report clean.

So: book the flows to make the total cheap, keep the reduction as the AUDIT, and cheapen its CADENCE rather
than removing it. An item that deletes a measured stock in favour of a computed one has not optimised the
instrument, it has removed it. The same argument holds for energy, where `turnover` and `energy_residual_rel`
already have this shape.


## 1b. The report walks the grid ~2 Hz, and only the heavy half is cached

`LASimReport.snapshot()` calls every provider, and `LAGameProgression._process` calls it twice per
`CHECK_INTERVAL` (0.5 s), plus the HUD and `LAVoxelHarness`. Only `_heavy_block()` is behind the 64-frame
cache. `sea_surface_stats`, `rock_radial_profile` (two passes) and `lava_shell_diag` are NOT —
whole-grid GDScript sweeps twice a second on the main thread.

Moving them inside the cache is a CADENCE change and forbidden as a speed measure on its own. Make them
cheap instead.


## 1c. One surface-cell list would empty six full-grid walks

`WaterSurfaceMesh.build`, `sea_surface_stats` and `rock_radial_profile` each walk every cell to find the
same thing: the skin. It is a stream compaction, so no reduce `Op` expresses it — it is the active-cell
list again. Build it once per step and all of them become O(surface cells), about N^(2/3).


## 2b. The dispatch budget, and where it is spent

`ReducePass` sweeps the whole grid once per `LAProcessSet.reduce_rows()` row, each dispatch followed by
an unconditional barrier, while `TransportPass` dispatches over its active list. It is the pass that
costs the whole box rather than what is moving.

**Fuse ReducePass into one multi-row dispatch.** O(rows × N) becomes O(distinct sources × N): one sweep,
one barrier, every row's lane accumulated in registers. `partials` already has a per-row base and the
float64 CPU fold is unchanged, so the result is identical. Only `LATCH` → `SUM_ABS_DIFF` needs a barrier
kept. Nothing structural blocks it.

**`transport.glsl` pass 1 has no solid early-out.** Pass 0 returns early on `solid != 0`; the gather does
not, so an active rock cell runs every row to add zero. And every row's pass 0 clears 18
`send`/`send_h`/`send_q` slots before deciding it has nothing to send. For the nine rows with
`density == 0` the `_h`/`_q` two thirds of that are provably dead.


## 2d. Work repeated per cell per step that is provably constant

- **`strain_rate(c)`** reads 6 neighbours × 3 velocity components and builds a 3×3 tensor. It is evaluated
  about twelve times per cell per step — every `LAW_EDDY` row plus four times inside `PASS_GRAIN`. `vel_*`
  are written once by `StateDerivePass` and not touched again, so caching it in one derived buffer is
  exactly equivalent, not an approximation.
- **`root_soil()`** re-walks its 4-cell column once per record naming `SOIL_ROOT` and again inside
  `root_soil_draw`. It is a march, so it is item 1a's shape at a small depth.


## 2f. The gravity solve is a fixed iteration count, not a convergence test

`SWEEPS` is a literal loop of 8 red-black pairs. `mode_residual` computes the residual and publishes it as
a gauge, and nothing reads it back to decide whether to sweep again. Error propagates one cell per sweep,
so eight cells per solve and one cell per simulation step — after a large sudden mass change the potential
is not the potential of the mass that is there, for tens of steps. **A geometric multigrid V-cycle is the
correct answer**: same discrete operator, same fixed point, O(N) per cycle, whole-grid propagation.
`check_gravity_solve.sh` is the gate to measure any replacement against. Raising `SOLVE_EVERY` or lowering
`SWEEPS` is FORBIDDEN — the published potential is an unconverged iterate, so both change the answer.

**And solve the CORRECTION, not the field.** Mass barely moves in a step, and `lap(dphi) = 4 pi G drho`
with `drho` sparse — only the cells whose mass actually changed. Same operator, same fixed point, a far
smaller problem, and exact. It composes with the V-cycle rather than competing with it; it needs the
previous step's density kept, which is one buffer.


## 2g. The drain reads derived buffers nobody consumes

The drain names ALL of `derived_buffers()` every step. Several of them have no per-frame CPU consumer at
all. The `request_channel`/`CHANNEL_HOLD_DRAINS` gate already exists for situational channels; the
derived set has no such gate.

**Measure any of 2b–2f against `field_readback_ms` / `field_dispatch_ms` before believing it helped.**


## 12. Θ(N²) creature scans, next to a spatial index that already works

`LASpatialIndex` exists, is rebuilt each frame for `"creature"` and `"plant"`, and is used correctly by
`LACreatureSenses`, `LACreatureLeadership`, `LAFish._forage_index` and the PANIC half of
`LACreatureFlocking.steer`. These callers do a full group scan instead, each Θ(N²) summed over the
population: `LACreatureFlocking.steer`'s main flock loop, `LACreatureThink._try_eat_food` (scans every
plant and carcass on the planet to find one within ~1.4 m), `_best_learned_cue`, `_reinforce_cue_success`,
`LACreatureNesting._nearest_tree`, `LAFish._school_steer`, `LAFish._nearest_threat`, and
`LAEcologyStimulus.broadcast_call`. This is unfinished adoption, not a design gap.

Two of them change behaviour, so decide deliberately: `broadcast_call` filters by each LISTENER's hearing
range, so the query radius must be the population maximum, not the caller's, or animals stop hearing calls.
`LocalAgentCognitionScheduler._scan_*` currently truncates at `SCAN_LIMIT` in GROUP ORDER — an arbitrary cut
standing in for a spatial query, so replacing it with a radius query changes perception and is its own
argument.

**This is creature-adjacent, so it waits on the 0.5 scope rule unless the planet needs it — but it is a
performance defect, not a creature feature, and `EcologyStimulus` and the index are shared substrate.**


## 13. Precompute `above[]` / `below[]` on the gravity-solve cadence

Every `LAFieldGeometry.above`/`below` is five interpreted calls deep and includes a square root, and it is
a pure function of solved gravity — which changes only when `GravityPass`'s `gravity_solves` changes. Two
`PackedInt32Array` tables rebuilt on that cadence make every full-grid sweep in items 1 and 2 several times
cheaper, numerically identically. Cheapest change per line in this file.

