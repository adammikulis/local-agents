# PLANET GEOPHYSICS — emergent deep-earth arc (design)

The maintainer's mandate, restated and hardened 2026-08-03: **the planet must be LOCKED DOWN before any
creature work resumes** ("creatures can't have realistic behavior without realistic water"). Creature work is
not merely lower priority — it is premature, and doing it now wastes it, because behaviour fitted to a broken
substrate has to be redone. `CLAUDE.md` → "SCOPE RULE" carries the measurable bar; `HANDOFF.md`'s 0.5 section
is parked until it is met. This doc captures the emergent-geophysics arc — what's DONE, and
the design for the big pieces (real fracturing → plate tectonics, giant impacts, Theia). All of it follows
**dissolve-don't-patch / one substrate**: named phenomena (fault, rift, subduction, mountain, moon) have zero
dedicated code — they're what the substrate physics does. NOTE: the maintainer has OK'd FAKING tectonics, but
only as scripted plate KINEMATICS that DRIVE the substrate; the Voronoi cartoon that only rolled dice into a
disaster spawner is deleted, and a plate model that does not move crust does not qualify. These interlock with
the terrain SDF, heat field, lava, and shock, so they want a design pass with the maintainer, not a blind one-shot.

## Substrate we already have (the ingredients)
- **Interior heat — RADIOGENIC, and nothing else.** ~~A finite reservoir seeded at real temperatures
  maintains the geotherm and slowly cools.~~ **That reservoir, its core temperature, the seeded Fourier
  profile and the boundary flux are deleted.** The rock's own decay (`LAPhysical.RADIOGENIC_W_PER_KG` on the
  mass each cell holds) is the whole source; conduction carries it and the surface radiates it, and the
  gradient is the outcome. A run covers hours of planet time and radiogenic warming is a megayear process,
  so the observed gradient will read near flat — that is the honest answer, not a reason to seed one back.
- **Magma / lava** — `_lava`, magma buoyancy (`magma_buoy_sphere3d`), lava flow, phase change (melt/solidify).
  Eruptions now draw from a FINITE mantle reserve; the vent used to be documented as "effectively infinite",
  which meant every island this planet ever built was made of matter that did not exist.
- **Rock as fractional bedrock** — `rock_fill` (GPU-owned); `solid` derived from it. Terrain is one SDF that can
  be carved (`carve_sphere`) + filled (`fill_box`), and rock solidifies/melts by temperature. It advects with
  the plates now, so continents genuinely drift. ONE composition, though — no mineralogy, no strata.
- **Shock waves** — `_shock` propagating seismic field (impacts/tremors inject it; terrain muffles it).
- **Groundwater AQUIFER — WORKING, and springs run.** *(Corrected 2026-08-03. This said "DONE → perennial
  springs/rivers", which was false — there were none. Then it said the only defect was slot-order greed in the
  outflow loop, which was also wrong: the greed was ~10% of it. The kernel had NO unsaturated-conductivity
  term, so regolith drained at its SATURATED conductivity down to zero water.)* Real media obey
  K = K_sat·k_r(S_e) and hold water against gravity below the residual saturation — that is field capacity,
  and it is why a real root zone is the wettest part of a profile after rain. Both fixed: the water table is
  surface-following (saturation ramp 1:65 → 1:2.3), lateral discharge exceeds downward percolation, and
  groundwater discharges at the surface. ~~Hot~~ springs: `--hotspring-test` used to hand the rock beneath
  the vent a reservoir draw, so the heat was injected, not found. That draw is deleted and the discharge
  is as warm as the rock it passed through. Conductivity is now computed from
  per-cell porosity and grain size (Kozeny-Carman) rather than one number for all regolith.
- **N-body gravity + bodies** — `LAGravity`, `LAPlanetBody`, a moon, orbits (moving-frame). Test-particle pull.

## 1. Real FRACTURING (task #15) — prerequisite for everything below
Impacts + stress must be able to CRACK the crust, not just crater it. Today `--auto-barrage` carves deep +
throws an ejecta cloud, but the body stays whole. Emergent fracture: the brittle crust carries a **stress**
field (from impact shock, thermal gradients, mantle drag); where stress exceeds local **rock strength**, the
SDF is cut along the stress concentration = a **fault/fissure**. A large enough impact fractures a whole region;
a Theia-scale hit shatters the body. Needs: a crust-stress channel + a fracture rule that carves the SDF along
stress maxima (and, for true shatter, spawns SDF fragments as independent gravitating bodies — the hard part).

## 2. Emergent PLATE TECTONICS (task #17) — the payoff
Built on 1 + the heat engine, entirely emergent:
1. **Mantle convection** — the core→surface heat gradient + magma buoyancy drives convection cells (hot mantle
   rises, cool sinks). This already half-exists; make it a genuine circulating flow in the deep field. THE ENGINE.
2. **Crust stress** — convection drags the crust from below; drag + thermal + impact stress accumulate.
3. **Fracture into PLATES** — where stress exceeds strength the crust cracks (system 1). The connected unbroken
   regions between cracks ARE the plates — no plate is "defined", it's what's left between faults.
4. **Plate motion** — each crust region advects with the mantle flow beneath it (the crust rides the convection).
5. **Boundaries emerge** — divergent: plates pull apart → a **rift**, upwelling lava freezes into **new seafloor**
   (seafloor spreading, for free from lava solidification). Convergent: plates collide → crust **buckles up into
   mountains**, or one **subducts** (dives under, melts → **arc volcanoes** from the melt reaching the surface).
   Transform: plates grind past → **faults**, and a quake is a stress RELEASE the substrate would have to
   carry as elastic strain; today it carries none, so nothing may inject one. Continents drift; mountains,
   volcanoes, quakes localize at boundaries — all falling out of the physics, none of them written as systems.

## 3. Giant impacts / THEIA (task #16)
A body-sized impactor arrives under N-body gravity and collides. Tractable first version (reuses meteor/heat/
ejecta scaled way up): a magma-ocean heat pulse + massive ejecta + global shock — a cataclysm that reshapes +
melts the surface. Full version: true body-splitting (system 1) + debris that re-accretes into the moon.

## Sequencing
`aquifer (WORKING)` → `real fracturing (#15)` → `mantle convection engine` → `plate tectonics (#17)` → giant impacts
/ Theia (#16) ride on the fracturing. This is the deep-geophysics half of "grow the planet" — the erosion/
sediment/glacier arc in `ROADMAP_0.5.md` is the surface half; together they make the planet genuinely alive.
