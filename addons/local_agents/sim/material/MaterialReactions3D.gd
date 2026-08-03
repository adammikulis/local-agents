class_name LAMaterialReactions3D
extends LAReactionDefs

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

const RECORD_MODULES: PackedStringArray = [
	"res://addons/local_agents/sim/material/reactions/GasRecords.gd",
	"res://addons/local_agents/sim/material/reactions/BioRecords.gd",
	"res://addons/local_agents/sim/material/reactions/PhaseRecords.gd",
	"res://addons/local_agents/sim/material/reactions/GeoRecords.gd",
]


## The live reaction table, composed from every registered domain module. Called once, at ReactionsPass
## setup, so the per-module `load()` costs nothing on the per-frame path. A module that fails to load is
## reported and skipped rather than silently dropped — a missing domain would otherwise look like a planet
## whose chemistry simply stopped, which is exactly the kind of failure this repo has shipped before.
static func records() -> Array:
	var out: Array = []
	for path in RECORD_MODULES:
		var scr: GDScript = load(path)
		if scr == null:
			push_error("LAMaterialReactions3D: record module missing: " + path)
			continue
		out.append_array(scr.records())
	return out
