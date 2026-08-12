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
	if _f._charge.size() != _f._cell_count:
		return
	var grid: RefCounted = _f.sphere_grid()
	if grid == null:
		return
	var depth: int = int(grid.depth)
	var surf: int = int(grid.surf_count)
	if depth <= 0 or surf * depth != _f._cell_count:
		return
	var tbl: PackedFloat32Array = grid.shell_table()
	var eps0: float = LAPhysical.VACUUM_PERMITTIVITY_F_M
	for s in surf:
		var base: int = s * depth
		var sigma: float = 0.0
		for r in depth:
			var c: int = base + r
			if _f._solid[c] == 0:
				var q: float = _f._charge[c]
				sigma += q * tbl[r * 4]
				if q > _charge_peak:
					_charge_peak = q
		var e: float = sigma / eps0
		if e > _e_peak:
			_e_peak = e


func bolts_fired() -> int:
	return _bolts


func charge_peak() -> float:
	return _charge_peak


func e_peak_v_m() -> float:
	return _e_peak
