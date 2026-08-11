# PHYSICS_RUBRIC.md — how good is the substrate, in numbers

**This is the standard the simulation is scored against, and the score is appended here on every landing so
the trend is a record rather than a claim.** `CLAUDE.md` holds the process rules and `HANDOFF.md` holds the
map of what is left; this holds the measurement of how physical the thing actually is.

## Why it exists

A whole session was spent making nine copies of one formula agree with each other, and five gates were built
to enforce that everything agrees with `PhysicalConstants.gd`. **Not one of them asks whether
`PhysicalConstants.gd` is right.** Consistency was mistaken for correctness, which made a wrong model harder
to change and presented it as progress.

The governing question, from `CLAUDE.md`'s Rule Zero, is **"do the laws of physics work this way?"** — and
the answer needs to be a number, not a judgement, because the person judging is the person who did the work.

**Half of this is computed, deliberately.** `scripts/physics_score.sh` reads criteria 1, 2 and 5 straight out
of `SIM_REPORT`. Criteria 3, 4 and 6 are counts from an audit and are hand-entered, so they are the ones to
distrust.

## The six criteria

Each scored **0–4**. Anything that cannot be measured scores **0 for that reason alone** — an unmeasurable
claim is how the project got here.

### 1. Matter conserved — *is anything created or destroyed?*
Per element, |drift| over 600 frames from the world seal, mask-free, **in moles**. A raw channel sum is not
admissible: `carbon_total` summed CO₂ + biomass + detritus units and read +1261% while the mole count read
−10.7%. The sign was different.

| 0 | unmeasured, or measured in a unit that is not a quantity |
|---|---|
| **1** | > 10% |
| **2** | 1 – 10% |
| **3** | 0.1 – 1% |
| **4** | < 0.1%, and every remaining change booked to a named mechanism |

### 2. Energy booked — *is every joule accounted for?*
Energy is **not** closed and must not be — sunlight enters and longwave leaves every step. The score is on
`energy_residual`, **not** drift. A gate demanding a constant energy stock would demand a planet with no sun.

| **0** | no stock ledger | **1** | residual > 50% of booked | **2** | 10–50% | **3** | 1–10% | **4** | < 1%, latent heat structural |
|---|---|---|---|---|---|---|---|---|---|

### 3. Constitutive honesty — *is each quantity a relation where physics says relation?*
Count of surviving "scalar where a relation belongs" defects. This shape has appeared five times: `rc_of`,
`rock_fill`, `carbon_total`, `boil_c`, `ATMOS_OPTICAL_DEPTH`.

| **0** | never audited | **1** | > 10 outstanding | **2** | 4–10 | **3** | 1–3, each with a stated reason and bounded error | **4** | none; every state-dependent quantity is a function with its validity range stated |
|---|---|---|---|---|---|---|---|---|---|

### 4. Computed, not asserted — *does the substrate derive its answers?*
Count of prescribed targets, outcome-deciding clamps, constant rates where a driving force belongs, and
processes ignoring a variable they physically depend on.

| **0** | never audited | **1** | > 15 | **2** | 6–15 | **3** | 1–5, each disclosed at its site | **4** | none outside declared numerical guards, each shown never to bind |
|---|---|---|---|---|---|---|---|---|---|

### 5. Seed minimality — *how much is the planet told?*
Read off the `world_seed` manifest. **Deleting seeding code is the score going up.**

| **0** | the interesting state is placed directly |
|---|---|
| **1** | sea, lakes, water table, surface temperature and atmosphere all asserted |
| **2** | ocean placed, but atmosphere and water table emerge |
| **3** | no ocean placed; water seeded as vapour/ice and condenses |
| **4** | post-Theia: a molten body and a bulk composition. Ocean, atmosphere and crust are OUTPUTS |

### 6. Instrument integrity — *can the numbers be believed?*

| **0** | claims argued from state variables | **1** | gauges exist, some read the wrong quantity | **2** | right quantities, no per-pass attribution | **3** | per-pass attribution for the leaking substances | **4** | every gauge mutation-tested, every gate seen to fail on purpose |
|---|---|---|---|---|---|---|---|---|---|

## Two hard couplings between criteria

- **5 cannot exceed 2 until 2 is at 3.** An ocean condensing out of a steam atmosphere *is* a latent-heat
  process; without it a post-Theia seed fails for reasons that have nothing to do with the seed.
- **1 is gated on 6.** Mineral is the only substance that conserves (−0.03%) and the only one with a
  per-pass probe. Everything else has a global total, which says a number moved and never where.

## Score history

Append a row per landing. Never edit a past row: a rubric that is rewritten backwards measures nothing.

*(The first row was hand-totalled as 8 and is 7. The error was in the hand-entered half, on the first
attempt, by the person who wrote the rubric — which is the whole argument for `physics_score.sh` computing
what it can. Corrected before the row was committed rather than left as a struck entry, because it had never
been published.)*

| date | commit | 1 matter | 2 energy | 3 constitutive | 4 computed | 5 seed | 6 instrument | **total** | what moved |
|---|---|---|---|---|---|---|---|---|---|
| 2026-08-09 | `0177274` | 1 | 1 | 1 | 1 | 1 | 2 | **7 / 24** | first score, after the three-audit baseline |

### Notes on the opening score

- **1 = 1.** C −26.7%, H₂O −19.5%, O₂ −90.3%, oxidant −56.2%, N −2.1% per 600 frames from the seal.
  Mineral alone is −0.027% and would score 3.
- **2 = 1.** `scripts/physics_score.sh` puts `energy_residual / energy_booked` at **1742** — the unbooked
  remainder is three orders of magnitude larger than everything the books can name. Sixteen
  reaction records cross a phase or chemical boundary booking zero joules; evaporative cooling, the largest
  term in Earth's surface energy budget, does not exist in the substrate.
- **3 = 1.** 17 confirmed scalar-where-a-relation-belongs defects plus 10 physical quantities missing
  entirely (dry-air gas constant, pascals-per-world-unit, thermal expansion, magma viscosity, salinity,
  saturation over ice, grain size for airborne phases, …).
- **4 = 1.** `heat3d_cool_sphere3d.glsl` is provably a 100 °C thermostat; most reaction rates are fitted
  per-step fractions; `params.dt` is uploaded to the reaction kernel and never read.
- **5 = 1.** The manifest's `temp_ground_p50` is exactly `INITIAL_TEMP`.
- **6 = 2.** Per-pass probes exist for energy and mineral only. Demerit noted:
  `check_physical_constants.sh` reports green across three mutually inconsistent representations of the
  latent-heat curve, because it binds the kernel to whichever one it happens to match.
