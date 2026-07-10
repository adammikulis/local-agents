class_name LACreatureChemSense
extends RefCounted

## Chemical sensing -> cue learning for LACreature — the Phase 2 owner-file for smell/taste-driven cues.
##
## Today perception is sight (a FOV cone via LAVision) plus hearing (omnidirectional calls); the shared
## scent/fertility field (LAMaterialScent3D) already carries blood, dung/musk, and food cues that
## LACreatureExcretion and wounds deposit. Phase 2 gives the creature a nose onto that field: it samples
## the local scent gradient at its head cell, reads which chemical channels are present (blood, prey musk,
## carrion, a rival's territory mark), and feeds those readings to LACognition as learnable cues — so a
## predator learns to track prey by dung upwind, a prey learns a predator's musk means flee, and cues ride
## the real wind and wash out in rain for free. This is the sensing counterpart to the deposit side already
## in CreatureExcretion, closing the scent loop through learning rather than any hardcoded scent reaction.
##
## Intended interface (Phase 2 — not built yet; sketch only, no behaviour today):
##   static func sense(c, pos: Vector3) -> Dictionary       # channel -> intensity sampled at the head cell
##   static func gradient(c, pos: Vector3, channel: String) -> Vector3   # up-cue heading to follow a smell
##   static func tick(c, pos: Vector3, delta: float) -> void            # sample + reinforce learned cues
##
## Any per-creature scent-memory state will live on the creature as plain fields once this lands, so a
## Phase 2 agent owns chemical sensing here without editing Creature.gd's brain. This stub exists so that
## owner boundary is claimed now. Do not add behaviour yet.
##
## Static + dependency-free of the LACreature type (dynamic field access, like the other Creature* helpers).
## (Explicit types only — project rule: no ':=' inferred typing.)
