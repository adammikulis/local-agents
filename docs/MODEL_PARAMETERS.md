# MODEL_PARAMETERS.md — every number that is not a property of matter

`scripts/check_model_parameters.sh` fails the build on any numeric constant in the kernels or the GDScript
simulation layer that is not one of:

1. **bound** to `LAPhysical` or `LASubstances` by a trailing comment,
2. **derived**, meaning its right-hand side is an expression over other constants rather than a literal, or
3. **declared here**, with a reason and the condition that deletes it.

`check_physical_constants.sh` asks whether a copy equals the authority. This file exists for the prior
question, which nothing could previously ask: should this be a number at all, and who decided?

## This is a deletion queue, not a home

Every row names what would have to exist for the number to stop being needed. A row that never acquires
that field is a value nobody intends to fix.

**MAX_DECLARED: 588**

The gate fails if the table grows past that ceiling. To add a number, derive it, bind it, or raise the
ceiling in the same commit and argue for it in the message. When the count drops, lower the ceiling to bank
the progress. It may shrink. It may not grow.

## Opening state, 2026-08-10

690 literal constants scanned across the kernels and `addons/local_agents/sim/**`. 77 are bound to the
authority. **613 are not**, which is the honest size of the problem and was invisible before this file
existed. The `why` and `deletes it` columns are filled in by class where the two 2026-08-10 audits
established one, and marked `inherited, unreviewed` otherwise. Unreviewed is a status, not a pass: it means
the number is now visible and counted, and the ceiling stops a 614th arriving unnoticed.

## Modelling choices that live in the authority file

`PhysicalConstants.gd` is excluded from the scan because it is the authority for properties of matter. Two
of its constants are not properties of matter and are therefore declared here instead. Both should
eventually move out of that file, because a modelling choice sitting among measured constants is
camouflaged by its neighbours.

| file | constant | value | why it is not physics | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `METRES_PER_MODEL_UNIT` | 168.6 | grid resolution, the way a weather model picks its mesh. Derived in commit `3bf94ac` from ten cells spanning three scale heights, cross-checked against the fitted `H_PER_KELVIN` it replaced and agreeing to 0.04%. It is credible, and it is still a choice. | never fully: a discretised model has a mesh. It must stop being derived through a biogenic modern-Earth air composition. *(Corrected 2026-08-10: this row used to also demand "it must become an anisotropic pair (horizontal and vertical)". That is not available on this grid — the field is laid on a cubed sphere where the radial stack and the lateral arc are the same coordinate, and `LASphereGrid.cell_volume` returns `solid_angle * (ro^3 - ri^3) / 3`, a model-unit volume that becomes m³ only under one scale factor cubed. A separate vertical metre would make the grid's own volumes and face areas wrong. The instruction had already produced one: `MaterialFieldGeotherm3D._derive_gradient` carried an undeclared vertical factor of 31.25 = `GROUNDWATER_CIRCULATION_M / (REGOLITH_CELLS * cell_size)`, applied to the seeded gradient and omitted from the flux in the same file.)* |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `AIR_MASS_HORIZON` | 38.0 | empirical airmass cutoff at the horizon, an approximation to the Chapman function, not a measured quantity | use the Chapman function, or cite the approximation and its error |

## Known wrong, already scheduled

These are not merely undeclared. The audits established they are incorrect, and they are listed so the
registry does not read as if everything in it is merely unreviewed.

| file | constant | value | what is wrong | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `BUOY_FRAC` | 0.55 | buoyancy as a fitted fraction, where `wind_step_sphere3d.glsl:115-123` states the same Archimedean law as Boussinesq `g·dT/T` with units | Stage 2: one buoyancy law, derived, for energy, mass and momentum alike |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `K_P` | 0.6 | buoyancy as a fitted fraction, where `wind_step_sphere3d.glsl:115-123` states the same Archimedean law as Boussinesq `g·dT/T` with units | Stage 2: one buoyancy law, derived, for energy, mass and momentum alike |
| `addons/local_agents/sim/material/kernels3d/heat3d_buoyancy_sphere3d.glsl` | `BUOYANCY` | 0.18 | the same, for the energy leg | as above |
| `addons/local_agents/sim/material/kernels3d/solid_derive_sphere3d.glsl` | `SOLID_THRESHOLD` | 0.5 | defines `solid` for every kernel in the tree, and is written unnamed three more times in `plate_advect_sphere3d.glsl:63,70,74` | Stage 2: one definition, in a shared include |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `H_REF` | `H_PER_KELVIN * 288.15` | derived, so the gate passes it, but 288.15 K is the ISA standard temperature: modern Earth, unbound, and wrong for a Hadean seed | Stage 3: scale height from the local mixture |

## The queue

| file | constant | value | why it is not physics | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl` | `MAX_COMPRESS` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl` | `CHARGE_GAIN` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl` | `CHARGE_LEAK` | 0.05 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl` | `CHARGE_LEAK_QUIET` | 0.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/charge_accum_sphere3d.glsl` | `UPDRAFT_MIN` | 0.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/lava_phase_sphere3d.glsl` | `LAVA_MIN_MASS` | 0.0001 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/sphere_passes/CellListPass.gd` | `LAVA_MIN_MASS` | 0.0001 | the compactor's lava row must equal `lava_phase_sphere3d.glsl`'s own floor, which that kernel no longer rechecks | lava_phase rechecks its own floor, or the floor is derived from a melt fraction |
| `addons/local_agents/sim/material/kernels3d/lava_phase_sphere3d.glsl` | `MAX_DT_PER_STEP` | 5.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/lava_phase_sphere3d.glsl` | `MAX_SUBSTEPS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/heat3d_buoyancy_sphere3d.glsl` | `BUOYANCY` | 0.18 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl` | `SETTLE_CALM_REF` | 6.0 | transport tuning, chosen not derived | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl` | `SETTLE_MIN_RATIO` | 0.08 | transport tuning, chosen not derived | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl` | `OUT_MAX` | 0.9 | transport tuning, chosen not derived | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `DETRITUS_MIN` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `FUNGUS_MIN` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `FUNGUS_MAX` | 3.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `MOIST_MIN` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `MOIST_REF` | 0.06 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `VAPOR_MOIST` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `RAIN_MOIST` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `DETRITUS_DAMP` | 0.15 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `TEMP_WARM` | 42.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `GROW_RATE` | 0.06 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `SPREAD` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `DECAY` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl` | `DRY_DECAY` | 0.06 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fert_sphere3d.glsl` | `FERT_DECAY` | 0.0015 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fert_sphere3d.glsl` | `FERT_RAIN_LEACH` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/fert_sphere3d.glsl` | `FERT_BLUR` | 0.04 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `T_MIN_K` | 180.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `T_MAX_K` | 400.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `AIR_DENS_REF` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `MAX_FACE_SHARE` | 0.2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_pressure_sphere3d.glsl` | `DIFFUSE_FACE` | 0.01 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl` | `LATERAL_SHARE` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl` | `WATER_MIN` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl` | `MIN_SUSP` | 1.0e-6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl` | `MAX_OUT_FRAC` | 0.9 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/solid_derive_sphere3d.glsl` | `SOLID_THRESHOLD` | 0.5 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/shock_sphere3d.glsl` | `SPREAD` | 0.15 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/shock_sphere3d.glsl` | `LOSS` | 0.25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl` | `MAX_OUT_FRAC` | 0.9 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl` | `MIN_MASS` | 1.0e-6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl` | `AIR_FLOOR` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl` | `DAMP_SURFACE` | 0.08 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl` | `DAMP_FREE` | 0.010 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl` | `BL_HEIGHT` | 40.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/wind_step_sphere3d.glsl` | `OROG_LIFT` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl` | `WATER_MIN` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl` | `STREAM_K` | 0.25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl` | `MAX_SCOUR` | 0.08 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl` | `ROCK_MIN` | 1.0e-4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl` | `HEAD_MIN` | 1.0e-3 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `BUOY_FRAC` | 0.55 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `K_P` | 0.6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `MAX_UP_FLOW` | 0.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/magma_buoy_sphere3d.glsl` | `MIN_OP` | 0.0001 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl` | `MAX_DT_PER_STEP` | 5.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl` | `MAX_SUBSTEPS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl` | `ICE_ALBEDO_GAIN` | 40.0 | radiative property not in the authority | add to PhysicalConstants.gd with a citation |
| `addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl` | `WATER_SURFACE_MIN` | 0.5 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/heat3d_solar_sphere3d.glsl` | `MAX_COLUMN_WALK` | 64 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `REG_CELLS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `MAX_FLOW_FRAC` | 0.35 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `RESIDUAL` | 0.30 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `SEEP_THRESH` | 0.9 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `SEEP_RATE` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `MIN_W` | 0.002 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `INFIL_RATE` | 0.045 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `DRY_CRUST` | 0.12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `WET_KNEE` | 0.25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `LEG_NONE` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `LEG_DARCY` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `LEG_SPRING` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl` | `DBG_SLOTS` | 21u | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/mesh/VegetationRenderer.gd` | `_CHUNK` | 256 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/mesh/VegetationRenderer.gd` | `_INITIAL_CAP` | 512 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/SimWorld.gd` | `SLOW_BUILD_CELLS` | 250000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `PLATE_COUNT` | 9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `EVENT_PERIOD` | 7.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `SAMPLES_PER_EVENT` | 10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `BOUNDARY_PROBE` | 0.06 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `CONVERGE_MIN` | 0.25 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/PlateTectonics.gd` | `GEOLOGIC_TIME_ACCELERATION` | 3.0e5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/PlateTectonics.gd` | `VOLCANO_CHANCE_CONVERGENT` | 0.3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/SimClock.gd` | `DAY_LENGTH` | 200.0 | a literal where a consequence belongs. The day is the planet's rotation period expressed in sim-clock seconds, which `LAMaterialFieldSphereStep3D.day_length_sim_seconds()` now computes from `PLANET_ANGULAR_VELOCITY_RAD_S` and the step quantum: 199.454, not 200. No rate reads it any more (`scripts/check_step_quantum.sh`), so what is left is a calendar and a sky. | replace the literal with `LAMaterialFieldSphereStep3D.day_length_sim_seconds()`, and point `game/world/VoxelSkyCycle.gd` at the same function |
| `addons/local_agents/sim/SimClock.gd` | `DAYS_PER_SEASON` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_OUTPUT_SDF` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_ADD` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_SUBTRACT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_MULTIPLY` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_ABS` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_MIN` | 16 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_MAX` | 17 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_SDF_SPHERE` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SpherePlanetGenerator.gd` | `T_FAST_NOISE_3D` | 40 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `FACES` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_IN` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_OUT` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_A0` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_A1` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_B0` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `N_B1` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `S_A0` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `S_A1` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `S_B0` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/sphere/SphereGrid.gd` | `S_B1` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/SimReportSources.gd` | `METAB_FIT_MIN_N` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Gravity.gd` | `SURFACE_G` | 55.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Gravity.gd` | `SOFTENING` | 4.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Moon.gd` | `RADIUS` | 42.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Moon.gd` | `MASS` | 8.0e4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `ORBIT_RADIUS` | 12000.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `INSOLATION_MIN` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `INSOLATION_MAX` | 4.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `DUST_OPACITY` | 3.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `CLOUD_OPACITY_K` | 0.35 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `KNOCK_GAIN` | 5.9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `MOON_RADIUS_MULT` | 3.2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `MOON_INCLINATION` | 0.28 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/SystemOrbits.gd` | `TIDE_AMP` | 4.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Star.gd` | `DEFAULT_MASS` | 1.0e7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/system/Star.gd` | `DEFAULT_RADIUS` | 250.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `WINDOW_MAX` | 4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `RESET_EVERY` | 12 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `SAMPLE_INTERVAL` | 0.5 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `INTENSITY_THRESHOLD` | 6.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `INTENSITY_DECAY` | 0.8 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `MIN_COOLDOWN` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `IDLE_FILLER` | 45.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `URGENT_BAR` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `URGENT_COOLDOWN` | 2.5 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `URGENT_MAX` | 6 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `ENERGY_TO_INTENSITY` | 0.02 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `ENERGY_URGENT_RISE` | 400.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_DISASTER` | 12.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_EXTINCT` | 10.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_FIRE` | 7.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_DEATH` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_STAMPEDE` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_CHASE` | 3.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_STALK` | 3.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_CIRCLE` | 2.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_BIRTH` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerDirector.gd` | `I_DAYNIGHT` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `SAMPLE_HZ` | 10.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `MIN_FRAME_GAP` | 30 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `HISTORY` | 300 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `W_KINETIC` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `W_SEISMIC` | 8.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/SceneEnergyGraph.gd` | `W_THERMAL` | 0.6 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerAvatar.gd` | `AVATAR_RENDER_EVERY` | 3 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerAvatar.gd` | `GLANCE_PITCH_UP` | -0.20 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerAvatar.gd` | `GLANCE_YAW_LEFT` | 0.34 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerOverlay.gd` | `CAPTION_HOLD` | 8.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/streamer/StreamerOverlay.gd` | `FEED_MAX` | 4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/HeatGlow.gd` | `GLOW_MIN` | 400.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Tornado.gd` | `LIFETIME_MAX` | 55.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Tornado.gd` | `STRENGTH_START` | 0.45 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `STRENGTH_MAX` | 1.6 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Tornado.gd` | `DISSIPATE_STRENGTH` | 0.12 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SPINUP_TIME` | 9.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORT_TO_STRENGTH` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `STRENGTH_RATE` | 0.1 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_FOLLOW` | 8.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_PROBE` | 26.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `WIND_FOLLOW` | 0.9 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `WANDER_SPEED` | 3.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `PLAY_HALF_EXTENT` | 285.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SCARE_BASE` | 40.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SCARE_INTERVAL` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_RADIUS_BASE` | 20.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_WIND` | 16.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_TANGENT_GAIN` | 1.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_INWARD_GAIN` | 0.6 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `VORTEX_LIFT_GAIN` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `FUNNEL_HEIGHT` | 62.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `FUNNEL_TOP_R` | 20.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `FUNNEL_BASE_R` | 1.4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `FUNNEL_CORE_FRAC` | 0.52 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Tornado.gd` | `SPIN_SPEED` | 7.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SWAY_SPEED` | 1.3 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SPOUT_VAPOR_PER_SEC` | 0.9 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tornado.gd` | `SPOUT_SPLASH_INTERVAL` | 0.18 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `SPAWN_HEIGHT` | 140.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `START_SPEED` | 70.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `LAUNCH_SPEED` | 150.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `MAX_SPEED` | 600.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `ESCAPE_RADIUS_MULT` | 30.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `MAX_LIFETIME` | 240.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `METEOR_MASS_SCALE` | 400.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `IMPACT_RADIUS` | 10.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `DAMAGE_SCALE` | 1.6 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `BODY_RADIUS` | 1.4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `AMBIENT_TEMP_C` | -60.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `ENTRY_HEAT_GAIN` | 4.23e-6 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `RADIATIVE_COOL` | 0.55 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `MAX_SURFACE_TEMP_C` | 3000.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `AIR_REFERENCE_O2` | 0.21 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `FX_LINGER` | 1.8 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `MIN_CRATER_CELLS` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Nest.gd` | `IDLE_TIMEOUT` | 120.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Nest.gd` | `DISREPAIR_START` | 60.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `STRIKE_HEIGHT` | 130.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `FLASH_ENERGY` | 34.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `LINGER` | 0.7 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `SEGMENTS` | 14 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `DURATION` | 4.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `FADE_TIME` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `RADIUS_SCALE` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `MIN_RADIUS` | 6.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `SCARE_MULT` | 2.6 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `VAPOR_PER_SEC` | 26.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `VAPOR_INJECT_R` | 16.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Flood.gd` | `CLOUD_ALOFT` | 58.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `SCARE_INTERVAL` | 2.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `SCARE_RADIUS` | 55.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `SUPPLY_PER_SEC` | 16.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `SUPPLY_INTERVAL` | 0.05 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `VENT_DISC` | 0.10 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `ERUPT_SEISMIC` | 3.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `PROFILE_AZIMUTHS` | 24 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `PROFILE_RINGS` | 14 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `PROFILE_SPAN` | 0.25 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `PROFILE_RISE` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Volcano.gd` | `BASELINE_DELAY` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `LIFETIME` | 46.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `BUILD_TIME` | 6.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `FADE_TIME` | 10.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `RADIUS` | 62.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `VAPOR_PER_SEC` | 5.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `VAPOR_INJECT_R` | 14.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `STRENGTH_MAX` | 1.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `UPDRAFT_TO_STRENGTH` | 0.3 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `STRENGTH_RATE` | 0.1 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `DISSIPATE_STRENGTH` | 0.12 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `LIFT_FOLLOW` | 5.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `LIFT_PROBE` | 40.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Thunderstorm.gd` | `WIND_DRIFT` | 0.7 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `GROW_TIME` | 20.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `START_FRACTION` | 0.35 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_BIOMASS_FULL` | 0.0025 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_GROWTH_FLOOR` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_TIME` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_ANGLE` | 1.483529 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_SETTLE_STRIDE` | 30 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `LIFETIME_MAX` | 150.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `STRENGTH_START` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `STRENGTH_MAX` | 1.8 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `DISSIPATE_STRENGTH` | 0.14 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `SPINUP_TIME` | 22.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `VORT_TO_STRENGTH` | 0.55 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `STRENGTH_RATE` | 0.1 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Hurricane.gd` | `WARM_OCEAN_TEMP` | 16.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `VORTEX_STEER` | 0.4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `VORTEX_PROBE` | 60.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `EYE_RADIUS` | 26.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `OUTER_RADIUS` | 150.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `EYEWALL_POINTS` | 12 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `VAPOR_PER_SEC` | 9.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `VAPOR_INJECT_R` | 20.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `TRACK_SPEED` | 7.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `WIND_STEER` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `PLAY_HALF_EXTENT` | 290.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `SPIN_SPEED` | 1.4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `WIND_FORCE` | 14.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Hurricane.gd` | `WIND_INWARD_FRAC` | 0.15 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Hurricane.gd` | `WIND_LIFT_FRAC` | 0.25 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Hurricane.gd` | `SCARE_INTERVAL` | 0.8 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Earthquake.gd` | `DURATION` | 3.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Earthquake.gd` | `SCARE_RADIUS` | 130.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Earthquake.gd` | `QUAKE_MAGNITUDE` | 14.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `BIOMASS_GROWTH_GAIN` | 4.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `BIOMASS_GROWTH_MAX` | 2.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Plant.gd` | `BIOMASS_PER_FOOD` | 1.8e-4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `FOOD_CAPACITY` | 46.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `FOOD_UPTAKE_RATE` | 8.0 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/actors/Plant.gd` | `FOOD_MIN_EDIBLE` | 5.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `ROOT_BASE` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `ROOT_PER_SCALE` | 3.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLINATE_PER_VISIT` | 1.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLINATE_DECAY` | 0.10 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLINATE_MAX` | 4.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLINATE_SEED_BOOST` | 7.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLEN_RADIUS` | 10.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `POLLEN_SCAN_PERIOD` | 0.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `PLANT_SETTLE_STRIDE` | 24 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/ThrownRock.gd` | `HIT_RADIUS` | 1.3 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/ThrownRock.gd` | `MAX_LIFETIME` | 4.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/ThrownRock.gd` | `ARC_HEIGHT` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/ThrownRock.gd` | `STONE_SIDE` | 0.35 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `ISLAND_RADIUS` | 180.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `SEA_LEVEL_Y` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `STEP_DISTANCE` | 1.2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `FADE_SECONDS` | 5.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `SURFACE_OFFSET` | 0.25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `MAX_DECALS` | 300 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `TEX_SIZE` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `SCAN_PERIOD` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `DWELL_SECONDS` | 1.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `MAX_WRITES_PER_SCAN` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `AQUATIC_STOCK_MULT` | 2.6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `GROW_MIN_TEMP` | 7.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `GROW_SNOW_MAX` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `SURFACE_PROBE_UP` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `AQUATIC_BREED_FRACTION` | 0.12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `AQUATIC_BREED_MAX_PER_TICK` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `GRAZE_BIOMASS_FULL` | 0.05 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `GRAZE_BIOMASS_FLOOR` | 0.30 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `GRAZE_BIOMASS_SAMPLES` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `SPAWN_ENERGY_FRAC` | 0.15 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `SPAWN_ENERGY_FLOOR` | 0.45 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `SEED_RESERVE_COST` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `TREE_POP_CAP` | 400 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `TREE_SEED_BIOMASS_FRAC` | 0.35 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `TREE_SEED_FLOOR` | 0.04 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `TREE_SEED_SPREAD` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyPlants.gd` | `TREE_SEEDS_PER_TICK` | 10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyAquatic.gd` | `AQUATIC_SAMPLE_TRIES` | 60 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `HERD_CLUSTER_SIZE` | 18 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `HERD_CLUSTER_SPREAD` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `FOUNDER_ELDER_AGE_MULT` | 1.6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `FOREST_CLUSTER_TRIES` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `FOREST_CLUSTER_SPREAD` | 15.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `FOREST_BIOMASS_WEIGHT` | 12.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `LAND_MARGIN` | 2.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologySpawner.gd` | `LAND_TRIES` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/events/LAEventTracker.gd` | `SAMPLE_INTERVAL` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/events/LAEventTracker.gd` | `RECENT_MAX` | 32 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `EVAP_KEEP_LIQUID` | 0.1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `EVAP_TAKE_FRAC` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `SOIL_SEARCH_SHELLS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `EXCAVATED_DUST_FRAC` | 0.25 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `CRATER_WATCH_MAX` | 256 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `ORGANIC_TAKE_FRAC` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldSolidCache3D.gd` | `SPOT_CELLS` | 256 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `SALT_FULL_DEPTH` | 22.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `BRACKISH_FLOOR` | 0.35 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `DUST_PRESENT` | 0.001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `MOLTEN_MIN` | 0.0001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `FIRE_PRESENT` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `SWEEP_PROBE` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `SWEEP_STRENGTH` | 9.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `SWEEP_MIN_WATER` | 0.12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `STRIDE` | 97 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `TUBE_LAVA_NEAR_ZERO` | 0.05 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `OPEN_SEA_TEMP_CAP` | 100.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SLOTS` | 21 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `DARCY_SENT` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_SENT` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SEEP_SENT` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `INFIL_SENT` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `REG_IN` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `REG_OUT` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `OWN_OUT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `DARCY_RECV` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `INFIL_RECV` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `CLAMP_GAIN` | 9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `OPEN_CLAMP_GAIN` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_RECV` | 10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `OPEN_DROP` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `OPEN_FROM_OPEN` | 12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `BEDROCK_IN` | 13 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_DOWN` | 14 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_LAT` | 15 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_UP` | 16 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_WET` | 17 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_CAPPED` | 18 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SPRING_FREECOL` | 19 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSoilBudget3D.gd` | `SAMPLE_EVERY` | 50 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `MAX_STEPS_PER_FRAME` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `FIELD_CADENCE_MAX` | 60 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `SIM_SECONDS_PER_STEP` | 43.2 | the substrate's time quantum: how much simulated time one field step advances. Nothing in physics fixes it — it is the integrator's resolution, the way a weather model picks its timestep. It is the value the whole substrate was already stepping at (it was `STEP_DT * 86400 / DAY_LENGTH`), kept so no reaction rate changes meaning in the commit that stops it being a function of a game-feel knob. Unreviewed as a magnitude. | derive it from the explicit-kernel stability limit — the smallest of the thermal diffusion number and the transport CFL at the shipped grid — so the step is set by what the kernels can integrate rather than declared |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `STATIONS_PER_BAND` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `LONG_DAYS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `SITE_RETRY_FRAMES` | 60 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBoxStep3D.gd` | `MAX_STEPS_PER_FRAME` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBoxStep3D.gd` | `DIFF` | 0.14 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBoxStep3D.gd` | `BUOY` | 0.10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `GROW_THRESHOLD` | 0.55 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `SHRINK_THRESHOLD` | 0.45 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `SCAN_EVERY` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `ACTIVE_WINDOW` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `STAMP_BUDGET` | 96 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/OceanPlane.gd` | `SPHERE_RADIAL_SEGMENTS` | 96 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/OceanPlane.gd` | `SPHERE_RINGS` | 64 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd` | `BASELINE_DETRITUS` | 0.15 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd` | `LITTER_FLAMMABLE_FRAC` | 0.30 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd` | `LITTER_FROM_BIOMASS` | 0.20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd` | `REFILL_EVERY` | 40 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd` | `FUEL_REQUEST_LEAD` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `SOIL_DBG_SLOTS` | 21 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `ACTIVE_ARGS_SLOTS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `ARG_SLOT_LIST_COUNT` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `PLATE_STRIDE` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `MAX_PLATES` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `CHANNEL_HOLD_DRAINS` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `SLOW_READBACK_EVERY` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `DRAIN_ALL` | -1.0e30 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `BREAKDOWN` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `RESIDUAL_AFTER_BOLT` | 0.1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `DEPLETE_R` | 22.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `MAX_BOLTS_PER_STEP` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `PROBE_STRIDE` | 64 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `PROBE_GATE` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialCharge3D.gd` | `FULL_SCAN_EVERY` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd` | `SAMPLE_EVERY` | 100 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd` | `SUSP_ACTIVE` | 0.001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `FREEZE_RATE` | 0.05 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `MELT_RATE` | 0.05 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `DEPOSIT_RATE` | 0.10 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SOLIDIFY_RATE` | 0.02 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `ROCK_MELT_RATE` | 0.02 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `VAPOUR_TRANSFER_COEFF` | 1.2e-3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SURFACE_WIND_M_S` | 7.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SOIL_SURFACE_RESISTANCE_S_M` | 1000.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SATURATED_SURFACE_LAYER` | 0.36 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `LOFT_WIND` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `LOFT_RATE` | 0.003 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `SUSP_SETTLE_RATE` | 0.05 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `DISSOLUTION_K` | 2.0e-5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `LITH_RATE_PER_PA` | 1.0e-9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `TEMP` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `WATER` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `MOISTURE` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `O2` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `CO2` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FUEL` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FIRE` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `DETRITUS` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FUNGUS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FERT` | 9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `LAVA` | 10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `BIOMASS` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SNOW` | 12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SEDIMENT` | 13 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `DUST` | 14 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SUSP` | 15 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `WINDSPEED` | 16 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `ROCK_FILL` | 17 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `LIGHT` | 18 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SOIL_ROOT` | 19 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `VAPOUR_DEFICIT` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SOIL_TOP` | 21 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `OVERBURDEN` | 22 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `BEDROCK_BELOW` | 23 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `CARBONATE` | 24 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SILICA` | 25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `CONST_FRAC` | 0 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `BILINEAR` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `EXCESS_OVER_THRESHOLD` | 2 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `DEFICIT_BELOW_THRESHOLD` | 4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `OPTIMUM_BAND` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `ARRHENIUS` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_OPEN_ABOVE` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_SURFACE` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_NEAR_GROUND` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_DAYLIGHT` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_DRY` | 16 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_AIR_ABOVE` | 128 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `TGT_SELF` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `TGT_SCRATCH` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RECORD_BYTES` | 144 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PHOTO_LUE_KG_C_PER_J` | 1.0e-9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PAR_FRACTION_OF_SHORTWAVE` | 0.45 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `TRANSPIRATION_MOL_H2O_PER_MOL_C` | 400.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_GPP_PG_C_PER_YEAR` | 123.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_NPP_PG_C_PER_YEAR` | 56.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_PLANT_CARBON_PG_C` | 450.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR` | 54.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_ORGANIC_CARBON_PG_C` | 1500.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_MICROBIAL_C_KG_PER_M2` | 0.128 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/CombustionRecords.gd` | `PYROLYSIS_REF_TEMP_K` | 600.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/CombustionRecords.gd` | `PYROLYSIS_K_PER_S` | 2.5e-3 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/ReactionBalance.gd` | `TOL` | 1.0e-6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd` | `DRAIN_ALL` | 1.0e30 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/sphere_passes/GasWindPass.gd` | `DEFAULT_BUOY` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/sphere_passes/TracerTransport.gd` | `SETTLE_V_PER_CONTRAST` | 0.05 | transport tuning, chosen not derived; one declaration for every tracer | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/sphere_passes/TracerTransport.gd` | `EDDY_DIFFUSE` | 0.02 | transport tuning, chosen not derived; one declaration for every tracer | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/sphere_passes/AtmospherePass.gd` | `AUTOCONVERSION_RATE_PER_S` | 1.0e-3 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/sphere_passes/AtmospherePass.gd` | `CLOUD_WATER_CRIT_KG_KG` | 0.5e-3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/sphere_passes/AtmospherePass.gd` | `MOISTURE_DIFFUSE` | 0.035 | transport tuning, chosen not derived | Stage 2: derive from the transport law, or delete with the kernel merge |
| `addons/local_agents/sim/material/sphere_passes/WaterSlumpLavaPass.gd` | `MIN_FLOW` | 0.01 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/sphere_passes/WaterSlumpLavaPass.gd` | `MIN_MASS` | 0.0001 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldLakes3D.gd` | `RIVER_ACCUM_MIN` | 6 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldLakes3D.gd` | `RIVER_MAX_DEPTH_CELLS` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldLakes3D.gd` | `RIVER_CARVE_MAX` | 6000 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldRegolith3D.gd` | `REGOLITH_CELLS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRegolith3D.gd` | `INITIAL_TABLE_FRAC` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `N_A1` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `N_B1` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `N_A0` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `N_B0` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `SEA_BIAS` | 0.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `GRAZE_RESIDUAL` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `BITE_TAKE_FRAC` | 0.35 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `HEAT_C_PER_MASS` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `HEAT_RADIUS` | 0.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `PARCELS_PER_EJECT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_GAIN` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_MIN` | 6.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_MAX` | 30.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `CONE` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `BUDGET_CEIL` | 256 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `BUDGET_FLOOR` | 48 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `MAX_LIFETIME` | 12.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `LAND_HEAT_R` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `K_ICE_ALBEDO_GAIN` | 40.0 | radiative property not in the authority | add to PhysicalConstants.gd with a citation |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `K_MAX_DT_PER_STEP` | 5.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `K_WATER_SURFACE_MIN` | 0.5 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/SeaIceTextureBaker.gd` | `ICE_GAIN` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `FUNGUS_PRESENT` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `DETRITUS_PRESENT` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/FieldPassAttribution3D.gd` | `SAMPLE_EVERY` | 50 | diagnostic cadence: a sample checkpoints between every pass, so it is not free. Not derived, not cited — a cost choice | an active-cell probe that costs nothing to leave armed every step |
| `addons/local_agents/sim/material/WaterParticles.gd` | `MAX_PARTICLES` | 12000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterParticles.gd` | `LIFETIME` | 7.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterParticles.gd` | `CAP_ANGLE` | 1.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `LIT_MIN` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `WET_SPLIT` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `DRY_EPS` | 0.01 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/BiomeTextureBaker.gd` | `WARM_COLD_C` | -25.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/BiomeTextureBaker.gd` | `WARM_HOT_C` | 40.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/BiomeTextureBaker.gd` | `RH_LUSH` | 1.2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialShock3D.gd` | `SHOCK_ACTIVE` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialShock3D.gd` | `SEED_NEIGHBOUR_FRACTION` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldConservation3D.gd` | `REFERENCE_STEPS` | 600 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `CAP_ANGLE` | 0.8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `FAR_ALT` | 130.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `REBUILD_PERIOD` | 0.22 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `RECENTER_DOT` | 0.999 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `RIPPLE_MAX` | 16 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `RIPPLE_SPEED` | 9.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `RIPPLE_DECAY` | 0.7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRender3D.gd` | `WIND_SCALE` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `HEAVY_EVERY_FRAMES` | 64 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `CLIMATE_BANDS` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `ALT_BANDS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `ALT_BAND_SPAN` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `CLIMATE_MAX_CELLS` | 200000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MAX_MASS` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MAX_COMPRESS` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MIN_MASS` | 0.0001 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MAX_FLOW` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MIN_FLOW` | 0.01 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `LATERAL_FRACTION` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `INITIAL_TEMP` | 15.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `O2_AMBIENT` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `SNOW_PRESENT` | 1.9e-4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `ICE_DEPTH` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `FOG_MAX_TEMP` | 12.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `CONDENSE_COVER_MIN` | 5.0e-8 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `STEP_HZ` | 10.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `MAX_STEPS_PER_FRAME` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `RENDER_MIN` | 0.08 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `SEA_WAVE_EPS` | 0.6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `HEAT_TEX_EVERY` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `SLOW_READ_EVERY` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `SAMPLE_COLS_PER_FRAME` | 700 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `AIR` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `WATER` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `ICE` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `STEAM` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `ROCK` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `DIRT` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `SAND` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `LAVA` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `ASH` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `SMOKE` | 9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `WOOD` | 10 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `SNOW` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `COUNT` | 12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `PHASE_SOLID` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `PHASE_GRANULAR` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `PHASE_LIQUID` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `PHASE_GAS` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/Materials.gd` | `NONE` | -1 | inherited, unreviewed | Stage 2 substrate rewrite |
