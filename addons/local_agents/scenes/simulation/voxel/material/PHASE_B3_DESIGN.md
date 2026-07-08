# Phase B3 — Generic DEFS Reaction Engine + Water-Cycle Unification (sphere path)

**Design spike only — no code changed.** Targets the cubed-sphere kernels
(`material/kernels3d/*_sphere3d.glsl`) + pass modules (`material/sphere_passes/*.gd`) orchestrated by
`material/MaterialSphereGPU3D.gd`. The box path (`*3d.glsl` without `_sphere`) is being deleted
(TODO.md B2-WIRE step 5) and is **not** a target.

North stars this obeys: *dissolve-don't-patch* (measure success in special-case code **deleted**),
*GPU-GLSL-only, no CPU oracle*, *perf-over-parity* (behavioural verification, not bit-exact CPU↔GPU).

---

## 1. Reaction inventory (every hand-coded chemical/phase reaction on the sphere path)

Legend for **Class**: **CLEAN** = same-cell reactants→products driven by a local threshold/rate →
subsumable by a generic reaction record. **SPECIAL** = cross-cell transport or SDF/geometry edit → stays
bespoke.

| # | Reaction | Kernel : line | Pass module | Transfer (this cell) | Class | Rationale |
|---|----------|---------------|-------------|----------------------|-------|-----------|
| R1 | **Evaporation** water→vapor | `atmos_evap_sphere3d.glsl:64-65` | `AtmospherePass.gd:160-165` | `vapor += EVAP_RATE*warmth` (today does **not** debit water → non-conserving) | **CLEAN** | per-cell, gated `water>WATER_MIN && open_above`; driver = temp. 2a makes it a true transfer `water-=e`. |
| R2 | **Condensation** vapor→cloud/fog | `atmos_condense_sphere3d.glsl:107-126` | `AtmospherePass.gd:182-186` | `cond=(vap-sat)*CONDENSE_RATE*(1+oro)`; vapor→cloud (aloft) or fog (cold+near-ground) | **CLEAN** (but **deleted** by 2a) | excess-over-threshold `vap>sat(T)`, product self. 2a makes cloud/fog *derived*, so this stops being a stored step at all (the `oro` neighbour test is a rate modifier only). |
| R3 | **Re-evaporation** cloud/fog→vapor | `atmos_condense_sphere3d.glsl:127-133` | same | `fr=f*CLOUD_REEVAP_RATE` when `vap<sat` | **CLEAN** (**deleted** by 2a) | const-frac; becomes free/instant under derivation. |
| R4 | **Condensate decay** | `atmos_condense_sphere3d.glsl:134-135` | same | `c*=(1-CLOUD_DECAY)` | **CLEAN** (**deleted** by 2a) | const-frac decay to null; a fudge only needed because cloud/fog were stored. |
| R5 | **Boiling** water→steam | `atmos_condense_sphere3d.glsl:140-149` + drain `atmos_rain_sphere3d.glsl:70` | `AtmospherePass.gd:182-194` | `boil=water*bfrac`, `vap+=boil` at `T>BOIL_TEMP` | **CLEAN** | excess-over-threshold in temp; same-cell water→airwater. The two-kernel split (gain in condense, debit in rain) is only a ping-pong artifact — semantically one same-cell transfer. |
| R6 | **Rain shed** cloud→rain | `atmos_condense_sphere3d.glsl:151-155` | same | `rain=(c-RAIN_CLOUD_THRESHOLD)*RAIN_RATE` into scratch | **SPECIAL** | the cloud debit is same-cell, but the rain mass then **falls to the ground column** (R7) — a cross-cell transport. |
| R7 | **Rain deposit** (gather) | `atmos_rain_sphere3d.glsl:45-73` | `AtmospherePass.gd:191-194` | rain from self+above → `water` at first grounded cell | **SPECIAL** | cross-cell: routes rain inward (slot 0) to ground. |
| R8 | **Lava solidify** lava→rock | `lava_phase_sphere3d.glsl:47-52` | `ThermalPass.gd:150-155` | `solid=1; lava=0` when `T<SOLIDIFY_TEMP` | **SPECIAL** | **edits geometry** (`solid` mask → SDF stamp + CPU mesh tail). Not a mass reaction. |
| R9 | **Lava sustain-heat** | `lava_phase_sphere3d.glsl:53-58` | same | `temp = max(temp, molten(lava))` | **CLEAN** (marginal) | same-cell, driver = lava mass, product = temp; but it is a `max()` **floor-clamp**, not a debit/credit transfer → needs a `RELAX/CLAMP` rate model, see §2. Low value; recommend deferring. |
| R10 | **Magma pressure-melt / buoy** | `magma_buoy_sphere3d.glsl:64-89` | `ThermalPass.gd:158-170` | overpressure lava + carry-heat buoyed to cell above | **SPECIAL** | cross-cell (slot 5/slot 0 gather) transport. |
| R11 | **Gas sky O₂ refill** | `gas_sky_sphere3d.glsl:55` | `GasWindPass.gd:148-152` | `o2 += SKY_EXCHANGE*(O2_AMBIENT-o2)` at surface | **CLEAN** | same-cell relax-toward-target, gated surface (slot 5 = space/rock). `RELAX_TARGET` model. |
| R12 | **Gas CO₂ sky vent** | `gas_sky_sphere3d.glsl:56` | same | `co2 -= CO2_SKY_VENT*co2` at surface | **CLEAN** | same-cell const-frac decay, gated surface. |
| R13 | **Combustion chemistry** fuel+O₂→CO₂ | `fire_sphere3d.glsl:111-115` | `FireDustPass.gd:119-124` | `fuel-=BURN_RATE·f; o2-=BURN_O2_RATE·f; co2+=CO2_PER_BURN·f` | **CLEAN** (subsumable, but see note) | same-cell multi-reactant/product, driver = fire. **Gate is multi-condition** (`fire>FIRE_MIN && fuel>0 && o2≥O2_MIN && water≤WET_MAX`) → needs a richer gate mask; recommend phase-2. |
| R14 | **Fire spread / ignition / heat-pin** | `fire_sphere3d.glsl:86-102,120-121` | same | ember gather from neighbours; fire STATE transitions; `temp` pin | **SPECIAL** | ember/plume are **cross-cell**; ignite/extinguish/grow is a **state machine**, not a mass transfer. |
| R15 | **Fungus decompose** detritus+O₂→CO₂+fert | `fungus_sphere3d.glsl:100-118` | `EcoSurfacePass.gd:206` | `consumed=DECOMPOSE_RATE·g·d` (capped by d and by `o2/O2_PER_DECOMPOSE`); `co2+=…; o2-=…; fert_scratch=…` | **CLEAN** (canonical) | same-cell **bilinear** (fungus×detritus), multi-product, reactant_cap + aux-cap (o2), fert product → **scratch** buffer (`fungus_fert`). Perfect reaction-record fit. |
| R16 | **Fungus growth / spread / death** | `fungus_sphere3d.glsl:82-95,120-126` | same | spore gather; `g += GROW_RATE·d·moist`; decay | **SPECIAL** | spore term is **cross-cell**; growth/death is non-conservative population dynamics, not a mass transfer. |
| R17 | **Snow accrete** precip→snow | `snowice_sphere3d.glsl:69-70` | `EcoSurfacePass.gd:208` | `depth += precip*SNOW_FALL_RATE` when cold | **SPECIAL** | reactant (`precip`) is an external push scalar, not a channel; snow is a surface-gated bespoke field. |
| R18 | **Snow melt** snow→meltwater | `snowice_sphere3d.glsl:71-76` | same | `depth-=melted; water += melted*SNOW_WATER_YIELD` | **SPECIAL** | surface-gated on a bespoke snow field; couples to the freeze/thaw **geometry** (water→ice `solid` stamp) CPU tail. Kept special per TODO.md:230. |
| R19 | **Photosynthesis** CO₂→O₂+growth | `Plant.gd:152-` (CPU actor via `field.photosynthesize`) | — (not a kernel) | daylight-gated `co2-=; o2+=` | **CLEAN in principle / BLOCKED** | same-cell, daylight-gated — but there is **no vegetation/biomass field channel** (plants are actor nodes), so it cannot be a pure field reaction yet. See §5 note. |

**Also present, not reactions** (pure transport/derivation, excluded): `o2_transport`, `co2_transport`,
`atmos_transport` (diffuse/advect), `scent_*`, `dust_*`, `shock`, `wind_pressure`/`wind_step`,
`heat3d_solar`/`heat3d_buoyancy`/`heat3d_cool` (energy forcing/relaxation, not chemistry),
`erosion_*` (cross-cell, sphere ports absent anyway — `EcoSurfacePass.gd:39-41`).

**Subsumable by the generic engine (this phase):** R1, R5 (water cycle, via 2a), R11, R12, R15, plus R13
and R9 as deferred candidates. R2/R3/R4 are **deleted** by 2a rather than moved. Everything else stays
bespoke. That is ~6-8 records live now, ~9-11 counting the deferred R13/R9/R19 — matching TODO.md:227.

---

## 2. The DEFS reaction record schema

A reaction is a fixed-size record. Records live in a read-only SSBO (one array), authored once in a
GDScript `LAReactionDefs` resource and uploaded at `setup()`. GLSL cannot index arbitrary buffers by a
runtime id, so **every channel a record can touch is bound at a fixed binding**, and a record names a
channel by a **slot enum** (§3) resolved through `read_ch(slot,i)` / `add_ch(slot,i,v)` helpers.

```
struct Reaction {          // std430, 64 bytes (16-float aligned)
    int   rate_model;      // 0 CONST_FRAC · 1 BILINEAR · 2 EXCESS_OVER_THRESHOLD · 3 RELAX_TARGET
    float rate_k;          // rate constant
    float threshold;       // driver threshold (EXCESS) or target value (RELAX_TARGET)
    int   gate_mask;       // bitflags: 1 OPEN_ABOVE · 2 SURFACE · 4 NEAR_GROUND · 8 DAYLIGHT (0 = none)

    int   driver_slot;     // channel slot whose value drives the rate
    int   driver2_slot;    // second multiplicand for BILINEAR (-1 if unused)
    int   cap_slot;        // aux reactant-cap channel, e.g. o2 (-1 if none)
    float cap_coeff;       // consumed*cap_coeff <= cap_slot value (e.g. O2_PER_DECOMPOSE)

    int   product_target;  // 0 SELF · 3 SCRATCH  (BELOW/COLUMN-TOP are SPECIAL, not supported here)
    int   n_react;         // count of reactant entries used below
    int   n_prod;          // count of product entries used below
    int   pad;

    int   react_slot[4];   // reactant channel slots
    float react_coeff[4];  // per-reactant coeff (mass removed = coeff * extent)
    int   prod_slot[4];    // product channel slots
    float prod_coeff[4];   // per-product coeff (mass added = coeff * extent)
};
```

**Extent computation** (the single per-cell rule the kernel evaluates for each record):

```
float drv = read_ch(driver_slot, i);
float x;                                   // reaction extent (>= 0 for transfers)
if      (rate_model == CONST_FRAC)            x = rate_k * drv;
else if (rate_model == BILINEAR)              x = rate_k * drv * read_ch(driver2_slot, i);
else if (rate_model == EXCESS_OVER_THRESHOLD) x = max(0.0, drv - threshold) * rate_k;
else /* RELAX_TARGET */                       x = rate_k * (threshold - drv);   // signed; relax toward `threshold`

if (!gate_ok(gate_mask, i)) x = 0.0;
// reactant caps: extent can't drive any reactant negative
for (r in 0..n_react) x = min(x, read_ch(react_slot[r], i) / react_coeff[r]);   // (RELAX_TARGET skips: it has no reactant)
if (cap_slot >= 0)    x = min(x, read_ch(cap_slot, i) / cap_coeff);

for (r in 0..n_react) add_ch(react_slot[r], i, -react_coeff[r] * x);
for (p in 0..n_prod)  deposit(product_target, prod_slot[p], i, prod_coeff[p] * x);
```

`RELAX_TARGET` is the exception: it has zero reactants, a single "product" that is the driver channel
itself, and `x` may be signed (`o2 += rate_k*(ambient - o2)`); it skips the reactant-cap loop.
`deposit(SELF,...)` writes the live/back cell; `deposit(SCRATCH,...)` writes a dedicated per-cell scratch
buffer (the fungus-fert pattern, `EcoSurfacePass.gd:166`).

### Example records (concrete, using real constants)

**Fungus decompose (R15) — bilinear, multi-product, aux-cap, scratch target** (canonical):
```
rate_model=BILINEAR  rate_k=0.05 (DECOMPOSE_RATE)  threshold=0
driver_slot=FUNGUS  driver2_slot=DETRITUS   gate_mask=0
cap_slot=O2  cap_coeff=0.8 (O2_PER_DECOMPOSE)
n_react=2: [DETRITUS×1.0, O2×0.8]           product_target=SELF/SCRATCH
n_prod=2:  [CO2×1.0 (CO2_PER_DECOMPOSE)→SELF, FERT×1.5 (FERT_PER_DECOMPOSE)→SCRATCH]
```
(fert to SCRATCH `fungus_fert`; CO₂/O₂ to SELF. Matches `fungus_sphere3d.glsl:102-116` exactly.)

**Gas CO₂ sky vent (R12) — const-frac decay, surface-gated:**
```
rate_model=CONST_FRAC  rate_k=0.25 (CO2_SKY_VENT)  gate_mask=SURFACE
driver_slot=CO2  n_react=1:[CO2×1.0]  n_prod=0  product_target=SELF
```

**Gas O₂ sky refill (R11) — relax-to-ambient, surface-gated:**
```
rate_model=RELAX_TARGET  rate_k=0.5 (SKY_EXCHANGE)  threshold=1.0 (O2_AMBIENT)  gate_mask=SURFACE
driver_slot=O2  n_react=0  n_prod=1:[O2×1.0 → SELF]   (x signed; add_ch(O2,x))
```

**Boiling (R5) — excess-over-threshold, water→airwater:**
```
rate_model=EXCESS_OVER_THRESHOLD  rate_k=0.02 (BOIL_RATE)  threshold=100.0 (BOIL_TEMP)
driver_slot=TEMP  n_react=1:[WATER×1.0]  n_prod=1:[AIRWATER×1.0 → SELF]  gate_mask=0
```
(BOIL_MAX_FRAC cap is naturally covered by the reactant cap on WATER; the static-sea steam branch
`atmos_condense_sphere3d.glsl:143-144` becomes a second record gated `static`, or stays a tiny bespoke line.)

**Combustion chemistry (R13) — deferred, shown for completeness** (multi-condition gate is the blocker):
```
rate_model=CONST_FRAC  rate_k=1.0  driver_slot=FIRE  gate_mask=BURNING(new bit)
n_react=2:[FUEL×0.045(BURN_RATE), O2×0.06(BURN_O2_RATE)]  n_prod=1:[CO2×0.06(CO2_PER_BURN)→SELF]
```

---

## 3. Generic kernel + pass module

### `reactions_sphere3d.glsl` (new)

One per-cell dispatch that loops all records. Static bindings for every channel a record may touch
(std430 storage buffers), a `nbr` table (binding 15) + `radial`(14) for gates, a solar buffer or
`sun_dir` push for DAYLIGHT, and the record SSBO.

```
binding 0..N-1  : the reactable channels (fixed slot enum below), each a float[] (live/back chosen by the pass)
binding 20      : Scratch { float scratch[]; }   // SCRATCH product target (e.g. fungus_fert)
binding 21      : ReactionDefs { Reaction recs[]; } (readonly)
binding 14 radial, 15 nbr, 5..7 solid/... as needed for gates
push_constant   : { uint cell_count; uint n_records; float dt; float pad; } (+ sun_dir if DAYLIGHT used)
```

**Channel slot enum** (compile-time `#define`s; `read_ch/add_ch` are switch-ladders over these):
`TEMP=0 WATER=1 AIRWATER=2 O2=3 CO2=4 FUEL=5 FIRE=6 DETRITUS=7 FUNGUS=8 FERT=9 LAVA=10`.
Add slots only as records need them — keep the ladder small (perf: it is a branch per access).

**Gate helpers** reuse the exact tests already proven in the kernels:
`SURFACE` = `nbr[i*6+5] < 0 || solid[up]!=0` (`gas_sky_sphere3d.glsl:50-51`);
`OPEN_ABOVE` = `atmos_evap_sphere3d.glsl:55-59`; `NEAR_GROUND` = walk slot 0 (`atmos_condense_sphere3d.glsl:61-73`);
`DAYLIGHT` = `max(0,dot(radial,sun_dir)) > PHOTO_LIGHT_MIN` (`Plant.gd:30`).

Race-freedom: every write is `add_ch(SELF,i,·)` or `scratch[i]=·` — **own cell only**, so the single
dispatch is order-independent across cells. Records that both consume and produce the *same* channel in
one cell are applied sequentially per cell (fine — serial within a thread).

### `ReactionsPass.gd` (new pass module)

Follows the existing plugin contract (`setup(rd,bufs,cc)` / `dispatch(rd,cl,phase,ctx,cc,groups)`),
identical shape to `EcoSurfacePass.gd`. It:
1. compiles `reactions_sphere3d.glsl`, allocates the SCRATCH buffer (or reuses `bufs["fungus_fert"]`);
2. uploads the record SSBO from an `LAReactionDefs` array (authored in GDScript, immutable);
3. builds **two uniform sets** (per ping-pong phase) binding each slot's channel to `bufs[key][phase]`
   for live-role channels;
4. `dispatch()` records one bind+push+dispatch(+barrier).

### Dispatch-order placement

The generic reactions read **settled** temp/water (after `ThermalPass`, pass 2) and **settled** o2/co2
(after `GasWindPass`, pass 3) and airwater (after `AtmospherePass`, pass 4). Because the whole sphere
pipeline already tolerates one-step coupling lags (`MaterialSphereGPU3D.gd:19-20`), the simplest correct
placement is a **single ReactionsPass inserted after Atmosphere**, i.e. new order in
`MaterialSphereGPU3D.gd:35-41`:

```
WaterSlumpLava → Thermal → GasWind → Atmosphere → REACTIONS → FireDust → EcoSurface
```

Rationale: at that slot temp/water/o2/co2/airwater are all in their post-step (`back`) state, so evap,
boil, sky-exchange and (when moved) fungus-decompose all read fresh inputs. Fungus-decompose (R15) can
either move here (reading fresh detritus) or stay in `fungus_sphere3d.glsl` for now — moving it lets us
**delete** the decompose block from `fungus_sphere3d.glsl:100-118`, shrinking that kernel to pure
growth/spread/death (R16), which is the dissolve win. Keep the fungus **growth/spread** kernel in
EcoSurface (it is cross-cell). One extra pass = one extra submit+sync; negligible vs the deletions.

> If a later profile shows the one-step lag matters for a specific record, that record's subset can be
> dispatched at its producer's slot instead (records carry no ordering; the pass can be invoked more than
> once with different record ranges). Not needed for v1.

---

## 4. Water-cycle unification (2a) — one conserved `airwater` channel

### Conserved formulation

Replace the three PAIR channels `vapor`/`cloud`/`fog` with **one** PAIR channel `airwater` = total water
mass suspended in the air of a cell. **Nothing else stores condensate.** Given the existing saturation
curve (already the query anchor, `MaterialAtmosphere3D.gd:522`, `:527`):

```
sat(T)      = SAT_BASE * exp(SAT_TEMP_GAIN * (T - EVAP_TEMP_REF))     // SAT_BASE=0.06, gain=0.055, ref=22
vapor(i)    = min(airwater[i], sat(T))                    // gaseous part
condensed(i)= max(0.0, airwater[i] - sat(T))              // suspended liquid/ice
fog(i)      = condensed  if (T < FOG_MAX_TEMP && near_ground(i))  else 0
cloud(i)    = condensed  if not the fog condition                 else 0
```

This is **derived, instantaneous, mass-neutral** — the cloud/fog split is exactly the label test at
`atmos_condense_sphere3d.glsl:122-126`, now applied at read time. `airwater` changes **only** through real
mass transfers:

- **Evaporation (R1, now conserving):** `water -= e; airwater += e` — fixes today's bug where
  `atmos_evap_sphere3d.glsl:65` adds vapor without debiting water (mass created). Reaction record.
- **Boiling (R5):** `water -= b; airwater += b` at `T>BOIL_TEMP`. Reaction record.
- **Rain (R6/R7, stays SPECIAL):** a small `atmos_precip_sphere3d.glsl` computes `condensed`, sheds
  `rain = max(0, condensed - RAIN_MASS_THRESHOLD) * RAIN_RATE`, does `airwater -= rain` and writes the rain
  scratch; the existing `atmos_rain_sphere3d.glsl` gather deposits it to the ground column (unchanged).
- **Transport:** `airwater` advects/diffuses **conservatively** through the existing
  `atmos_transport_sphere3d.glsl`, run **once** (not 3×).

### Vertical rise folds into buoyant wind

**Drop `VAPOR_RISE`/`CLOUD_RISE`** (`AtmospherePass.gd:52-53`) and the transport `rise_frac` term
(`atmos_transport_sphere3d.glsl:68-79`). Instead advect `airwater` by the **full velocity field**
(`vel_x, vel_y, vel_z`) the same way `co2_transport_sphere3d.glsl` already advects CO₂. Humid/warm air
rises because it is buoyant in the wind field (`wind_step` buoyancy term), not because of a per-channel
constant — strictly more emergent, and it deletes two constants + a kernel branch.

> Requires the transport kernel to read `vel_y` (add binding) and advect on the radial axis via
> slots 0/5, mirroring `co2_transport_sphere3d.glsl`. This is the one net *addition*; it pays for
> deleting the `rise_frac` special-case and the 3-channel duplication.

### Condensation is NOT a reaction record — it disappears

Because cloud/fog are derived from `airwater` vs `sat(T)`, **condensation, re-evaporation, and cloud
decay (R2/R3/R4) stop existing as discrete steps** — they are an instantaneous equilibrium read. This is
the elegant composition with 2b: the only water-cycle *reactions* left in the engine are the true
transfers **evap + boil**; rain stays the one cross-cell special. Net: 3 PAIR channels → 1, and the
condense kernel's entire dewpoint/re-evap/decay block is deleted.

### What changes / is deleted

- **`MaterialSphereGPU3D.gd:24-25`** — `PAIR_CHANNELS`: remove `"vapor","cloud","fog"`, add `"airwater"`.
  `end_frame:140` returns list + `_empty_result:238-247`: swap vapor/cloud/fog → airwater.
- **`AtmospherePass.gd`** — shrinks drastically:
  - **DELETE** the CONDENSE stage + `atmos_condense_sphere3d.glsl` (R2/R3/R4 gone; boil moves to a
    record; rain-shed moves to `atmos_precip`).
  - **DELETE** the three separate TRANSPORT dispatches (`AtmospherePass.gd:169-178`); keep **one**
    transport dispatch on `airwater` with full-wind advection.
  - **DELETE** the EVAP stage (`:160-165`) — becomes a reaction record.
  - **KEEP** rain gather (`atmos_rain_sphere3d.glsl`), fed by the new tiny `atmos_precip_sphere3d.glsl`.
  - Constants `VAPOR_DIFFUSE`/`CLOUD_DIFFUSE`/`FOG_DIFFUSE`/`*_RISE`/`*_WIND_GAIN`/`ORO_CONDENSE_GAIN`
    (`:49-58`) collapse to a single `AIRWATER_DIFFUSE` + `AIRWATER_WIND_GAIN` (oro boost optionally kept
    as a rain-shed modifier, or dropped).
- **Kernels deleted:** `atmos_condense_sphere3d.glsl`. **Renamed/edited:** `atmos_transport_sphere3d.glsl`
  (one channel, +vel_y). **New:** `atmos_precip_sphere3d.glsl` (derive condensed → rain scratch).
  `atmos_evap_sphere3d.glsl` deleted (folded into reaction record).
- **Queries (derive, keep signatures):** `MaterialAtmosphere3D.gd:540 cloud_at`, `:552 fog_at`,
  `:581 cloud_grid`, `:585 fog_grid`, `avg_cloud_cover`, `precipitation` — recompute from
  `airwater + temp` via the derivation above. `MaterialFieldQueries3D.gd:520 relative_humidity_at`,
  `:529 dewpoint_at` already use `sat()`; swap `_vapor[idx]` → `min(_airwater[idx], sat)`. Readers
  `RainLayer.gd:78-87`, `Thunderstorm.gd:82,208` are unchanged (facade intact).
- **CPU field arrays** (`_vapor/_cloud/_fog`) collapse to `_airwater`; the sphere readback
  (`_sphere_process`, TODO.md step 2) applies `airwater`+`temp`; queries derive.

---

## 5. Implementation checklist (ordered, sized for implementer subagents)

Do all of this in the `feature/sphere-spike` worktree; verify booted + headless before merge.

**Stage A — airwater unification (2a) first (it reshapes the atmosphere pass the engine slots into):**
1. `MaterialSphereGPU3D.gd`: `PAIR_CHANNELS` vapor/cloud/fog → `airwater`; fix `end_frame` +
   `_empty_result`. (1 file)
2. New `kernels3d/atmos_transport_sphere3d.glsl` edit: single channel, add `vel_y` binding + radial
   (slot 0/5) advection, delete `rise_frac`. Model on `co2_transport_sphere3d.glsl`. (1 kernel)
3. New `kernels3d/atmos_precip_sphere3d.glsl`: per-cell derive `condensed = max(0, airwater - sat(T))`,
   shed rain to scratch, `airwater -= rain`. (1 kernel)
4. Delete `kernels3d/atmos_condense_sphere3d.glsl`, `kernels3d/atmos_evap_sphere3d.glsl` (+ `.import`).
5. Rewrite `AtmospherePass.gd`: transport(×1 airwater) → precip → rain-gather. Delete evap/condense/×3
   transport wiring + dead constants. (1 file)
6. Rewrite query derivations: `MaterialAtmosphere3D.gd` cloud_at/fog_at/grids/covers,
   `MaterialFieldQueries3D.gd` relative_humidity_at/dewpoint_at. Collapse `_vapor/_cloud/_fog` → `_airwater`.
7. Verify: booted window + `--run-frames=N` SIM_REPORT; confirm clouds/rain still emerge, no NaN, fps.

**Stage B — generic reaction engine (2b):**
8. New `LAReactionDefs.gd` resource: author records R1(evap), R5(boil), R11(O₂ sky), R12(CO₂ vent),
   R15(fungus decompose). Define the channel slot enum. (1 file)
9. New `kernels3d/reactions_sphere3d.glsl`: bindings + `read_ch/add_ch` ladder + gate helpers + record
   loop + extent rule (§2/§3). (1 kernel)
10. New `sphere_passes/ReactionsPass.gd`: compile, upload record SSBO, per-phase uniform sets, dispatch.
    Model on `EcoSurfacePass.gd`. (1 file)
11. `MaterialSphereGPU3D.gd:35-41`: insert `ReactionsPass` after `AtmospherePass` in `PASS_SCRIPTS`.
12. Delete the now-duplicated logic from the source kernels: evap/boil already gone (Stage A);
    `gas_sky_sphere3d.glsl:55-56` (R11/R12) — delete + drop `gas_sky` from `GasWindPass.gd`;
    `fungus_sphere3d.glsl:100-118` decompose block (R15) — delete, leaving growth/spread/death.
13. Verify: SIM_REPORT behavioural checks (§6); confirm the deleted paths' behaviour is reproduced by the
    records (fungus still rots detritus→CO₂+fert; caves still suffocate; CO₂ still vents at surface).

**Deferred (own follow-up, not this phase):** R13 combustion chemistry (needs a `BURNING` gate bit),
R9 lava sustain (needs a `CLAMP`/floor rate model), R19 photosynthesis (needs a vegetation/biomass field
channel — flag to user: today plants are actor nodes, so this is a *held-back-by-architecture* item; a
`biomass` channel would let photosynthesis + plant growth dissolve into the field too).

---

## 6. Risks + behavioural SIM_REPORT proofs (perf-over-parity)

**Risks**
- **airwater mass conservation:** evap/boil are now debit+credit pairs and transport is a conservative
  gather, but a coeff/sign slip creates or destroys water. Guard with a conservation assert (below).
- **Derivation cost:** `cloud_at` column loops (`MaterialAtmosphere3D.gd:544`) now call `exp()` per cell —
  cache `sat(T)` or accept it (column loops are small). Watch fps.
- **`read_ch/add_ch` switch ladder** is a branch per channel access → keep the slot enum minimal; if a
  hot record dominates, that record can graduate to its own tiny kernel.
- **Gate correctness:** SURFACE/OPEN_ABOVE/NEAR_GROUND must match the originals bit-for-bit *behaviourally*
  (not numerically) — reuse the exact neighbour tests cited in §3.
- **One-step lag** at the new ReactionsPass slot is the accepted norm (`MaterialSphereGPU3D.gd:19-20`); if a
  record visibly lags, dispatch its subset at the producer slot.
- **Ordering of deletes:** never grow a kernel past limits; these are net deletions, low size risk.

**Behavioural checks (assert emergent aggregates, not CPU parity):**
- **Water cycle conserved:** track `sum(water) + sum(airwater) + rain_to_ground` across N frames — total
  moved is bounded and non-negative; no runaway (airwater not exploding, not draining to 0 under stable T).
  Add `airwater_total`, `wet_cells`, `cloud_cells`, `rain_intensity` to SIM_REPORT (TODO.md step 2 already
  wants fuller readback).
- **Clouds/fog still emerge:** `cloud_cells > 0` over humid regions; fog appears cold + near ground;
  raising solar (evaporation) then cooling produces condensed mass and rain — same qualitative cycle as
  pre-unify.
- **Reaction engine reproduces deleted behaviour:**
  - Fungus: with detritus present + damp + cool, `sum(detritus)` **decreases** while `sum(co2)` **increases**
    and `sum(fert)` accrues; `o2` draws down; rot halts when `o2→0` (aerobic cap) — same as
    `fungus_sphere3d.glsl:106-116`.
  - Gas: a sealed cave cell's `o2` draws down and stays low (no SURFACE gate) while a sky-exposed cell
    relaxes to `O2_AMBIENT`; surface `co2` vents toward 0. Confirms the SURFACE gate.
  - Boil: a cell held `>100°C` over water shows `water` falling and `airwater` rising by the same amount.
- **No NaN / no negative mass** in any channel readback; counts sane; **fps ≥ pre-B3** (fewer kernels: 3
  atmosphere transports → 1, condense deleted; one added reactions pass).
- Manual: booted window, Temperature + cloud debug views, confirm weather still visibly runs and a wildfire
  still spreads + emits CO₂ (fire spread stays in `fire_sphere3d.glsl`; only its chemistry could move later).

---

### Net dissolve tally (success = code deleted)
**Deleted:** `atmos_condense_sphere3d.glsl`, `atmos_evap_sphere3d.glsl`, 2 of 3 atmosphere transport
dispatches, `VAPOR_RISE`/`CLOUD_RISE`/`FOG_*`/`ORO_CONDENSE_GAIN` constants + `rise_frac` term, the
gas_sky kernel body, the fungus decompose block, 2 PAIR channels (`cloud`,`fog`).
**Added:** one conserved `airwater` channel, `atmos_precip_sphere3d.glsl`, `reactions_sphere3d.glsl`,
`ReactionsPass.gd`, `LAReactionDefs.gd`. Named phenomena (condensation, fog, decomposition, breathing)
now fall out of one substrate + one generic rule.
