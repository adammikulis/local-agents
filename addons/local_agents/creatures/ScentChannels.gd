class_name LAScentChannels
extends RefCounted

## Core scent-channel indices — the ONE source of truth for the ordering of the shared field's scent
## planes. Both the creature senses/cognition (which live in this core library) and the game's
## LAMaterialField3D substrate reference these constants, so the index layout can never drift between
## the reader (a creature's nose) and the writer (the field). Living in core means a creature parses
## and senses scent gradients with no dependency on the game's field class.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const SCENT_PREY: int = 0
const SCENT_PREDATOR: int = 1
const SCENT_BLOOD: int = 2
const SCENT_FOOD: int = 3
const SCENT_ALARM: int = 4
const SCENT_CHANNELS: int = 5
