# Design principle: emergent-everything

This simulation is built so that **complex, believable behavior arises from simple local rules
interacting** — not from scripted, hardcoded, or centrally-directed cases. When adding anything,
prefer a general rule that many agents evaluate locally over a special case for a specific pair,
species, or scenario.

## What this means in practice

- **No hardcoded relationships.** Predator/prey, fear, and flocking are driven by *properties*
  (diet, size, species, heading) and *proximity*, not by "if fox and rabbit" tables.
  - Fleeing a predator = "flee any nearby creature that **hunts** and is **≥1.2× my size**"
    (`Creature._nearest_larger_predator`). That single rule makes rabbits flee foxes *and* humans,
    foxes flee humans, and the biggest hunters fear nothing — with zero per-pair code. Add a bigger
    hunter later and everything smaller flees it automatically.
  - Hunting = "chase the nearest creature in my `preys_on`, eat on contact." Humans hunt because
    their config lists prey, not because of a `Villager.hunt()` method.
- **Flocking is imitation, universal.** Every ground species runs the same three local boids forces
  (cohesion / alignment-imitation / separation); only the *weights* differ per species. "Do what
  nearby same-kind do" is the core — herds, flocks, and packs are the same rule at different tunings.
- **Terror is a broadcast stimulus, not a scripted reaction.** Violent events (meteor impacts)
  `broadcast_scare(pos, radius, intensity)`; any creature that "hears/feels" it (`add_fear`) panics
  and sprints away, intensity falling off with distance. Any future loud/violent event can reuse the
  same channel — no new per-event creature code.
- **The world is data, edited live.** Terrain is a signed-distance field; destruction is just
  `carve_sphere`. Craters, debris, and exposed strata are consequences of the edit, not pre-authored.
- **Animals are cues to resources, not just competitors ("watch the vultures").** A carcass
  advertises itself: the corpse deposits a decaying carrion/food scent into the shared `MaterialScent3D`
  channels of `LAMaterialField3D` (the old `LAScentField` markers are retired).
  Aerial scavengers (vultures) do one thing — *follow the strongest food cue* — so they home on that
  scent and circle above it, descending from cruise altitude to feed. A circling/feeding animal is
  itself a cue: it is visible (vision cone) and audible (an omnidirectional `"carrion"` call). Ground
  scavengers (foxes, humans) run the *same* "investigate the strongest food cue" rule over three
  channels — sight, smell, sound — and so converge on the kill by reading the flyers.
  - No hardcoded `vulture→human` link: it is one general behaviour, and "more vultures = a stronger
    signal" just falls out of counts (kettle intensity summing on each channel).
  - The tendency is *both* faintly innate and learned: a scavenger that follows a cue and gets fed has
    that heuristic reinforced (`LACognition` reward), so it fires more readily next time.
  - Reinforced habits spread — socially to kin (vision/sound-gated imitation) and genetically to
    offspring — so a population *culturally learns to read the vultures* over generations, with no
    per-species scavenging script.
- **Nesting & natal philopatry are an emergent clustering force.** A species with the config flag
  `nests` establishes a home site the first time it settles (birds roost/nest in a tree, ground
  species dig a burrow). Breeding happens at the nest and offspring inherit the site (fidelity), so
  kin *cluster in space* over generations — colonies, rookeries, and warrens are all the same rule at
  different tunings.
  - Clustering feeds the cultural machinery: because social learning is vision/sound-gated and
    kin-weighted, philopatric families become **cultural units** — habits (including "watch the
    vultures") spread fastest among relatives who grew up in the same place.
  - Roosting is the same home-drive on the day/night clock: return to the nest when `is_night()`.
  - It is all config/properties + local rules (the `nests` flag, a stored home position, a return
    force) — no scripted per-species colony code.

## Emergent field processes (the same principle, over ONE shared substrate)

The physical world runs the same way: there is a single simulation field, `LAMaterialField3D`, and
every weather/geological/ecological force is a **module that steps local rules over its shared
channels** — never a scripted actor puppeteering an outcome. Because they all read and write the same
cells, they compose for free (scent rides the real wind and washes out in the real rain; a lightning
bolt's heat pulse ignites real fuel that spreads on the real wind). The "disaster" actors have shrunk
to visuals that seed a source and *read back* the feature the field produces.

- **Scent + waste are stigmergy, not tables (`MaterialScent3D`).** Creatures don't query each other's
  positions to find prey; they lay musk DERIVED from their own size/diet/hunger/wounds/panic into
  airborne channels (prey/predator/blood/food/alarm) and drop feces/urine/blood, and predators simply
  *walk up `scent_gradient(PREY)`*. Waste also deposits a soil FERTILITY channel, and plants regrow
  where fertility peaks — so grazing pressure and vegetation recovery couple through the ground with no
  bookkeeping. It all diffuses, advects on the local wind, decays, and washes in rain, like a real
  smell would.
- **Volcanoes bore their own conduit (`MaterialMagma3D`).** No scripted eruption timeline: a deep hot
  magma source has overpressure that melts the rock above it, so a conduit *carves itself* upward and
  the mountain erupts episodically when pressure wins. `Volcano.gd` just seeds the source and reads
  `magma_erupting()` for FX.
- **Storms are a rotation term, not a strength envelope (`MaterialWind3D`).** Adding a single
  Coriolis-like rotation to the pressure-driven wind makes any pressure low *spin*; tornadoes,
  mesocyclones, and hurricanes are the same emergent vortex at different seed strengths. The storm
  actors seed a low and read `vorticity_at`/`updraft_at` — the intensity is whatever the field spins up.
- **Lightning is charge separation, not a rain trigger (`MaterialCharge3D`).** Charge accumulates
  where convective updrafts lift cold cloud (`vel_y`×cloud×cold); when it exceeds breakdown it fires a
  bolt to the tallest ground, dumping a heat pulse (which can ignite a wildfire through the ordinary
  combustion rule) and a scare stimulus. Storms that make lightning make *fires* without anyone wiring
  the two together.
- **Erosion / snow / dust / shock are all the same move.** Water carrying sediment cuts canyons and
  builds deltas (`MaterialErosion3D`); snowpack accretes where it's cold and melts to meltwater where
  it's warm (`MaterialSnowIce3D`); wind lofts dry sediment into dust storms and migrates dunes
  (`MaterialDust3D`); a propagating pressure wave carries an earthquake's shake and startle outward
  (`MaterialShock3D`, which replaced a point-based seismic ring). Each is a local rule over a channel,
  so each rides the wind, water, and heat that are already there.
- **Temperature is conserved energy, so the treeline draws itself (`MaterialHeat3D`).** Heat is not a
  free-floating number that can be manufactured: conduction/buoyancy move bounded energy, a radiative
  sink bleeds hot dry plumes toward space, and a steep adiabatic lapse cools rising air — so summits get
  genuinely cold, snow accretes, and the *germination gate* (a cell too cold or snow-covered can't sprout)
  stops trees below the snow. Nobody paints a treeline altitude; it's wherever energy says it's too cold.
- **Air is a real gas mix — fire has to breathe (`MaterialGas3D` + `MaterialCombustion3D`).** Oxygen (`_o2`)
  is a transported channel: combustion CONSUMES it, so a fire in a sealed cave draws down its trapped O₂
  and suffocates, while the same fire in open wind roars because the wind keeps replenishing it — no
  "is-this-enclosed" special case, just a gas that flows. Burning emits CO₂ (`_co2`), a denser gas that
  advects on the wind but SETTLES downward and pools in hollows (a suffocation cue creatures read), and
  vents where it reaches open sky.
- **Photosynthesis + decay close one carbon loop (`Plant.gd`, `MaterialFungus3D`).** In daylight a living
  plant FIXES local CO₂ back into O₂ + growth, so a plant downwind of a fire scrubs the drifted CO₂ and
  shoots up. When an animal dies its carcass (and burnt-out fuel → ash) sheds DETRITUS into the ground;
  wherever detritus meets damp shade, **fungus** blooms, rots it — freeing CO₂ to the air, depositing soil
  FERTILITY, and drawing down O₂ (aerobic decay) — and spreads by spores, dying back in drought/fire/frost.
  The fertility it makes feeds the same plant-seeding that grazing waste feeds, so **rot becomes regrowth**:
  animal → carcass → detritus → fungus → CO₂ + fertility → new plants → O₂ → animals. A closed
  carbon/oxygen/nutrient cycle nobody scripted — every leg is a local rule over the one field.

The test is the same as for creatures: canyons, dune fields, tornado-spawned fires, manure-fed meadows,
snow-capped peaks that stop the forest, cave fires that smother themselves, and mushrooms fruiting on the
dead to feed the living are things we did not script — they *fall out* of local rules sharing one field.

## How to add new behavior (the rule of thumb)

1. Express it as a **local rule** an individual agent evaluates from what it can sense
   (nearby groups, distances, its own config properties).
2. Drive differences through **config/properties**, not branches on identity.
3. If you're about to write `if species == "X"`, ask whether a property (size, diet, a new
   scalar trait) could express the same thing generally.
4. Couple systems through **stimuli/broadcasts** (like `broadcast_scare`) so new events compose
   with existing reactions.

The measure of success: behaviors we didn't explicitly write (stampedes away from a strike, foxes
scattering when a human wanders in, herds reforming after a scare) should *fall out* of the rules.
