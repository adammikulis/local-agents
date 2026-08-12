extends SceneTree

## THE BALANCE GATE'S RUNNER. Loads every reaction-record module, hands the whole table to
## LAReactionBalance, and prints one line per violation.
##
## It deliberately does NOT go through `LAMaterialReactions3D.records()`, because that function REFUSES the
## table (returns an empty array) the moment anything fails — correct at runtime, useless for a gate, which
## needs the messages rather than the refusal. Both call the same checker, so they cannot disagree about what
## is legal.
##
## Usage (see scripts/check_reaction_balance.sh, which is what CI runs):
##   godot --headless --path <repo> -s scripts/check_reaction_balance.gd
## Prints REACTION_BALANCE={"records":N,"violations":M} as the last line so the shell wrapper can tell
## "clean" from "could not run" — a gate that examines zero records must FAIL, never pass.
## (Explicit types only, no ':=' inferred typing.)

const REGISTRY_PATH: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"
const BALANCE_PATH: String = "res://addons/local_agents/sim/material/reactions/ReactionBalance.gd"
const WORLD_PATH: String = "res://addons/local_agents/sim/SimWorld.gd"


## A flux-derived rate spreads a per-square-metre flux through a cell, so the table cannot be built without
## a grid. This is the grid LocalAgentSimWorld builds at its own defaults.
func _declare_cell_height() -> void:
	var world: GDScript = load(WORLD_PATH)
	if world == null:
		return
	var w: Node = world.new()
	LAReactionDefs.cell_size_m = w.field_cell_size_m()
	w.free()


func _init() -> void:
	_declare_cell_height()
	var registry: GDScript = load(REGISTRY_PATH)
	var balance: GDScript = load(BALANCE_PATH)
	if registry == null or balance == null:
		print("REACTION_BALANCE_ERROR: could not load %s or %s" % [REGISTRY_PATH, BALANCE_PATH])
		print('REACTION_BALANCE={"records":0,"violations":-1}')
		quit(2)
		return

	var recs: Array = []
	var labels: PackedStringArray = PackedStringArray()
	for path in registry.RECORD_MODULES:
		var mod: GDScript = load(path)
		if mod == null:
			print("REACTION_BALANCE_ERROR: record module missing: %s" % path)
			print('REACTION_BALANCE={"records":0,"violations":-1}')
			quit(2)
			return
		var domain: Array = mod.records()
		for i in range(domain.size()):
			labels.append("%s record %d" % [String(path).get_file(), i])
		recs.append_array(domain)

	if recs.is_empty():
		print("REACTION_BALANCE_ERROR: the reaction table is EMPTY — the gate examined nothing.")
		print('REACTION_BALANCE={"records":0,"violations":-1}')
		quit(2)
		return

	var violations: PackedStringArray = balance.check_all(recs, labels)
	for v in violations:
		print("REACTION_BALANCE_VIOLATION: " + v)
	print('REACTION_BALANCE={"records":%d,"violations":%d}' % [recs.size(), violations.size()])
	quit(1 if violations.size() > 0 else 0)
