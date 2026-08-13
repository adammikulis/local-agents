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
var heat_unsourced_dc: float = 0.0 # always 0: sourceless heat is refused by the seal now, and what it refused
                                   # is counted in `creation_after_seal`. LAMaterialFieldEnergyLedger3D still
                                   # reads this; the term is dead and that file's owner should drop it.
var heat_applied_j_m3: float = 0.0 # ENTHALPY DENSITY the device actually applied, summed over cells.
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
	coalesce(_c_ops, _c_index, key, {"src": src, "dst": dst, "ceiling": ceiling},
		src_cells, amounts, dst_cells)


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


## Queue a per-cell ENTHALPY edit. `cells[i]` gets `deltas[i]` J/m^3, applied to the LIVE device buffer at
## the next flush — never written to the CPU mirror, which the readback owns.
func queue_h(cells: PackedInt32Array, deltas: PackedFloat32Array) -> void:
	if cells.size() == 0 or cells.size() != deltas.size():
		return
	_t_cells.append_array(cells)
	_t_deltas.append_array(deltas)


## Book an ENERGY (joules) that was drawn from a named store and handed to the field as heat.
func note_energy(joules: float) -> void:
	heat_energy_j += joules


func is_empty() -> bool:
	return _t_cells.size() == 0 and _c_ops.is_empty() and super()


func flush(gpu) -> void:
	if gpu != null and _t_cells.size() > 0:
		heat_cells += _t_cells.size()
		heat_applied_j_m3 += gpu.add_field_sparse("h_j_m3", _t_cells, _t_deltas)
		_t_cells = PackedInt32Array()
		_t_deltas = PackedFloat32Array()
	if gpu != null and not _c_ops.is_empty():
		for op in _c_ops:
			carbon_cells += (op["src_cells"] as PackedInt32Array).size()
			var to_pool: bool = String(op["dst"]).is_empty()
			var applied: float = 0.0
			if to_pool:
				applied = gpu.add_field_sparse(op["src"], op["src_cells"], op["amounts"])
				carbon_returned += applied
			else:
				applied = gpu.move_field_sparse(op["src"], op["src_cells"], op["amounts"],
					op["dst"], op["dst_cells"], float(op["ceiling"]))
				carbon_moved += applied
			_credit_companions(gpu, String(op["src"]) if to_pool else String(op["dst"]),
				op["src_cells"] if to_pool else op["dst_cells"], op["amounts"], applied)
	_c_ops.clear()
	_c_index.clear()
	super(gpu)


## Credit the hydrogen and oxygen that travelled with a carbon edit into the dead organic pool, scaled by
## what the DEVICE actually applied. The request is a plan and the return value is the fact: crediting the
## plan is how a source-limited transfer would hand the pool H and O with no carbon under them.
func _credit_companions(gpu, channel: String, cells: PackedInt32Array, amounts: PackedFloat32Array,
		applied: float) -> void:
	if not DEAD_POOL_CARBON.has(channel) or applied <= 0.0:
		return
	var requested: float = 0.0
	var landed: PackedInt32Array = PackedInt32Array()
	var landed_amounts: PackedFloat32Array = PackedFloat32Array()
	for i in cells.size():
		if cells[i] < 0:
			continue
		landed.append(cells[i])
		landed_amounts.append(amounts[i])
		requested += amounts[i]
	if landed.size() == 0 or requested <= 0.0:
		return
	var f: float = minf(applied / requested, 1.0)
	for e in [["org_h", LASubstances.fresh_litter_per_carbon("H")],
			["org_o", LASubstances.fresh_litter_per_carbon("O")]]:
		var deltas: PackedFloat32Array = PackedFloat32Array()
		for v in landed_amounts:
			deltas.append(v * f * float(e[1]))
		gpu.add_field_sparse(String(e[0]), landed, deltas)


func report() -> Dictionary:
	var out: Dictionary = super()
	out["heat_inject_j"] = snappedf(heat_energy_j, 0.01)
	out["heat_inject_applied_j_m3"] = snappedf(heat_applied_j_m3, 0.01)
	out["heat_inject_cells"] = heat_cells
	out["carbon_inject_offered"] = snappedf(carbon_offered, 0.0001)
	out["carbon_inject_moved"] = snappedf(carbon_moved, 0.0001)
	out["carbon_inject_returned"] = snappedf(carbon_returned, 0.0001)
	out["carbon_inject_cells"] = carbon_cells
	return out
