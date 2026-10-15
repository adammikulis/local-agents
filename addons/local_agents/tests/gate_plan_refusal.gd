extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const Rig: GDScript = preload("res://addons/local_agents/tests/bench_rig.gd")
const Derive: String = "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"

func _init() -> void:
	QuietWindow.apply_if_automated()
	LAProcessSet.declare(LAProcessSet.ACOUSTIC)
	var rig: RefCounted = Rig.new()
	if not rig.open() or not rig.build(2, 1, 1, 1000.0):
		printerr(rig.error)
		quit(2)
		return
	var derive: RefCounted = rig.attach(Derive)
	if derive == null:
		rig.close()
		quit(2)
		return
	rig.upload("temp", rig.filled(rig.cell_count, 12345.0))
	var before: PackedByteArray = rig.rd.buffer_get_data(rig.bufs["temp"])
	rig.driver.setup_transport({"cell_count": rig.cell_count, "total_count": rig.cell_count,
		"rows": [{"channel": "fert", "substance": "fixed_n", "mode": LATransportRecords.POTENTIAL}]})
	var refused: bool = rig.driver.aborted() == "transport/invalid_heat_capacity"
	var blocks: Array = rig.driver.transport_blocks({})["rows"]
	var empty: bool = true
	for block: PackedByteArray in blocks[0]:
		empty = empty and block.is_empty()
	empty = empty and rig.driver.peak_block(0, 0, {}).is_empty()
	var ledger: Dictionary = rig.driver.ledger()
	rig.step_only(derive, {"cell_size": 1000.0, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
		"spin_rate_rad_s": 0.0, "dt_s": 1.0, "sea_radius": 0.0})
	var unchanged: bool = before == rig.rd.buffer_get_data(rig.bufs["temp"])
	var no_dispatch: bool = rig.driver.ledger()["dispatches"] == ledger["dispatches"]
	var ok: bool = refused and empty and unchanged and no_dispatch
	if not ok:
		printerr("Invalid heat escaped refusal, produced a block, changed a buffer or dispatched work.")
	rig.close()
	print("PLAN_REFUSAL: " + ("OK" if ok else "FAIL"))
	quit(0 if ok else 1)
