extends RefCounted

## Which rung each ladder gate belongs to, for lint_capture: a gate above the capture's rung is not examined.


func _initialize() -> void:
	for r in LAProcessSet.rungs():
		for g in r["gates"]:
			print("GATE_RUNG=%s %d" % [String(g), int(r["rung"])])
