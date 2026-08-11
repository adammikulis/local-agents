class_name LAMaterialFieldHeatQueue3D
extends LAMaterialFieldInjectQueue3D

## LAMaterialFieldHeatQueue3D: the pending-device-edit queue plus a THIRD book — TEMPERATURE.

# --- pending temperature edits (applied on device in flush, alongside the mass ops) --------------------------
var _t_cells: PackedInt32Array = PackedInt32Array()
var _t_deltas: PackedFloat32Array = PackedFloat32Array()

# --- cumulative THERMAL book (SIM_REPORT gauges) ------------------------------------------------------------
var heat_energy_j: float = 0.0     # ENERGY handed to add_heat_energy, in joules. This is the number that has
                                   # to come from somewhere: a bolt's electrostatic store, an impactor's
                                   # kinetic energy, a landing parcel's. It is booked here so a source that
                                   # stops being debited shows up as a rising figure with no matching debit.
var heat_unsourced_dc: float = 0.0 # DEGREES asked for by the raw `add_heat(pos, °C)` form, which names no
var heat_applied_dc: float = 0.0   # DEGREES the device actually applied (summed over cells), both forms.
var heat_cells: int = 0            # per-cell temperature edits that reached the device.


# --- pending CARBON edits + their own book -------------------------------------------------------------------
var _c_ops: Array = []                 # {"src","src_cells","amounts","dst","dst_cells","ceiling"}
var _c_index: Dictionary = {}          # op signature -> slot in _c_ops, so same-signature edits COALESCE
var carbon_offered: float = 0.0        # carbon mass the CPU-side scan believed the source held
var carbon_moved: float = 0.0          # carbon mass the DEVICE actually moved (debit == credit by construction)
var carbon_returned: float = 0.0       # carbon mass handed BACK to the field from an actor's own stock
var carbon_cells: int = 0


func _c_merge(key: String, src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, ceiling: float) -> void:
	var slot: int = _c_index.get(key, -1)
	if slot < 0:
		_c_index[key] = _c_ops.size()
		_c_ops.append({"src": src, "src_cells": src_cells.duplicate(), "amounts": amounts.duplicate(),
			"dst": dst, "dst_cells": dst_cells.duplicate(), "ceiling": ceiling})
		return
	var op: Dictionary = _c_ops[slot]
	var sc: PackedInt32Array = (op["src_cells"] as PackedInt32Array).duplicate()
	var am: PackedFloat32Array = (op["amounts"] as PackedFloat32Array).duplicate()
	var dc: PackedInt32Array = (op["dst_cells"] as PackedInt32Array).duplicate()
	sc.append_array(src_cells)
	am.append_array(amounts)
	dc.append_array(dst_cells)
	op["src_cells"] = sc
	op["amounts"] = am
	op["dst_cells"] = dc


## Queue a CONSERVING carbon move. `dst_cells[i]` of -1 means the mass leaves the field entirely (into an
## actor that is now holding it and is expected to hand it back); `move_field_sparse` then debits the source
## and credits nobody, which is exactly the semantics that call wants.
func carbon_transfer(src: String, src_cells: PackedInt32Array, amounts: PackedFloat32Array,
		dst: String, dst_cells: PackedInt32Array, ceiling: float = INF) -> void:
	if src_cells.size() == 0 or src_cells.size() != amounts.size() or src_cells.size() != dst_cells.size():
		return
	for a in amounts:
		carbon_offered += a
	_c_merge("ct|%s|%s|%f" % [src, dst, ceiling], src, src_cells, amounts, dst, dst_cells, ceiling)


func carbon_return(channel: String, cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_c_merge("cr|%s" % channel, channel, cells, deltas, "", PackedInt32Array(), INF)


## Queue a per-cell temperature edit. `cells[i]` gets `deltas[i]` °C, applied to the LIVE device buffer at the
## next flush — never written to the CPU mirror, which the readback owns.
func queue_temp(cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_t_cells.append_array(cells)
	_t_deltas.append_array(deltas)


## Book an ENERGY (joules) that was drawn from a named store and handed to the field as heat.
func note_energy(joules: float) -> void:
	heat_energy_j += joules


## Book DEGREES demanded by the raw, sourceless `add_heat` form.
func note_unsourced(degrees_times_cells: float) -> void:
	heat_unsourced_dc += degrees_times_cells


func is_empty() -> bool:
	return _t_cells.size() == 0 and _c_ops.is_empty() and super()


func flush(gpu) -> void:
	if gpu != null and _t_cells.size() > 0:
		heat_cells += _t_cells.size()
		heat_applied_dc += gpu.add_field_sparse("temp", _t_cells, _t_deltas)
		_t_cells = PackedInt32Array()
		_t_deltas = PackedFloat32Array()
	if gpu != null and not _c_ops.is_empty():
		for op in _c_ops:
			carbon_cells += (op["src_cells"] as PackedInt32Array).size()
			if String(op["dst"]).is_empty():
				carbon_returned += gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"])
			else:
				carbon_moved += gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
					op["dst"], op["dst_cells"], float(op["ceiling"]))
	_c_ops.clear()
	_c_index.clear()
	super(gpu)


func report() -> Dictionary:
	var out: Dictionary = super()
	out["heat_inject_j"] = snappedf(heat_energy_j, 0.01)
	out["heat_inject_unsourced_dc"] = snappedf(heat_unsourced_dc, 0.01)
	out["heat_inject_applied_dc"] = snappedf(heat_applied_dc, 0.01)
	out["heat_inject_cells"] = heat_cells
	out["carbon_inject_offered"] = snappedf(carbon_offered, 0.0001)
	out["carbon_inject_moved"] = snappedf(carbon_moved, 0.0001)
	out["carbon_inject_returned"] = snappedf(carbon_returned, 0.0001)
	out["carbon_inject_cells"] = carbon_cells
	return out
