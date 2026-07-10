class_name LACreatureDigestion
extends RefCounted

## Gut buffer + digestion for LACreature — the Phase 2 owner-file for turning ingested food into energy
## and waste over time, replacing today's instant-feed path.
##
## Today eating is instantaneous: LACreatureThink credits food value straight to `energy` at the moment
## of the bite (that path stays in CreatureThink — it is not moved here). Phase 2 routes a bite through a
## gut instead: a bite adds biomass to a per-creature gut buffer, and this module ticks that buffer down,
## converting biomass to energy at a digestive efficiency (scaled by the creature's microbiome/diet fit)
## while the indigestible remainder becomes the feces that LACreatureExcretion deposits. That makes diet
## fit, gut fill (satiety vs. hunger), and digestion time emergent rather than a single instant transfer.
##
## Intended interface (Phase 2 — not built yet; sketch only, no behaviour today):
##   static func ingest(c, biomass: float, quality: float) -> void   # a bite adds to the gut buffer
##   static func tick(c, delta: float) -> void                       # digest buffer -> energy (+ queue waste)
##   static func gut_fill(c) -> float                                # 0..1 satiety, for the hunger drive
##
## The gut-buffer state (contents, fill, in-flight waste) will live on the creature as plain fields once
## this lands, so a Phase 2 agent owns digestion here without editing Creature.gd's brain. This stub exists
## so that owner boundary is claimed now. Do not add behaviour here yet.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)
