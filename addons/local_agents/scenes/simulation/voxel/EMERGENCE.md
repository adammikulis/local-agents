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
  advertises itself: the corpse deposits a decaying `"carrion"` scent into the shared `LAScentField`.
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
