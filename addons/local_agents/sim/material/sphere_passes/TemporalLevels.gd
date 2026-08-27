class_name LATemporalLevels
extends RefCounted

## LEVELS IN TIME. A cell subdivides its OWN timestep; the quiet interior steps once (Berger & Oliger 1984).

## Slots per level in the args buffer: TransportPass.Arg. 0-2 the indirect uvec3, 3 the histogram count,
## 4 the sorted offset, 5 the scatter cursor, 6 the suffix count at this level or finer.
const SLOTS: int = 8

## Levels the sort holds. Unreachable by construction: `light_level` bounds a cell's level, and it
## exceeds this only for a cell edge under a tenth of a millimetre.
const BINS: int = 48

## The buffer key of the level field, the cells sorted by it, the per-level args and the group peaks.
const KEYS: Dictionary = {"level": "tlevel", "idx": "level_idx", "args": "level_args",
	"peak": "level_peak"}


## Driver-owned buffers: the per-cell level over interior plus ghost tail, the cells sorted by it, the
## per-level indirect args, and one peak slot per row group.
static func buffers(total: int, group_count: int) -> Dictionary:
	return {KEYS.level: total, KEYS.idx: total, KEYS.peak: maxi(group_count, 1),
		KEYS.args: {"n": BINS * SLOTS, "indirect": true}}


## The level at which dt/2^level is the time light takes to cross one cell. BELOW it a level is a
## timestep; AT it the cell's own state carries a superluminal signal speed and there is no timestep.
static func light_level(dt_s: float, cell_m: float) -> int:
	if dt_s <= 0.0 or cell_m <= 0.0:
		return BINS
	return int(ceil(log(dt_s * LAPhysical.SPEED_OF_LIGHT_M_S / cell_m) / log(2.0)))


## The coarsest level advancing on substep k of a 2^levels axis: level L steps when k is a multiple
## of 2^(levels-L), so the coarsest is levels minus k's trailing zeros.
static func coarsest_at(k: int, levels: int) -> int:
	var l: int = levels
	while k > 0 and (k & 1) == 0:
		k >>= 1
		l -= 1
	return 0 if k <= 0 else maxi(l, 0)
