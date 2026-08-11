@tool
extends RefCounted

## An in-place transfer must survive being coalesced.
##
## Callers are entitled to pass one cell array as both source and destination — that is how you say "this
## rock becomes sediment right where it stands", and `MaterialFieldInject3D.resample_terrain` says exactly
## that when a meteor excavates bedrock. But `PackedInt32Array` is copy-on-write, so storing one array in two
## of the op's dictionary slots left both slots reading a SHARED buffer, and `_merge` then appended into it
## twice: the cell lists grew by two edits per merge while `amounts` grew by one.
##
## That matters because `move_field_sparse` early-returns 0.0 unless `src_cells.size() == amounts.size()`.
## So every COALESCED mineral transfer was silently dropped, and coalescing is the common case the moment two
## excavations land between flushes, which is what a barrage is. Measured before the fix on a live barrage:
## 99/99/99 cells in, 268/169/268 out.
##
## The assertion is on the SIZES AGREEING, not on any call reporting ok — nothing reported anything. The
## queue accepted the edit, the device call quietly returned zero, and the only visible symptom was mineral
## that never arrived.
## (Explicit types only, project rule: no ':=' inferred typing.)

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")


func run_test(_tree: SceneTree) -> bool:
	var q: RefCounted = QueueScript.new()

	# Two edits under one (kind, src, dst) key, each passing ITS OWN array as both source and destination.
	var cells_a: PackedInt32Array = PackedInt32Array([1, 2, 3, 4, 5])
	q.transfer("rock_fill", cells_a, PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0]), "sediment", cells_a)
	var cells_b: PackedInt32Array = PackedInt32Array([6, 7])
	q.transfer("rock_fill", cells_b, PackedFloat32Array([1.0, 1.0]), "sediment", cells_b)

	var ops: Array = q.get("_ops")
	var ok: bool = _assert(ops.size() == 1, "the two edits share a key and must coalesce into one op, got %d" % ops.size())
	if not ok:
		return false

	var op: Dictionary = ops[0]
	var src_cells: PackedInt32Array = op["src_cells"]
	var amounts: PackedFloat32Array = op["amounts"]
	var dst_cells: PackedInt32Array = op["dst_cells"]

	ok = _assert(amounts.size() == 7, "the merged op must carry both edits' amounts, got %d" % amounts.size()) and ok
	ok = _assert(src_cells.size() == amounts.size(),
		"src_cells (%d) must match amounts (%d) or move_field_sparse silently drops the whole transfer; got %s"
			% [src_cells.size(), amounts.size(), str(src_cells)]) and ok
	ok = _assert(dst_cells.size() == amounts.size(),
		"dst_cells (%d) must match amounts (%d); an in-place transfer must not alias its own source"
			% [dst_cells.size(), amounts.size()]) and ok
	ok = _assert(src_cells == PackedInt32Array([1, 2, 3, 4, 5, 6, 7]),
		"each cell must appear once per edit that named it, got %s" % str(src_cells)) and ok

	if ok:
		print("Inject-queue alias test passed (an in-place transfer coalesces without duplicating its cells)")
	return ok


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
