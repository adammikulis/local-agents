class_name LAMaterialCharge3D
extends RefCounted

## A DETECTOR. The charge relaxes in the OHMIC transport row and nothing here makes a flash happen; this
## names one where the column field has passed the runaway threshold the local air density sets.

var _f = null
var _visual: Callable = Callable()
var _bolts: int = 0
var _charge_peak: float = 0.0                            # C/m^3
var _e_peak: float = 0.0                                 # V/m


func setup(field) -> void:
	_f = field


func set_visual(cb: Callable) -> void:
	_visual = cb


## Run once per step after the readback. Reads only; it must never write the field or wake a channel.
func post_step() -> void:
	_scan()


## Peak charge density, the peak column field, and where that field is over threshold. All off the mirror
## the drain already delivered, so none of it changes residency.
func _scan() -> void:
	_charge_peak = 0.0
	_e_peak = 0.0
	if _f._charge.size() != _f._cell_count or _f._grid == null:
		return
	var dz: float = _f._grid.cell_size
	var eps0: float = LAPhysical.VACUUM_PERMITTIVITY_F_M
	# The column field is the charge integrated along the local vertical, so it is a march from every cell
	# whose neighbour below is rock: the ground under an air column.
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		if _f._charge[c] > _charge_peak:
			_charge_peak = _f._charge[c]
		var lo: int = LAFieldGeometry.below(_f, c)
		if lo < 0 or _f._solid[lo] == 0:
			continue                                  # not the bottom of an air column
		var sigma: float = 0.0
		var at: int = c
		while at >= 0 and _f._solid[at] == 0:
			sigma += _f._charge[at] * dz
			at = LAFieldGeometry.above(_f, at)
		var e: float = absf(sigma) / eps0
		if e > _e_peak:
			_e_peak = e
		if e < LAPhysical.RREA_THRESHOLD_V_M:
			continue
		_bolts += 1
		if _visual.is_valid():
			_visual.call(_f.cell_world_pos_linear(c))


func bolts_fired() -> int:
	return _bolts


func charge_peak() -> float:
	return _charge_peak


func e_peak_v_m() -> float:
	return _e_peak
