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

**MAX_DECLARED: 336**   <!-- the grid's slot and face tags went with it; SimWorld's ten terrain lengths were
inline literals scaled by a Node3D transform and are now named metre constants the registry can see. -->

The gate fails if the table grows past that ceiling. To add a number, derive it, bind it, or raise the
ceiling in the same commit and argue for it in the message. When the count drops, lower the ceiling to bank
the progress. It may shrink. It may not grow.

## The grid has one length in it, and it is metres

`LAVoxelGrid.cell_size` is the edge of a cube, the same along every axis and at every cell. `LAFieldGravity`
solves Poisson in SI over that grid, so the cell edge is metres and there is no conversion factor anywhere
between the grid and the physics.

## Opening state, 2026-08-10

690 literal constants scanned across the kernels and `addons/local_agents/sim/**`. 77 are bound to the
authority. **613 are not**, which is the honest size of the problem and was invisible before this file
existed. The `why` and `deletes it` columns are filled in by class where the two 2026-08-10 audits
established one, and marked `inherited, unreviewed` otherwise. Unreviewed is a status, not a pass: it means
the number is now visible and counted, and the ceiling stops a 614th arriving unnoticed.

## Modelling choices that live in the authority file

`PhysicalConstants.gd` is excluded from the scan because it is the authority for properties of matter. The
constants below are not properties of matter and are therefore declared here instead. All of them should
eventually move out of that file, because a modelling choice sitting among measured constants is
camouflaged by its neighbours.

The three electrification rows are one modelling choice with three numbers in it. Non-inductive charging is
a collision process between graupel and ice crystals, and its rate is set by their number concentrations,
sizes and fall speeds. This substrate carries none of those — it has a cloud water fill fraction, a
temperature and a vertical wind — so the microphysical rate cannot be derived here. What is used instead is
the observed BULK separation rate in an active charging zone, saturated against the two drivers the field
does have. The arithmetic that anchors it: a flash neutralises about 25 C, an active cell flashes about
every 20 s, and its mixed-phase zone is roughly 2.4e11 m^3, which needs 5e-12 C/m^3/s averaged over the
whole zone. Charging is concentrated in a small part of that volume, so the local peak is orders higher,
and 1 nC/m^3/s is the top of the lab-constrained range.

| file | constant | value | why it is not physics | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `AIR_MASS_HORIZON` | 38.0 | empirical airmass cutoff at the horizon, an approximation to the Chapman function, not a measured quantity | use the Chapman function, or cite the approximation and its error |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `NIC_CHARGE_RATE_C_M3_S` | 1.0e-9 | bulk stand-in for a collision process whose microphysics this grid cannot resolve; the top of the lab-constrained 0.1-1 nC/m^3/s range | hydrometeor size distributions in the substrate, at which point the rate is computed rather than chosen |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `CONVECTIVE_UPDRAFT_M_S` | 10.0 | the updraft at which the charging rate is taken to saturate; observed mature-cell updrafts span 5-25 m/s and one had to be picked | same as above: with real collision kinetics the updraft enters through fall speed, not through a reference value |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `CHARGING_LWC_KG_M3` | 1.0e-3 | the cloud liquid water content at which the riming rate is taken to saturate; lab rates climb over 0.1-2 g/m^3 | same as above |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `SILICATE_HEAT_PRODUCTION_W_KG` | derived: `BSE_*_KG_PER_KG` x `HEAT_PRODUCTION_*_W_KG` | the U/Th/K abundances are the cited bulk silicate Earth average (McDonough & Sun 1995) and the per-element rates are Rybach 1988, so the number is measured; the MODELLING CHOICE is applying one bulk average to every rock cell when continental crust is enriched ~50x over depleted mantle, and taking the PRESENT-DAY rate on a body with no age | a second rock substance in `Substances.gd` carrying its own U/Th/K, and a planet age driving the four decay constants |

## Known wrong, already scheduled

These are not merely undeclared. The audits established they are incorrect, and they are listed so the
registry does not read as if everything in it is merely unreviewed.

| file | constant | value | what is wrong | what deletes it |
|---|---|---|---|---|

## The queue

| file | constant | value | why it is not physics | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/sim/material/AbsorptionBands.gd` | `BAND_COUNT` | 109 | spectral resolution of the absorption table, chosen so the 667 cm^-1 CO2 band is resolved at 10 cm^-1 | it is measured against the CO2-doubling forcing in tests/test_radiative_transfer.gd; raise it if that test drifts off 3.7 W/m^2 |
| `addons/local_agents/sim/material/AbsorptionBands.gd` | `TEMP_COUNT` | 9 | temperature resolution of the absorption table, 150-1000 K | a hot-band regime the slices cannot interpolate, which the Venus arm of the radiative test would catch |
| `addons/local_agents/sim/material/AbsorptionBands.gd` | `CDF_COUNT` | 1024 | sample count of the Planck cumulative table the GPU reads instead of summing the series | a GPU that can afford the series inline |
| `addons/local_agents/sim/material/AbsorptionBands.gd` | `CDF_XMAX` | 50.0 | upper limit of x = c2*nu/T in that table; above it the fraction of blackbody power is below 1e-9 | a body cold enough that x = 50 falls inside its emission, i.e. below about 30 K |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `SAMPLE_COLUMNS` | 64 | how many columns the gauge solves per report; a sampling rate, not a physical quantity | the kernel writing its own per-column fluxes back, so the gauge reads them instead of recomputing |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `K_SURFACE_FILL_MIN` | 0.5 | a cell is part solid and part air, so "is this the surface" has no sharp answer at this resolution | the RADIATE row meets the condensed fraction geometrically and needs no surface at all, so this is the last copy |
| `addons/local_agents/sim/mesh/VegetationRenderer.gd` | `_CHUNK` | 256 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/mesh/VegetationRenderer.gd` | `_INITIAL_CAP` | 512 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/SimWorld.gd` | `SLOW_BUILD_CELLS` | 250000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/SimWorld.gd` | `MODELLED_ATMOSPHERE_HEIGHT_M` | 1.0e5 | modelling extent: how much air the box holds | a body that declares its own atmosphere mass |
| `addons/local_agents/sim/SimWorld.gd` | `RELIEF_M` | 9.4e3 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `FEATURE_M` | 5.2e4 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `BASIN_RELIEF_M` | 4.0e3 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `BASIN_SIZE_M` | 4.4e4 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `RIDGE_RELIEF_M` | 1.35e3 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `RIDGE_SIZE_M` | 3.2e4 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `DETAIL_RELIEF_M` | 3.4e2 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `CAVE_SIZE_M` | 2.0e4 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimWorld.gd` | `CAVE_DEPTH_FADE_M` | 4.7e3 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimClock.gd` | `REAL_SECONDS_PER_SIM_SECOND` | 432.0 | time compression: real seconds that one sim-clock second stands for. A real planet has no such number, and this is now the only one the timebase asserts — the rotation itself is `LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S`, and `DAY_LENGTH` (199.454 sim s), `SPIN_RAD_PER_SIM_S` (0.0315019 rad/sim s) and `LAMaterialFieldSphereStep3D.real_seconds_per_step()` (43.2 real s) are all derived from that pair. It is not only a viewing speed: `real_seconds_per_step()` is every transport kernel's `params.dt`, so this number sets every rate in the substrate and every kernel's Courant number. | a substep budget that decouples the field's `dt` from the presentation clock, so this number sets how fast the player watches and no kernel `dt` reads it |
| `addons/local_agents/sim/SimClock.gd` | `DAYS_PER_SEASON` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_OUTPUT_SDF` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_ADD` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_SUBTRACT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_MULTIPLY` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_ABS` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `AIRBORNE_PRESENT` | 0.001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `TUBE_MELT_NEAR_ZERO` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_MIN` | 16 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_MAX` | 17 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_SDF_SPHERE` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/terrain/SpherePlanetGenerator.gd` | `T_FAST_NOISE_3D` | 40 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/SimReportSources.gd` | `METAB_FIT_MIN_N` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
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
| `addons/local_agents/sim/actors/Tree.gd` | `GROW_TIME` | 20.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `START_FRACTION` | 0.35 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_BIOMASS_FULL` | 0.0025 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_GROWTH_FLOOR` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_TIME` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_ANGLE` | 1.483529 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_SETTLE_STRIDE` | 30 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
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
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `CRATER_WATCH_MAX` | 256 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `ORGANIC_TAKE_FRAC` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldSolidCache3D.gd` | `SPOT_CELLS` | 256 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `MOLTEN_MIN` | 0.0001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `FIRE_PRESENT` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `STRIDE` | 97 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `MAX_STEPS_PER_FRAME` | 2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `FIELD_CADENCE_MAX` | 60 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `STATIONS_PER_BAND` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `LONG_DAYS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `SITE_RETRY_FRAMES` | 60 | inherited, unreviewed | Stage 2 substrate rewrite |
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
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `CHANNEL_HOLD_DRAINS` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `SLOW_READBACK_EVERY` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `DRAIN_ALL` | -1.0e30 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd` | `SAMPLE_EVERY` | 100 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldMineralProfile3D.gd` | `SUSP_ACTIVE` | 0.001 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `VAPOUR_TRANSFER_COEFF` | 1.2e-3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SOIL_SURFACE_RESISTANCE_S_M` | 1000.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/GeoRecords.gd` | `DISSOLUTION_K` | 2.0e-5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `LITHIFICATION_RATE_PER_PA` | 1.0e-9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `TEMP` | 0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `H2O` | 1 | slot id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `O2` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `CO2` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FUEL` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FIRE` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `DETRITUS` | 7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FUNGUS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `FERT` | 9 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `BIOMASS` | 11 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `WINDSPEED` | 16 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `LIGHT` | 18 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_RESISTANCE_SERIES` | 7 | rate-model id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `H2O_LIQUID` | 31 | slot id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SOIL_ROOT` | 19 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `VAPOUR_DEFICIT` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SOIL_TOP` | 21 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `BEDROCK_BELOW` | 23 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `CARBONATE` | 24 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `SILICA` | 25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `N2` | 26 | channel-slot TAG, not a quantity: it names the dinitrogen buffer the kernel binds | the slot block becomes a GDScript `enum` mirrored into the kernel, which is what this gate asks of every tag here |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `DISCHARGE` | 27 | channel-slot TAG, not a quantity: it names the lightning discharge stamp | same as `N2` above |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_CONST_FRAC` | 0 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_BILINEAR` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_EXCESS_OVER_THRESHOLD` | 2 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_DEFICIT_BELOW_THRESHOLD` | 4 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_OPTIMUM_BAND` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_ARRHENIUS` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_NEAR_GROUND` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
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
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `CLOUD_WATER_CRIT_KG_KG` | 0.5e-3 | Kessler (1969) q_crit | deleted when condensation is a reaction record and the detector reads the record |
| `addons/local_agents/sim/material/sphere_passes/TransportPass.gd` | `MIN_AMOUNT` | 0.0001 | the amount below which a cell is treated as empty; chosen, not derived | deleted when a donor's floor comes from the substance's own molar volume |
| `addons/local_agents/sim/material/MaterialFieldRegolith3D.gd` | `REGOLITH_CELLS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldRegolith3D.gd` | `INITIAL_TABLE_FRAC` | 0.5 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/WaterSurfaceMesh.gd` | `SEA_BIAS` | 0.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `PROFILE_BINS` | 16 | a diagnostic's resolution, not a physical quantity | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `ALOFT_CELLS` | 2.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `UPDRAFT_SAMPLE_M` | 40.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `CLOUD_BASE_ALT` | 62.0 | a renderer band radius, not a measured cloud base | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `FOG_TOP_ALT` | 16.0 | a renderer band radius, not a measured fog top | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `FOG_LO_ALT` | 0.0 | a renderer band radius, not a measured fog base | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `GROUND_SEARCH` | 6 | a march bound, not a physical quantity | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `HEAD_REACH` | 4 | a march bound, not a physical quantity | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `GRAZE_RESIDUAL` | 0.02 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `BITE_TAKE_FRAC` | 0.35 | per-step k, so it is a rate only at one timestep | Stage 2: params.dt is read, rates become per second |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `HEAT_RADIUS` | 0.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `PARCELS_PER_EJECT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_GAIN` | 1.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_MIN` | 6.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `SPEED_MAX` | 30.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `CONE` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `MAX_LIFETIME` | 12.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `LAND_HEAT_R` | 8.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldEnergyBudget3D.gd` | `K_ICE_ALBEDO_GAIN` | 40.0 | radiative property not in the authority | add to PhysicalConstants.gd with a citation |
| `addons/local_agents/sim/material/SeaIceTextureBaker.gd` | `ICE_GAIN` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `FUNGUS_PRESENT` | 0.02 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `DETRITUS_PRESENT` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/WaterParticles.gd` | `MAX_PARTICLES` | 12000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterParticles.gd` | `LIFETIME` | 7.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/WaterParticles.gd` | `CAP_ANGLE` | 1.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `LIT_MIN` | 0.05 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `WET_SPLIT` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldPhotoStats3D.gd` | `DRY_EPS` | 0.01 | inherited, unreviewed | Stage 2 substrate rewrite |
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
| `addons/local_agents/sim/material/MaterialFieldPassProbe3D.gd` | `DEFAULT_STEPS` | 3 | how many steps `LA_PASS_PROBE` samples before it disarms; a diagnostic default, not a property of the world | delete when the probe is cheap enough to leave armed for a whole run |
| `addons/local_agents/sim/material/MaterialFieldGravity3D.gd` | `SOLVE_EVERY` | 8 | how often the Poisson solve re-runs; mass moves slowly next to a step and the solve warm-starts | the residual between solves is published and stops being reported as small |
| `addons/local_agents/sim/material/MaterialFieldGravity3D.gd` | `SWEEPS` | 8 | red-black Gauss-Seidel sweeps per solve; a convergence budget, not a property of gravity | the solve reports a residual under the float floor at fewer sweeps |
| `addons/local_agents/sim/material/kernels3d/neighbours.glsli` | `N_SLOTS` | 6 | faces of a cube; it is geometry, not a choice | never — a box has six faces |
| `addons/local_agents/sim/material/kernels3d/generated.glsli` | `EXP_LIMIT` | 60.0 | generated from ReactionThermo.EXP_LIMIT; the exponent bound where exp() overflows float32 | deleted with its source row |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `GEN_RAY_STRIDE` | 1.0 | march step for the SDF surface search, metres. A DISCRETISATION, not a property of the ground | an analytic surface intersection, at which point there is no step to choose |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `GEN_RAY_REFINE` | 0.05 | bisection tolerance for the same search, metres. Sets how precisely the surface is located, nothing physical | as above |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `SIM_SECONDS_PER_STEP` | 43.2 | simulated seconds one field step advances. A DECISION about how fast the world runs, taken so slow geology is reachable; it is not a stability limit and nothing checks that it is one | a timestep chosen per step from the CFL condition the transport laws imply |
| `addons/local_agents/sim/material/reactions/ReactionThermo.gd` | `EXP_LIMIT` | 60.0 | argument clamp on exp() so a float32 cannot overflow to inf. Pure arithmetic protection with no physical meaning | nothing; it is a property of the number format, not of the model |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `ICE_FREE_LAND_AREA_M2` | 1.30e14 | EARTH's ice-free land area, used to scale a global biological flux down to a per-area rate. Measured for Earth, but this planet is not Earth and its own land area is emergent | measure the planet's own ice-free land from the field and scale by that |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PG_TO_KG` | 1.0e12 | exact unit conversion, petagrams to kilograms. A definition, not a parameter | nothing; it is exact by definition of the SI prefix |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `MICROBIAL_CUE` | 0.3 | microbial carbon-use efficiency: the share of consumed carbon that becomes biomass rather than CO2. A measured aggregate over communities that differ, applied as one number to every decomposer | a CUE that follows from the decomposer's own energetics and the substrate quality it is eating |
