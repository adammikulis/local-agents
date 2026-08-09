class_name LAMaterialReactions3D
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"

## REGISTRY for the generic DEFS reaction engine (Phase B3 §2). Every hand-coded "clean same-cell"
## chemical/phase reaction on the sphere path (gas sky-exchange, CO₂ vent, fungus decompose, …) is expressed
## as a fixed-size Reaction RECORD instead of a bespoke kernel. `reactions_sphere3d.glsl` loops these records
## per cell; ReactionsPass uploads them once as a read-only SSBO. Adding a future reaction is adding a record
## to a domain module, NOT writing a kernel. (dissolve-don't-patch: success = bespoke kernels deleted.)
##
## The kernel binds every reactable CHANNEL at a fixed binding and a record names a channel by a SLOT enum
## (LAReactionDefs), resolved through the kernel's read_ch/add_ch switch-ladders. Only the channels the live
## records touch need be bound (o2/co2/detritus/fungus + the fungus-fert SCRATCH); the ladder covers the rest
## so a later record can reference them by adding the one binding.
##
## WHY THIS IS A REGISTRY AND NOT ONE TABLE (2026-08-03). `records()` used to be a single flat function
## holding all thirteen records and every constant behind them, and that made it the serialization bottleneck
## for the whole 0.4 planet effort: the nitrogen, carbon and geology workstreams each had to edit the same
## function, so they could not be run as concurrent one-owner units. The records are now grouped by the DOMAIN
## that owns them, one file each, and this file only composes them. Adding a domain is adding a path below.
## The vocabulary (slots, rate models, gates, `rec()`, `serialize()`) lives in LAReactionDefs, which every
## module extends — so a record line still reads exactly as it did when this was one file.
##
## ORDER IS NOT IRRELEVANT, WHATEVER THE OLD TABLE SAID. Its docstring read "Order is irrelevant — every
## record writes only its own cell, so the per-cell loop is order-independent." That is false, and the
## reasoning behind it conflates two different things. Own-cell writes buy RACE-freedom between GPU threads.
## They do not buy order-independence WITHIN a thread, because `reactions_sphere3d.glsl`'s `read_ch` and
## `add_ch` address the same arrays — `co2[i] += v` is what the next record's `read_ch(CO2, i)` reads. So
## records CHAIN inside one cell: R15 makes the CO₂ that R19 can then fix, D1 makes the sediment that D2 can
## then lithify in the same step (which is exactly how the D1/D2 futile cycle happens).
##
## THE INVARIANT, therefore, when adding a record or reordering this list: two records that share any channel
## must keep their relative order. `scripts/verify_reaction_split.gd` gates precisely that — it checks the
## record multiset is unchanged and that no channel-sharing pair swapped. The domain grouping below passes it
## (the only block that moved, M5/M6, shares no channel with the M4/M3 it moved past), which is why this
## refactor is behaviour-neutral. It was verified, not assumed.

## GasRecords.gd IS GONE, deleted 2026-08-03, and it is worth saying what it held. It contributed exactly two
## records, R11 and R12, which pinned O₂ and CO₂ toward a fixed number at the top of the atmosphere using the
## RELAX_TARGET rate model — a model with NO REACTANT, whose cap-and-debit block the kernel skipped outright.
## R12 was the source of every carbon atom that has ever existed in this simulation. The planet now starts
## with a real finite atmosphere at Earth's measured composition, so there is nothing for a sky-exchange
## record to do: the air above a cell genuinely holds the gas, and o2_transport/co2_transport move it there
## as an ordinary conserving transfer.
## CombustionRecords.gd is LAST, and the order is physical rather than alphabetical. Records CHAIN within one
## cell (see the note above), and combustion is the fastest process in the table by orders of magnitude: it
## takes the oxygen the slower biology left and returns the carbon the slower biology will fix. Putting it
## after the bio records means a burning cell's photosynthesis and respiration have already run on the air
## they actually had, rather than on air a fire has emptied in the same step.
##
## It REPLACES fire_sphere3d.glsl, deleted 2026-08-09 with its whole state machine — IGNITE_TEMP (one global
## ignition temperature for every combustible cell on the planet), FIRE_START, FIRE_MIN, FIRE_GROW, the stored
## `fire` intensity and a bespoke radiant-spread gather. It was also the one piece of chemistry in the
## substrate that NO record described, so `check_reaction_balance.sh` could not see it, which is how it came to
## destroy hydrogen, oxygen and nitrogen for as long as it did.
const RECORD_MODULES: PackedStringArray = [
	"res://addons/local_agents/sim/material/reactions/BioRecords.gd",
	"res://addons/local_agents/sim/material/reactions/PhaseRecords.gd",
	"res://addons/local_agents/sim/material/reactions/GeoRecords.gd",
	"res://addons/local_agents/sim/material/reactions/CombustionRecords.gd",
]

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


## The live reaction table, composed from every registered domain module and CHECKED before it is returned.
## Called once, at ReactionsPass setup, so the per-module `load()` and the check cost nothing on the
## per-frame path. A module that fails to load is reported and skipped rather than silently dropped — a
## missing domain would otherwise look like a planet whose chemistry simply stopped, which is exactly the
## kind of failure this repo has shipped before.
##
## THE REFUSAL IS DELIBERATELY TOTAL. If any record fails LAReactionBalance, this returns an EMPTY table
## rather than dropping the offender, and ReactionsPass treats an empty table as fatal and says so. Dropping
## just the bad record would leave a planet running a chemistry nobody authored, quietly; refusing everything
## makes a matter-creating record impossible to ship by accident. That is the whole point — a rule that lives
## only in a comment has already been broken here twice.
static func records() -> Array:
	var out: Array = []
	var labels: PackedStringArray = PackedStringArray()
	for path in RECORD_MODULES:
		var scr: GDScript = load(path)
		if scr == null:
			push_error("LAMaterialReactions3D: record module missing: " + path)
			continue
		var domain: Array = scr.records()
		for i in range(domain.size()):
			labels.append("%s record %d" % [path.get_file(), i])
		out.append_array(domain)
	var violations: PackedStringArray = BalanceScript.check_all(out, labels)
	if not violations.is_empty():
		for v in violations:
			push_error("REACTION BALANCE VIOLATION — " + v)
		push_error("LAMaterialReactions3D: %d violation(s); the reaction table is REFUSED. " % violations.size()
			+ "A record that creates or destroys matter does not run here. Fix the record (or declare the "
			+ "substance it moves in LAReactionBalance.composition()) and try again.")
		return []
	return out
