class_name LAMaterialFieldInjectQueue3D
extends RefCounted

## LAMaterialFieldInjectQueue3D: the PENDING-DEVICE-EDIT queue and the H₂O injection LEDGER.
##
## Everything that injects into the field from the CPU (a storm lifting vapor, a flood surge, a cell of rock
## burying the water that was in it) parks its edit here, and the sphere-step loop flushes the whole queue on
## device just before it dispatches. Two things fall out of that, and both were bugs before this existed:
##
## 1. AN INJECTION ADDS, IT DOES NOT REWIND. The old path edited the CPU mirror and set a dirty flag, so the
##    step uploaded the WHOLE mirror over the live GPU buffer — but that mirror was last filled by a readback
##    one frame (up to two steps) old, so an injection frame replaced the device's current state with a stale
##    snapshot plus the injection, discarding whatever the kernels did in between. Every edit here is applied
##    to the LIVE buffer through LAMaterialSphereGPU3D.add_field_sparse / move_field_sparse instead.
##
## 2. A TRANSFER CANNOT MINT. `transfer()` names a SOURCE for every credit, and the move is resolved on device
##    against the live source values, so the debit and the credit are the same number by construction. What the
##    source could not supply shows up as `h2o_inject_short` (demand minus moved) and is reported — never
##    silently created. `minted` counts the edits that genuinely have no source (a scripted flood surge), so
##    that mass is visible rather than hidden inside a channel.
##
## The counters are cumulative over the run and published into SIM_REPORT by LAMaterialFieldReport3D, which is
## the whole point: a conservation law nothing reports is a claim, not a law.
## (Explicit types only, no ':=' inferred typing.)

## A per-cell amount this large means "take everything that is there" — move_field_sparse clamps the take to
## the live source value, so the caller gets an exact drain without knowing what the device holds.
const DRAIN_ALL: float = 1.0e30

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

# AUDIT (LA_INJECT_AUDIT=1): |CPU mirror total - live device total| for a channel at flush time. That gap IS
# the mass the old set_field-from-the-mirror upload would have written away, so a nonzero reading here is a
# direct measurement of the staleness this queue removes. Off by default — it costs a full-grid sum.
var rewind_peak: float = 0.0
var rewind_last: float = 0.0

var _ops: Array = []
var _index: Dictionary = {}    # op signature -> slot in _ops, so same-signature edits COALESCE (see _merge)


func is_empty() -> bool:
	return _ops.is_empty()


## Fold a new edit into the op with the same (kind, source channel, destination channel) signature instead of
## appending a second one. This is not tidiness, it is the cost model: every op costs a FULL-BUFFER device read
## and write-back, and a single thunderstorm frame issues one injection per seeding point (five, plus a soil
## pass each). Coalescing turns ~10 full-grid round-trips per storm frame into 2. Cells repeated across merged
## edits are still correct — move_field_sparse walks them in order against the values it is already updating.
func _merge(key: String, kind: String, src: String, dst: String, src_cells: PackedInt32Array,
		amounts: PackedFloat32Array, dst_cells: PackedInt32Array, ceiling: float) -> void:
	var slot: int = _index.get(key, -1)
	if slot < 0:
		_index[key] = _ops.size()
		_ops.append({"kind": kind, "src": src, "dst": dst, "src_cells": src_cells,
			"amounts": amounts, "dst_cells": dst_cells, "ceiling": ceiling})
		return
	var op: Dictionary = _ops[slot]
	var sc: PackedInt32Array = op["src_cells"]
	var am: PackedFloat32Array = op["amounts"]
	var dc: PackedInt32Array = op["dst_cells"]
	sc.append_array(src_cells)
	am.append_array(amounts)
	dc.append_array(dst_cells)
	op["src_cells"] = sc
	op["amounts"] = am
	op["dst_cells"] = dc


## Record the mass a transfer WANTED, before any of it is sourced. Kept separate from `transfer()` because one
## logical demand may be met from several source channels (a storm draws liquid first, then the water table),
## and because a demand with NO available source must still be counted — that case queues nothing at all and
## would otherwise vanish. `short` is then simply demand - moved, which is the number to look at.
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
	for a in amounts:
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


## Apply every queued edit to the LIVE device buffers and fold the results into the ledger. Call between the
## driver's drain and its dispatch (the GPU is idle there) — LAMaterialFieldSphereStep3D does exactly that.
func flush(gpu) -> void:
	if gpu == null or _ops.is_empty():
		return
	for op in _ops:
		var kind: String = String(op["kind"])
		if kind == "transfer":
			moved += gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
				op["dst"], op["dst_cells"], float(op["ceiling"]))
		elif kind == "displace":
			displaced += gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
				op["dst"], op["dst_cells"], float(op["ceiling"]))
		elif kind == "discard":
			buried += -gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"])
		elif kind == "add":
			minted += gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"], float(op["ceiling"]))
	_ops.clear()
	_index.clear()


## AUDIT hook (LA_INJECT_AUDIT=1 only): measure how far the CPU mirror of `channel` has drifted from the live
## device buffer at this instant. That difference is exactly what the old `set_field(channel, mirror)` upload
## would have written over the top of the kernels' work, so it is the direct evidence that an injection used
## to rewind the channel. Pure measurement — it changes nothing.
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
	}
