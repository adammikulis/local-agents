# Fakes

Every stand-in the running world is carried by. A fake supplies life with something the field cannot yet
produce; it holds the same seam as the real thing, so the swap is a switch rather than a deletion. Each
record is a three-way switch on `LAAblate`, beside the processes and the modules: `off` supplies nothing
(the honest absence, as the physics says), `fake` the registered stand-in, `real` the field's own process
answering through the same query. The default is `fake` while the record's rung is outside the run's
`LAProcessSet` and `real` once the run contains it; `--ablate=<name>:off|fake|real` sets one at launch and
the switch panel sets one mid-run.

`LAFakes.RECORDS` is the list the code reads and this page is the list a person reads;
`scripts/check_fakes.sh` holds them to each other and fails when a record whose rung is green has no real
seam to hand the world to. `scripts/check_fakes_states.sh` runs the life demo in one process, once in the
defaults and once per record `off`, and reads every record in all three states at the seam. The world reads a
stand-in through `LAFakes.stands_in` alone, so a run in `real` is the run in `off`.

A fake makes matter. `LAFakes.report()` says how much, per fake, in the run's own report, and
`fake_states` there says which state every record is in.

| fake | stands in for | real when | real seam | seam |
|---|---|---|---|---|
| `drinking_water` | Rain, springs and rivers wetting ground away from the sea. Nothing on this world moves water over the surface, so an animal born inland can never reach any. | `ADVECT` | `c._material.drink_water(pos, want)` | `addons/local_agents/creatures/creature/CreatureThirst.gd` |
| `breathable_o2` | Free atmospheric oxygen. The seeded 4.4 Ga air has none, so nothing that breathes can oxidise anything. | `CHEMISTRY` | `c._material.respire_at(pos, want)` | `addons/local_agents/creatures/creature/CreatureRespiration.gd` |
| `plant_carbon` | Photosynthesis fixing CO2 into standing biomass under a plant, which a plant then draws on. | `CHEMISTRY` | `_material.graze_biomass(pos, want_mass)` | `addons/local_agents/sim/actors/Plant.gd` |
| `founding_stock` | The matter a body is built out of. A creature that appears after the world sealed has no field to build itself from and no parent stock to draw on, so its elements are made here and booked. | `CHEMISTRY` | absent | `addons/local_agents/sim/material/MaterialFieldBiota3D.gd` |
| `population_caps` | Carrying capacity. What bounds a population is the energy and carbon its ground fixes; with none on the field, an authored ceiling holds each species' numbers instead. | `CHEMISTRY` | `p.feed(SEED_RESERVE_COST)` | `addons/local_agents/sim/ecology/EcologyPlants.gd` |
| `recruitment_rate` | How many young a school produces, which is the food its adults convert into eggs. No field feeds a fish, so a fraction of the mature adults spawns each tick instead. | `CHEMISTRY` | absent | `addons/local_agents/sim/ecology/EcologyBreeding.gd` |
| `species_tables` | Traits read off a genome's loci, sorted by what survives. Speed, senses, diet, hierarchy and which tree grows where are read from authored per-species rows instead. Body mass in kilograms is the one measured number a row may carry: the body's carbon, water, metabolic rate and mouth rate all derive from it. | `0.5 (traits from DNA loci)` | absent | `addons/local_agents/sim/ecology/EcologyService.gd` |
