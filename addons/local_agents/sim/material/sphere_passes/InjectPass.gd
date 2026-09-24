extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Sparse field edits: matter and energy arriving from outside the field, or moving between two named
## cells. One thread per named cell, so the batch costs its own size and not the grid's.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/sparse_edit.glsl"

const OP_ADD: int = 0
const OP_MOVE: int = 1

const KIND_MOVED: int = 0
const KIND_CREATED: int = 1
const KIND_REMOVED: int = 2

## Entries the batch buffers hold before they are grown; growth doubles and never shrinks.
const INITIAL_ENTRIES: int = 1024

var _pipe: RID = RID()
var _bufs: Dictionary = {}
var _idx: RID = RID()          # per entry: source cell, destination cell, op
var _val: RID = RID()          # per entry: amount, ceiling
var _applied: RID = RID()      # per entry: what the device applied, read at the drain
var _capacity: int = 0
var _span: int = 0             # cells a batch may name: interior plus the ghost tail
var _sets: Dictionary = {}     # "src|dst" -> the uniform set that binds those two channels

# The batch this step dispatches, and what each entry's applied amount books.
var _n: int = 0
var _book_channel: PackedStringArray = PackedStringArray()
var _book_kind: PackedInt32Array = PackedInt32Array()
var _dispatch_sets: Array = []
var _dispatch_pcs: Array = []
var _dispatch_groups: PackedInt32Array = PackedInt32Array()

# Cumulative, per channel, in that channel's own unit.
var _moved: Dictionary = {}
var _created: Dictionary = {}
var _removed: Dictionary = {}


func _setup(bufs: Dictionary, cc: int) -> void:
	_bufs = bufs
	_span = cc + ghost_count
	_pipe = _kernel(KERNEL_PATH)
	_grow(INITIAL_ENTRIES)


## Turn queued ops into one contiguous batch and upload it. Called before the step records.
func plan(ops: Array) -> void:
	_n = 0
	_book_channel = PackedStringArray()
	_book_kind = PackedInt32Array()
	_dispatch_sets = []
	_dispatch_pcs = []
	_dispatch_groups = PackedInt32Array()
	if not _dispatchable() or ops.is_empty():
		return
	var by_pair: Dictionary = {}
	var total: int = 0
	for op: Dictionary in ops:
		var key: String = String(op["src"]) + "|" + String(op["dst"])
		if not by_pair.has(key):
			by_pair[key] = []
		(by_pair[key] as Array).append(op)
		total += (op["src_cells"] as PackedInt32Array).size()
	if total > _capacity:
		_grow(total)
	var idx: PackedInt32Array = PackedInt32Array()
	var val: PackedFloat32Array = PackedFloat32Array()
	for key: String in by_pair:
		_plan_pair(key, by_pair[key], idx, val)
	_n = _book_kind.size()
	if _n == 0:
		return
	var ib: PackedByteArray = idx.to_byte_array()
	_rd.buffer_update(_idx, 0, ib.size(), ib)
	var vb: PackedByteArray = val.to_byte_array()
	_rd.buffer_update(_val, 0, vb.size(), vb)


## One channel pair's entries, split into ROUNDS: within a round no cell of either channel is named
## twice, so every thread owns its cells outright and the sum is the same whatever order they run in.
func _plan_pair(key: String, ops: Array, idx: PackedInt32Array, val: PackedFloat32Array) -> void:
	var src: String = key.get_slice("|", 0)
	var dst: String = key.get_slice("|", 1)
	var uset: RID = _set_for(src, dst)
	if not uset.is_valid():
		return
	var same: bool = src == dst
	var seen: Array = []       # per round: the cells it already names
	var rounds: Array = []     # per round: its entries, each [s, d, op, amount, ceiling, book kind]
	for op: Dictionary in ops:
		var cells: PackedInt32Array = op["src_cells"]
		var amounts: PackedFloat32Array = op["amounts"]
		var dsts: PackedInt32Array = op["dst_cells"]
		var kind: int = OP_ADD if String(op["kind"]) == "add" else OP_MOVE
		var ceiling: float = float(op["ceiling"])
		for i in cells.size():
			var s: int = cells[i]
			if s < 0 or s >= _span:
				continue
			var d: int = dsts[i] if kind == OP_MOVE else -1
			var book: int = KIND_CREATED
			if kind == OP_MOVE:
				book = KIND_MOVED if d >= 0 and d < _span else KIND_REMOVED
			var r: int = _round_for(seen, s, d, same)
			while rounds.size() <= r:
				rounds.append([])
			(rounds[r] as Array).append([s, d, kind, amounts[i], ceiling, book])
	for round_entries: Array in rounds:
		if round_entries.is_empty():
			continue
		var base: int = _book_kind.size()
		for e: Array in round_entries:
			idx.append(e[0])
			idx.append(e[1])
			idx.append(e[2])
			val.append(e[3])
			val.append(e[4])
			_book_channel.append(src)
			_book_kind.append(e[5])
		var count: int = round_entries.size()
		_dispatch_sets.append(uset)
		_dispatch_pcs.append(_push(base, count, same))
		_dispatch_groups.append(int(ceil(float(count) / 64.0)))


## The first round whose cells this entry does not collide with, opening a new one when they all do.
## A destination in the other channel of the pair is a different cell, so it gets its own key space.
func _round_for(seen: Array, s: int, d: int, same: bool) -> int:
	var d_key: int = -1
	if d >= 0 and d < _span:
		d_key = d if same else d + _span
	for r in seen.size():
		var taken: Dictionary = seen[r]
		if taken.has(s) or (d_key >= 0 and taken.has(d_key)):
			continue
		taken[s] = true
		if d_key >= 0:
			taken[d_key] = true
		return r
	var fresh: Dictionary = {s: true}
	if d_key >= 0:
		fresh[d_key] = true
	seen.append(fresh)
	return seen.size() - 1


func _push(base: int, count: int, same: bool) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, base)
	pc.encode_u32(4, count)
	pc.encode_u32(8, _span)
	pc.encode_u32(12, 1 if same else 0)
	return pc


## The uniform set binding this pair of channels. An unallocated channel is a named error and no set:
## a partial set would edit memory nobody wrote.
func _set_for(src: String, dst: String) -> RID:
	var key: String = src + "|" + dst
	if _sets.has(key):
		return _sets[key]
	var s_rid: RID = _single(_bufs, src)
	var d_rid: RID = _single(_bufs, dst) if dst != src else s_rid
	if not s_rid.is_valid() or not d_rid.is_valid():
		push_error("InjectPass: no buffer for channel \"%s\" or \"%s\"; the edit is dropped." % [src, dst])
		return RID()
	var own: Dictionary = {
		"inject_idx": _idx,
		"inject_val": _val,
		"inject_applied": _applied,
		"inject_src": s_rid,
		"inject_dst": d_rid}
	var uset: RID = _uset(_pipe, LABindings.set_for("sparse_edit.glsl", _bufs, own))
	_sets[key] = uset
	return uset


func dispatch(_rd_in: RenderingDevice, _ctx: Dictionary, _cc: int, _groups: int) -> void:
	if not _dispatchable() or _dispatch_pcs.is_empty():
		return
	_driver.run(_pipe, _dispatch_sets, _dispatch_pcs, _dispatch_groups, [], PackedInt32Array(), true,
		PackedStringArray([_label() + "/edit"]))
	_dispatch_pcs = []
	_dispatch_sets = []
	_dispatch_groups = PackedInt32Array()


## What the device applied, read once the driver has synced: the entries, not the grid.
func _drain(rd: RenderingDevice) -> Dictionary:
	if _n > 0 and _applied.is_valid() and rd != null:
		var got: PackedFloat32Array = rd.buffer_get_data(_applied, 0, _n * 4).to_float32_array()
		for i in mini(_n, got.size()):
			var ch: String = _book_channel[i]
			var kind: int = _book_kind[i]
			if kind == KIND_CREATED:
				_created[ch] = float(_created.get(ch, 0.0)) + got[i]
			elif kind == KIND_REMOVED:
				_removed[ch] = float(_removed.get(ch, 0.0)) + got[i]
			else:
				_moved[ch] = float(_moved.get(ch, 0.0)) + got[i]
		_n = 0
	var out: Dictionary = {}
	for ch: String in _moved:
		out["inject_moved_" + ch] = float(_moved[ch])
	for ch: String in _created:
		out["inject_created_" + ch] = float(_created[ch])
	for ch: String in _removed:
		out["inject_removed_" + ch] = float(_removed[ch])
	return out


## Cumulative amount injection has added to `channel` with no source anywhere in the field.
func created_total(channel: String) -> float:
	return float(_created.get(channel, 0.0))


func _grow(entries: int) -> void:
	if _rd == null:
		return
	for r: RID in [_idx, _val, _applied]:
		if r.is_valid():
			_owned_buffers.erase(r)
			_rd.free_rid(r)
	for r: RID in _sets.values():
		if r is RID and (r as RID).is_valid():
			_owned_sets.erase(r)
			_rd.free_rid(r)
	_sets = {}
	_capacity = entries
	var i3: PackedInt32Array = PackedInt32Array()
	i3.resize(entries * 3)
	_idx = _storage_buffer(i3.to_byte_array())
	_val = _scratch(entries * 2)
	_applied = _scratch(entries)
