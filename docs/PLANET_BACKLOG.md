# Planet development backlog

Consult this list when extending planet physics beyond [the 0.4 release](0.4_RELEASE_SCOPE.md).
Keep symptoms and reproduction commands until implementation and verification resolve them.
Physics requirements remain in [PHYSICS_TODO.md](PHYSICS_TODO.md); cost requirements remain in
[PERFORMANCE_TODO.md](PERFORMANCE_TODO.md). An item affecting an active 0.4 path is a release blocker.

## 1. THE PLANET'S POISSON RESIDUAL STOPS FALLING, AND THE MASS IT WEIGHS GROWS

`scripts/sim_run.sh --body --frames 6 --report gravity_residual_rel,gravity_vcycles,gravity_total_mass_kg`
reads a residual above `GravityPass.RESIDUAL_TOLERANCE` with the V-cycles spent, so
`MaterialFieldGravity3D.solve` invalidates the run, and a mass maximum several times its own minimum
while `mineral_total` and `h2o_total` drift by nothing. Branch `multigrid-gravity` holds an unlanded
V-cycle solver, green on the slice, red on the planet.
Reading: `MODE_SEED` in `kernels3d/gravity_poisson.glsl` writes `grav_ref` as one monopole.

## 2. THE PLANET'S SEEDED COLUMN IS NOT A FIXED POINT OF ITS DERIVE

`scripts/sim_run.sh --body --rung 2 --frames 6 --report pressure_rest_rel,derive_unconverged_cells`
reads `pressure_rest_rel` above its bar with every cell converged; the slice column
(`scripts/sim_run.sh --rung 2 --frames 6`) reads zero. `scripts/check_derive_safe_math.sh` counts
`pressure`, `p_fluid`, `k_cond`, `temp` and `temp_lith` as channels whose readings differ between
Godot's fast math and lasim's `MTLMathModeSafe`; its `once`/`twice` arms replay `plan_derive.lapl`
through `lasim --passes derive`. `docs/DERIVE_SAFE_MATH_CEILING` ratchets the count to zero.
Reading: `state_derive.glsl` ends the (T, p) solve on `abs(f) <= LA_STATE_TOL * max(p_pa, 1.0)`.

## 3. A SATURATED ROCK CELL'S PORE WATER HAS NO PRESSURE, SO AN OVERFILLED PORE PASSES

`scripts/check_sealed_state_range.sh` stays green with `pore_m3 = 1.5 * pore_kg * ...` in `state_derive.glsl`.
Reading: `state_derive.glsl` clamps `room_f` and takes `total_f <= 0.0` for a cell whose only fluid is pore water.

## 4. THE BOUNDARY GATES CANNOT RECORD THEIR OWN CAPTURE, AND A GHOST'S REST GRAVITY IS READ PAST ITS BUFFER

`scripts/check_boundary_books.sh` with no `LA_LINT_CAPTURE` exits 2: its capture run,
`scripts/sim_run.sh --body --frames 20 --rung 8 --slice-capture C`, logs `LASubstances gives "fixed_n"
no specific heat`, is killed at the run timeout and publishes no capture; at `--rung 3` it is killed at
the timeout. `rg -n 'g_rest.*cc \* 3' addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd`
Reading: `_allocate_declared` in `MaterialSphereGPU3D.gd` adds `_ng` once to a declared length, so a
three-vector declared `{"n": cc * 3, "ghosts": true}` is `cc * 3 + ng` long.

## 5. AN EARTH-MASS BODY SOLVES LARGER THAN EARTH, SO BASALT'S GRAIN DENSITY CANNOT LAND

The shell carries its high-pressure phases (`docs/PHYSICS_TODO.md` A, solid polymorphs); then
`ROCK_DENSITY_KG_M3` in `PhysicalConstants.gd` takes basalt's grain density, 2949.0 kg/m^3 (Hyndman &
Drury 1977, Init. Rep. DSDP 37:395), and `RHO_SILICATE` in `closures.glsli` and `reactions_sphere3d.glsl`
follows it. With that density alone `scripts/check_hypsometry.sh` reads its land fraction past the bound,
as `scripts/check_hypsometry.gd` does on this tree with `SAMPLES` at 65536.
Reading: `shell_minerals` in `LAPlanetTables.cpp` fills every shell with olivine, pyroxene, plagioclase,
silicate, apatite and halite at every pressure.

## 6. THE PLANET CARRIES LESS AIR THAN IT WAS GIVEN, AND A BOX CANNOT WEIGH ITS OWN SHARE

`scripts/check_atmosphere_mass.sh` prints a seeded nitrogen below the declared inventory, and its test is
one-sided because the deficit is not the seed's: `scripts/sim_run.sh --body --rung 2 --frames 2 --report
nitrogen_all,body_seed_atmosphere_n2_kg`. The same gate cannot read a slab, because a box's footprint on
the sphere is not a rectangle: `scripts/sim_run.sh --slice --rung 2 --frames 2 --report nitrogen_all`
reads a box whose long axis is the world axis nearest the local vertical, not the vertical itself.
Reading: `solid_of` in `LAPlanetTables.cpp` calls a cell solid at half rock, and `shape_atmosphere`
floods `sky` only through cells whose `solid[c] == 0`.

## 7. THE CRUST HAS TWO REPRESENTATIONS, AND THE SEA IS A SPHERE AT ONE RADIUS

Maintainer's decision, standing: the field is the only representation of matter; ground and water
surface are isosurfaces a kernel extracts per block (also the collider); the generator is sampled once at
seed; a body of water is where the inventory settled under the solved gravity. `rg -n "sea_radius|OceanPlane|_open_sea|sea_level_m|resample_terrain" addons/local_agents`
finds the sea as a declared shell radius and the field sampling the generator after the seal. A coast slice
(`LA_SLICE_BOX=0,site=coast,0,3,24,3,5120,10`, `--rung=2 --ui --shots=1000:-35:0`) draws its sea only over
the box's finest cells.
Reading: `LAWaterSurfaceMesh.build` skips every cell whose `level_of` is not `max_level`.

## 8. THE GROUND NEAR THE EYE IS TERRACED, AND THE LEVEL BOUNDARY SHADES AS A CREASE

`LA_SHOTS="30:-3:0" scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` shows
the near ground banded along its contours and a crease along the level boundary to the horizon.
Reading: `LASpherePlanetGenerator.build` leaves the position inputs of `NODE_SDF_SPHERE` unwired, so
`length(p) - radius` is taken at each voxel's absolute position.

## 9. THE DEMO SITE HOLDS NO WATER A VIEWER CAN STAND BESIDE

`LA_SHOTS="30:-3:0" scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` shows
no free water surface; `scripts/sim_run.sh --slice --rung 1 --frames 4 --report water_liquid_total,wet_cells`
counts what stands in the box.
Reading: `coast_site` in `LAPlanetTables.cpp` bisects onto the waterline and then scores the site by
`land_m + depth_m`, which is largest where the relief is steepest rather than where the box's own
footprint is half wet.

## 10. THE SURFACE IS STILL: EVERY WEATHER-SHAPED STAND-IN IS ABSENT RATHER THAN FAKED

`docs/FAKES.md` carries what creatures need and nothing the surface shows: `wind_field` (real at
ACOUSTIC), `rain` (WATER), `streams` (ADVECT), `diurnal_heat` (RADIATION), each read through the query
the real row will answer, offered in the HUD as a stand-in.

## 11. THE SLICE'S OWN GRAVITY READS ZERO IN THE REPORT WHILE A MASS FALLS AT ~9.5 m/s^2 IN IT

`scripts/sim_run.sh --slice --rung 1 --frames 4 --report gravity_mean_g,gravity_solves` reads
`gravity_mean_g` 0 in the box where `scripts/check_test_mass.sh` measures `g_release` near 9.5.
Reading: `dispatch_slab` in `GravityPass.gd` issues `MODE_FIELD_STATS` without the `MODE_MOMENTS` sweep
that `PRE_MODES` runs before it.

## 12. A FALL IS OVER BETWEEN TWO RENDERED FRAMES, AND ONE DRAG COEFFICIENT SERVES EVERY SPEED

`scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` photographs a test mass
already landed: 43.2 simulated seconds pass per rendered frame. `SPHERE_CD` in `LABallistics.cpp` is the
hypersonic limit at every Reynolds and Mach number.
Reading: `stride_m` in `LABallistics.cpp` reads no sound speed and no viscosity.

## 13. A CREATURE IS FLUNG ONLY PAST AN INVENTED IMPULSE

`rg -n 'impulse.length\(\) > 3.0' addons/local_agents/creatures/Creature.gd` finds the threshold that
decides whether a push throws a creature; it names no mass, no ground friction and no source.

## 14. MATTER INJECTED FROM OUTSIDE THE FIELD IS NOT BOOKED IN

`scripts/sim_run.sh --slice --rung 2 --frames 200 --report inject_created_silicate,mineral_src_total,mineral_run_drift,mineral_bnd_in -- --stamp-test`
reads `mineral_run_drift` equal to the deposited rock in moles and `mineral_bnd_in` 0, while
`mineral_src_total` carries the same deposit in mol/m^3 of one cell.
Reading: `_drain` in `InjectPass.gd` tallies `inject_created_<channel>` in cell values, and
`_publish_mineral` in `LAFieldLedger.cpp` nets `boundary_of(group, "Si")` alone.

## 15. NOT EXAMINED UNTIL THE RUNG-2 DEMO IS APPROVED — rung 3

- `scripts/check_bench_shock_tube.sh`: at a 10:1 Sod jump the rarefaction head stands outside the bound
  and the overshoot grows as the grid halves; at a 1% jump every claim passes.
- `scripts/sim_run.sh --rung 3 --frames 2` (slice or `--body`) ends with `RUN_TIMEOUT` and no report.
- `LA_REST_CELL_M=68000 LA_REST_CELLS=8 scripts/check_atmosphere_at_rest.sh` reads a rest departure
  above its bar on a land column; its vent arm reads an energy residual near a tenth of the turnover.
- `scripts/sim_run.sh --rung 3 --frames 3 --report nonfinite_cells,mach_max` refuses a water record at
  light speed by the second frame; `LA_PASS_PROBE=mach LA_PASS_PROBE_STEPS=1` names the cell.
- `scripts/check_boundary_momentum_book.sh`, with or without `LA_RUNG=3`, fails its device rig: an open
  face under a higher exterior pressure books no momentum and no nitrogen, and the REPLAY rim no nudge.
- Maintainer's decision, standing: the acoustic part of the momentum equation goes implicit (one
  Helmholtz solve per field step on `gravity_poisson.glsl`'s operator shape), the step is derived from
  the advective CFL, `SIM_SECONDS_PER_STEP` and the acoustic temporal levels are deleted; declared in
  `docs/APPROXIMATIONS.md` when built.

## 16. NOT EXAMINED UNTIL RUNG 3 IS GREEN — the rows above it and their books

- `scripts/check_bench_heat_slab.sh` (rung 4): every cell of the slab reads a non-finite temperature and
  a zero `cap_sensible`.
  Reading: `la_row_need` in `flux.glsl` gates the conduction row on `cap_sensible[c] > 0`.
- `scripts/check_bench_darcy.sh` (rung 5): six regolith columns under a head difference transfer zero.
- `scripts/check_active_rows.sh` (rung 5): nothing crosses a face on its sealed lines, and its blob never
  leaves the seed cell.
- `scripts/check_bench_grey_atmosphere.sh` (rung 7): identical neighbours exchange unevenly past the
  bound; the lit plate settles below the grey Eddington skin temperature.
- `scripts/sim_run.sh --frames 20 --slice-capture C` then `LA_RUN_TIMEOUT=900 scripts/sim_run.sh --slice
  --slice-state C --frames 650` fires CONSERVATION_VIOLATION on h2o, nitrogen, mineral, element_C and
  element_O; with every wall shut, `scripts/agent_harness.sh sim --rung=8 --frames 20` ends with
  `h2o_total` below its sealed baseline while the element and mineral books close.
- `LA_RUN_TIMEOUT=110 scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn --
  --sandbox --ui --run-frames=20` prints no report and logs no error; `--planet-only --no-fauna` reports.

## 17. APATITE NEVER MELTS, AND EVERY MINERAL WEARS BASALT'S ALBEDO

`rg -n '"apatite"' -A12 addons/local_agents/gdextensions/localagents/src/LASubstances.cpp` shows no melting
point or fusion enthalpy, and each planet mineral row takes `BASALT_EMISSIVITY` and `ALBEDO_BARE_GROUND`.

## 18. THE PHYSICS RUNS INSIDE GODOT'S PROCESS

Maintainer's decision, standing: a standalone native process with its own device, clock and CLI; Godot
attaches as a viewer. Today every pass runs on a Godot RenderingDevice and every gate launches Godot.
Branch `native-plans` is unlanded: `scripts/check_lasim_parity.sh` there reads `plan_reduce.lapl is truncated`.

## 19. THE LEDGER RECONSTRUCTS ELEMENTS FROM CHANNEL AMOUNTS

Maintainer's decision, standing: per-cell moles of elements are the state and species are derived
(`docs/PHYSICS_TODO.md` B); today the ledger reconstructs them from `Channels.gd` (`mol_per_unit`).

## 21. THE STAR IS SEEDED WITH TODAY'S RADIUS BESIDE THE EPOCH'S LUMINOSITY

`rg -n 'star\["(radius_m|luminosity_w)"\]' addons/local_agents/gdextensions/localagents/src/LABodySystem.cpp`
reads the present nominal radius for a star `star_age_at_epoch_gyr()` old, where the standard solar model
gives 0.869 of it at zero age and 0.882 at 0.2 Gyr (Bahcall, Pinsonneault & Basu 2001, ApJ 555:990,
Table 1); the sky's disc and the ground's sunlit unit are drawn from that radius.
Reading: `LABodySeeds::rows` sets the star's `radius_m` to `SOLAR_RADIUS_M`.

## REQUIRED BASELINE: COMBUSTION AND MIXTURE ENTHALPY FAIL

`scripts/agent_harness.sh single test_combustion_rate_law.gd` rejects reaction stoichiometry and enthalpy; `scripts/agent_harness.sh single test_mixture_enthalpy.gd` rejects saturated vapour.
Complete when both pass against the requirements in `docs/PHYSICS_TODO.md` and `scripts/agent_harness.sh all` passes.


## Future planet requirements

- Grow campaign starting terrain by pre-simulating volcanism, erosion and deposition, then save the
  resulting start world. This requires verified sediment pickup, transport and deposition.
- Model glaciers as ice moving under gravity, eroding ground and depositing transported material
  on melting, with the water and energy books intact.
- Model thermal weathering as rock becoming loose sediment under physical stresses.
- Carry aeolian dust and sediment with wind; book pickup, transport and deposition.
- Extend groundwater to lateral, head-driven Darcy transport through a physically specified
  permeable regolith and bedrock structure. Detect springs where the water table reaches the surface
  and remove any seeded-spring stand-in when that mechanism is verified.

Each addition requires a reproduction command, a conservation gate and a visible process demo
before its implementation is accepted.
