class_name LAMaterialFieldInjectQueue3D
extends RefCounted

## LAMaterialFieldInjectQueue3D: the PENDING-DEVICE-EDIT queue and the H₂O injection LEDGER.

## A per-cell amount this large means "take everything that is there" — move_field_sparse clamps the take to
## the live source value, so the caller gets an exact drain without knowing what the device holds.
const DRAIN_ALL: float = 1.0e30

const MINERAL_CHANNELS: PackedStringArray = ["rock_fill", "lava", "sediment", "susp", "dust"]

const BIOTIC_CHANNELS: PackedStringArray = ["biomass", "o2", "co2", "detritus", "fuel", "org_h", "org_o"]

# The dead organic pool's CARBON channels. Everything a living body hands back is fresh CH2O, so a credit into
# one of these has to credit the pool's hydrogen and oxygen stocks in the same breath — otherwise the returned
# matter reads as pure carbon and the composition the reaction engine divides by is a lie.
const DEAD_POOL_CARBON: PackedStringArray = ["detritus", "fuel"]

# --- cumulative H₂O injection ledger (SIM_REPORT gauges) ---------------------------------------------------
var demand: float = 0.0        # mass transfers ASKED their sources for. Before this fix the same figure was
                               # created out of nothing every time, so it doubles as the old mint rate.
var offered: float = 0.0       # mass the CPU-side scan BELIEVED its sources held. Splitting this out of
                               # `moved` is what separates "the footprint really is dry" (offered ~ 0) from
                               # "the scan found sources but the device disagreed" (offered > 0, moved 0) —
                               # two very different bugs that look identical in a shortfall figure alone.
var moved: float = 0.0         # mass actually transferred (source debited, sink credited — closed)
var minted: float = 0.0        # mass added with NO source at all (a flood surge). Honest, not hidden.
var buried: float = 0.0        # mass discarded because a cell turned solid with nowhere to displace it to
var displaced: float = 0.0     # mass a solidifying/melting cell handed to a neighbour instead of stranding

# --- cumulative MINERAL ledger (same mechanism, separate books — see MINERAL_CHANNELS) ----------------------
# MaterialFieldInject3D.gd:493-494 (device-resolved, so it lands in `mineral_moved`), and the ONLY `add()` on a
var mineral_offered: float = 0.0   # mineral mass a transfer's CPU-side scan believed its source held
var mineral_moved: float = 0.0     # TRANSFER: mass actually moved between phases — device-resolved, so debit
# --- cumulative BIOTIC ledger (same mechanism, third set of books — see BIOTIC_CHANNELS) --------------------
var biotic_offered: float = 0.0
var biotic_moved: float = 0.0
var biotic_minted: float = 0.0

var mineral_minted: float = 0.0    # SOURCE: mass added with NO debit anywhere in the field — the vent drawing

# AUDIT (LA_INJECT_AUDIT=1): |CPU mirror total - live device total| for a channel at flush time. That gap IS
# the mass the old set_field-from-the-mirror upload would have written away, so a nonzero reading here is a
# direct measurement of the staleness this queue removes. Off by default — it costs a full-grid sum.
var rewind_peak: float = 0.0
var rewind_last: float = 0.0

## Per-cell edits that actually reached a device primitive. An edit queued but never flushed is invisible in
## every other counter here — the totals only ever grow from what `flush` applied — so without this a lost
## queue looks exactly like a queue whose sources were all empty.
var flushed_cells: int = 0
var add_cells: int = 0         # ...of which belonged to `add` ops, so a credit that returned nothing is
                               # distinguishable from a credit that was never queued

var _ops: Array = []
var _index: Dictionary = {}    # op signature -> slot in _ops, so same-signature edits COALESCE (see _merge)


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


## Queue a CONSERVING transfer: take up to `amounts[i]` out of `src` at `src_cells[i]` and credit exactly what
## came out into `dst` at `dst_cells[i]`. The debit is resolved against the live source on device, so the two
## sides are equal by construction and this can never mint, however stale the mirror it was planned against.
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


## Queue a DISPLACEMENT: empty `src_cells[i]` of `channel` into `dst_cells[i]` of `dst_channel`. Used when a
## cell stops being able to hold what is in it (rock grows over water, rock melts and frees its pore water).
func displace(channel: String, src_cells: PackedInt32Array, dst_channel: String, dst_cells: PackedInt32Array) -> void:
	if src_cells.size() == 0 or src_cells.size() != dst_cells.size():
		return
	var amounts: PackedFloat32Array = PackedFloat32Array()
	amounts.resize(src_cells.size())
	amounts.fill(DRAIN_ALL)
	_merge("d|%s|%s" % [channel, dst_channel], "displace", channel, dst_channel, src_cells, amounts, dst_cells, INF)


## Queue a DISCARD: empty `cells` of `channel` with nowhere for the mass to go. The amount actually removed is
## added to `buried` so the loss appears in SIM_REPORT — the ledger stays closed because the residual is named.
func discard(channel: String, cells: PackedInt32Array) -> void:
	if cells.size() == 0:
		return
	var deltas: PackedFloat32Array = PackedFloat32Array()
	deltas.resize(cells.size())
	deltas.fill(-DRAIN_ALL)
	_merge("x|%s" % channel, "discard", channel, channel, cells, deltas, cells, INF)


## Queue a SOURCELESS add — mass that genuinely comes from outside the field (a scripted flood surge, a debug
## rain key). Counted in `minted` precisely because it is not conserved; nothing here hides it.
func add(channel: String, cells: PackedInt32Array, deltas: PackedFloat32Array, ceiling: float = INF) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_merge("a|%s|%f" % [channel, ceiling], "add", channel, channel, cells, deltas, cells, ceiling)
	fresh_companions(channel, cells, deltas)


## Credit the hydrogen and oxygen that came in with a fresh-litter carbon credit. A no-op for every other
## channel, and it cannot recurse: org_h and org_o are not dead-pool carbon.
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


## Apply every queued edit to the LIVE device buffers and fold the results into the ledger. Call between the
## driver's drain and its dispatch (the GPU is idle there) — LAMaterialFieldSphereStep3D does exactly that.
func flush(gpu) -> void:
	if gpu == null or _ops.is_empty():
		return
	for op in _ops:
		flushed_cells += (op["src_cells"] as PackedInt32Array).size()
		var kind: String = String(op["kind"])
		if kind == "transfer":
			var m: float = gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
				op["dst"], op["dst_cells"], float(op["ceiling"]))
			if MINERAL_CHANNELS.has(String(op["src"])):
				mineral_moved += m
			elif BIOTIC_CHANNELS.has(String(op["src"])):
				biotic_moved += m
			else:
				moved += m
		elif kind == "displace":
			displaced += gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
				op["dst"], op["dst_cells"], float(op["ceiling"]))
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


## The ledger, as SIM_REPORT gauges. `h2o_inject_demand` is what storms asked for and, before this fix, simply
## created; `h2o_inject_moved` is what the planet actually supplied; `h2o_inject_short` is the difference and
## is the honest measure of a storm running on a dry footprint.
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
		# `biotic_inject_short` is grass an animal bit at that the device did not actually hold.
		"biotic_inject_offered": snappedf(biotic_offered, 0.01),
		"biotic_inject_moved": snappedf(biotic_moved, 0.01),
		"biotic_inject_short": snappedf(maxf(0.0, biotic_offered - biotic_moved), 0.01),
		"biotic_inject_minted": snappedf(biotic_minted, 0.01),
		"inject_flushed_cells": flushed_cells,
		"inject_add_cells": add_cells,
	}
