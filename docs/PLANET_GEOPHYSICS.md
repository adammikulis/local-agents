# PLANET GEOPHYSICS — emergent deep-earth arc (design)

The maintainer's mandate: **a realistic planet comes before more creature work** ("creatures can't have
realistic behavior without realistic water"). This doc captures the emergent-geophysics arc — what's DONE, and
the design for the big pieces (real fracturing → plate tectonics, giant impacts, Theia). All of it follows
**dissolve-don't-patch / one substrate**: named phenomena (fault, rift, subduction, mountain, moon) have zero
dedicated code — they're what the substrate physics does. NOTE: the maintainer has OK'd FAKING tectonics (scripted plates whose boundary KINEMATICS drive emergent volcanism/quakes/uplift) since true geodynamics is research-grade. These interlock with the terrain
SDF, heat field, lava, and shock, so they want a design pass with the maintainer, not a blind one-shot.

## Substrate we already have (the ingredients)
- **Radial heat field** — hot core (pinned ~1300°C) → cool surface, conducted through the crust (rock insulates
  ~6× air). The geothermal ENGINE.
- **Magma / lava** — `_lava`, magma buoyancy (`magma_buoy_sphere3d`), lava flow, phase change (melt/solidify).
- **Rock as fractional bedrock** — `rock_fill` (GPU-owned); `solid` derived from it. Terrain is one SDF that can
  be carved (`carve_sphere`) + filled (`fill_box`), and rock solidifies/melts by temperature.
- **Shock waves** — `_shock` propagating seismic field (impacts/tremors inject it; terrain muffles it).
- **Groundwater AQUIFER (DONE, 0.4)** — regolith permeability band + bedrock floor + Darcy flow → perennial
  springs/rivers. `soil_sphere3d`. Realistic surface + subsurface water.
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
   Transform: plates grind past → **faults + earthquakes** (shock injection). Continents drift; mountains,
   volcanoes, quakes localize at boundaries — all falling out of the physics, none of them written as systems.

## 3. Giant impacts / THEIA (task #16)
A body-sized impactor arrives under N-body gravity and collides. Tractable first version (reuses meteor/heat/
ejecta scaled way up): a magma-ocean heat pulse + massive ejecta + global shock — a cataclysm that reshapes +
melts the surface. Full version: true body-splitting (system 1) + debris that re-accretes into the moon.

## Sequencing
`aquifer (DONE)` → `real fracturing (#15)` → `mantle convection engine` → `plate tectonics (#17)` → giant impacts
/ Theia (#16) ride on the fracturing. This is the deep-geophysics half of "grow the planet" — the erosion/
sediment/glacier arc in `ROADMAP_0.5.md` is the surface half; together they make the planet genuinely alive.
