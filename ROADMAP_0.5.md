# ROADMAP 0.5 — Emergent Geology & Deep Substrate

Items deliberately **deferred from 0.4 to 0.5** during the water-cycle work. 0.4 gets the *starting* world
right (noise-seeded planet, working hydrology); 0.5 is where the planet becomes **grown, not stamped** —
real geology, erosion, and sediment transport, all emergent (dissolve-don't-patch, one substrate). Keep this
list current as things are deferred. See also the `emergent-geology-0.5` memory and `EMERGENCE.md`.

## 1. Grow the planet by pre-simulating geology, then freeze it as the start state
Run the emergent geology forward (volcanism extrudes land, erosion carves it, sediment builds it up), then
**freeze the result** as the campaign start — the planet is *grown*, not noise-stamped. Prereq: the erosion +
sediment substrate below.

## 2. Emergent erosion + sediment-transport substrate
The through-line is **matter moves**: erosion picks it up, deposition lays it down, fertility follows the
deposits. All emergent field/physics — roll into `MaterialField3D` where possible; no scripted per-feature code.
- **Hydraulic erosion** — flowing water (the real rivers from 0.4) carves valleys and *carries* sediment,
  depositing beaches, deltas, floodplains, alluvial fans. Coasts erode.
- **Glaciers** — water freezes into ice that *flows* downhill under gravity and *cuts* through the landscape
  (U-valleys, fjords), depositing moraines on melt.
- **Thermal weathering** — rock breaks down on steep/cold slopes into loose sediment (feeds granular slump).
- **Aeolian (wind) transport** — *wind carries dust/sediment* and deposits it downwind: "the Saharan desert
  feeds the Amazon with nutrients." Dust = a field channel riding the existing wind, raising fertility where
  it lands (couples to the biosphere carbon/nutrient loop).

## 3. Full 3D groundwater aquifer → emergent, head-pressured springs
0.4 shipped the **vertical** water table (soil infiltration/storage/baseflow + the dry-crust flash-flood hump).
The **lateral / 3D** half is deferred here because the surface-following sphere grid makes it hard: a ridge's
surface-soil sits several radial shells *above* the adjacent valley's, so true ridge→valley groundwater flow
must go *through* the rock (full 3D Darcy), and without a modeled **impermeable bedrock floor** naive downward
percolation just sinks all the water to the core.
- Model a bedrock floor (a permeable regolith depth) so groundwater pools in a shallow surface-following band.
- Head-driven Darcy flow through the aquifer (head = water-table elevation): water recharged high flows down
  through the rock and **daylights as springs** wherever the table meets the surface, pressured by the head.
- Then **delete the seeded-spring placeholder entirely** — springs, wetlands, oases, and perennial rivers all
  emerge from the recharged table. (0.4 uses snowmelt-recharged table baseflow as the tractable stand-in.)

---
*0.4 water shipped: ocean-heavy Voronoi planet · land-biased spawn · mass-scaled water sweep + plant rooting ·
emergent cloudburst floods + smite governor · vertical soil water table (persistence, flash-flood realism,
baseflow, conservation) · snowmelt-recharged springs. Disease/pests (0.4 W-TRAITS) and off-camera statistical
creature LOD are 0.4 backlog, not 0.5.*
