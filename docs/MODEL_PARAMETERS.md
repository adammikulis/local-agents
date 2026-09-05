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

**MAX_DECLARED: 224**

The gate fails if the table grows past that ceiling. To add a number, derive it, bind it, or raise the
ceiling in the same commit and argue for it in the message. When the count drops, lower the ceiling to bank
the progress. It may shrink. It may not grow.

## The grid has one length in it, and it is metres

`LAVoxelGrid.cell_size` is the edge of a cube, the same along every axis and at every cell.
`kernels3d/gravity_poisson.glsl` solves Poisson in SI over that grid, so the cell edge is metres and there
is no conversion factor anywhere between the grid and the physics.

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
| `addons/local_agents/sim/material/kernels3d/state_derive.glsl` | `LA_STATE_TOL` | 1.0e-6 | the relative move below which the (T, p) solve has stopped, which is float32's own resolution on a pressure, not a property of matter | a direct solve of the pair, which needs no stopping rule |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `AIR_MASS_HORIZON` | 38.0 | empirical airmass cutoff at the horizon, an approximation to the Chapman function, not a measured quantity | use the Chapman function, or cite the approximation and its error |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `NIC_CHARGE_RATE_C_M3_S` | 1.0e-9 | bulk stand-in for a collision process whose microphysics this grid cannot resolve; the top of the lab-constrained 0.1-1 nC/m^3/s range | hydrometeor size distributions in the substrate, at which point the rate is computed rather than chosen |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `CONVECTIVE_UPDRAFT_M_S` | 10.0 | the updraft at which the charging rate is taken to saturate; observed mature-cell updrafts span 5-25 m/s and one had to be picked | same as above: with real collision kinetics the updraft enters through fall speed, not through a reference value |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `CHARGING_LWC_KG_M3` | 1.0e-3 | the cloud liquid water content at which the riming rate is taken to saturate; lab rates climb over 0.1-2 g/m^3 | same as above |
| `addons/local_agents/sim/material/PhysicalConstants.gd` | `SILICATE_HEAT_PRODUCTION_W_KG` | derived: `BSE_*_KG_PER_KG` x `HEAT_PRODUCTION_*_W_KG` | the U/Th/K abundances are the cited bulk silicate Earth average (McDonough & Sun 1995) and the per-element rates are Rybach 1988, so the number is measured; the MODELLING CHOICE is applying one bulk average to every rock cell when continental crust is enriched ~50x over depleted mantle, and taking the PRESENT-DAY rate on a body with no age | a second rock substance in `Substances.gd` carrying its own U/Th/K, and a planet age driving the four decay constants |

## Which substances get a measured phase curve

`h2o` alone carries the IAPWS formulations — Wagner & Pruß 2002 eq. 2.5 for saturation, IAPWS 2011
(R14-08) for sublimation over ice Ih and for the ice Ih melting curve. Their coefficients are scalar
properties of water's `LASubstances` row, so `check_physical_constants.sh` holds the `enthalpy.glsli`
copies to the built table.

Every other substance with a vapour phase (`n2`, `o2`, `co2`, `h2`, `co`, `so2`, `h2s`, `ch4`, `iron`)
takes the two-anchor Clausius-Clapeyron law: `ln p = A - B/T` with `B` set by the two measured points its
row already carries, the triple point and the normal boiling point (`boil_c` at `boil_ref_p_pa`). Both
anchors are reproduced exactly, but the curve between them integrates one constant latent heat instead of
the measured one. What deletes a substance from this list: its own published vapour-pressure
correlation, in the same branch water takes.

## Known wrong, already scheduled

These are not merely undeclared. The audits established they are incorrect, and they are listed so the
registry does not read as if everything in it is merely unreviewed.

| file | constant | value | what is wrong | what deletes it |
|---|---|---|---|---|

## The queue

| file | constant | value | why it is not physics | what deletes it |
|---|---|---|---|---|
| `addons/local_agents/gdextensions/localagents/include/LAAbsorptionBands.hpp` | `BAND_COUNT` | 157 | spectral resolution of the absorption table over 0-46000 cm^-1, chosen so the 667 cm^-1 CO2 band is resolved at 10 cm^-1 and the Huggins O3 structure at 500 | a convergence test against a finer grid: the RADIATE row now marches a column, but its transmittance is band-integrated before it is marched, so band count and correlated-k error are not yet separable |
| `addons/local_agents/gdextensions/localagents/include/LAAbsorptionBands.hpp` | `TEMP_COUNT` | 9 | temperature resolution of the absorption table, 150-1000 K | a hot-band regime the slices cannot interpolate |
| `addons/local_agents/gdextensions/localagents/include/LAAbsorptionBands.hpp` | `CDF_COUNT` | 1024 | sample count of the Planck cumulative table the GPU reads instead of summing the series | a GPU that can afford the series inline |
| `addons/local_agents/gdextensions/localagents/include/LAAbsorptionBands.hpp` | `CDF_XMAX` | 50.0 | upper limit of x = c2*nu/T in that table; above it the fraction of blackbody power is below 1e-9 | a body cold enough that x = 50 falls inside its emission, i.e. below about 30 K |
| `addons/local_agents/game/render/VegetationRenderer.gd` | `_CHUNK` | 256 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/game/render/VegetationRenderer.gd` | `_INITIAL_CAP` | 512 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/SimWorld.gd` | `SLOW_BUILD_CELLS` | 250000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/FieldGridBudget3D.gd` | `CELLS_PER_SCALE_HEIGHT` | 2.0 | cells one atmospheric scale height is cut into at the target edge; a DISCRETISATION of the air column, held under `docs/CELL_BUDGET` | a grid that resolves the scale height everywhere, which the cell budget forbids at planet scale |
| `addons/local_agents/sim/material/FieldGridBudget3D.gd` | `CELLS_PER_LEVEL_PAD` | 4.0 | cells of its own edge a refinement level carries around the terrain surface and around a box's focus axis; a DISCRETISATION of the octree grading, held under `docs/CELL_BUDGET` | a grid at the finest edge everywhere, which the cell budget forbids at planet scale |
| `addons/local_agents/sim/material/kernels3d/flux.glsl` | `LA_COURANT_LIMIT` | 0.5 | the Courant number one substep may reach: the face solve, the momentum close and the record moves run as a sequence off the substep's opening state, and the column at rest grows past this bound; a DISCRETISATION of time, the scheme's own stability, not a property of matter | an implicit acoustic update, or a flux-form simultaneous one, which has no Courant bound |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `FINEST_WAVELENGTH_M` | 4.0e2 | shortest relief wavelength the seeded body carries; a resolution of the declared shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CDF_SAMPLES` | 8192 | directions the relief cascade's own distribution is measured over before the hypsographic curve is laid along it | a closed form for the cascade's distribution |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CURVE_POINTS` | 65 | control points of that map | the same closed form |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CURVE_BAKE` | 512 | resolution the graph samples that map at | the same closed form |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CAVE_SIZE_M` | 2.0e4 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CAVE_THRESHOLD` | 0.09 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CAVE_STRENGTH` | 40.0 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/terrain/PlanetShape.gd` | `CAVE_DEPTH_FADE_M` | 4.7e3 | declared starting shape, not a rate | 0.5 grows the terrain by simulating geology forward |
| `addons/local_agents/sim/SimReportSources.gd` | `METAB_FIT_MIN_N` | 3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/streamer/StreamerDirector.gd` | `WINDOW_MAX` | 4 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `RESET_EVERY` | 12 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `SAMPLE_INTERVAL` | 0.5 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `INTENSITY_THRESHOLD` | 6.0 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `INTENSITY_DECAY` | 0.8 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `MIN_COOLDOWN` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `IDLE_FILLER` | 45.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `URGENT_BAR` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `URGENT_COOLDOWN` | 2.5 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `URGENT_MAX` | 6 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `ENERGY_TO_INTENSITY` | 0.02 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `ENERGY_URGENT_RISE` | 400.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_DISASTER` | 12.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_EXTINCT` | 10.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_FIRE` | 7.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_DEATH` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_STAMPEDE` | 6.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_CHASE` | 3.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_STALK` | 3.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_CIRCLE` | 2.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_BIRTH` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerDirector.gd` | `I_DAYNIGHT` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/SceneEnergyGraph.gd` | `SAMPLE_HZ` | 10.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/SceneEnergyGraph.gd` | `MIN_FRAME_GAP` | 30 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/SceneEnergyGraph.gd` | `HISTORY` | 300 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/SceneEnergyGraph.gd` | `W_KINETIC` | 1.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/SceneEnergyGraph.gd` | `W_THERMAL` | 0.6 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerAvatar.gd` | `AVATAR_RENDER_EVERY` | 3 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerAvatar.gd` | `GLANCE_PITCH_UP` | -0.20 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerAvatar.gd` | `GLANCE_YAW_LEFT` | 0.34 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerOverlay.gd` | `CAPTION_HOLD` | 8.0 | presentation, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/streamer/StreamerOverlay.gd` | `FEED_MAX` | 4 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/actors/Meteor.gd` | `TRANSIENT_DEPTH_PER_DIAMETER` | 1.0 / 3.0 | the observed depth-to-diameter ratio of a transient impact cavity (Melosh 1989, ch. 7), a measured shape of craters rather than a property of matter | a solved excavation flow, which produces the cavity shape instead of asserting it |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `EJECTION_ANGLE_RAD` | PI / 4.0 | the ejection angle crater ejecta clusters at (Melosh 1989, ch. 5) | the Maxwell Z-model, which gives each parcel its own angle from its launch position |
| `addons/local_agents/sim/actors/Meteor.gd` | `BODY_RADIUS` | 1.4 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Meteor.gd` | `FX_LINGER` | 1.8 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Nest.gd` | `IDLE_TIMEOUT` | 120.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Nest.gd` | `DISREPAIR_START` | 60.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `STRIKE_HEIGHT` | 130.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `FLASH_ENERGY` | 34.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `LINGER` | 0.7 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/LightningStrike.gd` | `SEGMENTS` | 14 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `MATURE_YEARS` | 60.0 | years from germination to full stem height for a temperate tree | the wood the tree has actually fixed sets its height, and the years fall out |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_BIOMASS_FULL` | 0.0025 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_TIME` | 1.5 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TOPPLE_ANGLE` | 1.483529 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Tree.gd` | `TREE_SETTLE_STRIDE` | 30 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `BIOMASS_GROWTH_GAIN` | 4.0 | disaster actor, inherited | dissolve-dont-patch: the actor becomes a seed, the constant goes with it |
| `addons/local_agents/sim/actors/Plant.gd` | `BIOMASS_GROWTH_MAX` | 2.0 | presence floor or numerical guard | Stage 2: show it never binds, or delete it |
| `addons/local_agents/sim/actors/Plant.gd` | `SEEDLING_SHOOT_M` | 0.05 | the shoot a germinating seed puts up: the smallest a living plant is | the seed's own mass sets the seedling it makes |
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
| `addons/local_agents/sim/TrackSystem.gd` | `STEP_DISTANCE` | 1.2 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `FADE_SECONDS` | 5.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `SURFACE_OFFSET` | 0.25 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `MAX_DECALS` | 300 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/TrackSystem.gd` | `TEX_SIZE` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `SCAN_PERIOD` | 0.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `DWELL_SECONDS` | 1.5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/BandChronicle.gd` | `MAX_WRITES_PER_SCAN` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `GDD_BASE_C` | 5.0 | growing-degree-day base temperature for temperate plants | the plant's own enzyme rate against temperature |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `TREELINE_ISOTHERM_C` | 10.0 | the warmest-month isotherm the treeline follows (Koppen) | a tree's carbon balance goes negative on its own |
| `addons/local_agents/sim/ecology/EcologyService.gd` | `SURFACE_PROBE_UP` | 6.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `AQUATIC_BREED_FRACTION` | 0.12 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `AQUATIC_BREED_MAX_PER_TICK` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/ecology/EcologyBreeding.gd` | `GRAZE_BIOMASS_FULL` | 0.05 | inherited, unreviewed | Stage 2 substrate rewrite |
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
| `addons/local_agents/sim/events/LAEventTracker.gd` | `RECENT_MAX` | 32 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/sim/material/MaterialFieldInject3D.gd` | `CRATER_WATCH_MAX` | 256 | a telemetry list's length, not a physical quantity | not owed: a diagnostic may size its own buffer |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `STATIONS_PER_BAND` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `LONG_DAYS` | 8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldClimateSwing3D.gd` | `SITE_RETRY_FRAMES` | 60 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `SCAN_EVERY` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `ACTIVE_WINDOW` | 32 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MineralStamp3D.gd` | `STAMP_BUDGET` | 96 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `CHANNEL_HOLD_DRAINS` | 20 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialSphereGPU3D.gd` | `SLOW_READBACK_EVERY` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `VAPOUR_TRANSFER_COEFF` | 1.2e-3 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/PhaseRecords.gd` | `SOIL_SURFACE_RESISTANCE_S_M` | 10.0 | r_s of a soil surface at or above field capacity, Van de Griend & Owe 1994, Water Resour. Res. 30:181; the record fires only where the cell below still holds pore water, so it is on that branch | a per-cell r_s from `SOIL_TOP` on their exponential dry branch, which needs a rate model that reads the resistance per cell |
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
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_CONST_FRAC` | 0 | rate-model id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_BILINEAR` | 1 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_EXCESS_OVER_THRESHOLD` | 2 | rate-model id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_DEFICIT_BELOW_THRESHOLD` | 4 | rate-model id, not a measured quantity | — |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_OPTIMUM_BAND` | 5 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RM_ARRHENIUS` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_NEAR_GROUND` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `GATE_AIR_ABOVE` | 128 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionDefs.gd` | `RECORD_BYTES` | 144 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PHOTO_T_OPT` | 30.0 | C3 electron-transport optimum, C, June, Evans & Farquhar 2004, Funct. Plant Biol. 31:275 | nothing; it is the measured optimum |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PHOTO_T_WIDTH` | 18.0 | Omega of the same Gaussian fit, C, June, Evans & Farquhar 2004 | nothing; it is the measured width |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `RESPIRATION_O2_P50_PA` | 35.0 | p50 of mitochondrial respiration, Pa: the midpoint of the 0.02-0.05 kPa range Gnaiger, Lassnig, Kuznetsov, Rieger & Margreiter 1998, J. Exp. Biol. 201:1129 measured across cell types | a p50 read off the cell's own tissue rather than one number for every organism |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_GPP_PG_C_PER_YEAR` | 123.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_NPP_PG_C_PER_YEAR` | 56.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `GLOBAL_PLANT_CARBON_PG_C` | 450.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_HETEROTROPHIC_RESP_PG_C_PER_YEAR` | 54.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_ORGANIC_CARBON_PG_C` | 1500.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `SOIL_MICROBIAL_C_KG_PER_M2` | 0.128 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/CombustionRecords.gd` | `PYROLYSIS_REF_TEMP_K` | 600.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/reactions/ReactionBalance.gd` | `TOL` | 1.0e-6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `CLOUD_WATER_CRIT_KG_KG` | 0.5e-3 | Kessler (1969) q_crit | deleted when condensation is a reaction record and the detector reads the record |
| `addons/local_agents/sim/material/MaterialFieldRegolith3D.gd` | `REGOLITH_CELLS` | 4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/WaterSurfaceMesh.gd` | `SEA_BIAS` | 0.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `ALOFT_CELLS` | 2.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldQueries3D.gd` | `UPDRAFT_SAMPLE_M` | 40.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `CLOUD_BASE_ALT` | 62.0 | a renderer band radius, not a measured cloud base | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `FOG_TOP_ALT` | 16.0 | a renderer band radius, not a measured fog top | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldAtmos3D.gd` | `FOG_LO_ALT` | 0.0 | a renderer band radius, not a measured fog base | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `GROUND_SEARCH` | 6 | a march bound, not a physical quantity | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldChannels3D.gd` | `HEAD_REACH` | 4 | a march bound, not a physical quantity | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` | `HEAT_RADIUS` | 0.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialEjecta3D.gd` | `PARCELS_PER_EJECT` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/WaterParticles.gd` | `MAX_PARTICLES` | 12000 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/WaterParticles.gd` | `LIFETIME` | 7.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/WaterParticles.gd` | `CAP_ANGLE` | 1.4 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldConservation3D.gd` | `REFERENCE_STEPS` | 600 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `CAP_ANGLE` | 0.8 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `FAR_ALT` | 130.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `REBUILD_PERIOD` | 0.22 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `RECENTER_DOT` | 0.999 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `RIPPLE_MAX` | 16 | presentation or diagnostic buffer length, not physics | not owed: presentation may choose numbers, but it may not write the field |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `RIPPLE_SPEED` | 9.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/game/render/MaterialFieldRender3D.gd` | `RIPPLE_DECAY` | 0.7 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `HEAVY_EVERY_FRAMES` | 64 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialFieldReport3D.gd` | `CLIMATE_BANDS` | 6 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `INITIAL_TEMP` | 15.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `O2_AMBIENT` | 0.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/sim/material/MaterialField3D.gd` | `FOG_MAX_TEMP` | 12.0 | inherited, unreviewed | Stage 2 substrate rewrite |
| `addons/local_agents/runtime/FieldPassProbe3D.gd` | `DEFAULT_STEPS` | 3 | how many steps `LA_PASS_PROBE` samples before it disarms; a diagnostic default, not a property of the world | delete when the probe is cheap enough to leave armed for a whole run |
| `addons/local_agents/sim/material/sphere_passes/GravityPass.gd` | `SOLVE_EVERY` | 2 | how often the Poisson solve re-runs; mass moves slowly next to a step and the solve warm-starts | the residual between solves is published and stops being reported as small |
| `addons/local_agents/sim/material/sphere_passes/GravityPass.gd` | `RESIDUAL_TOLERANCE` | 1.0e-4 | how well every solve must satisfy the discrete Poisson equation, as a fraction of its own source, before any walk reads `down` | a direct solve, which has no residual to tolerate |
| `addons/local_agents/sim/material/sphere_passes/GravityPass.gd` | `MAX_ITERATIONS` | 4000 | conjugate-gradient iterations one solve may take before it reports that it did not converge | a direct solve, which has no iteration to cap |
| `addons/local_agents/sim/material/kernels3d/neighbours.glsli` | `N_SLOTS` | 6 | faces of a cube; it is geometry, not a choice | never — a box has six faces |
| `addons/local_agents/sim/material/kernels3d/generated.glsli` | `EXP_LIMIT` | 60.0 | generated from ReactionThermo.EXP_LIMIT; the exponent bound where exp() overflows float32 | deleted with its source row |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `GEN_RAY_COARSE` | 32.0 | first sweep of the same search, metres. Brackets the crossing over the whole relief band before the metre and centimetre passes refine it; a DISCRETISATION | an analytic surface intersection, which needs no sweep at all |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `GEN_RAY_STRIDE` | 1.0 | march step for the SDF surface search, metres. A DISCRETISATION, not a property of the ground | an analytic surface intersection, at which point there is no step to choose |
| `addons/local_agents/sim/terrain/VoxelTerrainService.gd` | `GEN_RAY_REFINE` | 0.05 | bisection tolerance for the same search, metres. Sets how precisely the surface is located, nothing physical | as above |
| `addons/local_agents/sim/material/MaterialFieldSphereStep3D.gd` | `SIM_SECONDS_PER_STEP` | 43.2 | the coarsest temporal level, a DECISION about the clock quantum; every cell's own dt is picked from its CFL by LATemporalLevels below it | nothing: the CFL choice its deletion condition asked for already lives in the levels |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `ICE_FREE_LAND_AREA_M2` | 1.30e14 | EARTH's ice-free land area, used to scale a global biological flux down to a per-area rate. Measured for Earth, but this planet is not Earth and its own land area is emergent | measure the planet's own ice-free land from the field and scale by that |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `PG_TO_KG` | 1.0e12 | exact unit conversion, petagrams to kilograms. A definition, not a parameter | nothing; it is exact by definition of the SI prefix |
| `addons/local_agents/sim/material/reactions/BioRecords.gd` | `MICROBIAL_CUE` | 0.3 | microbial carbon-use efficiency: the share of consumed carbon that becomes biomass rather than CO2. A measured aggregate over communities that differ, applied as one number to every decomposer | a CUE that follows from the decomposer's own energetics and the substrate quality it is eating |
| `addons/local_agents/sim/material/kernels3d/cellvol.glsli` | `LA_FLOAT_EPS` | 1.1920929e-7 | float32's own epsilon: a band whose volume is below this share of its cube has a top no float32 depth can tell from its ground, so it is no band; a fact about the machine word, not about matter | a wider float, or a band solved in the cube's own integer depth |
| `addons/local_agents/sim/material/kernels3d/band.glsli` | `LA_BAND_EPS` | 1.0e-4 | the share of the vertical below which a cube axis counts as parallel to the free surface and the band integral drops that dimension; a DISCRETISATION guard on a formula that divides by that share, not a property of matter | an integral written in the form that is finite at zero, which needs no branch |
| `addons/local_agents/sim/material/sphere_passes/ActiveCells.gd` | `QUIET_SUBSTEPS` | 2 | substeps a crossing is remembered: the one it landed on and the next, because the counter ages before the rows run; structural, not a dial | a wake that carries the arrival itself rather than a counter, at which point there is no window to size |
