class_name LAMaterialFieldLedger3D
extends RefCounted

## LAMaterialFieldLedger3D — the conserved H₂O LEDGER of LAMaterialField3D (plus the snow/ice diagnostics it
## is built from), factored out of the extract-only field hub. Same pattern as the query / atmos / scent
## modules: it holds no state of its own and reaches into the owning field `_f` for the shared channels.
##
## There is ONE conserved water substance stored in four phase channels — liquid `_water`, airborne
## `_moisture`, frozen `_snow`, subsurface `_soil`. Freeze / melt / deposition / evaporation / rain /
## infiltration are all pure TRANSFERS between them, so their sum (`h2o_total`) must stay BOUNDED: that is
## the mass-conservation spot check the SIM_REPORT prints. Snow and ice are the same channel read at two
## depths (SNOW_PRESENT = covered, ICE_DEPTH = glacial), not two buffers.
##
## Every method here is a pure getter over the GPU readback — O(cells) scans polled at snapshot time, never
## per frame. (Explicit types only — no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Snow depth at a world point (frozen H₂O in the cell). 2.5D-style (x,z) calls have no radial point, so they
## return the safe default 0 (matching temp_at); a full 3D call (x,z,y) reads the real cell — three-d-always.
func snow_depth_at(pos: Vector3) -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._snow[c] if c >= 0 else 0.0


## Open cells carrying a snowpack (frozen H₂O over SNOW_PRESENT) — the emergent snow-line count for SIM_REPORT.
func snow_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			n += 1
	return n


## Cells whose pack is thick enough to read as glacial ICE (deep end of the SAME _snow channel, no separate buffer).
func ice_cell_count() -> int:
	if _f._snow.size() != _f._cell_count:
		return 0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] >= LAMaterialField3D.ICE_DEPTH:
			n += 1
	return n


## Total frozen H₂O over the field (one leg of the conserved h2o_total).
func snow_total() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			sum += snow[c]
	return sum


## Total dynamic liquid water over the field (excludes the static sea reservoir; one leg of h2o_total).
func water_total() -> float:
	if _f._water.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var water: PackedFloat32Array = _f._water
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0 and stat[c] == 0:          # exclude the static sea reservoir (matches the docstring) —
			sum += water[c]                         # else the infinite-reservoir cells inflate the conserved ledger
	return sum


## Total water stored in the SOIL (ground cells) — the subsurface leg of the conserved h2o budget. Infiltrated
## water lives here rather than in _water, so it must be counted or conservation would appear to leak.
func soil_total() -> float:
	if _f._soil.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var soil: PackedFloat32Array = _f._soil
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] != 0:
			sum += soil[c]
	return sum


## Conserved H₂O budget of the DYNAMIC system: liquid water + airborne moisture + frozen snow + SOIL water.
## Freeze/melt/deposition/evap/rain/infiltration are all pure transfers between these, so this stays BOUNDED
## (a slow static-sea source + rain-to-sea sink hold it steady) — the mass-conservation spot check for SIM_REPORT.
func h2o_total() -> float:
	return water_total() + _f.moisture_total() + snow_total() + soil_total()


## Mean temperature over the snow-covered cells — proves snow sits on the COLD side (should read below FREEZE_TEMP).
func snow_line_temp() -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var snow: PackedFloat32Array = _f._snow
	var temp: PackedFloat32Array = _f._temp
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] == 0 and snow[c] > LAMaterialField3D.SNOW_PRESENT:
			sum += temp[c]
			n += 1
	return sum / float(n) if n > 0 else 0.0
