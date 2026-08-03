class_name LAMaterialFieldHeatQueue3D
extends LAMaterialFieldInjectQueue3D

## LAMaterialFieldHeatQueue3D: the pending-device-edit queue plus a THIRD book — TEMPERATURE.
##
## WHY IT IS A SUBCLASS AND NOT A `queue.add("temp", …)`. The base queue carries two ledgers, H₂O and MINERAL,
## and routes an edit into one of them by its channel name. `temp` belongs to neither: its unit is DEGREES, not
## mass, so folding it into `minted` would print a lightning bolt as water created from nothing and would make
## `h2o_inject_short` (demand minus moved) under-report every storm that ran on a dry footprint. A separate
## book is what lets a heat injection be applied through the SAME device-sparse path — the whole point of the
## queue — without corrupting the two conservation gauges the queue exists to publish.
##
## WHAT IT FIXES. `LAMaterialFieldInject3D.add_heat` used to write the CPU `_temp` mirror and call
## `mark_temp_dirty()`, which makes `LAMaterialSphereGPU3D.begin_frame` re-upload the WHOLE mirror over the
## live GPU temperature field. That mirror is one readback (up to two steps) old, so every heat injection threw
## away a step of solar absorption, radiative emission, conduction and buoyancy across all ~123,000 cells — to
## deliver a spike in a handful of them. This is exactly the rewind `add_vapor` was converted off, and the
## conversion simply never reached `add_heat`.
##
## THE ONE KNOWN LIMITATION, stated because it is a real inaccuracy and it is not mine to fix:
## `LAMaterialSphereGPU3D.add_field_sparse` ends with `after = maxf(0.0, before + delta)`. That floor is right
## for a MASS channel and wrong for a temperature in °C — a cell at -7 °C given +2 °C comes out at 0 °C rather
## than -5 °C, which creates heat, and a negative (cooling) edit can never take a cell below freezing at all.
## The proper fix is a signed sparse add (or a temperature channel in KELVIN, where a 0 floor is absolute zero
## and physically correct), and it lives in `MaterialSphereGPU3D.gd`, which another track owns. Measured on the
## baseline this matters little in practice — `clim_air_frozen` 0 of 32289 air cells, `clim_ground_frozen` 183
## of 4806, `clim_coldest_now` -7.4 °C — and every remaining injector dumps a LARGE positive spike (an impact,
## a bolt, a landing ejecta parcel), where the floor cannot bind. It is recorded here so it is not rediscovered.
## (Explicit types only, no ':=' inferred typing.)

# --- pending temperature edits (applied on device in flush, alongside the mass ops) --------------------------
var _t_cells: PackedInt32Array = PackedInt32Array()
var _t_deltas: PackedFloat32Array = PackedFloat32Array()

# --- cumulative THERMAL book (SIM_REPORT gauges) ------------------------------------------------------------
var heat_energy_j: float = 0.0     # ENERGY handed to add_heat_energy, in joules. This is the number that has
                                   # to come from somewhere: a bolt's electrostatic store, an impactor's
                                   # kinetic energy, a landing parcel's. It is booked here so a source that
                                   # stops being debited shows up as a rising figure with no matching debit.
var heat_unsourced_dc: float = 0.0 # DEGREES asked for by the raw `add_heat(pos, °C)` form, which names no
                                   # source at all. Two callers outside this substrate still use it
                                   # (CreatureDisease's fever, the editor's magma brush); keeping their demand
                                   # in its own figure is what stops "heat from nothing" hiding inside a total
                                   # that also contains properly sourced injections.
var heat_applied_dc: float = 0.0   # DEGREES the device actually applied (summed over cells), both forms.
var heat_cells: int = 0            # per-cell temperature edits that reached the device.


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
	return _t_cells.size() == 0 and super()


func flush(gpu) -> void:
	if gpu != null and _t_cells.size() > 0:
		heat_cells += _t_cells.size()
		heat_applied_dc += gpu.add_field_sparse("temp", _t_cells, _t_deltas)
		_t_cells = PackedInt32Array()
		_t_deltas = PackedFloat32Array()
	super(gpu)


func report() -> Dictionary:
	var out: Dictionary = super()
	out["heat_inject_j"] = snappedf(heat_energy_j, 0.01)
	out["heat_inject_unsourced_dc"] = snappedf(heat_unsourced_dc, 0.01)
	out["heat_inject_applied_dc"] = snappedf(heat_applied_dc, 0.01)
	out["heat_inject_cells"] = heat_cells
	return out
