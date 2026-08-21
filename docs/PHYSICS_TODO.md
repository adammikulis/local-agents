# PHYSICS TODO — the one list

**This is the only list of physics work that is left.** Work comes from here, and anything found goes in
here. An item leaves this file when it is implemented and verified, never when it is worked around.

**A departure from real physics may not be added to close an item.** If an item cannot be done correctly,
it stays open and the maintainer is asked. See `CLAUDE.md`.

Each item says what is WRONG, and what would DECIDE it. No status columns, no priorities that rot — the
order is the order.

---

## The referent

**Earth at ~4.4 Ga: the magma ocean has crystallised, the Moon-forming impact has settled, there is crust
and there is liquid water.** Read every item against that world. The anchor is real evidence rather than a
model — the Jack Hills detrital zircons date to 4.404 Ga and their oxygen isotopes record liquid water and
low-temperature alteration of a crust that already existed.

**Why not the moment of formation:** core formation ran in about 30 Myr (Hf-W chronometry), which is
~10^13 steps at this timebase, so differentiation cannot be a thing the substrate produces at any
plausible compute. A differentiated planet is therefore SEEDED either way, and seeding one at an epoch the
rock record can confirm beats seeding one at an epoch only models describe. Iron is still a third of the
planet's mass; it starts in a core instead of forming one. A magma ocean also gives the built substrate —
rivers, weathering, sediment, aquifers — nothing to act on.

Free O2 at zero is correct. There is no photosynthesis, no biological nitrogen fixation, no litter and no
biosphere — LIVING THINGS AND THEIR BEHAVIOUR are 0.5 work, and nothing else is. Radiogenic abundances
belong at formation, not today. An item is open here only if it is wrong for a lifeless planet of that age.

**ALL OF THE PLANET'S MASS IS SEEDED IN 0.4, AND ITS ELEMENTAL COMPOSITION MUST BE THE REAL ONE.** No
element waits for a later version. The tell that this was misread: "a biosphere is 0.5" was taken to mean
"carbon is 0.5", and the planet ended up made of one mineral. Chemistry is not biology — a process runs in
0.4 unless it needs a living organism to catalyse it. Weathering, clay formation, serpentinization,
outgassing, ore concentration and abiotic organic synthesis are all 0.4.

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

The planet is lifeless — no seeded litter, no dead plant pool, no biomass→fuel refill:

<!-- claim: nofile addons/local_agents/sim/material/MaterialSurfaceSeed3D.gd -->
<!-- claim: absent BASELINE_DETRITUS addons/local_agents/sim -->
<!-- claim: absent LITTER_FROM_BIOMASS addons/local_agents/sim -->

## A. The phase curve

- [ ] **The GPU cannot evaluate the high rungs.** `kernels3d/enthalpy.glsli` stops at gas because inverting
      the equilibria needs bisection — too costly per cell per step. **Decide it:** a precomputed EOS table
      (specific enthalpy × pressure → temperature, phase, fractions), generated from `LASubstances` and
      uploaded, with a gate that the table reproduces the functions to tolerance. This is what real EOS
      codes do; it keeps the GPU cost O(1) per cell.
- [ ] **Freezing-point depression is implemented and cannot be wired, because there is no dissolved phase.**
      `LASubstances.melt_c_at` takes a molality; every call site passes 0. Halite now exists as a seeded
      substance in the rock, but no per-cell dissolved salt reaches the ocean's water. **Decide it:** a
      dissolution leg from the halite channel into a dissolved amount the enthalpy ladder's molality reads
      (CPU and `enthalpy.glsli` twin together), and either accept the ideal van 't Hoff law or carry an
      osmotic coefficient — ideal gives −2.16 °C for sea water against the measured −1.86.
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

- [ ] **The epoch is a sentence in a document, and the constants are present-day.** `SOLAR_CONSTANT_W_M2`
      is 1361, today's value, so this planet gets about 40% more sunlight than the real one did — which is
      how a missing greenhouse currently passes unnoticed. `PLANET_ANGULAR_VELOCITY_RAD_S` is the modern
      sidereal day against roughly six hours at 4.4 Ga, and Coriolis is linear in it, so the circulation is
      in the wrong regime. `PREBIOTIC_MOLE_FRAC_CO2` is correctly Hadean (Kasting 1993), which is what makes
      the mismatch invisible. **Decide it:** one declared epoch that luminosity, rotation and lunar distance
      are all derived from, so moving the world in time is one edit and the physics follows.
- [ ] **The interesting geology is slower than the clock by ten orders of magnitude.** Mantle convection,
      ore concentration and atmospheric evolution run over 10^6–10^9 years against a 43.2 s step. Real Earth
      system models split the timescales — atmosphere and ocean on a short step, ice and geology on a long
      one, coupled asynchronously — which keeps every equation and dependency intact and changes only the
      cadence. That is the same seam as "the field's `dt` is the presentation clock" in F, and it is what
      makes any slow process observable at all.
      **STEPPING A SLOW PROCESS WITH A LONGER dt IS THE FIX; SKIPPING ITS STEP IS NOT, AND THE DIFFERENCE
      IS THE WHOLE ITEM.** `docs/PERFORMANCE_TODO.md` records the attempt that gated inside full-grid
      dispatches and moved a reservoir total by 18%: a skipped step of an integrating quantity is a
      permanent offset, not a transient. A band that runs every N steps must integrate `N * dt` and book
      what it moved over that interval, so the conservation rows read the same as they would unsplit —
      which is also the gate. A row's band is a declared property of the row, never a global switch.
- [ ] **Conserve elements, derive species.** The runtime state is channel amounts, so the inventory
      RECONSTRUCTS moles (`mol_per_unit`). If the conserved state were moles of element per cell, no kernel
      could change total carbon, because no kernel would write it.
- [ ] **Organic matter is one lumped CH₂O.** Which is why ignition is a single number and a planet that
      demonstrably buries organics cannot have peat, coal or oil. Make it a C:H:O ratio plus a recalcitrance
      so burial → coalification is a continuous drift, not a new channel per fuel.
- [ ] **Weathering produces no clay, so there is no mineral soil.** Feldspar and silicate hydrolysis makes
      clay minerals — kaolinite, smectite — and `rg clay addons/local_agents/sim` finds none. Clay is the
      abiotic half of soil and it is what holds water and cations in regolith; only humus needs life.
      It is also a product the weathering records already have the reactants for.
- [ ] **The ocean has no chemistry.** No pH, no alkalinity, no carbonate saturation state — `rg` finds none
      of them. Carbonate precipitates and dissolves according to saturation, which is what decides whether
      the Urey cycle's CaCO₃ stays put, and it is pure inorganic equilibrium.
- [ ] **No abiotic organic synthesis.** Serpentinization of ultramafic rock makes H₂ and CH₄, and
      Fischer-Tropsch chemistry makes hydrocarbons from CO and H₂; carbonaceous infall carries organics
      ready-made. `rg serpentin|fischer|tropsch` finds nothing, so on this planet every organic molecule
      implies life. It does not: this is the carbon chemistry a lifeless Hadean Earth actually runs.

## C. The reaction engine

- [ ] **Direction is derived for dissolution and coal dehydration; the rest lack standard-state data.**
      Decarboxylation and combustion produce FERT, and `fixed_n` has no formation enthalpy or entropy until
      the fixed-N compound is decided; the five bio records run on cellulose, which has neither datum.
      Add the data (cited) and pass each record through `LAReactionThermo.reversible`.
- [ ] **Decay has no temperature dependence and production has an optimum.** Decomposition and respiration
      are `RM_BILINEAR` in their two reactants, so litter rots at the same rate at −40 °C and +40 °C, wet or
      bone dry, while photosynthesis carries `RM_OPTIMUM_BAND`. Michaelis–Menten and a Q₁₀ (or the
      Arrhenius the engine already has) are what the two uptake reactions want. The whole temperature
      feedback of the carbon cycle is this asymmetry.
- [ ] **`DISSOLUTION_K` is the one per-step rate left** (its `MODEL_PARAMETERS.md` row). A cited areal rate
      law (wollastonite, mol/m²/s) times a reactive surface area the grid can defend replaces it, and its
      `k_timebase` flips to per_real_second.

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

- [ ] **The core is seeded, and the seeded phases cannot yet move or melt on the GPU.** The planet now
      seeds differentiated — a metal core whose radius follows from the core mass fraction, one silicate
      shell of the registry's own mineral mix (maintainer's decision: differentiation at ~10^13 steps is
      not computable). What remains for the core to LIVE rather than sit: **the six new phases are
      sensible-heat entries**, so metal, olivine, pyroxene, plagioclase, halite and apatite never melt in
      `state_derive.glsl` — no liquid outer core, no mantle melt beyond the wollastonite share — and
      **none has a transport row**, so none of them erodes, slumps or percolates. The residual-descent
      physics is still open: **a dense phase descending under the solved potential releases NOTHING** —
      pass 0 carries enthalpy unchanged as `send_h[base+d] = flow * h_per_unit`, no term adds m·g·dz, and
      `MODE_POTENTIAL` is a relaxation rather than a momentum equation. The mechanism is viscous
      dissipation — metal percolating at terminal velocity heats what it passes through — deposited on the
      row and debited against a potential store.
- [ ] **The interior is seeded at the surface temperature.** `LAFieldEnthalpySeed.seed` hands every cell
      `INITIAL_TEMP`, so the core starts at 15 C against a real ~4,000-5,000 K and the geotherm must build
      from radiogenic decay alone. **Reproduce:** `scripts/agent_harness.sh sim --frames 20`, read `temp`
      at depth. Blocked in honesty by the phase ladders above: a hot interior needs the seeded phases to
      hold molten states.
- [ ] **Trace elements ride their host phase uniformly, and nothing can ever concentrate them.** Each
      shell mineral carries the registry's traces as fixed kg/kg. Real ore bodies form when partition
      coefficients move trace mass between silicate melt, sulfide melt and aqueous brine; that needs the
      traces to become per-cell state THE MOMENT a concentrating process exists, and the seam is the
      melt/brine partitioning step of whichever hydrothermal or magmatic lane lands first.
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
- [ ] **The planet has two masses.** `PlanetBody.mass()` is a toy value the parked orbit lane reads,
      while the field's gravity — the Poisson total and the slice monopole alike — carries the mass the
      seeded rock derives. One fact, two declarations; unifying them changes the 0.5 orbit integrator's
      regime, so which one dies is the maintainer's system decision.
- [ ] **The planet is pinned at the world origin** and the star orbits it. A deliberate moving-frame choice;
      making it literal is the 0.6 headline.

## G. The radiation and the solver

- [ ] **The shortwave side is one grey number for the whole spectrum.** `transport.glsl` attenuates
      sunlight with a single `SW_OPTICAL_DEPTH` on total air mass, asserting that N₂ and O₂ absorb
      sunlight and that CO₂ does nothing, while the longwave half already integrates per band over each
      absorber's own path. Give the shortwave the same band treatment.
- [ ] **A buffer allocated and never WRITTEN passes the gate.** `check_declared_and_dispatched.sh`
      fails a kernel with no pass and a buffer nothing allocates, and does not fail a buffer no kernel
      or pass ever writes — the read-never-written channel it was built for still slips through.
