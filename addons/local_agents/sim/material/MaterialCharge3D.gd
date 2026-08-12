class_name LAMaterialCharge3D
extends RefCounted

## Bolt visuals and telemetry. Initiation, neutralisation, the discharge stamp and the heat all happen in
## charge_breakdown_sphere3d.glsl; this reads the strike list the kernel published and nothing more.

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
	if _f._gpu == null or not _f._gpu.has_method("strikes"):
		return
	_refresh_peaks()
	var struck: PackedInt32Array = _f._gpu.strikes()
	for c in struck:
		if c < 0 or c >= _f._cell_count:
			continue
		_bolts += 1
		if _visual.is_valid():
			_visual.call(_f.cell_world_pos_linear(c))


## Peak charge density, and the peak column field that decides breakdown. Both come off the mirror the drain
## already delivered, so neither changes residency.
func _refresh_peaks() -> void:
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
		var e: float = sigma / eps0
		if e > _e_peak:
			_e_peak = e


func bolts_fired() -> int:
	return _bolts


func charge_peak() -> float:
	return _charge_peak


func e_peak_v_m() -> float:
	return _e_peak
