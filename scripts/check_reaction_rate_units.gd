extends SceneTree

## THE RATE-UNITS GATE'S RUNNER — sibling of check_reaction_balance.gd. Every record must declare its
## rate_k's units and timebase, and the declaration must match its rate model
## (LAReactionDefs.check_rate_units). The shell wrapper holds the structural half: record modules may not
## fold the step quantum (serialize() is the one fold point) and the kernel carries no dt.
## Prints RATE_UNITS={"records":N,"violations":M} as its last line; zero records examined must FAIL.
## (Explicit types only, no ':=' inferred typing.)

const REGISTRY_PATH: String = "res://addons/local_agents/sim/material/MaterialReactions3D.gd"
const WORLD_PATH: String = "res://addons/local_agents/sim/SimWorld.gd"


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
	if registry == null:
		print("RATE_UNITS_ERROR: could not load %s" % REGISTRY_PATH)
		print('RATE_UNITS={"records":0,"violations":-1}')
		quit(2)
		return
	var recs: Array = []
	var labels: PackedStringArray = PackedStringArray()
	for path in registry.RECORD_MODULES:
		var mod: GDScript = load(path)
		if mod == null:
			print("RATE_UNITS_ERROR: record module missing: %s" % path)
			print('RATE_UNITS={"records":0,"violations":-1}')
			quit(2)
			return
		var domain: Array = mod.records()
		for i in range(domain.size()):
			labels.append("%s record %d" % [String(path).get_file(), i])
		recs.append_array(domain)
	if recs.is_empty():
		print("RATE_UNITS_ERROR: the reaction table is EMPTY — the gate examined nothing.")
		print('RATE_UNITS={"records":0,"violations":-1}')
		quit(2)
		return
	var violations: int = 0
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var label: String = String(labels[r])
		var tb: String = String(rec.get("k_timebase", ""))
		if tb != LAReactionDefs.TB_PER_SECOND and tb != LAReactionDefs.TB_PER_STEP:
			print("RATE_UNITS_VIOLATION: %s declares no k_timebase, so its rate_k cannot be checked "
				% label + "against the step quantum.")
			violations += 1
			continue
		var model: int = int(rec.get("rate_model", -1))
		var want: String = String(LAReactionDefs.RATE_K_UNITS.get(model, ""))
		if want == "":
			print("RATE_UNITS_VIOLATION: %s has rate model %d with no RATE_K_UNITS row." % [label, model])
			violations += 1
			continue
		if model == LAReactionDefs.RM_ARRHENIUS and int(rec.get("driver2_slot", -1)) >= 0:
			want += " driver2^-1"
		want += " s^-1" if tb == LAReactionDefs.TB_PER_SECOND else " step^-1"
		var got: String = String(rec.get("k_units", ""))
		if got != want:
			print("RATE_UNITS_VIOLATION: %s: k_units is \"%s\" but its rate model and timebase make it \"%s\"."
				% [label, got, want])
			violations += 1
	print('RATE_UNITS={"records":%d,"violations":%d}' % [recs.size(), violations])
	quit(1 if violations > 0 else 0)
