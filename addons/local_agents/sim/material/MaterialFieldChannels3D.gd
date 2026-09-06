class_name LAMaterialFieldChannels3D
extends RefCounted

## LAMaterialFieldChannels3D: the per-cell CHANNEL accessors of LAMaterialField3D (the atmospheric gases,

## Cells a head may be buried under and still find air — a body half in rock, not a body entombed.
const HEAD_REACH: int = 4

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


# --- SMELL IS NOT A CHANNEL: an animal reads the airborne chemistry that is actually there. -----------

## Frozen H₂O in the cell at a world point, in channel units.
func snow_depth_at(pos: Vector3) -> float:
	var c: int = _f.world_to_cell(pos)
	return _f._queries.ice_at(c) if c >= 0 else 0.0


## An airborne substance in ONE cell, in that channel's own units. NAN when the substance is not airborne
## or its mirror is absent — a nose that cannot smell reads nothing, not zero.
func _airborne_at_cell(substance: String, c: int) -> float:
	if c < 0:
		return NAN
	match substance:
		"co2":
			return _f._mirrors.at("co2", c)
		"o2":
			return _f._mirrors.at("o2", c)
		"moisture":
			return _f._queries.vapour_at(c)
	return NAN


## Unit world direction UP the concentration gradient of an airborne substance — casting about for a smell.
## Zero where the air is uniform, which is the honest answer: there is nothing to follow.
func airborne_gradient(substance: String, world_pos: Vector3) -> Vector3:
	if _f._grid == null:
		return Vector3.ZERO
	if _f._gpu != null:
		_f._gpu.request_channel(substance)
	return LAFieldGeometry.gradient_at(_f, _f.world_to_cell(world_pos),
		func(i: int) -> float: return _airborne_at_cell(substance, i))


# --- Emergent atmospheric OXYGEN: O₂ level at a point + depletion diagnostics -------------------------

func o2_at(x: float, y: float, z: float) -> float:
	if _f._grid != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._mirrors.at("o2", c) if c >= 0 else LAMaterialField3D.O2_AMBIENT
	return LAMaterialField3D.O2_AMBIENT


func breathable_o2_at(x: float, y: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0:
		return LAMaterialField3D.O2_AMBIENT   # above the atmosphere shell = open sky
	# Water fills the cell → air is displaced → a lung drowns. Real; keep it (drowning + smoke stay 0).
	if _f._queries.liquid_at(c) >= LAMaterialField3D.MAX_MASS * 0.5:
		return 0.0
	if _f._solid[c] != 0:
		# Encased in rock unless a head-height march UP the local vertical reaches open air.
		c = LAFieldGeometry.air_above(_f, c, HEAD_REACH)
		if c < 0 or _f._queries.liquid_at(c) >= LAMaterialField3D.MAX_MASS * 0.5:
			return 0.0
	return _f._mirrors.at("o2", c)


## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	return c >= 0 and _f._solid[c] == 0 \
		and _f._queries.liquid_at(c) >= LAMaterialField3D.MAX_MASS * 0.5


# O2 min / mean over breathable open cells, reduced on the device; NAN when the reduction has not run.
func o2_min_open() -> float:
	return _f._queries.row_f("o2_open_min")


func o2_avg() -> float:
	var n: int = _f._queries.row_n("o2_open_cells")
	if n <= 0:
		return NAN
	return _f._queries.row_f("o2_open_sum") / float(n)


# --- Airborne MINERAL: the share of a cell's silicate the air is holding up ----------------------------

## Volume fraction of the cell that is wind-borne mineral: the amount times its derived airborne share.
func airborne_mineral_at(x: float, y: float, z: float) -> float:
	if _f._grid == null:
		return 0.0
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	return _f._queries.airborne_at(c)


# --- Emergent CARBON DIOXIDE (second gas channel): CO₂ level at a point + build-up diagnostics ---------

func co2_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")   # co2 is demand-gated; no producer-side event to hook, so query self-wakes it
	if _f._grid != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._mirrors.at("co2", c) if c >= 0 else 0.0
	return 0.0


# Peak and mean CO₂ over the open air. Reduced on the device off the co2 buffer, which is resident whether
# or not anything asked for its CPU mirror, so neither gauge requests a channel: residency decides which
# mirrors the simulation's own write paths read, and an instrument may not move it.
func co2_peak() -> float:
	return _f._queries.row_f("co2_open_max")


func co2_avg() -> float:
	var n: int = _f._queries.open_cells()
	if n <= 0:
		return NAN
	return _f._queries.row_f("co2_open_sum") / float(n)


# --- Emergent LIVING BIOMASS (MaterialReactions3D R19/R20): CO₂ fixed into plant matter on the GPU -----

func biomass_at(x: float, y: float, z: float) -> float:
	if _f._grid != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._mirrors.at("biomass", c) if c >= 0 else 0.0
	return 0.0


## Total living biomass over every open cell — the emergent-growth spot check (should rise then plateau, not
## explode; bounded by the CO₂ budget + respiration). The ledger's own open-cell row, volume-weighted.
func biomass_total() -> float:
	return _f._queries.row_f("open_biomass")




# Per-cell debug readers, pure reads for the DebugPanel field-view heatmaps.

## Volume fraction of the cell that is molten mineral: the amount times its derived melt share.
func melt_at(x: float, y: float, z: float) -> float:
	if _f._grid == null:
		return 0.0
	return _f._queries.melt_at(_f.world_to_cell(Vector3(x, y, z)))


## Volume fraction of the cell that is mineral, in any state.
func silicate_at(x: float, y: float, z: float) -> float:
	if _f._grid == null:
		return 0.0
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	return _f._mirrors.at("silicate", c) if c >= 0 else 0.0


func charge_at(x: float, y: float, z: float) -> float:
	if _f._grid != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._mirrors.at("charge", c) if c >= 0 else 0.0
	return 0.0


# --- Emergent DECOMPOSER loop: detritus (dead matter) → fungus → CO₂ + soil fertility -----------------

# Counting thresholds for the fungus_cells / detritus_cells gauges, mol/m^3. Gauge-only; no physics
# reads them — the decompose and die-back records are first-order all the way to zero.
const FUNGUS_PRESENT: float = 0.02 * LAPhysical.DRY_WOOD_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CH2O_UNIT_KG_MOL
const DETRITUS_PRESENT: float = 0.05 * LAPhysical.DRY_WOOD_DENSITY_KG_M3 / LAPhysical.MOLAR_MASS_CH2O_UNIT_KG_MOL


func fungus_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("fungus")
	if _f._grid != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._mirrors.at("fungus", c) if c >= 0 else 0.0
	return 0.0


## Extent and intensity of the decomposer loop, off the device. Null where the row is absent, never a zero
## that reads like "nothing is rotting".
func decomposer_stats() -> Dictionary:
	var q = _f._queries
	return {
		"fungus_peak": q.row_v("fungus_peak", false),
		"fungus_cells": q.row_v("fungus_cells", true),
		"detritus_peak": q.row_v("detritus_peak", false),
		"detritus_cells": q.row_v("detritus_cells", true),
	}
