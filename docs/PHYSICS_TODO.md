# PHYSICS TODO — the one list

**This is the only list of physics work that is left.** Work comes from here, and anything found goes in
here. An item leaves this file when it is implemented and verified, never when it is worked around.

**A departure from real physics may not be added to close an item.** If an item cannot be done correctly,
it stays open and the maintainer is asked. See `CLAUDE.md`.

Each item says what is WRONG, and what would DECIDE it. No status columns, no priorities that rot — the
order is the order.

---

## Regressions the build watches for

`scripts/check_doc_claims.sh` evaluates each directive below on every run, so a deletion that comes back
fails the build instead of waiting for a reader to notice it. Add one when a deletion must stay deleted;
delete one when its subject stops being a rule.

The Cartesian box is the only grid — no seam graph, no tangent basis, no radial shell stack:

<!-- claim: nofile addons/local_agents/sim/sphere -->
<!-- claim: absent link_partner addons/local_agents/sim -->

The grid is metres and gravity is solved — no fitted model unit, no held surface gravity:

<!-- claim: absent METRES_PER_MODEL_UNIT addons/local_agents/sim addons/local_agents/game -->
<!-- claim: absent PLANET_SCALE addons/local_agents/sim addons/local_agents/game -->
<!-- claim: absent SURFACE_G addons/local_agents/sim addons/local_agents/game -->

## A. The phase curve

- [x] **Dissociation and ionisation exist** — Saha for ionisation (per element, closed form), law of mass
      action for dissociation (ΔG = ΔH − TΔS, bisected extent). No onset constants. Verified: H₂O 11%
      dissociated at 4000 K, 99% at 6000 K; 2% ionised at 10 000 K, 98% at 25 000 K.
- [ ] **The GPU cannot evaluate the high rungs.** `kernels3d/enthalpy.glsli` stops at gas because inverting
      the equilibria needs bisection — too costly per cell per step. **Decide it:** a precomputed EOS table
      (specific enthalpy × pressure → temperature, phase, fractions), generated from `LASubstances` and
      uploaded, with a gate that the table reproduces the functions to tolerance. This is what real EOS
      codes do; it keeps the GPU cost O(1) per cell.
- [x] **Sublimation, the triple point, Clapeyron melting and supercritical** — all four land together.
      `triple_t_c` / `triple_p_pa` (IAPWS) are in the table; below the triple pressure the ladder has NO
      liquid branch and the plateau it crosses is sublimation, verified at 300 Pa: 93% through the plateau
      at h = 3.2e6, gas at 3.5e6, never passing through liquid. `melt_c_at` is Clausius–Clapeyron on the
      solid–liquid boundary, `dT/dP = T Δv / ΔH_fus` with `Δv = 1/ρ_liquid − 1/ρ_solid` straight out of the
      table — no new constant, and it comes out NEGATIVE for water at −0.0072 K/bar against the measured
      −0.0074, so a glacier melts under its own load. `sublimation_p_at` is Clausius–Clapeyron anchored on
      the triple point with the DERIVED sublimation enthalpy: 12.9 Pa at −40 °C against the measured 12.85.
      Supercritical is its own phase rather than a mislabelled gas.
- [ ] **Freezing-point depression is implemented but not wired — and cannot be, because there is no
  dissolved phase at all.** `molality` is 0 at every call site, no salt substance exists, and
  `salinity_at` returns a 0..1 number with no mass behind it. Original text: `melt_c_at` takes a molality and derives
      the cryoscopic constant rather than tabulating it — `K_f = R T_f² M / ΔH_fus,molar` gives 1.859 K·kg/mol
      against the measured 1.86. Two things stop it being live: (a) **there is no salinity channel**, so
      nothing can say which cells are sea and which are rain, and applying it globally would freeze lakes at
      −2 °C too; (b) the van 't Hoff law is IDEAL, and real sea water's ions have activity coefficients below
      1, so 1.16 mol/kg gives −2.16 °C against the measured −1.86. **Decide it:** add a salinity channel, and
      either accept the ideal law's ~15% or carry an osmotic coefficient.
- [ ] **Density is rho(T, p) on the CPU only, and water has no 4 °C maximum.**
      `LASubstances.density(id, t_c, p_pa)` gives a gas the ideal gas law and a condensed phase a linear
      expansivity with a bulk modulus, all cited. Three gaps: (a) `kernels3d/enthalpy.glsli` has no twin, so
      every kernel still multiplies by a scalar; (b) a LINEAR expansivity cannot produce water's density
      maximum near 4 °C, which is why deep water sits at 4 °C and why a lake freezes from the top — Kell
      1975, J. Chem. Eng. Data 20:97, is the measured relation and it needs a second EOS shape in the table;
      (c) `carbonate` has an expansivity and no bulk modulus, and `cellulose` has neither.
- [ ] **Molten silicate weighs the same as solid silicate, so magma buoyancy is only thermal.** The table
      gives `silicate` ONE density for crystals and melt, so the fusion volume change — the larger half of
      why a melt rises — is absent; only thermal expansion is left. Adding `density_solid` for silicate also
      moves `melt_c_at`'s Clapeyron slope off zero, which is real (decompression melting) and which
      `enthalpy.glsli` must move with or the two phase curves are no longer one curve.
- [ ] **`o2` and `co2` carry no phase boundaries, so nothing can say they are gases.** `density()` falls
      back to their declared reference for want of a boiling point, triple point and critical point, all of
      which `n2` and `h2o` already carry. Adding them changes those substances' phase ladder, so the GLSL
      twin moves at the same time.
- [x] **The `moisture` channel holds vapour and is priced as a condensed phase.** Gone with the h2o
  collapse: there is one h2o amount and the vapour share is derived from the saturation split.
- [ ] **The momentum ledger's atmosphere weighs the same at every altitude.** `LAMaterialFieldMomentumLedger3D`
      makes cell mass `air * AIR_DENSITY_KG_M3 * V`, a fixed ISA sea-level conversion, and its buoyancy leg is
      the ideal-gas Boussinesq `a = g dT/T` gated on `d_t > 0.0`, so cold air never sinks. Both need the `air`
      channel's unit, which is defined in the wind kernels.
- [ ] **Solid polymorphs** — ice I…VII, and olivine → wadsleyite → perovskite with depth. A planet's mantle
      structure IS these transitions, each with its own enthalpy and density jump. Maintainer asked for the
      structure to be built.
- [ ] **Glass vs crystalline.** Quenched basalt releases different heat than slow-cooled; `latent_rock` is
      one number.
- [ ] **Metastability** — supercooled water, superheated liquid. Real, and arguably beyond this granularity.

## B. The substrate's state

- [x] **FREE OXYGEN IS NO LONGER HANDED TO THE PLANET.** `O2_AMBIENT` was 1.0 in every open cell — Earth's
      MODERN mole fraction — which asserts two billion years of photosynthesis before frame 1. Free O2 is
      the textbook biosignature: it exists only because life made it. It seeds at zero now and has to be
      earned. `world_seed` reads `o2: 0.0`, which is one entry of the six retired.
      `CO2_AMBIENT` was defined as a RATIO TO O2, so zeroing oxygen would have silently taken the carbon
      with it; it keeps its value (volcanic, not biological) and no longer derives from O2.

- [ ] **AND IT IMMEDIATELY EXPOSED THAT NOTHING PRODUCES OXYGEN.** With the seed gone, `o2_total` reads
      **0.0** — not "less", none. The seeded value was masking whether the source works at all, which is
      the whole reason an input that should be an output is dangerous. `--planet-only` legitimately has no
      vegetation, so the arm that decides this is a run WITH flora; that measurement is owed.
      Also open: whether the biosphere can bootstrap at all from zero, since respiration and combustion
      CONSUME O2 and photosynthesis is the only source.


- [x] **The field stores ENERGY.** `h_j_m3` is the state; temperature, phase, pressure, velocity,
  conductivity and the gas/condensed split are derived per step by `StateDerivePass` and live in
  `LAChannels.derived_buffers()`. Latent heat is structural, so no kernel can skip a phase boundary.
  `water`/`moisture`/`snow`/`soil` collapsed into one `h2o`, and the freeze/melt/evaporate/sublimate/
  deposit records deleted themselves with their rate constants.

- [ ] **Conserve elements, derive species.** The runtime state is channel amounts, so the inventory
      RECONSTRUCTS moles (`mol_per_unit`) — which is how a carbon gauge once read +1261% when the truth was
      negative. If the conserved state were moles of element per cell, no kernel could change total carbon,
      because no kernel would write it.
- [ ] **Organic matter is one lumped CH₂O.** Which is why ignition is a single number and a planet that
      demonstrably buries organics cannot have peat, coal or oil. Make it a C:H:O ratio plus a recalcitrance
      so burial → coalification is a continuous drift, not a new channel per fuel.

## C. The reaction engine

- [ ] **Direction is a hand-set threshold, not thermodynamics.** Whether a reaction may proceed is a gate
      mask plus a threshold constant. Metamorphic decarbonation (D1c) needs 280.7 °C, the hottest cell
      reaches ~256 °C, so the carbonate sink is permanently one-way and CO₂ declines forever. With ΔG(T,P)
      the direction falls out of state and reactions run both ways near equilibrium. **Standard entropies
      now exist** for H₂O, O₂, CO₂ and the four atomic species, so this is unblocked for those.
- [ ] **Extents are applied one record at a time**, capped per channel, so several records competing for one
      reactant interact through application order — which is what the `cap_channel` field patches around.
      Evaluate every record against the same starting state, then one scaling if a reactant would go
      negative. Order-independence for free and `cap` deletes itself.
- [ ] **The reaction table carries two rate units.** Evaporation, photosynthesis, respiration, litterfall
      and decomposition fold `real_seconds_per_step()` into their own `k` and are per-real-second; the rest
      are flat per-step numbers, neither derived nor scaled by the clock. Multiplying by `dt` in the kernel
      would double-count the first group, which is why the dead `dt` upload was deleted rather than wired.
      Resolves with B1: enthalpy makes a phase plateau energy-limited, so the relaxation constants delete.

- [ ] **Three condition gates are used by no record** — `GATE_SURFACE`, `GATE_OPEN_ABOVE`, `GATE_DAYLIGHT`.
      `GATE_DAYLIGHT` is genuinely redundant (photosynthesis takes light as its rate driver). The other two
      are live machinery nothing calls: wire them in or delete them.

## Weathering has lost both its mechanisms

- [ ] **Frost shattering does not exist.** `LAGeoRecords` carries no `RM_DEFICIT_BELOW_THRESHOLD` record,
      no `FROST_*` constant survives anywhere in `sim/`, and `RM_DEFICIT_BELOW_THRESHOLD` is declared in
      `ReactionDefs` and handled in `reactions_sphere3d.glsl` for no record at all. Ice expansion is a
      first-order weathering mechanism on a planet with a freezing point. Most of what it needs is already
      here or citable: the 8.8% expansion is `WATER_DENSITY_KG_M3` against `ICE_DENSITY_KG_M3`, and a rock
      tensile strength is a measured property `Substances.gd` can carry with its source. What is a
      maintainer's call is the DAMAGE MODEL — how pore-ice pressure past that strength becomes a volume of
      rock detached per step. The substrate derives the frozen share structurally as `h2o_solid`, so a
      rebuilt record reads that rather than a freeze rate.
- [ ] **`tests/test_weathering_rate_law.gd` reads zero bedrock removed at every temperature, and the record
      is not the reason.** The dissolution record carries `rate_k` 2.0e-5, `threshold` 7216.34 (Ea/R off the
      cited 60 kJ/mol), `param2` 298.15 and a `BEDROCK_BELOW` reactant, so the arithmetic has non-zero
      inputs at every temperature the test sweeps. Nothing here is missing a constant. **The test evaluates
      the rate with a HAND COPY of the kernel's arithmetic — a second model of the reaction engine — and
      that copy is where the zero comes from.** Have it read the record through the real evaluator, then
      re-ask whether the rate is right.

## D. Transport and geometry

- [x] **The reverse link is arithmetic again, and now it is the RIGHT arithmetic.** `LAVoxelGrid` orders
      the six axis tags so the reverse of `d` is `d ^ 1`, and `link_partner` — a searched table that existed
      because a cubed-sphere seam could bend a link — is deleted with the seam. `check_neighbour_slots.sh`
      holds `neighbours.glsli` equal to `LAVoxelGrid`: same slot count, same reverse function.
- [ ] **The four gathers are still four kernels.** `gravity_flow`, `soil`, `erosion_transport` and
      `plate_advect` remain separate with different flow rules. The bug CLASS is now closed by the table
      above, so this is de-duplication rather than correctness — worth doing, no longer urgent.
- [ ] **Loose mineral may not be moving.** `silicate_bed` / `silicate_susp_water` are the derived shares
      that replaced the deleted `sediment_total` gauge. **Reproduce:** `scripts/agent_harness.sh sim
      --frames 200` and read whether either share is ever non-zero away from a slump.
- [ ] **Two mass transfers still move temperature without moving heat**: the regolith→regolith Darcy leg
      (`soil_sphere3d.glsl:51`) and sediment slump.
- [ ] **The grid cannot resolve its own aquifer.** Four regolith cells span 10.8 km against the 2 km
      `GROUNDWATER_CIRCULATION_M` describes. Non-uniform radial spacing is the physically correct fix —
      fine near the surface, coarse aloft and at depth — and `cell_size` becomes per-shell.

## E. Conservation, open

- [x] **The airborne runaway is CLOSED, and it was two layouts for one table.** The cubed-sphere grid had a
      `neighbours_kernel_order()` that uploaded a PERMUTED copy of the neighbour table to the GPU — the
      pre-SSOT layout, `below, lateral x4, above` — while `link_partner` was uploaded in the real order. So
      every kernel asking for "the cell above" got a lateral, and the two tables disagreed with EACH OTHER.
      For a link-exchange gather that is fatal: the receiver computed its gain from a different link than
      the sender debited, and a linear operator applied to its own output compounds the surplus ~2.4x per
      step once the wind spins up around step 12. Deleted; there is one layout, and
      `check_neighbour_slots.sh` check 3 now fails the build if the SSBO comes from anything but
      `.neighbours` (mutation-tested both ways).

      `o2` 2.29e15 -> **35 446** · `moisture` 4.47e9 -> **0.215** · `h2o` 2.23e8 -> **5 299** ·
      `conservation_failed` **False**.

      **The lesson is about the TEST, not the kernel.** The kernel harness uploaded `_grid.neighbours`
      directly — the correct order — so it was testing the kernel against a table the sim never sent it, and
      reported clean while the sim exploded. A harness that builds its own inputs proves the kernel correct
      and says nothing about the system.

- [ ] **THE DRIFT READOUT IS BLIND, and that is a gate that always passes.** Every ledger latches its
      `*_first` baseline on the first heavy REPORT after the seal, not at the seal. Heavy reports run on the
      64-frame gauge cadence, so a run shorter than 64 frames takes its baseline at the CLOSING sample and
      the `--- drift vs sealed baseline ---` block reads `+0.000%` no matter what happened — `o2` halved
      from 69 120 to 35 446 over 60 frames and the drift line read zero. Even at 600 frames the baseline is
      latched ~step 64 rather than at the seal (step 2). **Fix:** the ledgers must sample AT the seal, which
      is what LAMaterialFieldSeal3D was built for and what its own note claims already happens.

- [ ] **`o2` falls by half over 60 frames, and it is now entirely CHEMISTRY.** With transport conservative,
      `LA_PASS_PROBE=o2` shows GasWindPass exactly flat every step and ReactionsPass removing ~25/step,
      accelerating. Respiration and decomposition consume O2; photosynthesis is its only source. Belongs
      with the dG work in section C.

- [x] **~~The atmosphere is leaking~~ — THE CLAIM WAS AN INSTRUMENT ARTIFACT, AND THE REAL DEFECT WAS
      INVISIBLE TO IT.** *(Struck 2026-08-12.)* This said `air` declines 9220 to 5730 over 25 steps, about
      1.5% per step, measured with `LA_PASS_PROBE=air`. **It does not reproduce.** Before any fix the probe
      read 9573.176 to 9573.183 over 40 steps — flat to seven figures. And it could never have shown the
      defect: `LA_PASS_PROBE` sums BARE FILL FRACTIONS, which a kernel moving fill fractions conserves by
      construction. The quantity that was genuinely not conserved is the volume-weighted total, and no probe
      in the tree measured it. There WAS a real air defect — `wind_pressure_sphere3d.glsl` moved raw
      fractions between cells of different volume and re-settled each column conserving the sum of fractions
      rather than the mass — and it is fixed and gated (`wind_air`, mutation-tested on three grids). A third
      defect was found beside it: the exchange was asymmetric, donating across any face whose far cell was
      non-solid while only gathering within its own column's atmosphere, so a cell under a rock overhang was
      a one-way sink.

- [ ] **The wind is supersonic**, against a real jet stream of ~70 m/s. `MAX_WIND` was deleted on purpose,
      because a wind speed is an output and not a thing to clamp. **Reproduce:** `scripts/agent_harness.sh
      sim --frames 200` and read the peak speed off the `speed` derived channel.

- [ ] **`o2_total` and `oxidant_all`** are the largest remaining drifts, newly visible now that the
      air-above gates select the right cells.
- [ ] **`mineral_total`** still trips the conservation gate. The per-pass mineral probe localises it to
      `water_slump_lava`; every other leg reads exactly 0.0.
- [ ] **No per-pass attribution for ELEMENTS.** Mineral and energy each have a probe, and each named its
      culprit in a single run. Carbon, oxygen and water have only global totals, which say a number moved
      and never where.
- [ ] **The planet's thermal enthalpy sum is NON-FINITE, so energy is UNMEASURED rather than conserved.**
      The `h_j_m3` reduce row drains a value that is not a number, so `energy_residual_rel` cannot be formed
      and the conservation gate refuses the row. Decided by that row's sum reading finite.
- [ ] **`o2_first` latches at zero, so the o2 row has no scale to be a fraction of.** A baseline of zero is
      not a baseline; the row reads UNMEASURED. Decided by the o2 baseline latching after the channel is live.

## F. Prescribed where it should emerge

- [ ] **No mantle convection.** The rock's own radiogenic decay is now the only interior heat source and the
      geotherm is whatever it, conduction and the surface produce — but nothing carries that heat by MOVING
      rock, so the plates above are kinematic rather than driven.
- [ ] **`ThermalPass` still pushes a `core_boundary_c` nobody writes.** Its `ctx.get(..., 0.0)` fallback
      would put a 0 °C ghost cell under the deepest rock — a heat SINK — the moment `heat_sphere3d.glsl`
      returns. The base of the grid has no boundary condition to invent: delete the push constant.
- [ ] **There are no plates.** `PlateTectonics.gd` was deleted: its Voronoi was spherical geometry on a
      Cartesian grid, its substrate coupling (`PlateAdvectPass`) was already gone, and all it still did was
      roll dice into a disaster spawner. The maintainer's standing OK to FAKE plate kinematics only ever
      covered kinematics that DRIVE the substrate; nothing does. Melt must come from crustal thinning and
      the geotherm.
- [ ] **Rock has three compositions and no stratigraphy.** Carbonate and silica do not travel and do not
      lithify, so there is no limestone and no sandstone.
- [ ] **The field's `dt` is the presentation clock.** One rotation is now stated once
      (`LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S`) and the compression once
      (`LASimClock.REAL_SECONDS_PER_SIM_SECOND`), but `real_seconds_per_step()` is still
      `STEP_DT * compression`, so how fast the player watches sets every transport kernel's timestep. A
      substep budget separates them.
- [ ] **The planet is pinned at the world origin** and the star orbits it. A deliberate moving-frame choice;
      making it literal is the 0.6 headline.

## The biosphere has never run (found 2026-08-11, one run, seed 4242, 200 frames, `--full`)

- [ ] **Nothing can fix nitrogen, so photosynthesis has never once fired.** `fert_total` /
      `fert_all` / `fert_first` are all 0.0. Photosynthesis (`reactions/BioRecords.gd:119`) takes FERT as a
      REACTANT, so its rate is zero by the limiting reagent. Every FERT source in the tree is downstream of
      organic matter that must already exist — fungal decomposition of detritus (`:112`), respiration of
      biomass (`:125`), combustion of fuel (`CombustionRecords.gd:46`). There is no abiotic entry point, so
      the nutrient loop cannot start on a sterile planet. `photo_ground_cells` (4835) counts cells where the
      GATE passes, not where the reaction runs, and reading it as evidence of photosynthesis is what let this
      stand. It was invisible while `MaterialField3D` seeded 1.0 O2 into every open cell; deleting that seed
      is what exposed it.
- [ ] **The atmosphere has no nitrogen at all.** Real dry air is 78.08% N2 by mole and `Substances.gd` has no
      N2 entry — the most abundant component of the atmosphere is absent. Lightning fires
      (`phenomena_kinds` carries `lightning`) and fixes nothing.
- [ ] **Detritus cannot rot.** 612.34 carbon sits in 4574 detritus cells while `fungus_cells` is 1 of 69120,
      and decomposition is RM_BILINEAR in fungus x detritus, so the only live FERT source is off everywhere but
      one cell. Carbon is stranded, not cycling.
- [ ] **`fuel_seeded` is 216.0** — fuel is an input where it should be a product of vegetation.
- [ ] **`lava_phase_sphere3d.glsl` reads and writes one buffer.** It writes `temp[g]` while reading
      `temp[nb]` from the same binding, so a cell sees a mixture of pre- and post-step neighbour values
      according to GPU scheduling. It is the only kernel left doing this (surveyed, 2026-08-11). Its input
      order is also scrambled by the `atomicAdd` compaction in `cell_list_lava_sphere3d.glsl:63,69`, which is
      why two identical runs still differ in the last digits after the RNG was sealed. Needs the same
      ping-pong PAIR treatment every other transport kernel already has.

## Lightning is structurally dead, so the abiotic nitrogen source has no trigger (2026-08-11)

The N2 substance, the atmospheric seed and the lightning fixation record all exist and are verified working
(stamping `discharge = 1.0` for one run drives `fert_total` off zero and the element balance holds). What
does not work is the trigger.

- [x] **The charge channel has real units.** It is a charge DENSITY in C/m^3. The gain is the
      non-inductive graupel/ice rate saturated against updraft, cloud liquid water content and the
      -10/-25 C riming band; the leak is ohmic relaxation, `tau = eps0 / sigma`, with in-cloud and
      clear-air conductivities rather than two invented bleed fractions. Initiation is Gauss's law on the
      radial column, `E = sigma / eps0`, against the relativistic runaway threshold
      `2.84e5 V/m * rho_air / rho_sea` (Dwyer 2003), with air density from the ideal gas law on the
      pressure and temperature the field already carries — so the threshold falls with altitude for free
      and conventional 3 MV/m breakdown, which a storm never reaches, is not what is tested.
      `BREAKDOWN`, `RESIDUAL_AFTER_BOLT`, `J_PER_CHARGE`, `MAX_BOLTS_PER_STEP`, `PROBE_STRIDE`,
      `PROBE_GATE` and `FULL_SCAN_EVERY` are all deleted: the per-step bolt cap was a band-aid, and the
      strided probe was a sampling heuristic that the exact column integral replaces at the same cost.
      The energy a flash releases is now the electrostatic energy it destroys, `0.5 * eps0 * E^2` over the
      volume it neutralises, so the heat it hands the temperature field is paid for by a store.
      The `DISCHARGE` reaction driver is J/m^3 and the fixation constant is `LIGHTNING_N_FIXED_MOL_PER_J`
      with no cell volume in it.
- [x] **Impact ionisation is DELETED, not fixed.** `Meteor.gd` injected `min(4 + size*2.5, 9.0)` charge in
      units that meant nothing, for a mechanism nobody derived. Impact and volcanic plumes DO electrify —
      it is triboelectric and fractoemission charging of ash — but no coulomb figure for it was derivable
      here, and inventing one dressed as physics is worse than its absence. **What it wants:** the `dust`
      channel already carries the ash, so plume charging belongs as a general rule on dust concentration
      and velocity shear, which would give volcanic lightning the same way. That is real work, not a
      constant.
- [x] **`MaterialFieldInject3D.add_heat_energy` no longer creates energy by 4.8e6.** Fixed in `e0ea4717`
      along with four other sites where a MODEL-unit length met a per-m^3 or per-m^2 constant.
      `scripts/check_model_unit_volume.sh` gates the class.
- [ ] **No lightning rate can bootstrap a biosphere inside a 200-frame run, and none should be made to.**
      One flash fixes ~250 mol N (Schumann & Huntrieser 2007), and 5 Tg N/yr against a ~125 Pg N soil pool
      is 4e-5 per year — the same 25 000-year timescale it has on Earth. Either the fast-forward time scale
      carries it, or an initial soil-N stock is declared as a genuine initial condition of a 4.5-Gyr-old
      planet by the same argument that justifies seeding N2. **That is the maintainer's call and is not
      taken here.**

## The planet has no cold, and the headline water total is masked (found 2026-08-12)

- [x] **The atmosphere had no lapse rate, so nowhere on the planet was below 5.4 C.**
      `heat3d_buoyancy_sphere3d.glsl` moved heat up whenever a cell was warmer than the one above it, with a
      hand-picked `BUOYANCY = 0.18` and no reference to pressure or gravity. That drives a column
      ISOTHERMAL. Real convection drives it to the ADIABAT: a parcel rising by dz expands against falling
      pressure and cools by gamma*dz, so a lapse shallower than gamma is already stable. Measured before the
      fix, 200 frames seed 4242 `--full`: `temp_min` 5.42 C — the coldest cell at any altitude, any latitude,
      night side included — against `temp_ground_p50` 16.4. grep found no lapse rate, no adiabatic term and
      no potential temperature anywhere in the live substrate; the only one in the tree was synthesised
      inside a bench that built its own atmosphere. It is dry convective adjustment (Manabe & Strickler 1964)
      now, one thread per radial column, sweeping upward and mixing each superadiabatic pair to neutral at
      constant enthalpy. `BUOYANCY` is DELETED and nothing replaced it: the pair solve
      `q = ((T_lo - T_hi) - gamma*dz) / (1/C_lo + 1/C_hi)` has no free rate. `gamma` is derived per cell as
      `f_air * rho_air * g / rc_cell`, which is exactly `g/c_p` for a cell of pure air and ~0 for one full of
      water or rock — the stated approximation, because a condensed phase's adiabat needs a thermal
      expansion coefficient the substance table does not carry (real error in sea water: 0.15 K/km).
      After: `temp_min` -18.7 C. The -10/-25 C graupel riming band is reachable for the first time.

- [ ] **`h2o_total` and the H2O budget probe are two totals for one substance and they disagree by 23%.**
      One run, 200 frames, seed 4242, `--full`. `LA_H2O_BUDGET` closes with `residual_all` exactly 0.0 on
      every sample and reports total H2O flat at 3.0488e14 from step 1 to step 257 — water moved out of
      `water` (1.891e14 -> 1.661e14) and into `soil` (1.158e14 -> 1.388e14), which is infiltration, not
      loss. `SIM_REPORT`'s `h2o_total` reads 2.341e14 and its drift line reads -22.6%. The parts line up
      except one: the probe's water is 1.661e14 and the ledger's `water_total()` is 9.451e13.
      `LAMaterialFieldLedger3D.water_total()` and `snow_total()` pass `mask_open = true` while
      `soil_total()` passes false, so the planet's headline conservation number counts liquid water only
      where `solid == 0`. **Burial is not loss** — the same defect already found on `fuel_total`, on the
      substance the conservation gate is built around. Until it is fixed, no h2o drift figure means
      anything, including every one recorded today.

## G. Never ran at all — found 2026-08-12, each had silently disabled a subsystem

Every one of these was invisible: the file existed, compiled, and passed every gate that named it.

- [x] **`pressure.glsl` was dispatched by nobody.** No pass, no entry in `PASS_SCRIPTS`. The buffer held
  zero, so every phase boundary was evaluated at vacuum.
- [x] **The reaction engine bound a `radial` buffer nothing created**, so its uniform set was invalid and
  every reaction record in the tree was dead.
- [x] **`porosity` was written by nothing**, so Kozeny-Carman over phi = 0 meant groundwater never moved.
- [x] **`MODE_CONDUCT` named a `conductivity` buffer nobody created**, so heat never conducted.
- [x] **The momentum rows named `mom_x/y/z` and the channel table declared `vel_x/y/z`**, so every
  momentum row push_errored out and the momentum equation never ran.
- [x] **Coriolis was booked by a ledger and never applied.**
- [x] **`pinned` never fired on the GPU** — a phase boundary compared for float equality contracted
  differently at each call site in float32.
- [ ] **What else is declared and never dispatched?** Six of these in one day is a class, not a
  coincidence. A gate that fails when a kernel has no pass, or a buffer no writer, would have caught all
  six the day each landed.
