# PHYSICS_RUBRIC.md — how good is the substrate

The standard the simulation is scored against. `CLAUDE.md` holds the process rules and `HANDOFF.md` the
map of what is left; this holds the measurement of how physical the thing is.

The governing question is `CLAUDE.md`'s Rule Zero: does the real world work this way? The answer is a
number computed by `scripts/physics_score.sh` (`scripts/agent_harness.sh score`), never a judgement, because
the person scoring is the person who did the work. Nobody hand-enters a criterion.

**No score is recorded while `HANDOFF.md` or `docs/PHYSICS_TODO.md` holds an open item, or while the run
that would produce it is withheld for engine errors.** A reading off a substrate with a known defect is the
interaction of that day's defects, and two such readings differenced are a difference between fictions
(`CLAUDE.md` Rule 1b). `scripts/check_doc_prose.sh` fails the build on a row that violates this.

## The ten criteria

Each scored **0–4**. Anything that cannot be measured scores **0 for that reason alone**.

### 1. Matter conserved — *is anything created or destroyed?*
Per element, |drift| over the verification arm from the world seal, mask-free, **in moles**. A raw channel
sum is not admissible: it sums unlike units and its sign can differ from the mole count.

| 0 | unmeasured, or measured in a unit that is not a quantity |
|---|---|
| **1** | > 10% |
| **2** | 1 – 10% |
| **3** | 0.1 – 1% |
| **4** | < 0.1%, and every remaining change booked to a named mechanism |

### 2. Energy residual — *is every joule accounted for?*
Energy is **not** closed and must not be — sunlight enters and longwave leaves every step. The score is
`energy_residual_rel`, the residual as a fraction of `energy_turnover_j` (what crossed the boundary), never
drift, and never a fraction of `energy_booked`, which passes through zero at radiative equilibrium. The run
book weighs enthalpy plus kinetic energy (`energy_held`); the field stores specific enthalpy, so pressure
work rides with the mass and the equation of state restates pressure inside every substep.

| **0** | no `energy_residual_rel` | **1** | residual > 50% of turnover | **2** | 10–50% | **3** | 1–10% | **4** | < 1%, latent heat structural |
|---|---|---|---|---|---|---|---|---|---|

### 3. Constitutive honesty — *is each quantity a relation where physics says relation?*
The count of constants in `docs/MODEL_PARAMETERS.md` that are neither bound to an authority nor derived
from other constants. A scalar where a relation belongs is a row in that registry, so this is a population
a gate maintains, not an audit somebody must remember to redo.

| **0** | never audited | **1** | > 10 outstanding | **2** | 4–10 | **3** | 1–3, each with a stated reason and bounded error | **4** | none; every state-dependent quantity is a function with its validity range stated |
|---|---|---|---|---|---|---|---|---|---|

### 4. Computed, not asserted — *does the substrate derive its answers?*
The subset of criterion 3's population whose recorded reason says it is a prescribed target, an
outcome-deciding clamp, a presence floor, or a rate fitted to one timestep — the registry's own `why`
column.

| **0** | never audited | **1** | > 15 | **2** | 6–15 | **3** | 1–5, each disclosed at its site | **4** | none outside declared numerical guards, each shown never to bind |
|---|---|---|---|---|---|---|---|---|---|

### 5. Seed minimality — *how much is the planet told?*
Read off the `world_seed` manifest (`LAMaterialFieldSeal3D.note_creation`). Deleting seeding code is the
score going up.

| **0** | the interesting state is placed directly |
|---|---|
| **1** | sea, lakes, water table, surface temperature and atmosphere all asserted |
| **2** | ocean placed, but atmosphere and water table emerge |
| **3** | no ocean placed; water seeded as vapour/ice and condenses |
| **4** | post-Theia: a molten body and a bulk composition. Ocean, atmosphere and crust are OUTPUTS |

### 6. Instrument integrity — *can the numbers be believed?*
How many substances criterion 1 finds drifting, and how many of those have a per-pass probe
(`LA_MINERAL_BUDGET`, `LA_H2O_BUDGET`, `LA_ENERGY_BUDGET`). A global total says a number moved and never
where.

| **0** | claims argued from state variables | **1** | gauges exist, some read the wrong quantity | **2** | right quantities, no per-pass attribution | **3** | per-pass attribution for the leaking substances | **4** | every gauge mutation-tested, every gate seen to fail on purpose |
|---|---|---|---|---|---|---|---|---|---|

### 7. Momentum booked — *is the moving air and water accounted for like the matter and heat are?*
The residual of the momentum ledger (`MaterialFieldMomentumLedger3D`, `momentum_residual_rel`) as a
fraction of what it booked. Wind and flow carry momentum, pressure gradients and gravity create it, drag
destroys it; a substrate booking two of mechanics' three conserved quantities is not looking at the third.

| **0** | no momentum ledger | **1** | residual > 50% of booked | **2** | 10–50% | **3** | 1–10% | **4** | < 1% |
|---|---|---|---|---|---|---|---|---|---|

### 8. Emergence — *do named phenomena have dedicated code?*
The count of per-phenomenon actor scripts under `addons/local_agents/sim/actors` plus the special-case
symbols inside them, weighted as `physics_score.sh` states. A named phenomenon is a detector, never a
cause; the one exemption is a genuine external cause such as a meteor. This criterion goes up by deleting
files.

| **0** | never counted | **1** | > 12 weighted | **2** | 5–12 | **3** | 1–4 | **4** | none; disaster actors are seeds, markers and visuals only |
|---|---|---|---|---|---|---|---|---|---|

### 9. Determinism — *does the same seed give the same planet?*
Two runs at one seed and one length: the worst relative difference across the conserved totals
(`scripts/check_determinism.sh`). Without this no comparison between runs means anything.

| **0** | not measured | **1** | > 1% | **2** | 0.1–1% | **3** | 1e-6 – 0.1% | **4** | bit-identical |
|---|---|---|---|---|---|---|---|---|---|

### 10. Observer independence — *does looking at it change it?*
An arm with no `--ui` against the same run with the presentation layer on, over the conserved totals and
`energy_stock` (`scripts/check_observer_independence.sh`). No rate may change because of where the camera
points, what the framerate is, or which gauge is switched on. A probe narrowed to the quantities expected
to be fine cannot see a defect in the others.

| **0** | not measured | **1** | > 1% | **2** | 0.1–1% | **3** | 1e-6 – 0.1% | **4** | bit-identical |
|---|---|---|---|---|---|---|---|---|---|

## Two hard couplings between criteria

- **5 cannot exceed 2 until 2 is at 3.** An ocean condensing out of a steam atmosphere is a latent-heat
  process; without it a post-Theia seed fails for reasons that have nothing to do with the seed.
- **1 is gated on 6.** A substance with no per-pass probe has a global total, which says a number moved
  and never where.

## Score

`scripts/agent_harness.sh score` prints the row. It is appended here only under the condition at the top
of this file; until then the table is empty. A past row is never edited.

| commit | 1 matter | 2 energy | 3 constitutive | 4 computed | 5 seed | 6 instrument | 7 momentum | 8 emergence | 9 determinism | 10 observer | **total** |
|---|---|---|---|---|---|---|---|---|---|---|---|
