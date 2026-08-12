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
- [x] **Sublimation, the triple point, Clapeyron melting and supercritical** — all four land together.
      `triple_t_c` / `triple_p_pa` (IAPWS) are in the table; below the triple pressure the ladder has NO
      liquid branch and the plateau it crosses is sublimation, verified at 300 Pa: 93% through the plateau
      at h = 3.2e6, gas at 3.5e6, never passing through liquid. `melt_c_at` is Clausius–Clapeyron on the
      solid–liquid boundary, `dT/dP = T Δv / ΔH_fus` with `Δv = 1/ρ_liquid − 1/ρ_solid` straight out of the
      table — no new constant, and it comes out NEGATIVE for water at −0.0072 K/bar against the measured
      −0.0074, so a glacier melts under its own load. `sublimation_p_at` is Clausius–Clapeyron anchored on
      the triple point with the DERIVED sublimation enthalpy: 12.9 Pa at −40 °C against the measured 12.85.
      Supercritical is its own phase rather than a mislabelled gas.
- [ ] **Freezing-point depression is implemented but not wired.** `melt_c_at` takes a molality and derives
      the cryoscopic constant rather than tabulating it — `K_f = R T_f² M / ΔH_fus,molar` gives 1.859 K·kg/mol
      against the measured 1.86. Two things stop it being live: (a) **there is no salinity channel**, so
      nothing can say which cells are sea and which are rain, and applying it globally would freeze lakes at
      −2 °C too; (b) the van 't Hoff law is IDEAL, and real sea water's ions have activity coefficients below
      1, so 1.16 mol/kg gives −2.16 °C against the measured −1.86. **Decide it:** add a salinity channel, and
      either accept the ideal law's ~15% or carry an osmotic coefficient.
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
- [ ] **The reaction table carries TWO different rate units.** *(Corrected 2026-08-11. This said `params.dt`
      is uploaded and never read "so every reaction rate is per-STEP rather than per-second" — the first half
      was true and the second half was the wrong diagnosis.)* Evaporation, photosynthesis, respiration,
      litterfall and decomposition already fold `real_seconds_per_step()` into their own `k`, so they are
      per-real-second. `FREEZE_RATE`, `MELT_RATE`, `SOLIDIFY_RATE` and `ROCK_MELT_RATE` are flat per-step
      numbers that are neither derived nor scaled by the clock. Multiplying everything by `dt` in the kernel
      would therefore DOUBLE-COUNT the first group — which is why the dead `dt` upload was deleted rather
      than wired up. **Resolves with B1:** those four records are the phase-change relaxations, and once the
      field stores enthalpy the freezing rate is set by heat removal rather than by a rate constant, so all
      four delete themselves. Do not re-derive them first.
- [ ] **Three condition gates are used by no record** — `GATE_SURFACE`, `GATE_OPEN_ABOVE`, `GATE_DAYLIGHT`.
      `GATE_DAYLIGHT` is genuinely redundant (photosynthesis takes light as its rate driver). The other two
      are live machinery nothing calls: wire them in or delete them.

## D. Transport and geometry

- [x] **No kernel computes a reverse link any more.** `LASphereGrid` resolves each one into `link_partner`
      by SEARCHING the neighbour's own six slots for the one pointing back, so a gather is
      `send[partner[base + d]]` — a lookup, not arithmetic. Four kernels got that arithmetic wrong and a
      fifth got it wrong while being fixed; now it cannot be written. `opposite()` is deleted and
      `check_neighbour_slots.sh` fails the build on any kernel that computes a reverse link. Verified by
      `check_kernel_conservation.sh`: 8 checks still pass.
- [ ] **The four gathers are still four kernels.** `gravity_flow`, `soil`, `erosion_transport` and
      `plate_advect` remain separate with different flow rules. The bug CLASS is now closed by the table
      above, so this is de-duplication rather than correctness — worth doing, no longer urgent.
- [ ] **`sediment_total` is ~0** (0.05 before this work, 0.0 after) where it used to read in the hundreds.
      Downstream of E1 most likely, but unconfirmed; re-check once E1 is closed.
- [ ] **Two mass transfers still move temperature without moving heat**: the regolith→regolith Darcy leg
      (`soil_sphere3d.glsl:51`) and sediment slump.
- [ ] **The grid cannot resolve its own aquifer.** Four regolith cells span 10.8 km against the 2 km
      `GROUNDWATER_CIRCULATION_M` describes. Non-uniform radial spacing is the physically correct fix —
      fine near the surface, coarse aloft and at depth — and `cell_size` becomes per-shell.

## E. Conservation, open

- [ ] **`o2` ALONE STILL RUNS AWAY, AND IT IS LOCALISED TO ONE PASS AND ONE STEP.** `LA_PASS_PROBE=o2`
      names it exactly: sane for 11 steps (69 120 decaying ~0.7%/step), then from **step 12** `GasWindPass`
      multiplies it by ~2.4x EVERY step — 7.9e4, 1.9e5, 4.4e5, ... 1e16. Nothing else touches the channel.

      **Already fixed and no longer suspects.** `tracer_transport` computed its lateral reverse index as
      `l ^ 1`, which is right only where the cubed-sphere seam is not bent; it uses `link_partner` now. That
      alone took `element_C_total` from 2.44e17 to **1.53e7** and `mineral_total` to **31 977**, both sane,
      and `h2o` from 1.05e11 to 4.49e9. So the seam WAS one real bug — just not the whole of this one.

      **The discriminator to start from:** `co2` rides the SAME kernel, the same pass and the same dispatch
      loop as `o2`, differing only in `contrast` (0.10460 vs 0.51927, i.e. settling velocity) — and co2 does
      not run away. So the fault is o2-specific, not the shared operator. Look at what is different: the
      settle_v magnitude, and o2's second writer (photosynthesis in ReactionsPass, which the probe shows
      touching it only slightly).

      **Do not re-check, all measured:** the kernels conserve in isolation (`check_kernel_conservation.sh`,
      8/8 including a 160 m/s gale on a solid crust); the CPU mirror equals the GPU buffer exactly, so this
      is not a readback or residency problem; the checkpointed and normal step paths give the SAME result,
      so it is not pass ordering or sync; `restrict` aliasing on the deposit binding is removed.

- [ ] **The wind is supersonic and always has been** — 160 m/s after the lateral fix, 425 before, against a
      real jet stream of ~70 m/s. `MAX_WIND` was deleted on purpose (wind speed is an output), so this is the
      momentum equation or its timebase, not a missing clamp. Suspect first now that pressure is in pascals.

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
