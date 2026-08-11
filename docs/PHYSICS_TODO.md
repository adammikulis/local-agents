# PHYSICS TODO — the one list

**This is the only list of physics work that is left.** Work comes from here, and anything found goes in
here. An item leaves this file when it is implemented and verified, never when it is worked around.

**A departure from real physics may not be added to close an item.** If an item cannot be done correctly,
it stays open and the maintainer is asked. See `CLAUDE.md`.

Each item says what is WRONG, and what would DECIDE it. No status columns, no priorities that rot — the
order is the order.

---

## A. The phase curve

- [x] **Dissociation and ionisation exist** — Saha for ionisation (per element, closed form), law of mass
      action for dissociation (ΔG = ΔH − TΔS, bisected extent). No onset constants. Verified: H₂O 11%
      dissociated at 4000 K, 99% at 6000 K; 2% ionised at 10 000 K, 98% at 25 000 K.
- [ ] **The GPU cannot evaluate the high rungs.** `kernels3d/enthalpy.glsli` stops at gas because inverting
      the equilibria needs bisection — too costly per cell per step. **Decide it:** a precomputed EOS table
      (specific enthalpy × pressure → temperature, phase, fractions), generated from `LASubstances` and
      uploaded, with a gate that the table reproduces the functions to tolerance. This is what real EOS
      codes do; it keeps the GPU cost O(1) per cell.
- [ ] **Sublimation has no direct path.** The ladder forces solid → liquid → gas, so ice below the triple
      point melts first instead of subliming. `latent_sublimation_j_kg` exists and is unused by the curve.
- [ ] **No triple point in the substance table**, so nothing can choose sublimation over melting.
- [ ] **Melting is not pressure-dependent.** `boil_c_at` does Clausius–Clapeyron; `melt_c` is a flat
      constant. Fusion has a Clapeyron slope too, and for water it is NEGATIVE — which is why glaciers slide
      on their own base. The asymmetry is arbitrary.
- [ ] **Supercritical is not a state.** Above the critical pressure `boil_c_at` correctly gives no plateau,
      but the result is still labelled liquid or gas and uses `c_gas`. A post-Theia steam envelope sits
      exactly there, which is Stage 2's target.
- [ ] **No freezing-point depression.** Sea water freezes near −1.8 °C, not 0 °C. Sea ice is rendered and
      computed from a pure-water curve.
- [ ] **Solid polymorphs** — ice I…VII, and olivine → wadsleyite → perovskite with depth. A planet's mantle
      structure IS these transitions, each with its own enthalpy and density jump. Maintainer asked for the
      structure to be built.
- [ ] **Glass vs crystalline.** Quenched basalt releases different heat than slow-cooled; `latent_rock` is
      one number.
- [ ] **Metastability** — supercooled water, superheated liquid. Real, and arguably beyond this granularity.

## B. The substrate's state

- [ ] **The field stores temperature, not energy.** Phase is therefore a set of CHANNELS (`water` /
      `moisture` / `snow` are one substance; `rock_fill` / `lava` are another) and a phase change is a
      REACTION RECORD with latent heat attached by hand. Store enthalpy per cell, derive temperature and
      phase, and 7 of the 18 records plus the snow-deposition and rain-condensation legs delete themselves.
      **This is the largest single item and everything in C gets easier after it.**
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
- [ ] **`params.dt` is uploaded to `reactions_sphere3d.glsl` and never read**, so every reaction rate is
      per-STEP rather than per-second.
- [ ] **Three condition gates are used by no record** — `GATE_SURFACE`, `GATE_OPEN_ABOVE`, `GATE_DAYLIGHT`.
      `GATE_DAYLIGHT` is genuinely redundant (photosynthesis takes light as its rate driver). The other two
      are live machinery nothing calls: wire them in or delete them.

## D. Transport and geometry

- [ ] **Four kernels are the same two-pass send/gather** — `gravity_flow`, `soil`, `erosion_transport`,
      `plate_advect` — with different flow rules. All four carried the same reciprocity bug. One operator
      with per-material rules makes that class unrepresentable, the way the slot SSOT already does.
- [ ] **Two mass transfers still move temperature without moving heat**: the regolith→regolith Darcy leg
      (`soil_sphere3d.glsl:51`) and sediment slump.
- [ ] **The grid cannot resolve its own aquifer.** Four regolith cells span 10.8 km against the 2 km
      `GROUNDWATER_CIRCULATION_M` describes. Non-uniform radial spacing is the physically correct fix —
      fine near the surface, coarse aloft and at depth — and `cell_size` becomes per-shell.

## E. Conservation, open

- [ ] **`o2_total` and `oxidant_all`** are the largest remaining drifts, newly visible now that the
      air-above gates select the right cells.
- [ ] **`mineral_total`** still trips the conservation gate. The per-pass mineral probe localises it to
      `water_slump_lava`; every other leg reads exactly 0.0.
- [ ] **No per-pass attribution for ELEMENTS.** Mineral and energy each have a probe, and each named its
      culprit in a single run. Carbon, oxygen and water have only global totals, which say a number moved
      and never where.

## F. Prescribed where it should emerge

- [ ] **No mantle convection.** The geotherm is a seeded initial condition maintained by a reservoir, so the
      plates above are kinematic rather than driven.
- [ ] **Plate tectonics is kinematic Voronoi.** *(Maintainer has explicitly OK'd faking this one — true
      geodynamics is research-grade.)*
- [ ] **Rock has three compositions and no stratigraphy.** Carbonate and silica do not travel and do not
      lithify, so there is no limestone and no sandstone.
- [ ] **The day is a game number** — `DAY_LENGTH = 200.0` against Earth's 86 400 s, with a `PLANET_SPIN_RATE`
      that is not derived from it. Three clocks, one rotation.
- [ ] **The planet is pinned at the world origin** and the star orbits it. A deliberate moving-frame choice;
      making it literal is the 0.6 headline.
