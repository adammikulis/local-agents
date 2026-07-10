class_name LACreatureReproduction
extends RefCounted

## Per-creature courtship, mate-seeking, and gestation for LACreature — the Phase 2 owner-file for the
## individual side of breeding.
##
## Today reproduction is a population-level concern handled outside the creature (the ecology spawns
## offspring); a creature only exposes readiness via maturity + energy. Phase 2 makes breeding an emergent
## per-creature drive that lives here: a mature, well-fed adult seeks a compatible nearby mate (same
## species, opposite/available), courts it, and on a successful pairing enters gestation (a timed carry
## that costs energy), then gives birth at the nest — the offspring inheriting a bred genome from both
## parents. That composes with the existing nesting/home drive and the genome cross so a new generation
## falls out of animals living, not a scripted spawn tick.
##
## Intended interface (Phase 2 — not built yet; sketch only, no behaviour today):
##   static func seek_mate(c, pos: Vector3, delta: float) -> Vector3   # heading toward a chosen mate (or ZERO)
##   static func tick_gestation(c, delta: float) -> void               # advance a pregnancy; birth on term
##   static func ready_to_breed(c) -> bool                             # mature + fed + not already gestating
##
## The mate/gestation state (chosen mate, gestation timer, partner genome) will live on the creature as
## plain fields once this lands, so a Phase 2 agent owns courtship/gestation here without editing
## Creature.gd's brain. This stub exists so that owner boundary is claimed now. Do not add behaviour yet.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)
