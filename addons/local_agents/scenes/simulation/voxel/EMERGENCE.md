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
