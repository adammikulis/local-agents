class_name LAMaterialFieldInjectQueue3D
extends RefCounted

## LAMaterialFieldInjectQueue3D: one step's pending sparse field edits. What each edit actually applied
## is the device's answer, booked by the InjectPass at the drain; nothing here reads a channel.

# The dead organic pool's CARBON channels: fresh litter arrives with its hydrogen and oxygen.
const DEAD_POOL_CARBON: PackedStringArray = ["detritus", "fuel"]

## Amount handed to the field as heat, in joules, drawn from a named store. It is the source side of the
## enthalpy edits below: a store that stops being debited shows as a rising figure with no matching debit.
var heat_energy_j: float = 0.0

## Per-cell edits handed to the device.
var flushed_cells: int = 0

var _ops: Array = []
var _index: Dictionary = {}    # op signature -> slot in _ops, so same-signature edits COALESCE (see _merge)

# The grid the field is laid over. Cross-cell transfers are sized in mass on the device, off cell_edge.
var _grid = null


## `grid` is the LAVoxelGrid the field is laid over. Called by LAMaterialFieldInject3D.setup.
func setup(grid) -> void:
	_grid = grid


func is_empty() -> bool:
	return _ops.is_empty()


## Append one edit's cells into the op `key` already opened in `ops`, or open that op with `head` as its
## non-cell fields. Every cell buffer is duplicated, so no op holds one caller's buffer in two slots.
static func coalesce(ops: Array, index: Dictionary, key: String, head: Dictionary,
		src_cells: PackedInt32Array, amounts: PackedFloat32Array, dst_cells: PackedInt32Array) -> void:
	var slot: int = index.get(key, -1)
	if slot < 0:
		index[key] = ops.size()
		head["src_cells"] = src_cells.duplicate()
		head["amounts"] = amounts.duplicate()
		head["dst_cells"] = dst_cells.duplicate()
		ops.append(head)
		return
	var op: Dictionary = ops[slot]
	var sc: PackedInt32Array = (op["src_cells"] as PackedInt32Array).duplicate()
	var am: PackedFloat32Array = (op["amounts"] as PackedFloat32Array).duplicate()
	var dc: PackedInt32Array = (op["dst_cells"] as PackedInt32Array).duplicate()
	sc.append_array(src_cells)
	am.append_array(amounts)
	dc.append_array(dst_cells)
	op["src_cells"] = sc
	op["amounts"] = am
	op["dst_cells"] = dc


func _merge(key: String, kind: String, src: String, dst: String, src_cells: PackedInt32Array,
		amounts: PackedFloat32Array, dst_cells: PackedInt32Array, ceiling: float) -> void:
	coalesce(_ops, _index, key, {"kind": kind, "src": src, "dst": dst, "ceiling": ceiling},
		src_cells, amounts, dst_cells)


## Queue a CONSERVING transfer. The device takes only what the source cell holds.
func transfer(src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, dst_ceiling: float = INF) -> void:
	if src_cells.size() == 0 or src_cells.size() != amounts.size() or src_cells.size() != dst_cells.size():
		return
	_merge("t|%s|%s|%f" % [src, dst, dst_ceiling], "move", src, dst, src_cells, amounts, dst_cells, dst_ceiling)


## Queue a DISPLACEMENT: empty `src_cells[i]` of `channel` into `dst_cells[i]` of `dst_channel`.
func displace(channel: String, src_cells: PackedInt32Array, dst_channel: String, dst_cells: PackedInt32Array) -> void:
	if src_cells.size() == 0 or src_cells.size() != dst_cells.size():
		return
	_merge("d|%s|%s" % [channel, dst_channel], "move", channel, dst_channel, src_cells,
		_all_of(src_cells.size()), dst_cells, INF)


## Queue a DISCARD: empty `cells` of `channel` with nowhere for the mass to go.
func discard(channel: String, cells: PackedInt32Array) -> void:
	if cells.size() == 0:
		return
	var nowhere: PackedInt32Array = PackedInt32Array()
	nowhere.resize(cells.size())
	nowhere.fill(-1)
	_merge("x|%s" % channel, "move", channel, channel, cells, _all_of(cells.size()), nowhere, INF)


## Queue a SOURCELESS add.
func add(channel: String, cells: PackedInt32Array, deltas: PackedFloat32Array, ceiling: float = INF) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_merge("a|%s|%f" % [channel, ceiling], "add", channel, channel, cells, deltas, cells, ceiling)
	fresh_companions(channel, cells, deltas)


## Queue a per-cell ENTHALPY edit: `cells[i]` gets `deltas[i]` J/m^3 of the field's internal energy.
func queue_h(cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	add("e_j_m3", cells, deltas)


## Book an ENERGY (joules) drawn from a named store and handed to the field as heat.
func note_energy(joules: float) -> void:
	heat_energy_j += joules


## Credit the hydrogen and oxygen that came in with a fresh-litter carbon credit.
func fresh_companions(channel: String, cells: PackedInt32Array, amounts: PackedFloat32Array) -> void:
	if not DEAD_POOL_CARBON.has(channel):
		return
	var h_per_c: float = LASubstances.fresh_litter_per_carbon("H")
	var o_per_c: float = LASubstances.fresh_litter_per_carbon("O")
	var h: PackedFloat32Array = PackedFloat32Array()
	var o: PackedFloat32Array = PackedFloat32Array()
	for v in amounts:
		h.append(v * h_per_c)
		o.append(v * o_per_c)
	add("org_h", cells, h)
	add("org_o", cells, o)


## An amount larger than any cell holds: the device clamps every take to the live value, so this is
## "everything that is there" without the CPU knowing what that is.
func _all_of(n: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	out.fill(INF)
	return out


## Hand the whole step's edits to the device in one batch.
func flush(gpu) -> void:
	if gpu == null or _ops.is_empty():
		return
	if _grid == null:
		push_error("InjectQueue.flush with no grid: a cross-cell transfer cannot be sized in mass. Call setup(grid).")
		return
	for op in _ops:
		flushed_cells += (op["src_cells"] as PackedInt32Array).size()
	gpu.queue_sparse(_ops)
	_ops = []
	_index.clear()


## The ledger, as SIM_REPORT gauges. What each edit APPLIED is the InjectPass's own book.
func report() -> Dictionary:
	return {
		"inject_energy_j": snappedf(heat_energy_j, 0.01),
		"inject_cells": flushed_cells,
	}
