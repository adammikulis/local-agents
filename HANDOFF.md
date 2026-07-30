# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

Master tracker. Main scene: the game boots to `addons/local_agents/game/menu/MainMenu.tscn`
(`project.godot:15`); the flagship sim is `addons/local_agents/game/VoxelWorld.tscn`. Read `CLAUDE.md` +
`addons/local_agents/sim/EMERGENCE.md` first.
*(Paths corrected 2026-07-29. This line gave `scenes/menu/MainMenu.tscn` and
`scenes/simulation/voxel/VoxelWorld.tscn`; neither has existed since the addon-UX directory split moved
everything under `addons/local_agents/{sim,game}/`. Stale `scenes/simulation/voxel/...` paths appear
elsewhere in this file too — treat any of them as pre-split.)*

## ▶ NEXT SESSION — START HERE (this file IS the plan doc; feed it in)
**ROADMAP PIVOT (2026-07-12): 0.4 is now THE EMERGENT PLANET; the living creatures moved to 0.5; the full
solar system moved to 0.6.** 0.4 makes the physical substrate the star — geology + hydrology + volcanism +
climate, all emergent from the ONE field, simulated START TO FINISH (a geological bake: rough world → weathering/
erosion/volcanism/climate run forward → frozen as a livable, beautiful start state you can tend or just watch —
"deism-optional"). Look = CEL-SHADING. See **"0.4 — THE EMERGENT PLANET"** below (the full tiered plan). 0.3.1
shipped on `main` (`v0.3.1`); development is on `0.4-dev`. Read `CLAUDE.md` · `EMERGENCE.md` · memories
(`roadmap-0.4-life-cycle` [pivot], `dissolve-dont-patch`, `perf-first-ruthlessly`, `big-o-first-class`,
`fire-balance-wildfire`, `worktree-shader-import-gotcha`, `three-d-always`); work in a worktree off `0.4-dev`.

---
### ⚑ INTEGRATION ROUND (2026-07-30, latest) — gravity + terrain-to-field merged, three substrate bugs found

Three worktree-isolated tracks landed and were integrated. **CI green; `0.4-dev` at `c4f16a9`.**

**Merged: the star is a real gravity body.** `LAStar` had no `center()`, so every gravity loop's
`has_method("center")` guard silently skipped it and meteors felt zero solar pull, while the planet's orbit
ran on a separate `SUN_MU` in unrelated units and the visible star sat at a decorative
`SUN_SCENE_DISTANCE = 1200`. Four numbers, four different suns, all gone. The frame is planetocentric and in
free fall, so `LAGravity` subtracts each body's pull on the frame origin and what survives is the tidal
differential: measured +0.114 sunward at r=640 and anti-sunward on the far side, which is the correct
signature and not a global shove. Orbit holds 11880..12122 (2.0%) identically at 700 s and 2100 s.

**An adversarial verify pass caught a real defect in that work, after I had already merged it.** The G cache
validated only that the remembered instance id was still *alive*, never that it was still the reference body.
`reference_body()` falls back to max mass until something declares `is_gravity_reference()`, and the star
outweighs the planet ten to one, so one gravity query in the window between the star registering and the
planet registering latched surface gravity at 1.37 against the intended 55.0, permanently and silently. The
commit that introduced it claimed the opposite, that keying on instance id killed a load-order race; there was
no such race, because the old guard was `if _g_const > 0.0` and a failed calibration returned -1, which
retried. Fixed in `c4f16a9`, with `test_gravity_calibration.gd` as a regression test that is mutation-checked:
reverting the fix fails it with "got 1.372879". Nothing in the shipped boot opened the window, which is
exactly why it needed a test and not a comment.

**Merged: terrain destruction reaches the substrate.** `carve_sphere` only moved the godot_voxel SDF, so a
crater was a hole you could stand in that water would not pool into. `resample_terrain` had zero callers and
wrote `_solid`, which `SolidDerivePass` recomputes from `rock_fill` every step, so wiring it up as written
would have looked correct and done nothing. It now writes `rock_fill`, and the excavated bedrock is moved
rather than deleted: one conserving transfer per cell into sediment and dust, giving impact winter with no
impact-winter code.

**Correction to how that was measured, because it cost me a wrong conclusion.** The default sandbox run spawns
**no meteors at all**. `phenomenon/impact` in a plain run comes from `LAThresholdDetector` inferring an impact
from a heat spike, not from any `Meteor` node. My first integration run therefore reported `crater_cells 0`
with 10 "impacts" logged, and I briefly took that as the merge being broken. Pass `--auto-barrage` (or
`--auto-meteor`). With it, at seed 4242 / `--fast=2` / 150 frames / field_step 746: `crater_cells 110`,
`crater_water 66.8`, `rock_shrinks 95`, `mineral_inject_moved 115.08`, `dust_total 46.38`.
Separately: that track's own commit message quotes one run out of five whose numbers disagree wildly at the
same field_step (`crater_cells` 1, 2, 101, 114, 175). Treat its figures as one draw, not a measurement.

**Verified substrate bug: the neighbour table is not slot-opposite reciprocal.** Confirmed independently on
`0.4-dev` with a from-scratch probe rather than the reporting branch's own `validate()`: at res 24, **5760 of
407808 links (1.412%)** have B listing A in some slot other than the opposite one, producing **5760 send slots
no cell ever reads** and **5680 read twice**. Every 2-pass gather kernel here (soil, water, slump, lava)
computes inflow as `send[neighbour*6 + OPPOSITE(slot)]`, so this destroys mass at the cube-face seams and
duplicates it elsewhere. Measured downstream as `darcy_lost` of -2.13/step in the soil budget. `_seam()`
stitches by nearest direction and cannot promise opposition, because the local (a,b) axes rotate across a face
boundary. Kernel slot order is `[0]=in, [1]=-a, [2]=+a, [3]=-b, [4]=+b, [5]=out`, so the pairs are 0↔5, 1↔2,
3↔4. `validate()` reported `symmetric = true` throughout because it only checked that B lists A *somewhere*.

**Found, not yet fixed: `add_field_sparse` applies nothing in this build.** 1515 per-cell add edits reached it
and it returned 0.0 for every one, while `move_field_sparse` works on the same buffers. That means
`add_water_pooled`'s flood surge has never delivered its water.

**Fixed, and it was eating the crater transfers: an in-place transfer aliased its own source.**
`resample_terrain` queues `transfer("rock_fill", src, amounts, "sediment", src)` — one array as both source
and destination, which is the honest way to say "this rock becomes sediment where it stands". But
`PackedInt32Array` is copy-on-write, so the op held that single buffer in two of its dictionary slots and
`_merge` appended into it twice: cell lists grew by two edits per merge while `amounts` grew by one.
`move_field_sparse` early-returns 0.0 unless the sizes match, so **every coalesced mineral transfer was
silently dropped**, and coalescing is what a barrage guarantees. Deterministic, two edits, no sim: before
`9/7/9` with cells `[1,2,3,4,5,6,7,6,7]`, after `7/7/7`. Fixed in the queue (it owns the invariant) in
`70dd6b7`, with `test_inject_queue_alias.gd` mutation-checked against it.

**Soil drain: root cause found and fixed, on `feature/soil-drain-fix` (not merged).** Two real causes, both
from the branch's own budget. `SPRING_CONDUCT` multiplied a head in **world units** while `INFIL_RATE` is a
dimensionless per-step fraction, so `0.20 * a few metres` always exceeded `remaining = MAX_FLOW_FRAC*s` and
every spring on the planet ran at the stability cap, head-proportional in name only; the head is now divided
by `cell_size` to give a real gradient. And for the inward neighbour the geometry makes the head positive by
construction, so a regolith cell drained into the cell beneath it however full that cell was; discharge is
now capped by the outlet's remaining capacity, the same receiver-headroom rule the Darcy leg already used.
Stopping that drain then exposed the leg it was propping up: the seabed saturated, crossed `SEEP_THRESH`,
and up-seep took over at `6.03 -> 29.50` per step, so it got the same cap. Measured at `field_step 746`
across three runs: **`soil_total` 48.96 → 105.15 / 106.86 / 108.79** (3.4% spread). The leak is closed and
the budget says so: `kernel_delta` now oscillates about zero (+0.020, +0.340, −0.085, +0.109, +0.162 at
steps 600–800) while `post_kernel`, which is R19 root uptake, runs a steady −0.35 to −0.64. What remains is
plants drinking, which is consumption rather than leakage.

**~~Still blocking the dynamic sea: `h2o_total` is 4537–5885 against ~11539 on the static build.~~ THAT WAS
WRONG, AND I WROTE IT. Corrected 2026-07-30.** The dynamic sea does not lose the planet's water. It
**conserves it to 0.00–0.09% over 766 steps**, measured by a per-leg instrument that reads the channels off
the device between passes so each leg is a difference of measured buffer state: `legs_all` is **0.0000 for
all twelve passes at every sample** across three runs. No pass creates or destroys H₂O.

**The static build was MINTING.** Both arms start at the same 7485.40 units — `_seed_sphere_sea` differs by
the single line `_static[c] = 1`, which does not touch `_water` — so the static build's ~14272 was never the
same water. Restoring that one line for one run: 7488.26 → 13751.54, **+6263.28 minted** (a verifier
independently reproduced +6616.87 and +6635.40). The budget named the leg unprompted: `atmosphere` at
+6.61/step tapering to +0.33/step, which is `atmos_evap_sphere3d.glsl`'s `added += e * static_brake` **with no
matching debit**. The static sea evaporates water it never loses. The "missing" 5600–7000 units were on the
static side of the comparison the whole time.

**What the ledger's decline actually is: BURIAL, and mostly moisture rather than sea water.** Of 1197–1755
units buried at `field_step 767`: moisture 1021–1563, water 165–184, snow 6.0–8.5, soil off the regolith mask
exactly 0.00. A cell whose `rock_fill` crosses 0.5 stops being counted *and* stops being simulated.
`MineralStamp3D._settle_h2o` exists to displace exactly this but only catches what its throttled CPU scan
reaches, and `h2o_buried`/`h2o_displaced` both read **0.0** on a run where the substrate buried ~1400. That
under-reporting is the real remaining defect.

**Lesson for the tracker itself:** this entry stood as a merge blocker for a day because a difference between
two builds was read as a loss in one rather than a gain in the other. When two arms disagree, check what each
one STARTS at before deciding which moved.

**ROUND 2 — three more units, all merged.** Each was implemented worktree-isolated and then re-measured by
an independent verifier that re-ran the acceptance gate itself rather than reading the diff.

**The neighbour table is reciprocal now, and the fix is not the one I asked for.** I specified a
reconciliation pass that would place each cross-face back-link in the opposing slot. The agent proved that
**impossible**, three ways: each face is crossed by exactly two of the three great-ring families, so labelling
one family "the a-axis" globally is 2-colouring a triangle; and at each cube corner the three corner cells
form an odd cycle needing a proper 2-edge-colouring. Rejecting the bad links was not available either — they
are four entire cube edges. What it built instead: the four lateral slots stop being compass directions and
become **two reciprocal pairs**, which is a 2-factorisation of the 4-regular surface graph and always exists.
The pairing is seeded from the geometry, so in every face interior pair A is still ±a and pair B still ±b, and
is repaired only at the topological branch cuts the eight corners demand. Cost is **O(res), not O(res²)**:
48 bent links of 6912 at res 24. Zero kernel edits, zero links dropped, link count bit-identical.
`surf_nbr` is untouched, which matters because `WaterSurfaceMesh` and `MaterialFieldLakes3D` build quads and
drainage from its literal geometry. Verified 0/0/0 at res 16/24/32, and the agent found and fixed a bug in its
own first two attempts that leaked at **odd** res — the inspector allows any res in 8..64.
Conservation moved and the ranges are **disjoint**, which is the real evidence it reaches the kernels:
`h2o_total` 14252–14286 → 14090–14126, `soil_total` 3629–3679 → 3530–3543, both at `field_step 746`.

**`add_field_sparse` was dead for the same copy-on-write reason the crater transfers were.** `add()` and
`discard()` pass one array as both source and destination, the two dictionary slots shared a buffer, and the
merge grew it twice: `[1, 2, 3, 3]` against three amounts, so the size check dropped the op. Reachability
differs from the transfer case and the agent measured it honestly: it needs two same-signature adds in **one
flush window**, and five instrumented runs raised the mismatch zero times, so it is latent, and the fix must
not be read as the cause of any crater-fill change.

**Two of my own baselines did not reproduce, and I quoted both from single runs.** I gave `0.843` for
`h2o_drift_per_step`; four baseline runs measured −0.046, 0.263, 0.355, 0.506, so my gate threshold was far
more generous than intended and passing it proved less than it looked. I gave `crater_water 66.8`; three
baseline runs measured 17.65, 32.54, 43.89. This is exactly the error I flagged in the terrain track one
section above, committed by me in the same session. **Quote a range from repeats, or say it is one draw.**

**THE JET EXISTS — and the route to it went through a theorem, not a patch.**

The handedness regression above **cannot be fixed as posed**, and the proof is worth keeping. At each cell the
two 2-factor cycle-curves either cross transversally or bend; at a crossing the handedness sign *is* the
transverse intersection sign of two closed curves, and on a sphere every closed curve bounds, so that signed
count is exactly 0. Measured at res 16/24/32: every curve pair that meets holds **both** signs, every pair's
signed sum is **0**. Uniform handedness would need zero crossings, which makes every cell a degenerate bend.
The 50/50 split is a floor. Discrete hairy-ball; a torus is fine, which is why box grids never meet this.

**And the damage was an order worse than a sign flip.** Cycle orientation sets the convention momentum is
*stored and exchanged* in, so adjacent cells on different cycles disagreed about which way `tanA` points:
**17.1% of links at res 24, an interior defect, flat across resolutions (O(res²))**, against the face-local
frame's cross-face-only 2.1% (O(res)). Measuring the defect's *order* rather than its presence is what showed
the seam repair had traded the wrong way for wind.

**The fix: two tables instead of one overloaded one.** The 2-factor pairing keeps the adjacency (reciprocity
untouched, 0/0/0 at res 16/24/32, 407808 links). The tangent frame gets its own face-local table — `tan_a`
from `_FACE_R` projected into the tangent plane, `tan_b = radial × tan_a`, which forces `tan_a × tan_b ==
radial` unconditionally. Verified independently: **3456 right / 0 left at res 24, `worst_handed` exactly
1.000000, every face uniform**, and cross-frame disagreement now *falls* with resolution (2.08 → 1.39 →
1.04%). Stored per *surface* cell, not per cell — the direction is identical in every radial layer of a
column, so 110 KB at res 24 instead of 2.2 MB. Cross-seam vector transport uses a precomputed per-link
rotation; round-trip error 5e-7, and the world-space dot matches the geometric bound `cos(cell tilt)` to
3e-7, i.e. zero twist beyond the unavoidable plane tilt.

**Then the Coriolis sign turned out to be negated** — a left deflection in the northern hemisphere. That was
*literally an undefined quantity* while the frame was 50/50 handed, which is why it survived so long.

**Result** (`bench_atmosphere_column`, res 24, 400 steps, positive = eastward): a westerly maximum aloft at
h=120 of **+1.89 to +1.95 across bands 15–75**, over surface easterlies of −0.15 to −0.23 beneath it — about
**13× the surface magnitude**, with the trades in the right sense. The driver is measured: equator-minus-pole
pressure is −8.88 at the surface and reverses to **+2.46 at h=72**. Overturning was right all along and is
unchanged by the sign flip.

**Still missing, and not a constant to tune:** it is a westerly *belt*, not a jet stream — 1.72–1.95 across
four adjacent bands with no sharp latitudinal core. Sharpening needs an eddy momentum flux this substrate
does not carry, because res 24 does not resolve baroclinic eddies.

**⚠ `wind` in `SIM_REPORT` is not comparable across this change.** `MaterialFieldQueries3D.wind3_at()`
indexed the *internal* neighbour table (`[IN,OUT,A0,A1,B0,B1]`) with *kernel* slot numbers
(`[IN,-a,+a,-b,+b,OUT]`), so "tangent A" was built from a lateral neighbour minus the **outward radial** one.
**Every world-space wind vector handed to a creature or the HUD was wrong**, and the bench had the same bug.
Any `wind` figure quoted before 2026-07-30 — including my own "0.0515 → 0.146" note above — is a wrong
quantity, not a physics change.

---
**ROUND 3 — the atmosphere gets mass, and two of my own claims were demolished.**

**Merged: a conserved AIR channel with real hydrostatic pressure.** Pass A was `P0 - K_T*(temp - T_REF)`,
purely per-cell with no neighbour table, no mass, no altitude. It is now a column solver: one thread per
radial column moves column mass by vertically-integrated upwind flux through four lateral faces, settles it
onto the exponential profile the local temperature sets, and integrates pressure inward as the weight of the
air above. O(cells) total at 1/depth the thread count, stride-1 because `SphereGrid` packs a column
contiguously. Measured: **monotone decreasing across all 20 shells**, p 82.05 at the surface → 0.617 at the
top, **scale height 39.97** (varying with temperature as it should, 43 at the pole and 53 at the equator),
**air mass conserved to 0.0004% over 400 steps**. Two things this made expressible for the first time:
`(1/ρ)·∇p` replacing a constant gain (zonal wind ×155), and drag decaying with altitude — a height-independent
`DAMP` asserts the whole atmosphere rubs on the ground, and that single assumption made friction beat Coriolis
at *every* height, which forbids a jet by construction.

**And `u(lat) = -BASE_WIND·cos(3·lat)` is deleted.** The hand-drawn Hadley cell is gone. A genuinely emergent
thermally-direct overturning replaces it (`v_pole` equatorward low, poleward from h=40 up), and the
thermal-wind driver is measured, not assumed: the equator-to-pole pressure difference grows from 1.77 at the
surface to 35% of local pressure at h=120.

**GATE 2 FAILED — there is no jet, and it must be recorded as failed, not as the "weak pass" the author
offered.** The 0.0778 aloft maximum reproduces as a number and fails as physics: zonal wind sits 6–110× below
what the kernel's own Coriolis constant and its own meridional wind imply, its sign alternates across latitude
bands in a way one direct cell cannot produce, and its maximum lands in the 64-cell polar band where the
thermal driver is 4× weaker than at mid-latitudes. **Merging the cosine deletion removes the planet's zonal
bands outright** — an honest ~0.08 replaces a fake 6.0. That is the right call by this repo's own rules, but
it is a real loss of appearance and it should be a knowing choice.

**Why there is no jet — and it is a regression I merged, not the pre-existing cause the verifier assumed.**
The tangent basis is no longer consistently handed, so Coriolis deflects half the cells backwards. Measured
with a GPU-free probe at the mid shell: **pre-seam-repair 3456 right / 0 left; current dev 1732 / 1724.** The
2-factorisation that bought slot-opposite reciprocity did not preserve orientation. Faces 0–3 are split within
themselves; face 5 is entirely left-handed. **Do not revert the seam repair** — reciprocity is correct and its
conservation win is real — fix the orientation on top of it, per-cycle rather than per-cell, since swapping one
cell's slots breaks its neighbour's reciprocity. Nothing that only needs reciprocity (soil, water, slump, lava)
is affected; everything reading tangent components (wind, scent, dust, CO₂ advection) is.

**REFUTED: "`--fast≥4` kills the population."** It does not, and the rule cost this project a 4.3× iteration
dial for weeks. There is no field/ecology clock divergence at any speed — the gap is 0.03–0.10 s in all 20
instrumented runs with no trend, and the discard path I blamed is arithmetically unreachable (it needs
`time_scale 18`; the maximum is 8). What actually happens: `max_physics_steps_per_frame` scales with the speed
*while* `time_scale` already scales the delta, so sim-time per rendered frame is **quadratic** in the
multiplier — 0.0995 / 0.533 / 1.98 / 5.28 sim-s per frame at `--fast` 1/2/4/8, a 53× spread over an 8× range.
The original measurement compared 0.4 sim days against 1.5. The fast run had not starved; it was four sim-days
older. **At equal field time: `--fast=2` → 146–174 creatures, `--fast=4` → 193–200, `--fast=8` → 213–236.**
`CLAUDE.md` is corrected. Separate real finding: deep runs kill the population at *any* multiplier (1 and 0
creatures at `field_step 3146`), which is the honest form of the livability gap.

**FAILED HONESTLY: the lava spire.** Three substrate rules tried, none moved height or shape outside spread,
nothing committed. But two things in my brief were wrong. It is not a one-cell spire — the screenshots show a
**ten-column picket fence** with visible gaps, and the same growths appear on unrelated parts of the planet.
And the vent **plugs its own column** and stops erupting around frame 300, so the height measured is how fast
it plugs, not what sustained supply builds — which means `ISLAND_FREEBOARD` was measuring a plug. Suspected
mechanism is the supply path, not the stamp: `erupt_source` writes the CPU lava mirror and never calls
`request_channel("lava")`, so a demand-gated channel gets a stale whole-channel upload ~2.6 field steps apart.

---
### ⚑ PHYSICAL-PLANET SESSION (2026-07-30, later) — rotation MERGED, energy balance WIP

Follow-on to the audit below. Addressing the four structural fakes it named. **CI green throughout.**

**MERGED: the planet turns.** Spin was gated behind `not _input.manual_rotate()`, which is
`not (_auto_spin or _geosync)` with both false — so it only ever turned if the player pressed K. It was
disabled to hide a frame mismatch (a world-fixed field against a spinning body smeared an accretion cone
into an arc). The field is **body-local** now. Reparenting would not have worked: the cell↔world mapping
is pure arithmetic off `grid.center` and never consults a transform, so the frame lives in the only two
functions that cross world↔cell space — all ~49 call sites go through them unchanged. `sun_dir`,
`camera_pos` (a POINT, so the origin offset comes out before rotating) and `spin_axis` are transformed to
match. **`ctx["spin_axis"]` had never been set by anything**, so every wind band was referenced to world
+Y while the real axis is 23.5° away. Measured: `night_frac` now spans 0.337→0.614 over 200 frames where
the old clock read `{cur:0.3, min:0.3, max:0.3}` forever. Seasons follow for free — the obliquity was
always there; what was missing is that without spin, day and year are the same period.

**WIP on `feature/energy-balance` (3 commits, DO NOT MERGE).** The mechanism is real; the calibration is
not. Every prescribed temperature target is gone: the surface does `dT = (absorbed − σεT⁴)·dt/C` with
albedo (nothing computed reflectivity anywhere before) and heat capacity from existing channels; the
`ATMOS_RELAX` anchor is deleted; the ocean thermostat and the hot-spring gate that existed only to escape
it are deleted; the core is a bounded flux instead of an infinite Dirichlet clamp. `FREEZE_TEMP` is 0.0 —
the first band-aid gone because the root was fixed.

Three measurements worth keeping, in order of usefulness:
1. **Cutting the solar constant 20% moved the global mean by ONE degree.** The sun was never the dominant
   term. Dimming it to hit an Earth-like number would have been fitting a constant to an outcome; it was
   reverted.
2. **With every prescriber removed the floor sat at 11.06 °C — and the old `AMBIENT_NIGHT` was 13.0.**
   That constant was approximately the GEOTHERMAL equilibrium. The fake had been tracking a real effect at
   the wrong scale.
3. Two conductivities were letting the interior flood the surface. `ROCK_CONDUCT` 0.004→0.0002 (floor
   11.06→9.82), then `VOID_CONDUCT` 0.016→0.0015 (floor 9.82→**4.27**). The second is the vindication of
   *deleting* the anchor rather than tuning it: at 0.096/step over six bonds the atmosphere equilibrated
   globally in ~10 steps — it conducted like a metal, which is exactly the homogenisation the anchor's own
   comment complained about. Real air is an insulator; Earth moves heat poleward by wind, which this sim
   already advects.

**Still short:** floor 4.27 °C, above freezing, so snow and sea ice are zero. Ecosystem unbothered
throughout (176 creatures, 400 trees).

**Corrected 2026-07-30, later:** the line above used to name "buoyancy mixing and the ground-hug cells'
rock coupling" as the next suspects. That was a guess, and a better answer turned up while cleaning dead
code. `LAPSE` was the **only altitude term in surface temperature**, and it died with the prescriber it
belonged to: `target = AMBIENT_NIGHT + SOLAR_WARMTH*insolation - LAPSE*altitude` was still being computed
every step by every cell for three commits, read by nothing. So there is now **no height dependence
anywhere** in the surface balance. A mountain top and a sea-level cell at the same latitude, albedo and
heat capacity reach the same equilibrium, and the snow-capped peaks and alpine treeline an old comment
credited to "geometry" are not produced by anything. That is a likelier reason for zero snow and sea ice
than a floor a few degrees too warm. Cleaned up in `ff0d8f9`, along with `ATMOS_RELAX` and five other
constants that still read as live and had misled a reader that same day.

**Do not re-prescribe the lapse.** A real surface is colder at height because the column above it is
thinner: less mass, less downwelling longwave, adiabatic cooling of whatever rises. Two of those want the
hydrostatic pressure channel; the third wants `EMISSIVITY` to vary with overlying air mass instead of
being the constant 0.9 it is now. **That is the same missing term the jet stream is waiting on**, so
pressure buys the lapse, the snow line, the ice-albedo feedback and the jet in one piece of work. It is
the next thing to build on this branch.

**A JET STREAM IS ONE TERM AWAY, and it is worth knowing before designing anything.** Wind is ALREADY 3D
per cell (`vel_x` tangent A, `vel_y` redefined as outward-radial, `vel_z` tangent B) across 20 radial
shells — height-varying wind is representable today. What is missing is that
`wind_pressure_sphere3d.glsl` is `p = P0 − K_T·(temp − T_REF)`: purely per-cell, no neighbour reads, no
air mass, no density, **no altitude term**. So pressure does not fall with height and the atmosphere has
no vertical structure. A jet stream IS the thermal wind, `∂u/∂z ∝ −(g/fT)·∂T/∂y`, and two of its three
ingredients now exist — a real meridional gradient (from removing the anchor and cutting conduction) and
Coriolis with the correct spin axis. Add hydrostatic pressure and the jet falls out of machinery already
present. Then DELETE `u = −BASE_WIND·cos(3·lat)` in `wind_step_sphere3d.glsl`, an analytic cosine standing
in for a Hadley cell — the same shape as the anchor already removed. Tell that it is load-bearing:
`WeatherSystem` was deliberately weakened so it "must not overpower the field's own latitude bands".

### ⚑ CONSERVATION + FROZEN-FAKES SESSION (2026-07-30) — merged to `0.4-dev`, CI green

Started as "read HANDOFF and do it", became an audit of what this simulation freezes in the name of
performance. Nine merges. **CI passed for the first time in this history** — it had failed on every push
since at least 2026-07-11.

**CI was red for months, and the gates were worse than red — they were vacuous.** `ripgrep` is not
installed on the GitHub runner and never was in the apt list, so `check_max_file_length.sh` printed
"rg: command not found" three times, ended with an empty file list, said "No matching files found" and
**exited 0**. `check_no_direct_refcounted_invocation.sh` wrapped its `rg` in `|| true` and reported
"passed" the same way. Both examined ZERO files on every push while two files sat over the limit. The one
step that genuinely failed required the log to contain `Cognition trace isolation test passed`, from a
test pruned in `e14c79d`. Also fixed: CI ran Godot 4.6 against a 4.7 project; a `perf-benchmarks` job ran
`tests/run_perf_benchmarks.gd`, which does not exist (Godot exits 0 on a missing script, so it burned ~21
minutes a push reporting success for nothing); the "no fallback paths" gate grepped three files under
`simulation/`, a directory renamed to `sim/`; and five lint gates never ran in CI at all. New
`scripts/lib_require.sh` makes a gate that cannot run FAIL (exit 2), never pass. `agent_harness.sh lint`
is now the single list and CI calls it. **Also: an agent session's scratchpad path was committed as the
default log dir**, and `mktemp -t` without X's is BSD-only — both broke the runner.

**`--fast=N` did nothing at all, and every measurement that leaned on it is suspect.** `Engine.time_scale`
had two owners: `parse_cmdline()` applied the flag at `VoxelWorld.gd:177`, then `LAVoxelTimeControl` was
built ~114 lines later and its `_ready()` reset the global to 1.0×. A runtime probe under `--fast=8` read
back `time_scale 1.000` with delta exactly 1/60; matched 300-frame runs gave 135 field steps at
`--fast=1` versus 113 at `--fast=8`. Fixed to one owner. Now 114 → **5705** field steps, 0.06 → **3.97
sim days**, and the day-rollover path executed for the first time. **CAVEAT: at `--fast>=4` the
population dies** (150 frames: `--fast=2` holds 180 creatures, `--fast=4` reaches 0). Creatures tick on
scaled delta while the field is capped by `max_physics_steps_per_frame`. **Use `--fast=2`.**

**Night did not exist.** `LAVoxelSkyCycle` latches `_planet_mode` and returns before `_advance_clocks()`,
so `time_of_day` stayed at its seed: the gauge reads `{"cur":0.3,"min":0.3,"max":0.3}` across a whole run.
`is_night()` answered FALSE for every creature, forever — diurnal animals never rested, nocturnal ones
never woke, and the `night` bit in the learned-policy signature was constant, so **half the signature
space was unreachable and every heuristic any creature has learned is a daytime heuristic**.
`LACreatureLod`'s cost model documents "a fraction of the population is always asleep"; it was not.
Dissolved rather than repaired: `is_night_at(pos)` is `dot(local_up, sun_dir) < 0`. The terminator was
physical the whole time. New `night_frac` (0.479) and `resting_frac` (0.441) gauges.

**Water conservation is now instrumented and mostly honest.** Nothing measured it before —
`smoke_check.sh` only asserts h2o is finite and non-zero, so a run losing half the planet's water passed.
The four ledger legs used four different cell predicates, so any transfer crossing the static boundary
minted or destroyed ledger mass while the GPU buffers stayed conserving. Unified. New gauges:
`h2o_closed_total`, `h2o_drift_per_step`, `static_water_total`, `soil_stranded`, `h2o_inject_minted`,
`h2o_displaced`, `h2o_buried`, `h2o_stale_rewind`. Storms no longer mint water (`add_vapor` is a real
transfer; shortfall reported, `h2o_inject_minted` 0.00). Injections no longer overwrite the live GPU
buffer with a one-frame-stale CPU mirror (`h2o_stale_rewind` measures what that used to destroy: ~15
units a run). `MineralStamp3D` displaces water out of cells it solidifies instead of stranding it.
**Keystone C's asymptotic half started**: compacted active-cell list + indirect dispatch, proven on
`lava_phase`.

**The photosynthesis "-93% biomass regression" was not one.** The old R19 was gated `GATE_SURFACE`, which
on a shell means the TOP OF THE ATMOSPHERE. Measured: biomass at the sky skin 2334, **at the ground skin
0.0**. All primary production was happening in the stratosphere. Comparing that total to ground biomass
is comparing a bug to its fix. Trees and plants are identical across the change (400/400, 439/439).
`PHOTO_WATER_COST` retuned 0.2 → 0.05, which gives MORE vegetation and **six times** the wet/dry contrast:
a cost that heavy makes the water cap bind everywhere, flattening the contrast it exists to create. Same
trap as `FERT_UPTAKE_COST`, which was cut 25× for the same reason.

**What is still frozen, ranked by how much it distorts the sim** (full audit in the session log):
1. **No radiative sink anywhere.** `heat3d_solar` relaxes toward a prescribed target; its own comment says
   that "mirrors radiative cooling to space", and `ATMOS_RELAX = 0.14` is deliberately tuned to OUTVOTE
   real conduction. The ocean is a thermostat dragged to `SST_SURFACE = 26.0` by fiat. The core is an
   infinite constant-temperature source. **Four separate band-aids exist because of this**: `FREEZE_TEMP`
   moved to 12.5 °C because 0 °C "can never fire here", a whole `HOT_SPRING_GATE` invented to escape the
   thermostat, arc volcanoes "kept rare so sustained volcanic heat doesn't accumulate", and
   `CLOUD_OPACITY_CAP = 0.22` clipping a real feedback to stop a snowball runaway. One fix deletes all four.
2. **There are no seasons and, by default, no planet rotation.** `ctx["spin_axis"]` is never set by anyone,
   so the field's pole is world +Y while the planet spins about a 23.5° axis; the heliocentric orbit runs
   entirely in the XZ plane, so the sub-solar latitude is pinned at the equator forever. `SystemOrbits`
   documents seasons it structurally cannot produce. Spin is off by default and is explicitly FROZEN for
   the seabed-volcano demo to hide a field-vs-terrain frame mismatch.
3. **The Star is not in the `gravity_body` group** (`Star.gd` never calls `add_to_group`), so meteors feel
   planet + moon and ZERO solar gravity, while the planet's orbit runs on a separate `SUN_MU` in
   disconnected units — against `Gravity.gd`'s stated HARD PRINCIPLE of "no hardcoded single-centre
   gravity anywhere". One line.
4. **`resample_terrain` has zero callers**, so every meteor crater exists in the mesh and the collision but
   not in the physics. Water will not pool in it.

---
### ⚑ ADDON-UX SESSION (2026-07-29) — MERGED to `0.4-dev`, lint green
Goal: make `addons/local_agents/` installable and usable without reading its source.
*(Corrected 2026-07-29. This heading said "IN FLIGHT on `feature/addon-ux`, not yet merged", with worktree
`../local-agents-addon-ux` and "**Lint is intentionally RED on this branch** until the renames below land".
All three are false now: the work is on `0.4-dev` as `06d943c` + `c48200c`, the branch and worktree are gone,
and `scripts/agent_harness.sh lint` measured GREEN — "All lint gates passed", `check_public_surface: OK
(25 public, 130 classes reach a dialog)". The "currently FAILS with 24 named offenders" note below is
likewise the pre-rename state, kept only as the record of why the gate was written.)*

**Landed and verified.** Directory split into `sim/` + `game/`; 58 classes canonicalized; dead types
removed (`ModelParams`, `Character`, `RuntimeHealth`, `api/`, `addons/phantom_camera/`); inspector
surfaces for agent/creature/world/field/cognition; every example rebuilt as a real scene (three scripts
deleted outright, the rest cut 40-70%); the addon's icon set. **The acceptance gate passes**:
`scripts/check_dropin_scene.sh` stages a consumer project holding only `addons/local_agents/`, authors
a scene with no script in it, and gets `DROPIN_REPLY=Paris` from a local 4B model. Run it with
`scripts/agent_harness.sh dropin` (3s), or `LA_GATE_MODEL=<path>.gguf` for the full reply mode.

**`LocalAgent.say()` was dead in every install and now works.** The native path needs a `piper` binary
that is not shipped, so `AgentSpeech` went through it and produced nothing, while the streamer already
ran `python -m piper` in `StreamerVoice`. Both now share `agents/SpeechEngine.gd`
(`LocalAgentSpeechEngine`): piper binary, then python piper, then `DisplayServer` TTS, then one warning.
Verified by an independent agent in a scratch project: 78380-byte wav, real PCM, 601 ms.

**New gates, all wired into `agent_harness.sh lint` and each observed failing on purpose.**
`check_public_surface.sh` (only sanctioned public API may reach a creation dialog under the
`LocalAgent` prefix, currently FAILS with 24 named offenders), `check_tool_safety.sh`,
`check_demo_catalog.sh`, and `check_library_only.sh`, which was strengthened after it was found passing
green over three real breaks. Two measured facts are baked into it: an editor scan only loads what
something references, and `load()` on a script with a missing preload returns NON-null while printing
the error to stderr. It now force-loads all 217 scripts (`scripts/parse_all_scripts.gd`) and greps.

**Boundary truths that gate then exposed.** `audio/` is NOT game-only: `CreatureThink.gd:158` and
`sim/actors/{Meteor,LightningStrike,Flood,Volcano}.gd` all call `LAAudioDirector.emit()`, so it
is core and the staging no longer deletes it. `game/ui/SceneEnergyGraph.gd` moved to `sim/streamer/`,
next to the only code that used it, which removed the last `sim/` to `game/` edge.

**Naming.** 23 internal classes renamed off the public prefix, so `check_public_surface.sh` now holds
the line: typing "LocalAgent" in Add Node returns 25 types and every one is meant to be used. The
speech surface was renamed too: `say`/`listen` became `speak`/`transcribe`, because `speak` already
outnumbered `say` 71 to 8 in-tree, `say()` beside `think()` reads as "speak what you thought" (it
vocalizes whatever String you pass), and `listen()` never opened a microphone at all, it transcribed a
file path. `LocalAgentSpeechEngine` moved from `agents/` to `runtime/audio/`, which let
`AgentStatus._speech_ok()` stop asking for a piper binary the addon does not ship and start asking
whether anything can speak. That was the real cause of a healthy install reporting itself degraded.

**Two constants dissolved rather than tidied.** `Meteor` had a flat `1600.0` °C injected on impact
regardless of how it arrived, plus a separate hardcoded orange for the visual, so the look and the
physics could disagree about the same rock. Temperature is now an outcome: heating goes as air density
times speed cubed, cooling as the excess over ambient, and **air density is read from the field's own
`o2_at()`** rather than from a scale-height formula living inside the actor. Measured spread: 600 u/s
in thick air reaches 1541 °C and glows, 300 u/s reaches 140 °C and does not, a 150 u/s lob stays cold,
and 600 u/s in vacuum never lights up but still craters at 1380 °C from kinetic energy alone. None of
that is written down anywhere. `LAHeatGlow` is wired to it, and its header no longer claims creatures
and trees glow: they combust (`Creature.gd:79`), which the code already did correctly.

**Duplicates collapsed.** `LlmService.resolve_model_path()` had its own `MODEL_CANDIDATES` list and a
re-try of a step that could never fire; it now defers to `LocalAgentStatus`, the one resolver. And
**`VoxelWorld.tscn` now mounts a `LocalAgentDemoHarness` like every demo scene.** The stated reason it
could not ("it needs --perf-frames and --bench") was never true: of 20 flags exactly 3 overlapped, and
`LASimReport.snapshot()` already returned the payload in the shape the harness wants. `VoxelHarness`
split into `build_report()`, the harness owns counting, printing, `LA_RUN_COMPLETE` and the exit, and
`--perf-frames`/`--bench` stayed in `VoxelInputController` where they belong. `LAGenome` is deleted,
its own header having set the removal condition. Verified windowed at 200 frames: POP_TRACE at 180,
SIM_REPORT, `LA_RUN_COMPLETE={"code":0}`, exit 0.

**Backstory is wired (2026-07-29, merged).** `LocalAgent` has a long memory: assign a
`LocalAgentBackstoryGraphService` to its Backstory slot, give it an `npc_id`, and every line in and out
is ingested into the SQLite store, with the most relevant memories recalled into a system message ahead
of each prompt. Semantic search first, recent-and-important as the fallback when no llama-server with
`--embeddings` is up. New module `agents/AgentBackstory.gd`; `Agent.gd` gained only exports and two
call sites. `tests/test_agent_backstory.gd` asserts on the RECALLED TEXT, not on any call reporting ok,
because the first version returned ok everywhere and recalled nothing (it looked for row keys
`memories`/`results`/`rows`; the one carrying recent memories is `candidates`). Mutation-tested.

**Still owed in Backstory.** Only conversation memory is connected. Relationship state, belief versus
world-truth with `detect_contradictions()`, sacred sites and rituals, and the oral-knowledge lineage
with transmission hops are all still reachable only by hand. That last one is most of the "signal
spine" 0.5 wants, and it is the interesting one: knowledge spreading between characters with
provenance.

**Correction, same day: quests and factions are NOT the RPG-shaped leftovers this entry first called
them.** That was reading the nouns instead of the signatures.

- **Factions are what `family_id` is already failing to be.** Group identity today is a bare integer
  declared `var family_id: int = 0` (`Creature.gd:250`, mirrored at `Fish.gd:110`) and defaulted to the
  creature's own instance id in the setup path, `c.family_id = int(config.get("family_id",
  c.get_instance_id()))` (`CreatureSetup.gd:119`, mirrored at `Fish.gd:163`).
  *(Citation corrected 2026-07-29: this said the declaration itself was `var family_id: int =
  get_instance_id()` at `Creature.gd:250`. It is not — the instance-id default lives in `CreatureSetup`,
  not on the field. Same wrong quote is at `GODOT_BEST_PRACTICES.md:519` and in item A below.)*
  It carries no name, no founding day and no metadata; it dies with its
  members, so a warren has no existence apart from the animals currently in it; and two groups cannot
  relate to each other, so rival packs and allied herds are not expressible.
  `upsert_faction(id, name, metadata)` plus
  `add_relationship(npc, faction, "MEMBER_OF", from_day, to_day, confidence, source, exclusive)` gives
  all of that AND membership over time, so a creature that leaves one pack for another has a history
  rather than just a different integer. Inter-faction `add_relationship` is territorial conflict.
- **Quests are the long-horizon intention the cognition stack does not have.** Its drives are per-tick
  (energy, hydration, fear). Nothing represents "I have been trying to do X since day N and here is
  where I got to". `update_quest_state(npc_id, quest_id, state, world_day, is_active, metadata)` is
  exactly that. A bird building a nest over days, a herd migrating, an animal seeking new territory
  after being driven out. In this codebase a quest record is not authored content, it is a record of an
  intention a creature FORMED, which is what the slow brain is for and what it currently cannot
  remember having decided.

**`feature/thaw-tropics` is RETIRED (2026-07-29), measured obsolete rather than abandoned.** Both v2 and
v3 are deleted, local and remote. Do not resurrect it without re-reading this.

The patch existed to break an "equatorial ice-albedo freeze-lock" that held `t_eq` at 7C. That
condition no longer exists: a baseline `0.4-dev` run reaches `t_eq` 12.5C by frame 180 and 29.2C by
1080, so whatever fixed it arrived in the intervening work. Measured head to head, same seed 7, same
`--fast=4`, same 1200 frames:

| frame | baseline t_eq / foxes | with the patch |
| --- | --- | --- |
| 180 | 12.5 / 10 | 15.5 / 10 |
| 540 | 18.0 / 10 | 20.3 / 7 |
| 900 | 25.1 / 10 | 29.7 / 6 |

So it solves a problem that is already solved and costs 40% of the fox population doing it, which is
the same fox decline the original author reported and paused on. Two independent observations agree.

Two corrections worth keeping, because both were mine and both were wrong in the same session. The
monotonic `t_eq` climb is the BASELINE's behaviour under `--fast=4` (solar forcing compressed), not
something the patch introduced. And an earlier partial read of only the early samples said the fox
decline "does not reproduce"; it does, from frame 540 on. Caveat on the surviving claim: one seed, one
run, so 10-vs-6 could carry noise. The obsolete-premise finding does not depend on it.

The idea is still sound if the freeze-lock ever returns: insolation-driven melt with an albedo-feedback
bound, in `heat3d_solar_sphere3d.glsl` + `ThermalPass.gd`, 37 lines. `git log --all --oneline` will not
find it after this, so the shape is recorded here deliberately.

**Superseded note, kept for provenance.** `feature/thaw-tropics-v3` replaced `feature/thaw-tropics-v2`, which edited
`scenes/simulation/voxel/material/...` and could no longer be applied at all after the restructure. Same
change, ported onto `sim/` paths, both hunks clean via `--3way`. STILL UNVERIFIED, DO NOT MERGE: the
climate half works (t_eq ~15.5C against a 7C locked baseline, poles cold, sea ice persists) but
population still declines, foxes go extinct, and tmin dipped to -6C against a ~0C baseline. Resume by
pulling death causes at f~2000, checking the -6C is not a new cold-kill, then re-running multi-season
with density-dependent breeding.

**Process lesson worth keeping.** Seven of seven fan-out units FAILED their adversarial verification
first time, and the verifiers were right nearly every time. Two fix agents then introduced NEW false
claims while correcting old ones, so a fix pass needs its own recheck. Eleven dated entries were added
to `GODOT_BEST_PRACTICES.md`; the load-bearing one is that an `@export` nothing reads is
indistinguishable from a working one, and only running the model proved `system_prompt` was dead.

---
**REMAINING (pick up in this order):**
- **#24 — ✅ MERGED 2026-07-30. The static sea is gone and the planet no longer mints water.**
  Three runs at `field_step 746`: `static_cells` **3480 → 0**, `h2o_static_water` **2733 → 0.0**,
  `h2o_total` 14012–14019 → **5956–6201** (the honest figure), `soil_total` 3531–3551 → 173–205,
  creatures 175–197 → **177–190** (held), `field_ms` min 3.00–3.60 → 3.10–3.36 (unchanged).
  - **⚠ `biomass_total` fell 41%: 1594–1605 → 933–951.** Attributable, not mysterious: the minted water
    entered through the `atmosphere` leg at +6.61/step, so it became moisture, then rain, then plant water.
    A large part of the old biomass was fed by water that did not exist. **Do not revert this** — 933–951 is
    the first honest measurement of what this water cycle supports. **See #32: how much water the planet
    should START with is a design decision, and it is now open.**
  - *What this entry used to say, kept because it was wrong in an instructive way:* "the dynamic sea is
    half-done, DO NOT MERGE, blocker: soil_total drains, root cause unknown." The drain was real and is
    fixed; the "loses the planet's water" premise was inverted — the other arm was minting. Both arms start
    at the same 7485.40, which is the check that would have caught it on day one.
- **#24-history — the static mask MINTED water, and here is the proof.** The static mask makes
  `atmos_evap_sphere3d.glsl`'s `added += e * static_brake` run **with no matching debit**, so the sea
  evaporates water it never loses. Restoring the single line `_static[c] = 1` for one run: 7488.26 →
  13751.54, **+6263.28 minted** (a verifier reproduced +6616.87 and +6635.40). Dev's `h2o_total` of ~14000 is
  roughly half invented, and every water figure in this file's history is inflated by it.
  **The fix is measured and sitting on `feature/soil-drain-fix`** (4 commits off `a038e4b`): the dynamic sea
  **conserves to 0.00–0.22% over 766 steps**, with `legs_all` = 0.0000 for all twelve passes at every sample.
  It also carries `MaterialFieldH2OBudget3D.gd` (`LA_H2O_BUDGET=1`), the instrument that proved it.
  - **Rebase notes.** Three files collide. `SphereGrid.gd`: **drop the branch's change** — it is the old
    `validate()` reciprocity check, superseded by the 2-factor pairing and the tangent-basis tables.
    `MaterialSphereGPU3D.gd` and `MaterialFieldSphereStep3D.gd`: both sides are purely additive, take both.
  - **Doc fixes required first:** every quoted range on that branch is too narrow, and the headline
    "0.00–0.09%" is **non-overlapping** with the verifier's 0.11–0.22%. Honest combined range 0.00–16.70
    units. And its "caveat 2" is wrong — the residual is exactly `h2o_buried`, 3 of 3 to snap precision.
  - **Expect a large CORRECT shift, not a regression:** `soil_total` ~3540 → ~105–165, `static_cells` 3480 →
    0, `h2o_static_water` 2733 → 0, `h2o_total` ~14000 → ~5700. The dynamic numbers are the honest ones.
  - ~~"BLOCKER: soil_total drains, root cause unknown"~~ — resolved. Springs ran at the stability cap because
    conductance multiplied a head in world units, and downward head was positive by construction so cells
    drained into whatever sat beneath them. Fixed; `kernel_delta` now oscillates about zero and the residual
    decline is R19 root uptake, i.e. plants drinking.
- **#25 — ~~`--fast>=4` kills the population~~ REFUTED 2026-07-30. `--fast=8` is safe and 4.3× faster.**
  There is no clock desync: the field/ecology gap is 0.03–0.10 s in all 20 instrumented runs with no trend,
  and the discard path this entry blamed is arithmetically unreachable (needs `time_scale 18`; max is 8).
  What was really happening: `max_physics_steps_per_frame` scales with speed *while* `time_scale` already
  scales the delta, so **sim-time per rendered frame is quadratic in the multiplier** — 0.0995 / 0.533 / 1.98
  / 5.28 at `--fast` 1/2/4/8. The old measurement compared 0.4 sim days against 1.5; the fast run had not
  starved, it was four sim-days older. **At equal field time: `--fast=2` → 146–174 creatures, `--fast=4` →
  193–200, `--fast=8` → 213–236.** Compare at equal `field_sim_s`, never equal `--run-frames`.
- **#26 — the energy balance, WIP on `feature/energy-balance`, and NOW UNBLOCKED.** Mechanism complete,
  calibration short: floor 4.27 °C, snow and sea ice zero. ~~Buoyancy mixing and the ground-hug cells' rock
  coupling are the next suspects~~ — that was a guess and it is superseded twice over. First: **`LAPSE` was
  the only altitude term in surface temperature and it died with the prescriber**, so nothing makes high
  ground cold. Second, and this is the opening: **air mass now exists as a channel**, so `EMISSIVITY` (a
  constant 0.9) can finally vary with the overlying air mass. A thinner column above means less downwelling
  longwave, which is the real reason a summit is cold — and it gives the lapse, the snow line and the
  ice-albedo feedback in one change, without re-prescribing anything. Rebase the branch onto current dev
  first; it predates the air channel entirely.
- **#27 — DONE 2026-07-30, and its premise was already stale when written.** This item said the
  `--auto-seavolcano` spin freeze still existed. **It did not.** Commit `440a86d` ("the planet turns") had
  already removed `and not _input.auto_seavolcano()` from `VoxelWorld.gd`, and simply never re-ran the
  capstone to check. What survived was the freeze's *paperwork*: `Volcano.gd:15-20` still asserted the spin
  was frozen, and `VoxelInputController.auto_seavolcano()` was an orphan whose only caller had been the
  deleted gate. Both are gone now, along with the verification `440a86d` skipped.
  - **The cone holds its position with the planet turning.** "Smeared into an arc" is a shape and no scalar
    told it from a cone, so `Volcano.cone_profile()` now takes a baseline radial profile on a body-local
    polar grid around the vent and subtracts it later, leaving exactly what that vent added. Reduced to
    second moments it gives `drift` (angular distance to the grown material's centroid) and `smear`
    (major/minor half-width: ~1 round, >>1 an arc). Measured `smear` 1.03-1.29 across the agent's runs and
    1.13/1.18 on the verifier's, at equal `field_step 3146`. It is a pile, not a band.
  - **Corrected before merge:** the agent's own commit says the planet turns "~1.6 rotations", reading
    `sim_days` as rotations. `PLANET_SPIN_RATE = 0.10` rad/s against `LASimClock.DAY_LENGTH = 200.0` s makes
    `sim_days 1.6` **5.09 rotations**, carrying the vent about **14,040 units**, not 5,000. The error runs in
    the conclusion's favour, so the finding stands and is stronger than claimed.
  - **`ISLAND_FREEBOARD` is deleted but its root is NOT fixed — see #28.** It was not inert (657 of 5120
    deposit attempts, 13%), it just never did its stated job.
- **#28 — the runaway lava tower, still unsolved.** With `ISLAND_FREEBOARD` engaged the seabed pile stood
  **107-116 units above sea level against the 14-unit freeboard it names**, and removing it changed nothing
  outside run-to-run spread. It only ever chose WHICH column in the vent disc took the next deposit; height
  is set downstream by quench/solidify/stamp, which no supply routing reaches. It also tested a one-cell-wide
  spire with a single ray that misses it and reports the seafloor far below. **The fix belongs in the
  substrate's stamp response to accumulated `rock_fill`**, not in supply routing. Deleting the clamp was
  right — it told every reader this was handled — but the runaway is still there.
- **A4 — dogfood: rebuild `VoxelWorld` -> Anima.** Refactor the 730-line inline `VoxelWorld._ready` to
  COMPOSE from `SimWorld` + the reusable nodes, and RENAME the game `VoxelWorld` -> **Anima**. HELD for
  direct/supervised handling — it rebuilds the composition root, so it needs launched-window verification.

**Branch/worktree state (2026-07-30):** `0.4-dev` is the integration branch and CI is GREEN on it.
Outstanding feature branches: `feature/dynamic-sea` (#24) and `feature/energy-balance` (#26), both WIP and
deliberately unmerged. `sorting.py` at repo root is the maintainer's, untracked — leave it.

### ⚑ STANDING FACTS — engine limits and deferrals rescued from six deleted session logs

Six completed session logs (LIBRARY-REFACTOR 07-12, PERF-FIRST 07-22, RELEVANCE-LOD 07-23, REPO-HYGIENE
07-23, FERTILITY-UPTAKE 07-23, FIELD-READBACK 07-23, THOUGHT-PANEL 07-24) were DELETED on 2026-07-30 —
about 360 lines of finished narrative whose work is merged and whose shipped features are already listed
under "Shipped in 0.4 so far". What follows is everything in them that is still LIVE, which is the only
reason any of it survives. Do not re-derive these.

**Engine limits, measured here, still true:**
- **`buffer_get_data_async` returns STALE data** for compute-shader-written buffers on Godot 4.4+ (open
  engine bug [#105256](https://github.com/godotengine/godot/issues/105256)). Do not use it to fix readback.
  Forking the engine was considered and explicitly rejected.
- **There is NO GPU-side execution timer in this build.** `gpu_ms` is always `0.00`; `field_dispatch_ms`
  measures CPU-side command RECORDING, not shader execution. `capture_timestamp` is illegal while a compute
  list is open (fixed), but `get_captured_timestamps_count()` still reads 0 in this driver even for the
  smallest case. Metal's `get_captured_timestamp_gpu_time` always returns 0 regardless; Vulkan/MoltenVK
  works, and `LA_RENDER_DRIVER=vulkan` exists for a one-off diagnostic. **So read fps/`field_ms` as
  directional only, and never claim a dispatch-side perf win from them.**
- `field_readback_ms` (~4.4-4.7 ms) dominates `field_dispatch_ms` (~0.13-0.19 ms) by 25-30x, so
  dispatch-side savings stay invisible until readback is addressed.

**Keystone C deferrals, with the reasons, so nobody re-attempts the unsafe ones.** The old "extend the
gate to the other 8 passes" instruction was WRONG as written — several of those passes are continuous
planetary forcings, not sparse events, and gating them on an activity bubble silently disables them
almost everywhere. Still deliberately ungated: `magma_buoy_sphere3d.glsl` (its 2-pass donor/receiver
transfer loses mass under per-thread gating — needs wake-on-inject first), `AtmospherePass` (the ocean is
a perpetual unconditional source), `ReactionsPass` (background biology is active almost everywhere —
would need per-record gate bits), `EcoSurfacePass` (mixed sparsity, already cheap), `SolidDerivePass`
(runs before relevance exists), and the continuous legs of `ThermalPass`/`GasWindPass`.

**Still owed on readback:** GPU-side reduction kernels for the `report()` aggregates that read back a FULL
per-cell array just to sum it on the CPU — `hot_cell_count`, `active_cells`/`mean_relevance`, `soil_total`,
`sediment_total`/`susp_total`, `_open_temp_stats`, `mineral_total`, `scent_cell_count`, in that order of
callsite frequency x array size. Likely the larger remaining lever. Measure with `--bench=readback`.

**Determinism caveat:** even with a fixed `--seed=`, back-to-back runs are close but NOT bit-identical
(229 vs 225 creatures at the same frame). Most likely physics-tick/real-delta coupling. A fixed physics
timestep decoupled from wall-clock is the natural fix if bit-exact reproducibility is ever needed.


## North-star
- **Dissolve, don't patch (THE CORE):** ONE physical substrate (`MaterialField3D`) — matter with pressure/
  temperature/phase/gravity/momentum + chemistry (a generic DEFS reaction engine). Named phenomena
  (volcano, eruption, tornado, storm, weather, decomposition, …) have **zero dedicated behavior code**; they
  EMERGE. Removing a hack (a timer/cap/`restock`-from-nowhere/special-case) and making it emergent is the
  **definition of done, not an optional feature.** Success = special-case code DELETED.
- **Emergent-everything** · **3D always** (no 2.5D holdovers) · **GPU/native-first, GPU-GLSL-only** (no CPU
  oracles) · **perf-first** (playable frame-rate is first-class) · **Big-O first-class** (better-scaling
  structures + do-less-by-relevance/LOD + activity bubbles) · **bias to action** · **config over `if
  species==X`**.
- **Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND a full game that is the
  flagship demo. Local LLMs drive creature cognition + the streamer, fully offline — headline this.

---

## 0.3 — THE CARETAKER GAME (SHIPPED as 0.3.1, tagged `v0.3.1` on `main`)

*(Heading corrected 2026-07-30: this said "current release — nearly done" long after 0.3.1 shipped. The
feature list below is kept as the record of what the game contains, not as a work list. Three items in its
tail were never done and are NOT 0.3 blockers — insects/flowers/bees (#76), rebuilding the native
extension (#71), and shooting the trailer. Treat them as backlog against a future release, not as
outstanding work on a shipped one.)*

A caretaker god-game on an emergent chemistry planet, driven by local LLMs, shipping as a native itch.io
download. **The game is feature-complete, playable (~67 fps default @ 720p), and exports to a standalone
build that boots.** Everything below is MERGED on `feature/sphere-followups` unless noted.

### Done + integrated
- **Emergent world:** cubed-sphere chemistry substrate (one conserved H₂O; DEFS reaction engine; biomass/
  photosynthesis; rock/mineral unified; GPU water-particle render). Solar terminator, geothermal **hot core +
  temperate surface via crust insulation**, water cycle, snow line, carbon loop.
- **All disasters DISSOLVED** into the substrate (Volcano/Meteor/Tornado/Hurricane/Earthquake/Thunderstorm-
  Lightning) — momentum/ejecta + charge→bolt + shock + local heat/vapor injection primitives; disaster actors
  are seeds/visuals only. Emergent phenomenon **event tracker** feeds the streamer + telemetry.
- **Outer-Wilds N-body gravity + moving-frame solar system:** meteors are test particles (orbit / flyby /
  slingshot / launch anywhere); the planet carries a heliocentric orbital state driving the **sun across the
  sky, seasons (23.5° tilt), and insolation** (orbit-distance² × atmospheric dust → **bake / freeze / impact
  winter**); a **moon** orbits the planet; a meteor **volley knocks the planet toward the sun or out of the
  system** (momentum). Debris/ejecta perf-bounded (pooled). Full literal planet-flight = 0.5.
- **Living, learning creatures:** clustered herds + permanent **kinship graph** + sticky leadership;
  **value-based cognition** (multi-sense reward valence — pain/fear/suffocation/cold; drive-modulated risk
  tolerance; learned-lethal **veto**; social aversion spread; **followers learn too** → ~95% of the population
  learns, not just leaders). Family-tree inspector. **Sustainable ecosystem** (renewable pasture, capped
  breeding, prey pyramid — stable ~130). Fish eat bugs/shrimp (aquatic web given a bottom).
- **The game:** campaign **progression** (start constrained → unlock overview → orbit → geosync → **solar-
  system view** capstone) · **Sandbox** mode · gamified **HUD** (objectives/progress/unlock toasts) ·
  **main menu + settings** · **quality settings** (Graphics Potato/Low/Medium/High/Ultra + separate Sim/AI
  category, numeric sliders, per-setting tooltips) · **save/load** (full world + learned cognition + kinship +
  progression, slot-based) · in-UI **tutorial** (first-run campaign) + **help/reference** (controls auto-gen
  from the hotkey registry, codex, tooltips) · **hotkeys** (digit-select palette + full map) · audio/music
  (salted; silent in editor/debug, on in the release) · human **huts**.
- **The local-LLM showcase (the identity):** click a creature → its **actual on-device reasoning** (thought
  inspector) + the streamer; **LLM-thinking control** (per-creature/group on/off + highlight/select who's
  thinking/queued).
- **Model UX:** in-game **downloader** (ungated Q4, size + EMA ETA) + **model management** (HF-cache reuse,
  bring-your-own GGUF, rich inference config).
- **Release/tooling:** native **itch export** (presets + build script + `docs/EXPORT.md`; boots standalone) ·
  **credits** screen + `AUTHORS`/`CREDITS.md`/`THIRD_PARTY_LICENSES.md` (Kenney, Quaternius, Zylann/godot_voxel,
  engine, models) · **quickstart node** + identity/origin README + demos ladder · **crash-on-quit fixed**
  (native `LAProcess._Exit`, rc 0) · GPU teardown/RID cleanup · 3D-query port (sphere-correct field reads) ·
  perf (**vegetation MultiMesh instancing**, playable default) · **30s trailer script** (`docs/TRAILER.md`).

### 0.3 remaining (the tail)
- [~] **Emergent decomposition + fish fix** (running) — carcasses decompose via a warmth/moisture-gated
  bacterial bloom into the existing detritus→fertility+CO₂ loop (mummification/permafrost fall out free); fish
  no longer suffocate in shallows. (#74 + polish)
- [ ] **Insects + flowers + bees** (#76, next — de-hacking, NOT a feature) — bugs/shrimp eat real biomass/
  detritus (drop the `restock`-from-nowhere hack); add a land-insect layer; flowers + more plants; **bee↔flower
  pollination mutualism** (visiting spreads pollen → pollinated flowers spread). Broadens the web for stability.
- [ ] **Rebuild the native extension** (#71) — activate the `LAProcess`/clean-quit primitive in the shared bin;
  verify rc 0 end-to-end. (CI/release build does this automatically for the shipped build.)
- [ ] **Shoot the 30s trailer** (per `docs/TRAILER.md`) + a few looping GIFs for the itch page/README.
- [x] **0.3 shipped** — released as **0.3.1** on `main` (tagged `v0.3.1`; macOS + Linux builds on the GitHub
  release). `0.3-dev` retired; development continues on `0.4-dev`.

---

## 0.4 — THE EMERGENT PLANET (current release — the physical world as the star)

The substrate is genuinely **~70% there**; almost every gap below is **coupling / read-out of fields already
simulated**, not new systems (full audit + file:line detail: the domain-audit synthesis). Guiding: dissolve-
don't-patch · emergent-everything · perf-first · Big-O + activity-bubble LOD · **fakery = the LOD tier** (full
sim in the compute-bubble; cheap analytic stand-ins for distant/dormant/offscreen, re-materialize on approach).

**3 KEYSTONES (everything leans on these):**
- **A — Erosion re-land. SHIPPED.** *(Corrected 2026-07-29. This entry said for weeks that the pickup kernel
  "doesn't exist", and it does.)* `sim/material/kernels3d/erosion_pickup_sphere3d.glsl`, driven by
  `sim/material/sphere_passes/ErosionPickupPass.gd`, registered at `MaterialSphereGPU3D.gd:51` immediately before
  `ReactionsPass` so M3 SETTLE reads the freshly-scoured `susp` in the same step. `susp` is a live phase in the
  mineral ledger, not a dead one. Still owed is the BEHAVIOURAL proof that deltas, beaches, canyons and
  floodplains actually form over geological time, which needs C's fast-forward before it can be observed.
- **B — Moisture→vegetation→albedo. THE ONE GENUINELY OWED KEYSTONE.** *(Visual half SHIPPED in Wave-1 biome
  color.)* Sim half still owed and confirmed still owed on 2026-07-29: `grep -n moisture
  MaterialReactions3D.gd` returns one comment about H₂O conservation and nothing else, so a dry plateau greens
  like a rainforest.

  **The gap is bigger than this entry said, and the fix is not small.** *(Corrected 2026-07-29. This read
  "R19's reactants are CO₂, FERT, light and temp" and prescribed "moisture as a third Liebig-limiting reactant
  beside FERT, plus a germination gate". Light is NOT a reactant — that was the record's own header comment
  being read as if it were the code.)* R19 is
  `_rec(BILINEAR, PHOTO_RATE, CO2, [[CO2, 1.0], [FERT, FERT_UPTAKE_COST]], …, GATE_SURFACE, 0.0, TEMP)`
  (`MaterialReactions3D.gd:220`), i.e. `x = PHOTO_RATE * co2 * temp`, and `:215` says what `temp` is doing
  there in as many words: *"temp = the daylight proxy; the day side is warmer → fixes more"*. **Photosynthesis
  is being driven by the temperature field standing in for the sun.** So a hot desert fixes carbon at night, a
  bright cold polar summer barely fixes any, lava and wildfires feed plants, and volcanic-dust dimming only
  suppresses growth second-hand through cooling.

  It is a plumbing gap, not a design choice, and the kernel admits it: *"NEAR_GROUND / DAYLIGHT: no live record
  needs them yet (would require radial+sun_dir bindings)"* (`reactions_sphere3d.glsl:186`). Both already exist
  in the driver — `heat3d_solar_sphere3d.glsl` computes real per-cell insolation as
  `max(0, dot(cell_radial, sun_dir))`, `radial` is a bound per-cell buffer, and `sun_dir` is already a pass-
  context value (`ThermalPass.gd:150`, `:285-287`). Likewise the `soil` water table is a real channel in the
  conserved H₂O ledger (`MaterialSphereGPU3D.gd:29`, `MaterialFieldLedger3D.gd:104`) with **no biological
  consumer at all** — it feeds infiltration, baseflow and springs only. So Keystone B is: bind real light and
  soil water into the reaction engine, make R19 light-driven with CO₂/water/nutrient as Liebig limits and
  transpiration as a conserving soil→moisture transfer, and delete the temp-as-daylight proxy. Adding a
  moisture cap on top of the proxy would have cemented it.
- **C — Activity-bubble field LOD. SHIPPED IN ITS CHEAP FORM; the asymptotic half is owed.** *(Corrected
  2026-07-29. This entry said "Not built".)* `sim/material/kernels3d/activity_sphere3d.glsl` +
  `sphere_passes/ActivityPass.gd`, registered at `MaterialSphereGPU3D.gd:55` before FireDustPass, computing a
  wake-bubble plus camera-proximity relevance channel, with an `LA_NO_ACTIVITY_LOD=1` A/B knob. But the second
  half of the old sentence is still true: gating is per-cell stride and early-out, so every kernel still
  dispatches the full grid and cells merely bail. That saves ALU, not dispatch or bandwidth. CLAUDE.md sanctions
  the early-out form as the floor, so this is a deliberate stopping point rather than a relic. **Before building
  the O(active) indirect-dispatch version, run the `LA_NO_ACTIVITY_LOD=1` A/B that already exists** and find out
  whether the shipped gating buys measurable frame time. That measurement decides whether the rewrite is worth it.

**TIERS** (SIMULATE = emerge from substrate · FAKE = justified LOD/cosmetic · [✓]=shipped this session):
- **T1 (do first, small):** hot springs (in flight) · moon tides [FAKE] [✓] · altitude lapse [✓] · default-look MSAA/grade [✓ partial] · moisture growth-gate (Keystone B sim half).
- **T2 (core systems):** biome coloration [✓] · **erosion pickup kernel (Keystone A, L)** · weathering + lithification (2 DEFS records) · Coriolis + orographic wind [✓] · snow render from real `_snow` field + honest 0°C freeze · sea ice at poles [✓] · fertility→growth loop [✓ closed 2026-07-23, fertility-uptake session — R19 photosynthesis now consumes FERT as a Liebig-limiting reactant] · emergent river supply (highland baseflow + snowmelt) · **radiative-sink fix** (the one un-dissolved band-aid — lets volcanism be frequent without baking the planet).
- **T3 (visual polish):** cel-shading [✓] · scattering sky [✓] · sphere-aware ocean [✓] · cloud→ground shadows · re-enable sun shadows · grass/ground-cover [FAKE] · climate-typed flora envelopes · glacier flow (retarget slump to `_snow`) · cheap strata [FAKE] · lava tubes (edge-cooling — in flight).
- **T4 (bake + livability):** **activity-bubble LOD (Keystone C, L)** → geotime `--geotime=N` bake → bake-then-freeze orchestration (snapshot path exists) · season/year retune.

**FAKE ledger (deliberate):** tides · far/orbit ocean (mid/ground MUST be real) · accretion (see-once) · plate
tectonics (keep kinematic Voronoi; true tectonics = 0.5) · grass/clouds/strata · **static sea + static lakes (the
livability anchor — a fully-conserved cycle drains land dry).**
**Livability risks:** volcano thermal runaway (→ radiative sink) · high-`--fast` field desync (→ Keystone C) ·
land drains dry (→ spring baseflow) · erosion mass drift (→ cap by stream-power, verify vs `mineral_total`).

**SEQUENCE:** Phase-0 seam ownership (4 shared files: `MaterialReactions3D`, `VoxelTerrainTriplanar.gdshader`,
`heat3d_solar_sphere3d.glsl`, sphere GPU host) — one owner each, consumers staged. Then fan out lanes (Wave-1
climate/terrain-look/sky-ocean SHIPPED; Wave-2 = erosion Keystone A + activity-LOD Keystone C, staged behind the
host-touching fire-balance/hot-springs merges). Critical path: Keystone B all-the-way-through the shader (biggest
"one lawn → distinct places") + Keystone A (highest-leverage sim add) + Keystone C (unlocks the literal formation arc;
if it slips, 0.4 still ships a livable+beautiful+stable planet — "start-to-finish" degrades to climate/ecology settling).

---

## 0.5 — THE LIVING CREATURES (moved from 0.4 — their entire life cycle)

Where 0.3 went broad (the game + emergent world), **0.4 goes deep on the creatures themselves — the whole arc
of a life**, all emergent (one substrate, reaction engine, config over `if species==X`). The creatures are the
star (local LLMs driving the minds). **This section is the approved, sequenced plan** (idea bank:
`docs/0.4_CREATURE_FEATURES.md`; split plan: `docs/0.4_PARALLELIZATION_GUIDE.md`).

> **2026-07-29: the memory/social substrate for this release already exists and is now reachable.**
> `graph/BackstoryGraphService.gd` is wired to `LocalAgent` (see "Next — pick up here", item A). It
> supplies factions with dated membership (the real version of `family_id`), persistent per-creature
> goals with state across days (the long-horizon intention the per-tick drive stack lacks), oral
> knowledge with transmission lineage and hop counts, and per-creature belief that can contradict world
> truth. Design the signal system with that in hand: the "deception" the scope note expects to fall out
> is `upsert_npc_belief` disagreeing with `upsert_world_truth`, and "dialects" are lineage distortion
> across hops. Nothing here needs a model. It is SQLite; only semantic recall wants embeddings.

**Scope decisions (locked):** full living-creatures release, **sequenced** (no single centerpiece) · build ONE
**general signal system first**, then every call/scent/display composes in (deception/dialects fall out) ·
**heritable, not yet evolving** (offspring inherit/blend; no mutation/selection loop pushed) · the **pet
companion is later/stretch** (ecosystem + communication richness first).

**Standing rule (user directive):** whenever a phase gives the chance, **add chemistry to the substrate** (new
conserved substances / DEFS reaction records) and **rip out hand-coded systems** that should be emergent —
don't route around them. This is the definition of done, not scope creep. Concrete 0.4 targets the exploration
already found: Phase 1 deletes the ad-hoc `match call_type` comms branches (`Creature.gd:992-1003`) + per-type
`EcologyStimulus` methods → one emergent signal+learned-meaning path; Phase 3 adds digestion/microbiome/soil
**as DEFS reactions** (chemistry), not hand-coded metabolism; personality/diet become heritable genome config,
not `if species==X`. See [[dissolve-dont-patch]].

### Reuse-vs-build ground truth (from code exploration — anchors)
| Concern | Verdict | Anchor |
|---|---|---|
| Learning core (`reinforce_cue`, `decide`, `learn_and_veto`, reward/valence, veto, social `observe`) | reuse, **generalize off `LocalAgentCreature`** | `cognition/Cognition.gd` (545/144/201/278/227/424) |
| Slow brain (LLM + teacher, budget, perception scans) | reuse, generalize | `cognition/CognitionScheduler.gd:73,220` |
| Kinship graph + `family_id` · Leadership/leader-pin (= pet's "player as Leader") | reuse as-is | `ecology/KinshipGraph.gd` · `actors/creature/CreatureLeadership.gd` |
| Genome (crossover+mutate exist; `eye_fov`/`sense_radius` acuity already heritable) | reuse, **extend** (add personality + diet genes) | `cognition/Genome.gd` (22/92/113) |
| Scent field (5 GPU channels evolve on-device: prey/predator/blood/food/alarm) | **partial — finish CPU wiring** (~4 sites) | GPU live `EcoSurfacePass.gd:205`; stubbed `MaterialField3D.gd:908-937`, `MaterialFieldSphereStep3D.gd:124-145` |
| Sound calls / scare bus (ad-hoc per-type today) | reuse, **generalize** | `ecology/EcologyStimulus.gd:96-144`, `Creature.gd:979-1003` |
| Perception spatial index · Shock/charge read+emit (charge lacks `gradient()`) | reuse as-is | `actors/creature/SpatialIndex.gd` · `MaterialShock3D.gd`, `MaterialField3D.gd:817,1149` |
| Generic signal/stimulus + learned-meaning layer | **must build** (the Phase-1 spine) | only ad-hoc `EcologyStimulus.gd` |
| `Creature.gd` god-file (1042; every workstream routes through it) | reuse, **split #1** | `actors/Creature.gd` |
| Graded life stages / body growth (binary `is_mature()` only) · courtship/gestation | **must build** | `Creature.gd:1017`, `EcologyService.gd:485` |

### Phase 0 — FOUNDATIONS (serialized, one-owner; FIRST, so the fan-out stays parallel)
- [ ] Split `Creature.gd` → modules under `actors/creature/` (hand/carry/throw · damage/death/fling · think-LOD ·
  movement · social/calls · life-stage · nesting-glue · state-tint); split `EcologyService.gd` → Spawner/
  Breeding/Plants/Aquatic (guide Wave 0a).
- [ ] **Generalize cognition off `LocalAgentCreature`** — a small duck-typed cognizer interface + `cognition/adapters/`
  per actor kind (unblocks bee/fish/pet minds). Keep `reinforce_cue` verbatim.
- [ ] **Finish the scent-field wiring** — scatter `_f._scent` in `_apply_readback` (+ `"scent"` in driver
  `read()`), implement `scent_at`/`scent_gradient` (5-packed `base=ch*cell_count`), `deposit_*` → seed +
  `_scent_dirty`, dirty-gated `set_field("scent", …)` upload. Same pattern shock/charge already use.
- [ ] **Extend `Genome`** — add personality/temperament gene(s) + heritable diet/appearance; mutation modest.
- [ ] **Goal-directed foraging: FIND + STEER (user-flagged, foundational — do via workflow/subagents).** Two
  primitives every forager / hunter / pollinator needs and lacks today: **(A) sense the nearest edible** — query
  the shared 3D spatial index by the creature's diet → a target; **(B) steer locomotion toward a chosen
  direction/target** (goal-seek, not just wander/flee). Right now forage has NO food-seeking steer, so a hungry
  bee can't approach a flower (0.3 fell back to proximity pollination). Add both to the generalized cognition +
  radial locomotion so true nectar-seeking, grazing-toward-pasture, and pursuit hunting fall out emergently.

### Phase 1 — THE SIGNAL SPINE (build once; communication emerges)
- [ ] One general **Signal** system: emit (a typed record: medium + payload + intensity) into a medium
  (scent/sound/shock/charge/posture/touch) → perceive (via `LASpatialIndex` + field reads) → **meaning is the
  learned response** (`reinforce_cue`). Refactor the ad-hoc `EcologyStimulus` methods + `Creature.hear_call`
  `match` branches into this path; each concrete signal (alarm scent, mating call, threat display) becomes a
  **data record**, not code. Honest-vs-deceptive signalling, dialects, skepticism fall out.

### Phase 2 — FAN OUT over the spine (Workflow — each workstream = "config a signal + a learned response")
- [ ] **W-COMMS:** scent trails, alarm/mating/contact/food calls, visual displays/postures, touch/grooming,
  seismic (shock), electric (charge + `charge_gradient()`), bioluminescence.
- [ ] **W-SOCIAL:** dominance hierarchy (extend leadership), cooperation (pack hunt/mobbing/sentinel/
  alloparenting), bonding/alliances/reciprocity, play, territory (scent boundaries), migration, culture-spread.
- [ ] **W-FISH minds** (generalized cognition via a fish adapter). **W-BEES** learning + pollinator-driven
  flower selection (needs bee cognition + scent — both unblocked by Phase 0; coordinate with 0.3 #76).
- [ ] **W-TRAITS:** circadian/dormancy (hibernation/torpor/estivation — compose with compute-bubble LOD),
  thermoregulation, crypsis/mimicry, predator/prey tactics, foraging/caching, parental care/teaching, disease/
  parasites, personality-driven behavior, emotional states, habituation.
- [ ] **W-LIFECYCLE:** graded life stages + body-growth curves, courtship/mating (→ kinship mate edge), aging/
  senescence.

### Phase 3 — THE NUTRIENT / METABOLIC CYCLE (#75 flagship)
- [ ] Digestion over time (efficiency set by the microbiome; herbivores need gut flora) + gut-microbiome benefit +
  excretion/pooping (→ soil detritus/fertility + spreads gut bacteria) + soil bacteria/nitrogen-fixers (→ plants
  grow) + death decomposition (0.3 shipped the field-side taste). Bacterial **roles as DEFS reactions**;
  conserved matter food→energy+waste→soil→plants→food. **Prereq status (corrected 2026-07-23, closed same
  day — fertility-uptake session):** the WHOLE detritus→fertility→growth chain is now DONE:
  `CreatureExcretion` deposits real feces detritus (fixed same session — it previously only wrote a scent
  cue despite claiming otherwise), R15 fungus-decompose produces fertility, and **R19 photosynthesis now
  consumes FERT as a second, Liebig-limiting reactant** (`MaterialReactions3D.gd`, `FERT_UPTAKE_COST`) — soil
  fertility genuinely gates plant growth on barren ground without destabilizing already-vegetated land
  (tuned + verified via same-seed A/B, see the session note above). What's still open for THIS phase is the
  narrower remainder: digestion-over-time (a gut buffer instead of instant `feed()`), the microbiome
  efficiency scalar, and nitrogen-fixer bacteria as a genuinely new DEFS reaction (R-NFIX) — the loop-closing
  part is done, the deeper metabolism modeling is not.

### Phase 4 — THE PET COMPANION (stretch — end of 0.4 or 0.5)
- [ ] Large animal + player pinned as permanent **Leader** + **operant conditioning** (`reinforce_cue`) +
  non-verbal need/emotion readout UX. "Not a special system" — the shared richness focused on one bonded
  individual. Only if the ecosystem lands with room.

### Phase 5 — REUSABLE CREATURE NODE + perf/platform (deferred)
- [ ] **Reusable creature NODE (#dual-purpose gap)** — decouple `Creature` behind small interfaces + a default
  adapter so a bare "AgentCreature" works standalone (rules-based) and lights up with a sim + a model.
- [ ] **Async/partial GPU field readback** (#72 — dominant field cost; speeds every verify). **HTML5 web-export
  spike** (#44 — browser-local LLM via WASM/WebGPU + `JavaScriptBridge`, chat/agent first). **Composition-per-
  cell** (#30 — DEFS ~80% there; thin slice when a metal/ore/salt feature is wanted).

### Chemistry to add + hand-coded to rip out (specifics — the standing rule, grounded)
**New DEFS reactions/channels** (`material/MaterialReactions3D.gd`, `_rec(rate_model, k, driver, reactants[],
products[], gate_mask, threshold, driver2)`; slots biomass/O₂/CO₂/detritus/fungus/fertility already exist — the
carbon loop **R15 fungus-decompose** `detritus+O₂→CO₂+fertility` and **R20 respiration** `biomass+O₂→CO₂+detritus`
already close it):
- **Excretion → soil (mostly REUSE):** creatures deposit feces into the existing **detritus** channel
  (`deposit_detritus`) → **R15** already rots it → fertility. Only add a faster **R-MANURE** (BILINEAR decompose
  on a new `manure` slot) if leaf-litter rate is too slow for feces to enrich noticeably.
- **Nitrogen fixation → fertility (GENUINELY NEW):** add an atmospheric **nitrogen** slot + **R-NFIX**
  `nitrogen(air)→fertility(soil)`, BILINEAR/CONST gated (`gate_mask`) on legume-biomass × moisture (the N-fixer
  bacterial role the user named). Conserved (draws from the N pool); makes fertility actually replenish → plants
  regrow. Without this the loop leaks fertility and can't sustain.
- **Death decomposition = UNIFY, do NOT re-add:** a carcass becomes **biomass/detritus in the field** → the
  existing **R20 + R15** rot it → CO₂ + fertility. No new reaction.
- **Digestion + gut microbiome = per-creature metabolism, NOT a field CA** — lives in `CreatureMetabolism`
  (gut buffer: ingested biomass → energy + waste over time, efficiency × microbiome scalar); only its **waste
  output** deposits into field detritus. State this boundary so it isn't mis-built as a DEFS record.

**Hand-coded systems to rip out → emergent** (delete + route through substrate/cognition):
- **Comms (Phase 1):** `Creature.gd:992-1003` `hear_call` `match call_type` branches + per-type
  `EcologyStimulus` methods (`broadcast_call`/`broadcast_scare`, :96-144) → ONE signal record + `reinforce_cue`
  learned meaning.
- **Eating (Phase 3):** instant `feed()`→energy (`Creature.gd:1031` `feed`/`food_profile`/`nutrition`) →
  digestion-over-time gut buffer × microbiome efficiency.
- **Death decomposition (Phase 3):** the bespoke `CreatureRagdoll` `MICROBE_SEED`/`DECOMP_RATE_PER_SEC` bloom
  (0.3's field-side taste) → carcass = biomass/detritus rotted by R20+R15; delete the constants.
- **Breeding (Phase 2 W-LIFECYCLE):** population-tick `EcologyService._tick_breeding` (:485, every 2 s fraction +
  `pop_cap`) → emergent per-creature courtship/mate-seeking + gestation; population regulated by food/energy/
  space, not a global cap.
- **Fish (Phase 2 W-FISH):** brainless config-band swim logic in `Fish.gd` → generalized cognition via a fish
  adapter. **Any `if species==X`** → genome/config (the new personality/diet genes).

### Confirmed field/GPU bugs to fix in the 0.4 field pass (from the 0.3 bug-hunt — deferred as substrate-risky)
- [ ] **Combustion O₂/CO₂ written to the wrong ping-pong half** (`sphere_passes/FireDustPass.gd:82`) — bind o2/co2
  to the BACK half in the fire uniform set so the in-place consume/emit lands on the buffer transport wrote.
- [x] **`deposit_detritus`→GPU + detritus readback + full fertility loop** (`MaterialField3D.gd:1139`) —
  **RESOLVED** as of the 2026-07-23 repo-hygiene audit: `detritus_peak`/`fungus_peak`/`fertility_peak` are all
  live nonzero GPU reads now (R15 fungus-decompose runs, `CreatureExcretion` deposits feces into detritus/
  fertility). Dated historical record of the original 0.3 bug-hunt finding, kept for context — do NOT
  re-investigate this from scratch. The ONE piece still open is plant **uptake**: nothing consumes
  `fertility_at` to modulate growth yet (see Phase 3 above, corrected same session).
- [ ] **Fuel channel allocated to zeros, never populated** (`MaterialField3D.gd:325`) — seed fuel from biomass on
  surface cells + upload, so the fire kernel has something to burn (combustion currently has no fuel substrate).
- [ ] **Organically-grown storm charge can cross breakdown but never fire a bolt** (`MaterialCharge3D.gd:63`) —
  give grown charge the same wake safety-net as injected charge (set a wake flag when accumulated charge exceeds
  threshold) so natural-storm lightning isn't lost to the strided-probe blind spot.
- [ ] **Energy chemistry 0.4 deepening:** the 0.3 muscle-lactate/conserve-drive is the first step — deepen into full
  ATP / glycogen / O₂-gated aerobic-vs-anaerobic chemistry (ties into the nutrient cycle + DNA-driven metabolism).

### Orchestration + verification
Phase 0 = serialized (splits + generalize + wiring). Phases 1→2 = **Workflow fan-out** (`pipeline()`
implement→verify per workstream; worktree isolation; per-agent pre-write contract + behavioural SIM_REPORT gate;
adversarial verify for correctness-sensitive bits). Main thread integrates/merges/gates. Verify behaviourally:
`scripts/smoke_check.sh` while iterating; a long `--run-frames=1500`/`--fast` run + `--shoot` at each phase gate
(population stable, herds/kinship intact, no NaN/runaway, fps good; scent round-trips, a signal's meaning is
learned-not-branched, fish/bees learn, the nutrient loop conserves matter). Windowed launch for the pet.

---

## 0.6 — THE FULL SOLAR SYSTEM (moved from 0.5 by the 2026-07-12 pivot; 0.4=planet, 0.5=creatures)

0.3 shipped the **moving-frame** solar system: the sim stays centred on the planet, but a real heliocentric
orbital STATE drives the sun across the sky, seasons (axial tilt), insolation (bake/freeze/impact-winter), a
moon, and momentum knock-out-of-orbit. 0.5 makes the system **literal + navigable**:
- [ ] **Literal planet flight through space** — migrate the GPU field/ocean to a **moving-frame body-local**
  representation so the planet node can actually translate (not just its orbital state). Unblocks everything
  below. (The one 0.3 relic: `MaterialField`/ocean/water are world-anchored at the planet's start.)
- [ ] **Full multi-body physics** — planets + moons + sun as first-class bodies on real orbits; fly between
  them; land on the moon (give it terrain/field); N-body for the bodies themselves, not just test particles.
- [ ] **Solar-system view renders the real orbits** (the campaign capstone) from the body states.
- [ ] **Persist + save** the orbital state; barycentre drift; slingshot missions; comets.

## How to run / verify
- **Non-interactive (off-screen, focus-safe, SILENT audio) — always use the wrapper:**
  `scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=N`
  → one `SIM_REPORT={…}` line (gauges: fps/field_ms/physics_ms/leaders/followers/…; field/population/cognition
  sections). `--shoot=<png>` for a screenshot; `--campaign`/`--sandbox` to boot the sim in a mode; disaster
  triggers `--auto-{meteor,volcano,lightning,tornado,thunderstorm,hurricane,earthquake}`; `--auto-select`.
  `LA_RES=WxH` sets resolution; `LA_NO_STREAMER=1` skips the LLM streamer; `LA_NO_AUDIO=0`/`--audio` forces
  audio on in dev. Acceptance is BEHAVIOURAL (aggregates sane, no NaN/runaway, fps good) — no CPU↔GPU parity.
- **Gotcha:** a NEW `.gd` `class_name` / `.gdextension` / new `.glsl` registers only after an editor scan:
  `godot --headless --path . --editor --quit-after 400`. Native changes (e.g. `LAProcess`) need the extension
  rebuilt (CI `build-extension.yml` or the local build).
- **Lint/tests:** `scripts/agent_harness.sh <lint|fast|bounded|extension>`; `scripts/check_max_file_length.sh`.
- **REPRODUCIBLE MEASUREMENTS — add `--fixed-fps 60` (2026-07-30).** It is a Godot ENGINE flag, so it goes
  BEFORE the `--` separator: `run_sim_offscreen.sh --path . --fixed-fps 60 <scene> -- --run-frames=N ...`.
  With it, field/climate/conservation numbers reproduce: three runs gave `soil_total` and `biomass_total`
  identical and `creatures` identical. Without it they do not — three runs at one seed gave creatures
  169/172/180 and phenomenon totals 11/11/17.
  - **Buy horizon with MORE FRAMES, not a lower rate.** At `--fixed-fps 60` 150 frames covers only
    `field_step 46` against ~746 unfixed, but frames are nearly free in wall clock (the windowed scene never
    exits, so the wrapper waits out `LA_RUN_TIMEOUT` regardless). `--fixed-fps 10` gives 6x the horizon and
    LOSES determinism, because at `--fast=2` a 0.1 s delta lands exactly on the field's 0.2 s per-frame
    ceiling where the excess is discarded, and the longer horizon lets the agents feed back into the field.
  - **Still needs repeats:** anything gated on escalation or decision counts (#27). `escalations` and
    `slow_brain_calls` still vary, because an escalation holds a slot until its answer arrives and that
    latency is real time. Field numbers are unaffected.
  - The two fixes that made this work: the cognition budget now counts physics frames instead of
    `Time.get_ticks_msec()` (`067552a`), and `--seed` now actually reaches `LASimRng`, which nothing had ever
    called `reset()` on (`61206c1`).

## Where everything lives
- **Front end:** `scenes/menu/` (MainMenu · SettingsMenu + Graphics/Sim sections · CreditsMenu · HelpMenu/tabs ·
  GameSettings/GameMode/GameSave). **Game systems:** `scenes/simulation/voxel/game/` (GameProgression ·
  WorldSaveState/Controller). **Composition root:** `VoxelWorld.gd` (extract-only). **Quit:** `scenes/AppExit.gd`
  + native `LAProcess`.
- **THE substrate:** `material/MaterialField3D.gd` (thin facade, extract-only) + modules `MaterialSphereGPU3D`
  (GPU host) · `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialField{Queries,Inject,
  Snapshot}3D` · `Material{Ejecta,Charge,Shock}3D` · `MaterialReactions3D` (DEFS) · `WaterParticles` ·
  `mesh/VegetationRenderer`.
- **Actors:** `actors/{Creature,Fish,Plant,Tree,Rock,Nest,Food}` + `actors/creature/*` (leadership/metabolism/
  flocking/think/senses/nesting/ragdoll/field-forces); disasters `actors/{Meteor,Volcano,…}` (dissolved →
  seeds/visuals). **Cognition:** `cognition/*` (value-based policy + sparing local-LLM slow brain).
  **Ecology:** `ecology/{EcologyService,EcologySpawner,KinshipGraph}`. **Events/streamer:** `events/*`,
  `streamer/*`. **UI:** `ui/*` (HUD, thought panel, debug, tutorial). **Data:** `data/species/**/*.json`.
- **Reusable addon (dev tool):** `agents/` (LocalAgent + Agent3D) · `runtime/` · `ui/ModelManager*` ·
  `examples/` (AgentQuickstart, demos, DemoLauncher). **Design:** `EMERGENCE.md`, `docs/TRAILER.md`, `docs/EXPORT.md`.

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
removing a hack to make behavior emergent is the definition of done. See `EMERGENCE.md`.
