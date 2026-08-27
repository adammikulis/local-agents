class_name LAMaterialReactions3D
extends "res://addons/local_agents/sim/material/reactions/ReactionDefs.gd"


const RECORD_MODULES: PackedStringArray = [
	"res://addons/local_agents/sim/material/reactions/BioRecords.gd",
	"res://addons/local_agents/sim/material/reactions/PhaseRecords.gd",
	"res://addons/local_agents/sim/material/reactions/GeoRecords.gd",
	"res://addons/local_agents/sim/material/reactions/CombustionRecords.gd",
	"res://addons/local_agents/sim/material/reactions/LightningRecords.gd",
]

const BalanceScript: GDScript = preload("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")


static func records() -> Array:
	return records_from(RECORD_MODULES)


## The table `paths` declares, balance-checked as one whole. A rung runs a subset of the modules, and the
## table it forms has to balance on its own.
static func records_from(paths: PackedStringArray) -> Array:
	var out: Array = []
	var labels: PackedStringArray = PackedStringArray()
	for path in paths:
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
