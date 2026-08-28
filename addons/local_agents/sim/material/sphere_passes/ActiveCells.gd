class_name LAActiveCells
extends RefCounted

## BUBBLES OF COMPUTE. A cell is stepped while matter crosses it and sleeps when none has.

## Substeps without a crossing before a cell stops donating. docs/MODEL_PARAMETERS.md carries why.
const QUIET_SUBSTEPS: int = 2

## The bin past the levels, holding the compaction queue's own length and dispatch.
const QUEUE_BIN: int = LATemporalLevels.BINS

const KEYS: Dictionary = {"quiet": "act_quiet", "claim": "act_claim", "queue": "act_queue",
	"wake": "act_wake", "wake_args": "act_wake_args"}


## Driver-owned: a quiet counter per cell per row group, the compaction's claim and queue, and the
## cells another kernel changed, with their own indirect args.
static func buffers(total: int, group_count: int) -> Dictionary:
	return {KEYS.quiet: total * maxi(group_count, 1), KEYS.claim: total, KEYS.queue: total,
		KEYS.wake: total,
		KEYS.wake_args: {"n": LATemporalLevels.SLOTS, "indirect": true}}


## Byte offset of one group's bin in the per-level args buffer.
static func args_offset(group: int, bin: int) -> int:
	return (group * (QUEUE_BIN + 1) + bin) * LATemporalLevels.SLOTS * 4
