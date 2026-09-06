class_name LAActiveCells
extends RefCounted

## BUBBLES OF COMPUTE. A cell is stepped while matter crosses it and sleeps when none has.

## Steps without a crossing before a cell stops donating. docs/MODEL_PARAMETERS.md carries why.
const QUIET_STEPS: int = 2

## Slots per row group in the args buffer: FluxPass.Arg.
const SLOTS: int = 8

const KEYS: Dictionary = {"quiet": "act_quiet", "claim": "act_claim", "queue": "act_queue",
	"wake": "act_wake", "wake_args": "act_wake_args", "idx": "act_idx", "args": "act_args",
	"step_dt": "step_dt"}


## Driver-owned: ONE ACTIVE LIST PER ROW GROUP with its own indirect args and the step its cells
## afford, a quiet counter per cell per group, the claim and queue, and the wake another kernel fills.
static func buffers(total: int, group_count: int) -> Dictionary:
	var g: int = maxi(group_count, 1)
	return {KEYS.quiet: total * g, KEYS.claim: total, KEYS.queue: total,
		KEYS.idx: total * g, KEYS.step_dt: g,
		KEYS.args: {"n": SLOTS * g, "indirect": true},
		KEYS.wake: total,
		KEYS.wake_args: {"n": SLOTS, "indirect": true}}


## Byte offset of one group's block in the args buffer.
static func args_offset(group: int) -> int:
	return group * SLOTS * 4
