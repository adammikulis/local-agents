# PHYSICS TODO — the one list

**This is the only list of physics work that is left.** Work comes from here, and anything found goes in
here. An item leaves this file when it is implemented and verified, never when it is worked around.

**A departure from real physics may not be added to close an item.** If an item cannot be done correctly,
it stays open and the maintainer is asked. See `CLAUDE.md`.

Each item says what is WRONG, and what would DECIDE it. No status columns, no priorities that rot — the
order is the order.

---

## The referent

**A post-Theia Earth, just formed, ~4.5 Ga.** Read every item against that world.

Free O2 at zero is correct. There is no photosynthesis, no biological nitrogen fixation, no soil, no litter
and no biosphere — a biosphere is 0.5 work. Radiogenic abundances belong at formation, not today. An item is
open here only if it is wrong for a lifeless planet of that age.

## Regressions the build watches for

`scripts/check_doc_claims.sh` evaluates each directive below on every run, so a deletion that comes back
fails the build instead of waiting for a reader to notice it. Add one when a deletion must stay deleted;
delete one when its subject stops being a rule. The same gate checks every file path this file cites in
backticks, with no directive needed — a path that is meant to be absent is declared `nofile`.

The Cartesian box is the only grid — no seam graph, no tangent basis, no radial shell stack:

<!-- claim: nofile addons/local_agents/sim/sphere -->
<!-- claim: absent link_partner addons/local_agents/sim -->

The grid is metres and gravity is solved — no fitted model unit, no held surface gravity:

<!-- claim: absent METRES_PER_MODEL_UNIT addons/local_agents/sim addons/local_agents/game -->
<!-- claim: absent PLANET_SCALE addons/local_agents/sim addons/local_agents/game -->
<!-- claim: absent SURFACE_G addons/local_agents/sim addons/local_agents/game -->

## A. The phase curve

- [ ] **The GPU cannot evaluate the high rungs.** `kernels3d/enthalpy.glsli` stops at gas because inverting
      the equilibria needs bisection — too costly per cell per step. **Decide it:** a precomputed EOS table
      (specific enthalpy × pressure → temperature, phase, fractions), generated from `LASubstances` and
      uploaded, with a gate that the table reproduces the functions to tolerance. This is what real EOS
      codes do; it keeps the GPU cost O(1) per cell.
- [ ] **Freezing-point depression is implemented and cannot be wired, because there is no dissolved phase.**
      `LASubstances.melt_c_at` takes a molality; every call site passes 0, no salt substance exists, and
      `salinity_at` returns a 0..1 number with no mass behind it. **Decide it:** add a salinity channel with
      a real dissolved mass, and either accept the ideal van 't Hoff law or carry an osmotic coefficient —
      ideal gives −2.16 °C for sea water against the measured −1.86.
- [ ] **Density is rho(T, p) on the CPU only, and water has no 4 °C maximum.** `LASubstances.density` gives
      a gas the ideal gas law and a condensed phase a linear expansivity with a bulk modulus, all cited.
      Three gaps: `kernels3d/enthalpy.glsli` has no twin, so every kernel still multiplies by a scalar; a
      LINEAR expansivity cannot produce the density maximum near 4 °C, which is why deep water sits at 4 °C
      and a lake freezes from the top (Kell 1975, J. Chem. Eng. Data 20:97); `carbonate` has an expansivity
      and no bulk modulus, and `cellulose` has neither.
- [ ] **Molten silicate weighs the same as solid silicate, so magma buoyancy is only thermal.** Only `h2o`
      carries `density_solid`, so silicate's fusion volume change — the larger half of why a melt rises — is
      absent. Adding it also moves `melt_c_at`'s Clapeyron slope off zero, which is real (decompression
      melting) and which `enthalpy.glsli` must move with, or the two phase curves are no longer one curve.
- [ ] **`o2` and `co2` carry no phase boundaries, so nothing can say they are gases.** `density()` falls
      back to their declared reference for want of a boiling point, triple point and critical point, all of
      which `n2` and `h2o` already carry. Adding them changes those substances' phase ladder, so the GLSL
      twin moves at the same time.
- [ ] **The momentum ledger's atmosphere weighs the same at every altitude.** `LAMaterialFieldMomentumLedger3D`
      makes cell mass `air * AIR_DENSITY_KG_M3 * V`, a fixed ISA sea-level conversion, and its buoyancy leg is
      the ideal-gas Boussinesq `a = g dT/T` gated on `d_t > 0.0`, so cold air never sinks.
- [ ] **Solid polymorphs** — ice I…VII, and olivine → wadsleyite → perovskite with depth. A planet's mantle
      structure IS these transitions, each with its own enthalpy and density jump. Maintainer asked for the
      structure to be built.
- [ ] **Glass vs crystalline.** Quenched basalt releases different heat than slow-cooled; `latent_rock` is
      one number.
- [ ] **Metastability** — supercooled water, superheated liquid. Real, and arguably beyond this granularity.

## B. The substrate's state

- [ ] **The seed lays organic matter on a lifeless planet.** `MaterialSurfaceSeed3D` writes a baseline of
      `fuel` and `detritus` onto every surface cell, and refills fuel from biomass on a cadence. A
      just-formed Earth has no litter and no dead plant pool: this is carbon created for a biosphere that
      does not exist, and it is what a fire then burns. Delete the seed; the pools become products or they
      stay empty.
- [ ] **Free O2 is zero and must stay zero, and no gauge proves it.** `O2_AMBIENT` is 0.0 and the only
      source in the reaction table is photosynthesis, which is 0.5 work — so on this planet any non-zero
      `o2` is matter created from nothing. The gauge that decides it is a per-element oxygen attribution,
      not a total (see E).
- [ ] **Conserve elements, derive species.** The runtime state is channel amounts, so the inventory
      RECONSTRUCTS moles (`mol_per_unit`). If the conserved state were moles of element per cell, no kernel
      could change total carbon, because no kernel would write it.
- [ ] **Organic matter is one lumped CH₂O.** Which is why ignition is a single number and a planet that
      demonstrably buries organics cannot have peat, coal or oil. Make it a C:H:O ratio plus a recalcitrance
      so burial → coalification is a continuous drift, not a new channel per fuel.

## C. The reaction engine

- [ ] **Direction is a hand-set threshold for every record but one.** `LAReactionThermo.reversible` derives
      dG = dH − T dS + RT ln Q from the record's own stoichiometry, and only the dissolution record in
      `GeoRecords.gd` uses it. Everything else is a gate mask plus a threshold constant, so it is
      permanently one-way. Standard entropies exist for H₂O, O₂, CO₂ and the four atomic species, so every
      record whose participants are in that set is unblocked today.
- [ ] **Organic oxidation books no reaction heat unless it is called combustion.** `CombustionRecords.gd`
      prices its heat per element from `LASubstances.organic_energy_j_mol`; decomposition and respiration in
      `BioRecords.gd` oxidise the same organic matter to the same products and pass no `enthalpy_j_m3` at
      all. There is no thermodynamic path by which one reaction is exothermic when fast and athermal when
      slow. **Decide it:** run every organic-oxidation record through the same element accounting, so one
      set of enthalpies prices all of them.
- [ ] **Decay has no temperature dependence and production has an optimum.** Decomposition and respiration
      are `RM_BILINEAR` in their two reactants, so litter rots at the same rate at −40 °C and +40 °C, wet or
      bone dry, while photosynthesis carries `RM_OPTIMUM_BAND`. Michaelis–Menten and a Q₁₀ (or the
      Arrhenius the engine already has) are what the two uptake reactions want. The whole temperature
      feedback of the carbon cycle is this asymmetry.
- [ ] **`rate_k` has a different dimension in every record** — 1/step, 1/(fungus-unit·step), per kelvin, per
      pascal — and the extent is denominated per record too, so no cross-record dimensional check is
      possible and nothing checks it. **Decide it:** declare each rate model's units in `ReactionDefs` and
      gate that a record's `rate_k` matches its model.
- [ ] **Extents are applied one record at a time**, capped per channel, so several records competing for one
      reactant interact through application order. Evaluate every record against the same starting state,
      then one scaling if a reactant would go negative. Order-independence for free.
- [ ] **The reaction table carries two rate units.** Photosynthesis, respiration, litterfall, decomposition
      and combustion fold `real_seconds_per_step()` into their own `k` and are per-real-second; the rest are
      flat per-step numbers, neither derived nor scaled by the clock. Multiplying by `dt` in the kernel
      would double-count the first group, which is why the dead `dt` upload was deleted rather than wired.

## Weathering has lost both its mechanisms

- [ ] **Frost shattering does not exist.** `LAGeoRecords` carries no record on `RM_DEFICIT_BELOW_THRESHOLD`,
      the rate model is declared in `ReactionDefs` and handled in `reactions_sphere3d.glsl` for no record at
      all, and no frost constant survives in the substrate. Ice segregation is a first-order weathering
      mechanism on a planet with a freezing point. What is a maintainer's call is the DAMAGE MODEL — how
      pore-ice pressure past a rock's tensile strength becomes a volume detached per step.
- [ ] **`tests/test_weathering_rate_law.gd` evaluates the rate with a HAND COPY of the kernel's
      arithmetic** — a second model of the reaction engine — and reads zero bedrock removed at every
      temperature. The record itself carries non-zero inputs at every temperature the test sweeps. Have the
      test read the record through the real evaluator, then re-ask whether the rate is right.

## D. Transport and geometry

- [ ] **The grid cannot resolve its own aquifer.** `LAVoxelGrid.cell_size` is one number for all three axes,
      so the few cells of regolith between the surface and the water table are as coarse as the sky.
      Non-uniform radial spacing is the physically correct fix — fine near the surface, coarse aloft and at
      depth — and `cell_size` becomes per-shell.

## E. Conservation, open

- [ ] **Loose mineral may not be moving.** `silicate_bed` / `silicate_susp_water` are the derived shares
      that replaced the deleted `sediment_total` gauge. **Reproduce:** `scripts/agent_harness.sh sim
      --frames 200` and read whether either share is ever non-zero away from a slump.
- [ ] **Five matter rows trip the conservation gate on a clean tree** — h2o, nitrogen, mineral, oxidant and
      element_C — and the energy row reads UNMEASURED rather than conserved. **Reproduce:**
      `scripts/check_conservation.sh`.
- [ ] **`o2_first` latches at zero**, so the o2 row has no scale to be a fraction of. A baseline of zero is
      not a baseline.

- [ ] **`LA_PASS_PROBE` sums bare fill fractions**, which a kernel moving fill fractions conserves by
      construction, so it cannot see a volume-weighted loss and its silence is not evidence. Every
      per-pass probe wants the same volume weight the reduce rows carry.
- [ ] **The wind is supersonic and always has been**, against a real jet stream of ~70 m/s. `MAX_WIND` was
      deleted on purpose (wind speed is an output), so this is the momentum equation or its timebase, not a
      missing clamp. **Reproduce:** `scripts/agent_harness.sh sim --frames 200`, then read the peak off the
      derived `speed` channel.
- [ ] **`mineral_total` still trips the conservation gate**, and the pass its per-pass probe once named no
      longer exists. Re-localise it against the surviving passes before theorising.
- [ ] **No per-pass attribution for ELEMENTS.** Mineral and energy each have a probe, and each named its
      culprit in a single run. Carbon, oxygen and water have only global totals, which say a number moved
      and never where.

## F. Prescribed where it should emerge

- [ ] **There is no core, because nothing differentiates.** `Substances.gd` carries no iron at all, so the
      planet is silicate all the way down. A just-formed post-Theia Earth is mid-differentiation: metal
      segregating from silicate under gravity, which is one of the largest heat sources of that epoch and
      the reason the interior is layered. Without it there is no metallic core, no compositional contrast
      for the mantle to convect against, and no seat for a dynamo. **The route:** iron as a substance with
      its measured density, melting curve, conductivity and latent heat; it sinks through silicate under the
      solved potential using the transport the substrate already has for a dense phase; the gravitational
      energy released is BOOKED as heat rather than discarded; a liquid outer core is then whatever the
      geotherm crossing iron's melting curve produces, not a declared region.
      Three things block it, all established by reading. **`melt_c_at` gives iron a melting slope of about
      119 K/GPa against a measured ~33** (Williams 1987, Science 236:181), because `dv` is taken from the two
      REFERENCE densities and iron's sit 1518 K apart — alpha-Fe at 20 C against the liquid at its melting
      point — so the slope carries 1518 K of thermal expansion. It wants `density_solid` quoted AT the
      melting point with its own `density_solid_ref_t_c`, which needs a cited value for solid iron at 1811 K.
      **A fifteenth matter channel must take binding 14, which is `Solid` in `state_derive.glsl` and
      `Props` in `gravity_poisson.glsl`**, because `StateDerivePass` and `GravityPass` build uniform sets as
      `entries.append([i, channels[i]])` — the entry index IS the channel index, so a high free binding is
      not available. And **a dense phase descending under the solved potential releases NOTHING today**:
      pass 0 carries enthalpy unchanged as `send_h[base+d] = flow * h_per_unit`, no term adds m·g·dz, and
      `MODE_POTENTIAL` is a relaxation rather than a momentum equation, so the work is discarded. The
      mechanism is viscous dissipation — metal percolating at terminal velocity heats what it passes through
      — deposited on the row and debited against a potential store.
- [ ] **No magnetic field, and it is downstream of the core rather than a subsystem to add.** A geodynamo is
      a convecting, electrically conducting, rotating fluid shell; the rotation and the conducting-fluid
      machinery exist and the shell does not. Note two things before scheduling it. A cell edge of this size
      cannot resolve a dynamo — dedicated geodynamo codes do not reach Earth's parameter regime — so what
      the field COSTS the atmosphere (solar-wind stripping, and the aurora that is its detector) may be the
      only honest coupling at this grain. And for this epoch a planet with no field is defensible: the
      oldest paleomagnetic record postdates formation by a long way. **Decide it** after differentiation
      exists, never by prescribing a field.
- [ ] **No mantle convection.** Radiogenic decay is the only interior heat source and the geotherm is
      whatever it, conduction and the surface produce — but nothing carries that heat by MOVING rock, so
      the plates above are kinematic rather than driven.
- [ ] **The radiogenic source is deposited from GDScript.** A volumetric source term belongs in the kernel
      beside `∇·(k∇T)`; `LAMaterialFieldGeotherm3D` hands it to the sparse heat queue instead, on the
      gravity solve's cadence.
- [ ] **There are no plates.** The maintainer's standing OK to FAKE plate kinematics only ever covered
      kinematics that DRIVE the substrate; nothing does. Melt must come from crustal thinning and the
      geotherm.
- [ ] **Rock has three compositions and no stratigraphy.** `carbonate` and `silica` are channels with no
      transport row and no lithification leg, so there is no limestone and no sandstone.
- [ ] **The field's `dt` is the presentation clock.** One rotation is stated once
      (`LAPhysical.PLANET_ANGULAR_VELOCITY_RAD_S`) and the compression once
      (`LASimClock.REAL_SECONDS_PER_SIM_SECOND`), but `real_seconds_per_step()` is still
      `STEP_DT * compression`, so how fast the player watches sets every transport kernel's timestep. A
      substep budget separates them.
- [ ] **The planet is pinned at the world origin** and the star orbits it. A deliberate moving-frame choice;
      making it literal is the 0.6 headline.

## G. The radiation and the solver

- [ ] **`ATMOS_OPTICAL_DEPTH` is read by nothing.** It is a fitted greybody number back-derived from Earth's
      own 288/255 K ratio, in the file whose header forbids fitted constants, and the longwave side is
      band-resolved now. Delete the constant.
- [ ] **The shortwave side is one grey number for the whole spectrum.** `transport.glsl` attenuates
      sunlight with a single `SW_OPTICAL_DEPTH` on total air mass, asserting that N₂ and O₂ absorb
      sunlight and that CO₂ does nothing, while the longwave half already integrates per band over each
      absorber's own path. Give the shortwave the same band treatment.
- [ ] **`gravity_poisson.glsl` relaxes `phi` in place.** It writes `phi[c]` from a stencil that reads
      `phi[nbr]` out of the same binding, so a cell sees a mixture of pre- and post-iteration neighbour
      values according to GPU scheduling, and two identical runs differ. Chaotic relaxation converges; it
      is not reproducible. No channel carries a second half to relax into: a red-black sweep reads only the
      opposite colour, so the ordering is the fix rather than a buffer.
- [ ] **What else is declared and never dispatched?** Six kernels, buffers and channel rows were found in
      one day that compiled, passed every gate naming them, and ran never. A gate that fails when a kernel
      has no pass, or a buffer no writer, would have caught all six.
