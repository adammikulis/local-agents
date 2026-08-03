extends SceneTree

## Prove the MaterialReactions3D domain split is a PURE REFACTOR — and gate the invariant that makes any
## future record addition safe.
##
## WHY THIS IS NOT JUST A BYTE COMPARE. The old table's docstring said "Order is irrelevant — every record
## writes only its own cell, so the per-cell loop is order-independent." That is FALSE, and it is worth being
## precise about why, because the claim reads plausible. Own-cell writes buy RACE-freedom between threads;
## they do not buy order-independence within a thread. reactions_sphere3d.glsl's `read_ch` and `add_ch`
## address the SAME arrays (`co2[i] += v` is read back by the next record's `read_ch(CO2, i)`), so records
## CHAIN inside one cell: R15 makes CO₂ that R19 can then fix, D1 makes sediment that D2 can then lithify.
##
## So grouping records by domain — which necessarily reorders them — is only safe if no two records that
## SHARE A CHANNEL changed their relative order. That is the invariant this checks:
##
##   1. the multiset of serialised records is unchanged (nothing added, dropped or edited), and
##   2. for every PAIR of records touching a common channel, their relative order is unchanged.
##
## Usage: godot --headless --path <worktree> -s scripts/verify_reaction_split.gd -- --old=<res:// path>
## The old file must have had its `class_name` line stripped, or it collides with the live one.

const STRIDE: int = 128


func _rec_key(bytes: PackedByteArray, r: int) -> String:
	return bytes.slice(r * STRIDE, (r + 1) * STRIDE).hex_encode()


## Every channel slot a record reads or writes: its driver(s), reactants and products.
func _channels_of(rec: Dictionary) -> Dictionary:
	var s: Dictionary = {}
	s[int(rec.get("driver_slot", -1))] = true
	var d2: int = int(rec.get("driver2_slot", -1))
	if d2 >= 0:
		s[d2] = true
	for e in rec.get("reactants", []):
		s[int(e[0])] = true
	for e in rec.get("products", []):
		s[int(e[0])] = true
	return s


func _init() -> void:
	var old_path: String = ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--old="):
			old_path = a.substr(6)
	if old_path == "":
		push_error("verify_reaction_split: --old=<path> required")
		quit(2)
		return
	var old_scr: GDScript = load(old_path)
	if old_scr == null:
		push_error("verify_reaction_split: could not load " + old_path)
		quit(2)
		return

	var new_recs: Array = LAMaterialReactions3D.records()
	var old_recs: Array = old_scr.records()
	var new_bytes: PackedByteArray = LAMaterialReactions3D.serialize(new_recs)
	var old_bytes: PackedByteArray = old_scr.serialize(old_recs)

	# 1. Same records, ignoring order.
	var old_keys: Array = []
	var new_keys: Array = []
	for r in range(old_recs.size()):
		old_keys.append(_rec_key(old_bytes, r))
	for r in range(new_recs.size()):
		new_keys.append(_rec_key(new_bytes, r))
	var old_sorted: Array = old_keys.duplicate()
	var new_sorted: Array = new_keys.duplicate()
	old_sorted.sort()
	new_sorted.sort()
	var same_set: bool = old_sorted == new_sorted

	# 2. Relative order preserved for every channel-sharing pair.
	var violations: Array = []
	for i in range(old_recs.size()):
		for j in range(i + 1, old_recs.size()):
			var ci: Dictionary = _channels_of(old_recs[i])
			var cj: Dictionary = _channels_of(old_recs[j])
			var shares: bool = false
			for slot in ci:
				if cj.has(slot):
					shares = true
					break
			if not shares:
				continue
			var ni: int = new_keys.find(old_keys[i])
			var nj: int = new_keys.find(old_keys[j])
			if ni < 0 or nj < 0:
				continue
			if (ni < nj) != (i < j):
				violations.append("records %d/%d swapped (now %d/%d)" % [i, j, ni, nj])

	print("REACTION_SPLIT_CHECK={\"old\":%d,\"new\":%d,\"same_set\":%s,\"order_violations\":%d,\"byte_identical\":%s}" % [
		old_recs.size(), new_recs.size(), str(same_set), violations.size(), str(old_bytes == new_bytes)])
	for v in violations:
		push_error("channel-sharing pair reordered: " + v)
	if not same_set:
		push_error("the record SET changed — a record was added, dropped or edited by the split")
	quit(0 if (same_set and violations.is_empty()) else 1)
