class_name LAMaterialFieldAtmos3D
extends RefCounted

## The field's cloud, fog and vapour, read off the device's reduce rows.

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Cloud and fog cell counts and the vapour off the device, NAN when absent.
func refresh_aggregates() -> void:
	_f._atmos_dirty = false
	var q = _f._queries
	var cell_count: int = _f._cell_count
	var cloud_n: int = q.row_n("cloud_cells")
	var fog_n: int = q.row_n("fog_cells")
	var inv: float = 1.0 / float(cell_count) if cell_count > 0 else 0.0
	_f._cloud_cells_c = cloud_n
	_f._cloud_cover_c = float(cloud_n) * inv if cloud_n >= 0 else NAN
	_f._fog_cover_c = float(fog_n) * inv if fog_n >= 0 else NAN
	_f._vapour_total_c = q.row_f("vapour_amount")


func avg_cloud_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cover_c


func avg_fog_cover() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._fog_cover_c


## Airborne H2O over every cell, no residency mask, in moles.
func vapour_total() -> float:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._vapour_total_c


## Cells whose condensate hangs above the surface layer.
func cloud_cell_count() -> int:
	if _f._atmos_dirty:
		refresh_aggregates()
	return _f._cloud_cells_c
