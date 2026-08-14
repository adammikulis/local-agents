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

**ALL SIX ARE COMPUTED, AND NOBODY MAY HAND-ENTER A ROW.** `scripts/physics_score.sh` reads 1, 2 and 5 out
of `SIM_REPORT`, and 3, 4 and 6 out of `docs/MODEL_PARAMETERS.md` and the probe coverage. It prints the row
ready to paste. Run it with `scripts/agent_harness.sh score`.

*(Changed 2026-08-11, and the first run proved the point immediately. Criteria 3, 4 and 6 used to be audit
counts entered by hand, described right here as "the ones to distrust" — and they were. On a landing that
rebuilt the instruments, I would have hand-entered criterion 6 as a 3. The script says **2**: four of the six
drifting substances still have no per-pass probe, which is the band's literal wording. The half a person
scores is the half that moves.)*

## The ten criteria

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
**Computed:** the count of constants in `docs/MODEL_PARAMETERS.md` that are neither bound to an authority
nor derived from other constants. A scalar where a relation belongs IS a number in that registry — the gate
counts them on every lint, so this has a real population instead of an audit somebody must remember to redo.
This shape has appeared five times by hand: `rc_of`, `rock_fill`, `carbon_total`, `boil_c`, and a greybody
optical depth standing in for a band model.

| **0** | never audited | **1** | > 10 outstanding | **2** | 4–10 | **3** | 1–3, each with a stated reason and bounded error | **4** | none; every state-dependent quantity is a function with its validity range stated |
|---|---|---|---|---|---|---|---|---|---|

### 4. Computed, not asserted — *does the substrate derive its answers?*
**Computed:** the subset of criterion 3's population whose recorded REASON in the registry says it is a
prescribed target, an outcome-deciding clamp, a presence floor, or a rate fitted to one timestep — the
registry's own `why` column, written when each row was filed.

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
**Computed:** how many substances criterion 1 finds drifting, and how many of those have a per-pass probe
(`LA_MINERAL_BUDGET`, `LA_H2O_BUDGET`, `LA_ENERGY_BUDGET`). A global total says a number moved and never
where; attribution is the difference between a diagnosis and a symptom.

| **0** | claims argued from state variables | **1** | gauges exist, some read the wrong quantity | **2** | right quantities, no per-pass attribution | **3** | per-pass attribution for the leaking substances | **4** | every gauge mutation-tested, every gate seen to fail on purpose |
|---|---|---|---|---|---|---|---|---|---|

### 7. Momentum booked — *is the moving air and water accounted for like the matter and heat are?*
**Computed** from the presence and residual of a momentum ledger. Matter has ledgers and energy has one.
Momentum has none — wind and flow carry it, pressure gradients and gravity create it, drag destroys it, and
nothing sums it. A substrate booking two of mechanics' three conserved quantities is not measuring the
third, it is not looking.

| **0** | no momentum ledger | **1** | residual > 50% of booked | **2** | 10–50% | **3** | 1–10% | **4** | < 1% |
|---|---|---|---|---|---|---|---|---|---|

### 8. Emergence — *do named phenomena have dedicated code?*
**Computed** as the count of per-phenomenon actor scripts plus the special-case symbols inside them
(`_is_erupting`, `BOMBS_PER_BURST`, burst timers). `CLAUDE.md`'s north star: "volcano", "eruption",
"tornado" are words humans put on what the physics does, not systems anyone writes, and success is measured
in special-case code DELETED. This is the only criterion that goes up by deleting files.

| **0** | never counted | **1** | > 12 weighted | **2** | 5–12 | **3** | 1–4 | **4** | none; disaster actors are seeds, markers and visuals only |
|---|---|---|---|---|---|---|---|---|---|

### 9. Determinism — *does the same seed give the same planet?*
**Computed** from two runs at one seed and one length: the worst relative difference across the conserved
totals. Without this, no A/B means anything and parallel universes cannot be compared at all — a difference
between two seed vectors is unreadable if the same vector does not reproduce itself.

| **0** | not measured | **1** | > 1% | **2** | 0.1–1% | **3** | 1e-6 – 0.1% | **4** | bit-identical |
|---|---|---|---|---|---|---|---|---|---|

### 10. Observer independence — *does looking at it change it?*
**Computed** from a `--bare` arm against the same run with the presentation layer on, over the conserved
totals AND `energy_stock`. A lockdown criterion in `CLAUDE.md`: no rate may change because of where the
camera points, what the framerate is, or which gauge is switched on. It is also the precondition for a
throughput sweep with the probes off.

**`scripts/check_observer_independence.sh` is the gate, and it must be run BEFORE any other number is
trusted.** *(Added 2026-08-11. This criterion first scored on the element totals alone and read 3.83%.
Including `energy_stock` took it to **87.13%** — the same substrate, a wider probe. A criterion that omits
a quantity cannot see a defect in it, which is the rubric's own argument for computing rather than judging,
turned on the rubric. Do not narrow a probe to the quantities you expect to be fine.)*

| **0** | not measured | **1** | > 1% | **2** | 0.1–1% | **3** | 1e-6 – 0.1% | **4** | bit-identical |
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

*(The denominator changed on 2026-08-11 from 24 to 40, when four criteria were added. Past rows keep their
own denominator — a rubric rewritten backwards measures nothing — so read the columns, not the totals,
across that boundary.)*

| date | commit | 1 matter | 2 energy | 3 constitutive | 4 computed | 5 seed | 6 instrument | 7 momentum | 8 emergence | 9 determinism | 10 observer | **total** | what moved |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-08-09 | `0177274` | 1 | 1 | 1 | 1 | 1 | 2 | — | — | — | — | **7 / 24** | first score, after the three-audit baseline |
| 2026-08-11 | `dd64de9` | 1 | 1 | 1 | 1 | 1 | 2 | 0 | 1 | 1 | 1 | **10 / 40** | all ten computed; three new criteria measured for the first time |
| 2026-08-11 | `00f994b` | 1 | 1 | 1 | 1 | 1 | 2 | 0 | 1 | 1 | 1 | **10 / 40** | criterion 10 re-measured against energy: 3.8% -> **87.1%** |

### Notes on 2026-08-11 — four criteria added, and they found three things nothing was watching

**7 = 0.** There is no momentum ledger at all. Matter has ledgers, energy has one, and the third conserved
quantity of mechanics is unmeasured.

**8 = 1.** Eight named-phenomenon actor scripts survive — Earthquake, Flood, Hurricane, LightningStrike,
Meteor, Thunderstorm, Tornado, Volcano — plus three special-case symbols. This is the criterion that goes
up by deleting files, and it is the project's own north star.

**9 = 1. THE SIM IS NOT REPRODUCIBLE.** Two runs at the same seed and the same length differ by 0.41% in a
conserved total. That is new information: every A/B this project has ever quoted was taken against a
substrate that does not repeat itself, and parallel universes cannot compare seed vectors until it does.

**10 = 1.** `--bare` differs by 3.83%. The whole-mirror upload was one mechanism and closing it did not
close the property, so the standing rule holds: no conservation number may be quoted from a `--bare` run.

### Notes on 2026-08-11 (six-criterion half) — a day of work, and the score did not move

**That is the honest result and it is worth more than a point would have been.** The landing rebuilt the
INSTRUMENTS, not the physics: cells got a real volume (they differ by up to 8.8x and nothing weighted by
it), the energy ledger stopped calling model-units-cubed "joules", `element_C_mol` became moles, the
conservation gate stopped evaluating once and going blind, and four gates were added. None of that makes
the planet conserve anything — it makes the failure legible.

- **1 = 1.** Worst is mineral at +52.4%; carbon +15.8%, h2o +41.7%, o2 +21.4%, oxidant +15.0%, N +2.5%.
  Mineral is the one to chase: it is the same ORDER of drift as carbon but carries a ceiling four orders
  tighter, and the per-pass probe says no sampled pass produces it while `solid_cells` grows 31978 -> 53935.
- **2 = 1.** `energy_residual / energy_booked` reads 150772. It read 1742 before the unit fix, which is not
  an improvement in the physics and not a regression either: the old figure divided a stock short by
  METRES_PER_MODEL_UNIT^3 by a flux short by the square of it, so the ratio carried a spurious factor of
  168.6. The residual is now measured in real joules against real watts and is simply very large.
- **3 = 1, 4 = 1.** 611 constants in the registry are neither bound nor derived; 453 of those are recorded
  as a clamp, a floor, or a per-step fitted rate. Both are now populations that a gate maintains rather
  than counts from a remembered audit.
- **5 = 1.** Unchanged. `INITIAL_TEMP` and the placed ocean are still there; that is Stage 4.
- **6 = 2, and I would have written 3.** Four of the six drifting substances — carbon, nitrogen, o2,
  oxidant — have no per-pass probe. 18 gates exist.

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
