# Fakes

Every stand-in the running world is carried by. A fake supplies life with something the field cannot yet
produce; it holds the same seam as the real thing, so the swap is a deletion. `LAFakes.RECORDS` is the
list the code reads and this page is the list a person reads; `scripts/check_fakes.sh` holds them to each
other and fails the moment `docs/PLAYABLE_RUNG` reaches a row's replacing rung.

A fake makes matter. `LAFakes.report()` says how much, per fake, in the run's own report.

| fake | stands in for | replaced by | seam |
|---|---|---|---|
| `drinking_water` | Rain, springs and rivers wetting ground away from the sea. Nothing on this world moves water over the surface, so an animal born inland can never reach any. | `ADVECT` | `addons/local_agents/creatures/creature/CreatureThirst.gd` |
| `breathable_o2` | Free atmospheric oxygen. The seeded 4.4 Ga air has none, so nothing that breathes can oxidise anything. | `CHEMISTRY` | `addons/local_agents/creatures/creature/CreatureRespiration.gd` |
| `plant_carbon` | Photosynthesis fixing CO2 into standing biomass under a plant, which a plant then draws on. | `CHEMISTRY` | `addons/local_agents/sim/actors/Plant.gd` |
| `population_caps` | Carrying capacity. What bounds a population is the energy and carbon its ground fixes; with none on the field, an authored ceiling holds each species' numbers instead. | `CHEMISTRY` | `addons/local_agents/sim/ecology/EcologyPlants.gd` |
| `recruitment_rate` | How many young a school produces, which is the food its adults convert into eggs. No field feeds a fish, so a fraction of the mature adults spawns each tick instead. | `CHEMISTRY` | `addons/local_agents/sim/ecology/EcologyBreeding.gd` |
| `species_tables` | Traits read off a genome's loci, sorted by what survives. Speed, senses, diet, hierarchy and which tree grows where are read from authored per-species rows instead. | `0.5 (traits from DNA loci)` | `addons/local_agents/sim/ecology/EcologyService.gd` |
