class_name LAMaterialFieldChannels3D
extends RefCounted

const CellVolScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldCellVolume3D.gd")

## LAMaterialFieldChannels3D: the per-cell CHANNEL accessors of LAMaterialField3D (the atmospheric gases,

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


# --- SMELL IS NOT A CHANNEL. IT IS READING THE AIRBORNE CHEMISTRY THAT IS ACTUALLY THERE. ------------------
# There is no `scent` channel: smell is generic over the substance. An animal reads the concentration of a

## Frozen H₂O in the cell at a world point, in channel units. A 2.5D (x,z) call has no radial point and
## returns 0, matching temp_at; a full 3D call reads the real cell.
func snow_depth_at(pos: Vector3) -> float:
	if _f._snow.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(pos)
	return _f._snow[c] if c >= 0 else 0.0


## CPU mirror of an airborne channel, or an empty array when that channel is not one.
func _airborne_mirror(substance: String) -> PackedFloat32Array:
	match substance:
		"co2": return _f._co2
		"o2": return _f._o2
		"moisture": return _f._moisture
		"dust": return _f._dust
	return PackedFloat32Array()


## Concentration of an airborne substance at a world point, in that channel's own units.
func airborne_at(substance: String, world_pos: Vector3) -> float:
	var m: PackedFloat32Array = _airborne_mirror(substance)
	if m.size() != _f._cell_count or _f._sphere == null:
		return 0.0
	if _f._gpu != null:
		_f._gpu.request_channel(substance)
	var c: int = _f.world_to_cell(world_pos)
	return m[c] if c >= 0 else 0.0


## Unit world direction UP the concentration gradient of an airborne substance — casting about for a smell.
## Zero where the air is uniform, which is the honest answer: there is nothing to follow.
func airborne_gradient(substance: String, world_pos: Vector3) -> Vector3:
	var m: PackedFloat32Array = _airborne_mirror(substance)
	if m.size() != _f._cell_count or _f._sphere == null:
		return Vector3.ZERO
	if _f._gpu != null:
		_f._gpu.request_channel(substance)
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return Vector3.ZERO
	var pos_c: Vector3 = _f.cell_world_pos_linear(c)
	var here: float = m[c]
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var grad: Vector3 = Vector3.ZERO
	for d in range(6):
		var nb: int = nbr[c * 6 + d]
		if nb < 0 or _f._solid[nb] != 0:
			continue
		var dir: Vector3 = _f.cell_world_pos_linear(nb) - pos_c
		if dir.length_squared() < 1.0e-8:
			continue
		grad += dir.normalized() * (m[nb] - here)
	if grad.length_squared() < 1.0e-8:
		return Vector3.ZERO
	return grad.normalized()


# --- Emergent atmospheric OXYGEN: O₂ level at a point + depletion diagnostics -------------------------

func o2_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._o2[c] if c >= 0 else LAMaterialField3D.O2_AMBIENT
	return LAMaterialField3D.O2_AMBIENT


func breathable_o2_at(x: float, y: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0:
		return LAMaterialField3D.O2_AMBIENT   # above the atmosphere shell = open sky
	# Water fills the cell → air is displaced → a lung drowns. Real; keep it (drowning + smoke stay 0).
	if _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5:
		return 0.0
	if _f._solid[c] != 0:
		if _f._sphere == null:
			return 0.0                        # box mode (unused in the sim): keep the strict rule
		var steps: int = 0
		while _f._solid[c] != 0 and steps < 4:
			var up_c: int = _f._sphere.neighbours[c * 6 + 1]   # N_OUT = 1 (radially outward)
			if up_c < 0:
				return 0.0                    # reached space while still in rock → encased
			c = up_c
			steps += 1
		if _f._solid[c] != 0 or _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5:
			return 0.0
	return _f._o2[c]


## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	return c >= 0 and _f._solid[c] == 0 and _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5


# Open-cell O₂ min / mean over the GPU readback (_o2). Proves the sky-refill + transport keep the open air
# oxygenated and expose sealed-cavity draw-down. Falls back to ambient when no field is resident.
func o2_min_open() -> float:
	if _f._o2.size() != _f._cell_count or _f._cell_count <= 0:
		return LAMaterialField3D.O2_AMBIENT
	var solid: PackedByteArray = _f._solid
	var water: PackedFloat32Array = _f._water
	var o2: PackedFloat32Array = _f._o2
	var flooded: float = LAMaterialField3D.MAX_MASS * 0.5
	var mn: float = 1.0e20
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0 or water[c] >= flooded:
			continue
		mn = minf(mn, o2[c])
		n += 1
	return mn if n > 0 else LAMaterialField3D.O2_AMBIENT


func o2_avg() -> float:
	if _f._o2.size() != _f._cell_count or _f._cell_count <= 0:
		return LAMaterialField3D.O2_AMBIENT
	var solid: PackedByteArray = _f._solid
	var water: PackedFloat32Array = _f._water
	var o2: PackedFloat32Array = _f._o2
	var flooded: float = LAMaterialField3D.MAX_MASS * 0.5
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0 or water[c] >= flooded:
			continue
		sum += o2[c]
		n += 1
	return sum / float(n) if n > 0 else LAMaterialField3D.O2_AMBIENT


# --- Airborne DUST (the mineral ledger's "airborne" phase) ---------------------------------------------

## Airborne wind-lofted dust at a world point. `dust` is demand-gated exactly like `co2`, so the query
## self-wakes its readback the same way — without that, a caller reads whatever the last crater left in the
## `return 0.0`; this is its real body.
func dust_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("dust")
	if _f._sphere != null and _f._dust.size() == _f._cell_count:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._dust[c] if c >= 0 else 0.0
	return 0.0


# --- Emergent CARBON DIOXIDE (second gas channel): CO₂ level at a point + build-up diagnostics ---------

func co2_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")   # co2 is demand-gated; no producer-side event to hook, so query self-wakes it
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._co2[c] if c >= 0 else 0.0
	return 0.0


func co2_peak() -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")
	if _f._co2.size() != _f._cell_count or _f._cell_count <= 0:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var co2: PackedFloat32Array = _f._co2
	var mx: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			mx = maxf(mx, co2[c])
	return mx


func co2_avg() -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")
	if _f._co2.size() != _f._cell_count or _f._cell_count <= 0:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var co2: PackedFloat32Array = _f._co2
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0:
			continue
		sum += co2[c]
		n += 1
	return sum / float(n) if n > 0 else 0.0


# --- Emergent LIVING BIOMASS (MaterialReactions3D R19/R20): CO₂ fixed into plant matter on the GPU -----

func biomass_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._biomass[c] if (c >= 0 and _f._biomass.size() == _f._cell_count) else 0.0
	return 0.0


## Total living biomass over every open cell — the emergent-growth spot check (should rise then plateau, not
## explode; bounded by the CO₂ budget + respiration). Fed into SIM_REPORT.
func biomass_total() -> float:
	return CellVolScript.weighted(_f._biomass, CellVolScript.of(_f), _f._solid, true)




# Per-cell debug readers for the phase channels (mirror biomass_at/co2_at): molten mineral, bedrock
# fraction, and pre-lightning electrification. Pure reads for the DebugPanel field-view heatmaps.
func lava_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		if _f._gpu != null:
			_f._gpu.request_channel("lava")   # keep lava readback hot while something queries it
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._lava[c] if (c >= 0 and _f._lava.size() == _f._cell_count) else 0.0
	return 0.0


func rock_fill_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._rock_fill[c] if (c >= 0 and _f._rock_fill.size() == _f._cell_count) else 0.0
	return 0.0


func charge_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._charge[c] if (c >= 0 and _f._charge.size() == _f._cell_count) else 0.0
	return 0.0


# --- Emergent DECOMPOSER loop: detritus (dead matter) → fungus → CO₂ + soil fertility -----------------

const FUNGUS_PRESENT: float = 0.02        # == fungus_sphere3d.glsl FUNGUS_MIN
const DETRITUS_PRESENT: float = 0.05      # == fungus_sphere3d.glsl DETRITUS_MIN


func fungus_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("fungus")
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._fungus[c] if (c >= 0 and _f._fungus.size() == _f._cell_count) else 0.0
	return 0.0


func decomposer_stats() -> Dictionary:
	if _f._gpu != null:
		_f._gpu.request_channel("fungus")
		_f._gpu.request_channel("detritus")
	var out: Dictionary = {"fungus_peak": 0.0, "fungus_cells": 0, "detritus_peak": 0.0, "detritus_cells": 0}
	var cc: int = _f._cell_count
	if cc <= 0:
		return out
	var solid: PackedByteArray = _f._solid
	var fung: PackedFloat32Array = _f._fungus
	var det: PackedFloat32Array = _f._detritus
	var has_fung: bool = fung.size() == cc
	var has_det: bool = det.size() == cc
	if solid.size() != cc or not (has_fung or has_det):
		return out
	var f_peak: float = 0.0
	var f_n: int = 0
	var d_peak: float = 0.0
	var d_n: int = 0
	for c in cc:
		if solid[c] != 0:
			continue
		if has_fung:
			var fv: float = fung[c]
			f_peak = maxf(f_peak, fv)
			if fv >= FUNGUS_PRESENT:
				f_n += 1
		if has_det:
			var dv: float = det[c]
			d_peak = maxf(d_peak, dv)
			if dv >= DETRITUS_PRESENT:
				d_n += 1
	out["fungus_peak"] = f_peak
	out["fungus_cells"] = f_n
	out["detritus_peak"] = d_peak
	out["detritus_cells"] = d_n
	return out
