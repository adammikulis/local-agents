# Physics audit, 2026-08-09 — what the substrate asserts instead of computing

Three audits (the constants authority, the reaction engine, the GPU kernels), each asked one question:
**do the laws of physics work this way?** Not "is it consistent", not "does the gate pass" — those are how
the substrate got here. Findings are ordered by how much each distorts the simulation.

**Read this before planning substrate work.** `PHYSICS_RUBRIC.md` scores against it; `HANDOFF.md` carries
the live queue. Nothing here is speculative — every item has a file:line and, where it matters, arithmetic.

## The defect shape, five times in one session

**A scalar standing where a relation belongs.** `rc_of` (one number where a function of composition
belongs), `rock_fill` (a saturation read as a volume fraction), `carbon_total` (a sum of things that are not
the same quantity), `boil_c` (a point read as a curve), `ATMOS_OPTICAL_DEPTH` (air mass read as opacity).
The first four are fixed. When you find a constant, ask what it is a function OF before anything else.

## The meta-finding: what the gates cannot see

`check_physical_constants.sh` verifies a kernel's **copy of a number**. `check_reaction_balance.sh` verifies
that **six elements close, per record**. Between them, a record can have a made-up rate law, a rate 10⁴× too
fast, incoherent units, zero enthalpy across a phase change, and a fatal interaction with the record above
it — **and both gates report green.** Nothing checks laws, energy, dimensions, or interactions.

`rc_shared.glsli` already states the general form: *"a gate on constants does not gate the FORMULA they sit
in."*

---

# A. ENERGY — the largest class

### A1. Sixteen reaction records cross a phase or chemical boundary and book zero joules
`PhaseRecords.gd` contains the string `enthalpy` **zero times**. R21 freeze, R22 melt, R23 evaporation, R24
soil evaporation, R25 sublimation, M5/M6 rock melt/solidify, D1a frost — none book energy. The constants all
exist and are unused; the engine's mechanism exists and is correct (`reactions_sphere3d.glsl:649`); only
combustion uses it.

**Evaporative cooling — ~80 W/m², the largest single term in Earth's surface energy budget — does not exist
in this simulation.** `PhaseRecords.gd:16-21` records that a previous pass responded to "the planet could
not get cold" by moving water's freezing point to 12.5 °C. The missing 2.49e9 J/m³ is why it could not.

Per unit extent: evaporation/soil-evap 2.49e9 J/m³, sublimation 2.83e9, freeze/melt 3.33e8, rock 1.16e9.

### A2. Rotting and burning are declared to be the same reaction; one books 6.98e9 J/m³ and the other zero
`CombustionRecords.gd:35-41` says R26 is *"literally the reaction R15 already runs for decomposition — same
reactants, same products, a different rate law."* R26 books 6.98e9 J/m³; R15 and R20 book 0. There is no
thermodynamic path by which one reaction is exothermic when fast and athermal when slow.

Booking it would immediately expose a second defect: R20's unbooked heat is +9.6 K per 43 s step. **Energy
is the conserved quantity that would have caught the biological rate error, and it is the one the gate does
not count.**

### A3. `heat3d_cool_sphere3d.glsl` is a 100 °C thermostat. Delete it.
Its header is a long essay celebrating the removal of a thermostat. It was re-derived from the latent heat
instead of written as a constant, which is why nobody caught it. At `cell_size` 16:

```
cost_per_frac = 16 x 997 x 2.257e6 = 3.60e10 J/m2 per unit cell-fill
cap (full water cell) = 4.171e6 x 16 = 6.674e7 J/m2/K
affordable per degree = 1.854e-3      rate leg = w x BOIL_RATE = 0.02      ratio 10.8x
=> min() at :139 always selects `affordable`
=> :140 evaluates to  t - (t - BOIL_TEMP)  =  EXACTLY 100.0
```

It is `if (t > 100 && water > 0.05) temp = 100.0;` for every wet cell from 100 to 370 °C, in one step.

**And no mass moves.** The mass leg is R23, ~970× smaller — and R23 carries `GATE_AIR_ABOVE`, so a
**submerged** cell (the pillow-basalt case the kernel exists for) gets the full latent-heat sink and
**exactly zero** mass transfer. The seawater is boiled infinitely many times.

### A4. Condensation and deposition are free
`atmos_precip_sphere3d.glsl:66` computes `condensed` and uses it only to decide how much falls; the
2.26e6 J/kg released is never booked. `snowice_sphere3d.glsl:74` deposits vapour as ice, also free.
**This is the engine of every storm on the planet and it drives no convection.** Note the asymmetry with
A3: water can condense for free but cannot evaporate without being pinned to 100 °C.

### A5. Heat does not travel with matter
Only `lava_flow`, `magma_buoy`, `soil` and `heat3d_buoyancy` carry enthalpy. Water (ρc 4.17e6,
`MAX_FLOW = 1.0` — a whole cell per step), sediment, suspended rock, moisture, dust, gases and **whole
continents** move at their destination's temperature. `rc_shared.glsli` fixed the *stock*; nothing fixed the
*flux*.

---

# B. THE GREENHOUSE — why a post-Theia planet cannot cool

### B1. `ATMOS_OPTICAL_DEPTH = 0.835` makes CO₂ and water vapour radiatively invisible
`eps_a` scales longwave opacity with **total air mass** — asserting that N₂ and O₂ are greenhouse gases and
that doubling CO₂ does nothing. Real τ = Σ κ_i·u_i over the absorbing species, with pressure broadening.
It is back-derived from Earth's own 288/255 K ratio, i.e. **fitted**, in the file whose header forbids
fitted constants.

- **The Urey sink can strip the atmosphere of CO₂ and the surface temperature will not move a millikelvin.**
  The entire carbon cycle is radiatively disconnected.
- For a ~100 bar steam envelope the real grey τ is 10²–10³. **Two to three orders of magnitude low, in the
  direction that makes a magma-ocean cooldown impossible.**

`ATMOS_SW_OPTICAL_DEPTH = 0.2597` has the same defect. Cloud is computed in `atmos_precip` and shades
nothing — no cloud albedo, no cloud greenhouse. Surface emissivity is asserted at exactly 1.0
(`heat3d_solar:511`) while the shortwave side computes a careful four-way albedo mix.

### B2. Saturation has no ceiling and no ice branch
Magnus is clamped only at the bottom. At 1000 °C `saturation_mass_fraction()` returns **1.50** — "air holds
one and a half cells full of liquid water." Above the critical temperature saturation does not exist, and
the file now *has* that constant. Separately there is no over-ice curve, so deposition runs on the
over-liquid one — 5% wrong at −5 °C, 32% at −40 °C — and **the Bergeron process, the reason snow exists, is
absent.**

### B3. The atmosphere has no vertical structure in its heat capacity
`AIR_DENSITY_KG_M3` is applied to every cell of the column. Density falls ~25× across 3.2 scale heights, so
the upper atmosphere is 25–100× too hard to heat and to cool. `wind_pressure_sphere3d.glsl:198-206`
**already computes the `exp(-dz/H)` profile** and writes it to an `air` channel `rc_of` does not read.

---

# C. THE REACTION ENGINE

### C1. The reactant cap is first-come-first-served, and it decides the biggest outcomes
`reactions_sphere3d.glsl:605-615` clips `x = min(x, avail/coeff)` — a record may take a channel to zero in
one step. Order is R15 → R19 → R20 → … → R26.

- **R20 respiration's O₂ cap binds for any cell with biomass > 0.085** (measured ~0.5), so it takes *all*
  the oxygen. **R26 combustion, which runs last, therefore cannot fire in a vegetated cell.** Six runs
  report `fires 0`; the repo attributes this to temperature and a no-op `ignite()`. **Respiration is a
  sufficient cause on its own.**
- **R19 photosynthesis is CO₂-capped, not light-limited** — the cap is 5× tighter than the rate law, so the
  OPTIMUM_BAND law is inoperative except at night. It strips 100% of a cell's CO₂ every step; real leaves
  have a compensation point below which assimilation goes negative.

**Physics: competing sinks share a substrate in proportion to their instantaneous rates.** Evaluate every
rate against the same start-of-step state, sum demands, scale proportionally when over-subscribed. ~15 lines
in the kernel's main loop, and it also removes C2 and the evaporation priority.

### C2. R21 and D1a freeze the same water twice
Same rate model, driver, threshold, constant and 1:1 water→snow leg (`PhaseRecords.gd:147`,
`GeoRecords.gd:264`). Any near-ground cell below 0 °C freezes at **2× FREEZE_RATE**. Each balances
individually, so the gate is silent.

### C3. Rate models: only one is a real law
`ARRHENIUS` is correct (two-point form, first-order mass action). `CONST_FRAC` and `BILINEAR` are mass
action **only when the driver is the reactant**, which is often not the case. `EXCESS_OVER_THRESHOLD` /
`DEFICIT_BELOW_THRESHOLD` are rectified linear ramps standing in for degree-day melt, saltation (real flux
is **cubic** in shear velocity), and a solid-state reaction that should be Arrhenius. `OPTIMUM_BAND` is a
made-up clipped parabola; the real photosynthesis temperature response is asymmetric (a denaturation limb).

**Missing entirely:** Michaelis–Menten (needed by R15, R20), Q₁₀ on decomposition and respiration — so
litter rots at the same rate at −40 °C and +40 °C, wet or bone dry. **The entire temperature feedback of the
terrestrial carbon cycle is absent**, and asymmetrically: production has an optimum, decay does not.

### C4. Nutrient limitation is authored, documented at length, and inert
`BioRecords.gd:155-176` derives `FERT_UPTAKE_COST = 0.05` and **the record does not use it** — the
coefficient in force is 1.768e-6, **28,000× smaller**. Nitrogen never limits growth anywhere. Root cause:
`fixed_n` is given the density of **rock** (2900 kg/m³), so one FERT unit is 207,045 mol N/m³. Three more
constants in the same file are likewise dead.

### C5. Three clocks, and `params.dt` is never read
`params.dt` is uploaded to `reactions_sphere3d.glsl` and **never used**. Every rate is per *step*, so
halving the timestep doubles every physical rate — except evaporation and combustion, which opted into real
seconds. A third clock is invoked for geological time. Photosynthesis runs ~200× faster than peak real NPP;
combustion runs at its real rate. **A forest fixes and rots carbon hundreds of times faster than a fire
burns it**, which is the inverse of the real relationship.

### C6. `rate_k` has a different dimension in every record
1/step, 1/(fungus-unit·step), cell-fill/(K·step), cell-fill/(Pa·step), … Nothing checks it. The extent `x`
is also denominated per-record, so no cross-record dimensional check is possible.

---

# D. WHAT IS SIMPLY MISSING

Each of these has something else asserting an answer in its place.

| missing | what asserts it instead |
|---|---|
| **Salinity** | sea ice forms at 0 °C not −1.8 °C; no brine rejection, no thermohaline overturning |
| **Thermal expansion β** | `heat3d_buoyancy`'s `BUOYANCY = 0.18`; the 4 °C density maximum cannot be expressed |
| **Magma viscosity μ(T,φ)** | `lava_flow`'s `LAVA_MAX_FLOW = 0.25` — "a 1200 °C melt and a nearly-solid 850 °C toe creep at the same rate" (its own comment). Real basalt spans 10–10⁵ Pa·s; the divergence at critical crystallinity is what makes a flow front **stop** |
| **Saturation over ice** | the over-liquid Magnus curve (B2) |
| **Grain size for `dust` / `susp`** | one settling fraction for all; real Stokes is ∝ d², spanning four orders |
| **Radiative conductivity above ~1000 K** | absent, so lava cools too slowly |
| **Solidus–liquidus interval** | rock melts at a single temperature; `BASALT_LIQUIDUS_C` exists with **zero readers** |

Also: `RADIOGENIC_W_PER_KG` is the **present-day** value on a project targeting 4.5 Ga, when it was ~5×
higher. `INNER_CORE_C = 5200` is iron's melting point **at 330 GPa** — it asserts Earth's mass and radius,
set nowhere.

---

# E. MATTER DESTROYED BY DESIGN

- **Static sea cells are infinite sinks** (`water_sphere3d.glsl:84-86,148-151`). Water poured in vanishes —
  likely most of the measured −19.5% H₂O. `erosion_transport:39-44` explicitly refuses to do this for
  mineral (*"Mineral may NOT vanish"*), so the substrate already knows it is wrong for one substance.
- **`scent_fert_sphere3d.glsl:104` destroys nitrogen**, with both real destinations named in the comment and
  no channel to receive them.
- **D2 lithification is structurally unable to fire**: it is driven on overburden, the engine only runs in
  open cells, and an open cell with rock above it is a **cave**. The sediment→bedrock leg of the rock cycle
  is dead everywhere except caves.

---

# F. WHAT IS GENUINELY GOOD — do not "fix" these

`soil_sphere3d.glsl` is the best kernel in the tree: Kozeny–Carman from real porosity, Irmay k_r = S_e³,
Darcy on a real head gradient, capacity-weighted enthalpy on both legs, and a 21-slot conservation probe ·
`heat_sphere3d` conduction (harmonic-mean interface, each side divided by its own rc; the geotherm is a
ghost-cell **conduction bond**, not a pinned temperature) · `heat3d_buoyancy` (exactly conserving) ·
`lava_phase`'s σεT⁴ net grey exchange · R26 combustion (Arrhenius on measured pyrolysis kinetics, the only
record that books its enthalpy) · D1b the Urey reaction (water correctly a catalyst, net H₂O zero) ·
`atmos_precip`'s Kessler autoconversion (real q_crit, converted through the substrate's own clock — the
counter-example for C5) · `unit_ratio()` in `ReactionBalance` · Hess's law made unviolatable in
`Substances.latent_sublimation_j_kg()` · `slump`'s repose angle against a real arc length.
