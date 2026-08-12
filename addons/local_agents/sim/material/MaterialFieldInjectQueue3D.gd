class_name LAMaterialFieldInjectQueue3D
extends RefCounted

## LAMaterialFieldInjectQueue3D: the PENDING-DEVICE-EDIT queue and the H₂O injection LEDGER.

## A per-cell amount this large means "take everything that is there".
const DRAIN_ALL: float = 1.0e30

const MINERAL_CHANNELS: PackedStringArray = ["silicate"]

const BIOTIC_CHANNELS: PackedStringArray = ["biomass", "o2", "co2", "detritus", "fuel", "org_h", "org_o"]

# The dead organic pool's CARBON channels.
const DEAD_POOL_CARBON: PackedStringArray = ["detritus", "fuel"]

# --- cumulative H₂O injection ledger (SIM_REPORT gauges) ---------------------------------------------------
var demand: float = 0.0        # mass transfers asked their sources for
var offered: float = 0.0       # mass the CPU-side scan believed its sources held
var moved: float = 0.0         # mass actually transferred (source debited, sink credited — closed)
var minted: float = 0.0        # mass added with no source at all
var buried: float = 0.0        # mass discarded because a cell turned solid with nowhere to displace it to
var displaced: float = 0.0     # mass a solidifying/melting cell handed to a neighbour instead of stranding

# --- cumulative MINERAL ledger (same mechanism, separate books — see MINERAL_CHANNELS) ----------------------
var mineral_offered: float = 0.0   # mineral mass a transfer's CPU-side scan believed its source held
var mineral_moved: float = 0.0     # TRANSFER: debit actually taken, in source-cell fractions. Eruption,
                                   # excavation and melt are all transfers and land HERE, not in mineral_minted.
# --- cumulative BIOTIC ledger (same mechanism, third set of books — see BIOTIC_CHANNELS) --------------------
var biotic_offered: float = 0.0
var biotic_moved: float = 0.0
var biotic_minted: float = 0.0

var mineral_minted: float = 0.0    # SOURCE: mineral added with NO debit anywhere in the field. Only `add()`
                                   # reaches it — deposit_sediment and the stamp's debug_deposit.

# AUDIT (LA_INJECT_AUDIT=1): |CPU mirror total - live device total| at flush time.
var rewind_peak: float = 0.0
var rewind_last: float = 0.0

## Per-cell edits that actually reached a device primitive.
var flushed_cells: int = 0
var add_cells: int = 0         # ...of which belonged to `add` ops, so a credit that returned nothing is
                               # distinguishable from a credit that was never queued

var _ops: Array = []
var _index: Dictionary = {}    # op signature -> slot in _ops, so same-signature edits COALESCE (see _merge)

# The grid whose cell volumes size every cross-cell transfer. A channel value is a FRACTION of a cell.
var _grid = null


## `grid` is the LAVoxelGrid the field is laid over. Called by LAMaterialFieldInject3D.setup.
func setup(grid) -> void:
	_grid = grid


func is_empty() -> bool:
	return _ops.is_empty()


func _merge(key: String, kind: String, src: String, dst: String, src_cells: PackedInt32Array,
		amounts: PackedFloat32Array, dst_cells: PackedInt32Array, ceiling: float) -> void:
	var slot: int = _index.get(key, -1)
	if slot < 0:
		_index[key] = _ops.size()
		# See the header: `dst_cells` is duplicated so no op ever holds one buffer in both of its cell slots.
		_ops.append({"kind": kind, "src": src, "dst": dst, "src_cells": src_cells,
			"amounts": amounts, "dst_cells": dst_cells.duplicate(), "ceiling": ceiling})
		return
	var op: Dictionary = _ops[slot]
	var sc: PackedInt32Array = (op["src_cells"] as PackedInt32Array).duplicate()
	var am: PackedFloat32Array = (op["amounts"] as PackedFloat32Array).duplicate()
	var dc: PackedInt32Array = (op["dst_cells"] as PackedInt32Array).duplicate()
	sc.append_array(src_cells)
	am.append_array(amounts)
	dc.append_array(dst_cells)
	op["src_cells"] = sc
	op["amounts"] = am
	op["dst_cells"] = dc


func note_demand(want: float) -> void:
	if want > 0.0:
		demand += want


## Queue a CONSERVING transfer.
func transfer(src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, dst_ceiling: float = INF) -> void:
	if src_cells.size() == 0 or src_cells.size() != amounts.size() or src_cells.size() != dst_cells.size():
		return
	var is_mineral: bool = MINERAL_CHANNELS.has(src)
	var is_biotic: bool = BIOTIC_CHANNELS.has(src)
	for a in amounts:
		if is_mineral:
			mineral_offered += a
		elif is_biotic:
			biotic_offered += a
		else:
			offered += a
	_merge("t|%s|%s|%f" % [src, dst, dst_ceiling], "transfer", src, dst, src_cells, amounts, dst_cells, dst_ceiling)


## Queue a DISPLACEMENT: empty `src_cells[i]` of `channel` into `dst_cells[i]` of `dst_channel`.
func displace(channel: String, src_cells: PackedInt32Array, dst_channel: String, dst_cells: PackedInt32Array) -> void:
	if src_cells.size() == 0 or src_cells.size() != dst_cells.size():
		return
	var amounts: PackedFloat32Array = PackedFloat32Array()
	amounts.resize(src_cells.size())
	amounts.fill(DRAIN_ALL)
	_merge("d|%s|%s" % [channel, dst_channel], "displace", channel, dst_channel, src_cells, amounts, dst_cells, INF)


## Queue a DISCARD: empty `cells` of `channel` with nowhere for the mass to go.
func discard(channel: String, cells: PackedInt32Array) -> void:
	if cells.size() == 0:
		return
	var deltas: PackedFloat32Array = PackedFloat32Array()
	deltas.resize(cells.size())
	deltas.fill(-DRAIN_ALL)
	_merge("x|%s" % channel, "discard", channel, channel, cells, deltas, cells, INF)


## Queue a SOURCELESS add.
func add(channel: String, cells: PackedInt32Array, deltas: PackedFloat32Array, ceiling: float = INF) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_merge("a|%s|%f" % [channel, ceiling], "add", channel, channel, cells, deltas, cells, ceiling)
	fresh_companions(channel, cells, deltas)


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


## Apply every queued edit to the LIVE device buffers and fold the results into the ledger.
func flush(gpu) -> void:
	if gpu == null or _ops.is_empty():
		return
	if _grid == null:
		push_error("InjectQueue.flush with no grid: a cross-cell transfer cannot be sized in mass. Call setup(grid).")
		return
	for op in _ops:
		flushed_cells += (op["src_cells"] as PackedInt32Array).size()
		var kind: String = String(op["kind"])
		if kind == "transfer":
			var m: float = _move(gpu, op)
			if MINERAL_CHANNELS.has(String(op["src"])):
				mineral_moved += m
			elif BIOTIC_CHANNELS.has(String(op["src"])):
				biotic_moved += m
			else:
				moved += m
		elif kind == "displace":
			displaced += _move(gpu, op)
		elif kind == "discard":
			buried += -gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"])
		elif kind == "add":
			add_cells += (op["src_cells"] as PackedInt32Array).size()
			var a: float = gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"], float(op["ceiling"]))
			if MINERAL_CHANNELS.has(String(op["src"])):
				mineral_minted += a
			elif BIOTIC_CHANNELS.has(String(op["src"])):
				biotic_minted += a
			else:
				minted += a
	_ops.clear()
	_index.clear()


## vol(src_cell) / vol(dst_cell) — how much of the destination cell one cell-fraction of the source fills.
func _ratio(s: int, d: int) -> float:
	if s == d or s < 0 or d < 0 or s >= _grid.cell_count or d >= _grid.cell_count:
		return 1.0
	return _grid.cell_volume(s) / _grid.cell_volume(d)


## Apply one transfer/displace op to the live device buffers; returns the debit, in SOURCE-cell fractions.
func _move(gpu, op: Dictionary) -> float:
	var src: String = String(op["src"])
	var dst: String = String(op["dst"])
	var half: int = int(gpu.probe_phase())
	var live_s: PackedFloat32Array = gpu.read_raw(src, half)
	var same: bool = src == dst
	var live_d: PackedFloat32Array = live_s if same else gpu.read_raw(dst, half)
	if live_s.is_empty() or live_d.is_empty():
		return 0.0
	var sc: PackedInt32Array = op["src_cells"]
	var dc: PackedInt32Array = op["dst_cells"]
	var am: PackedFloat32Array = op["amounts"]
	var ceiling: float = float(op["ceiling"])
	var debit_cells: PackedInt32Array = PackedInt32Array()
	var debit: PackedFloat32Array = PackedFloat32Array()
	var credit_cells: PackedInt32Array = PackedInt32Array()
	var credit: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for i in sc.size():
		var s: int = sc[i]
		if s < 0 or s >= live_s.size():
			continue
		var d: int = dc[i]
		var has_dst: bool = d >= 0 and d < live_d.size()
		var k: float = _ratio(s, d) if has_dst else 1.0
		var take: float = minf(maxf(am[i], 0.0), live_s[s])
		if has_dst and ceiling < INF:
			var held: float = live_s[d] if same else live_d[d]
			take = minf(take, maxf(0.0, ceiling - held) / k)
		if take <= 0.0:
			continue
		live_s[s] -= take
		debit_cells.append(s)
		debit.append(-take)
		if has_dst:
			var gain: float = take * k
			if same:
				live_s[d] += gain
			else:
				live_d[d] += gain
			credit_cells.append(d)
			credit.append(gain)
		total += take
	if debit_cells.size() > 0:
		gpu.add_field_sparse(src, debit_cells, debit)
	if credit_cells.size() > 0:
		gpu.add_field_sparse(dst, credit_cells, credit)
	return total


func audit_rewind(gpu, channel: String, mirror: PackedFloat32Array) -> void:
	if gpu == null or not gpu.has_method("channel_total") or mirror.size() == 0:
		return
	var live: float = gpu.channel_total(channel)
	var mirrored: float = 0.0
	for v in mirror:
		mirrored += v
	rewind_last = mirrored - live
	if absf(rewind_last) > absf(rewind_peak):
		rewind_peak = rewind_last


## The ledger, as SIM_REPORT gauges.
func report() -> Dictionary:
	return {
		"h2o_inject_demand": snappedf(demand, 0.01),
		"h2o_inject_offered": snappedf(offered, 0.01),
		"h2o_inject_moved": snappedf(moved, 0.01),
		"h2o_inject_short": snappedf(maxf(0.0, demand - moved), 0.01),
		"h2o_inject_minted": snappedf(minted, 0.01),
		"h2o_buried": snappedf(buried, 0.01),
		"h2o_displaced": snappedf(displaced, 0.01),
		"h2o_stale_rewind": snappedf(rewind_peak, 0.01),
		"mineral_inject_offered": snappedf(mineral_offered, 0.01),
		"mineral_inject_moved": snappedf(mineral_moved, 0.01),
		"mineral_inject_minted": snappedf(mineral_minted, 0.01),
		# BIOTIC — what living bodies took out of the field and put back (see BIOTIC_CHANNELS).
		"biotic_inject_offered": snappedf(biotic_offered, 0.01),
		"biotic_inject_moved": snappedf(biotic_moved, 0.01),
		"biotic_inject_short": snappedf(maxf(0.0, biotic_offered - biotic_moved), 0.01),
		"biotic_inject_minted": snappedf(biotic_minted, 0.01),
		"inject_flushed_cells": flushed_cells,
		"inject_add_cells": add_cells,
	}
