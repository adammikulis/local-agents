class_name LAMaterialLiquid
extends RefCounted

## LAMaterialLiquid — the FLUIDS concern of the material field (water + lava shallow-water CA).
##
## Split out of LAMaterialField: this module owns the shallow-water cellular automaton that moves the
## WATER and LAVA materials. Water rains, flows downhill by surface head, fills sub-sea-level basins
## into oceans and evaporates to airborne VAPOR; lava (a slow, hot liquid) runs the SAME flow rule
## with a much smaller flow factor, sustains its molten heat, and SOLIDIFIES back to rock (SDF fill)
## when it cools. Extreme surface heat (a big meteor/volcano) MELTS rock to lava (SDF carve). Rivers,
## lakes, oceans and lava flows all EMERGE from these local rules — nothing is scripted per-case.
##
## It holds NO grid state of its own beyond its own fluid state (rain rate, melt cooldown/cursor, lava
## diagnostics); it reaches back into the owning LAMaterialField (`_f`) for the shared grid state
## (`_temp`, `_mats`, `_vapor`, `_terrain_h`, `_sampled`, `_cell_count`, `_dim`, `_cell_size`,
## `_terrain`, the index helpers `_cell_x`/`_cell_z`/`_mat_array`, `sea_level`, `STEP_DT`,
## `WATER_THRESHOLD`, `EVAP_TEMP_REF`, `EVAP_TEMP_GAIN`) and SETS the render dirty flags
## (`_f._liquid_dirty` / `_f._lava_dirty`). Behaviour is identical to the old inline code.
## (Explicit types only — no ':=' inferred typing.)

# Material registry (preloaded so cross-file constants resolve without an editor class-scan).
const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")
# Render module (for its RENDER_THRESHOLD const — the "any wet cell to render" cutoff).
const RenderScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialRender.gd")

# --- Liquid CA (ported verbatim from the retired LAWaterFieldSystem; WATER is a material in the field).
# The shallow-water redistribution is generic over liquids — WATER uses these constants; LAVA runs the
# same rule with a much smaller flow factor and no evaporation/sea-fill.
const FLOW_FACTOR: float = 0.25
const MAX_PAIR_FRACTION: float = 0.5
const EVAP_PER_STEP: float = 0.0035
const SEA_FILL_RATE: float = 0.6

# --- Phase changes (temperature-driven). Water freezes to ice below 0°C (frozen cells hold solid).
# LAVA is molten rock: a slow, hot liquid that pumps heat into the field, GLOWS, and SOLIDIFIES back
# to rock (SDF fill) when it cools; surface rock MELTS to lava above 1200°C (a big meteor/volcano). ---
const FREEZE_TEMP: float = 0.0            # water freezes below this (°C)
const LAVA_FLOW: float = 0.05             # viscous slow creep (water is 0.25)
# LAVA_MIN lives on the field (shared with the render module, read as _f.LAVA_MIN).
const LAVA_EMPLACE_TEMP: float = 1150.0   # temperature fresh lava carries
const LAVA_HEAT_PER_DEPTH: float = 650.0  # °C/s a lava cell sustains per unit depth (thick stays molten)
const SOLIDIFY_TEMP: float = 800.0        # lava freezes to rock below this
const MELT_TEMP: float = 1200.0           # surface rock melts to lava above this
const MELT_MAX_EDITS: int = 40            # cap melt/solidify SDF edits per step
const MELT_RADIUS: float = 2.0
const MELT_CHECK_INTERVAL: float = 0.2

var _f = null                             # back-reference to the owning LAMaterialField

var _rain_rate: float = 0.0               # WATER depth-per-second input (add_rain)
var _melt_cd: float = 0.0                  # melt-check throttle countdown
var _melt_cursor: int = 0                  # rotating scan cursor for melt edits
var _lava_cells_last: int = 0             # diagnostic: current lava cells
var _lava_peak: int = 0                   # diagnostic: most lava cells ever live at once


func setup(field) -> void:
	_f = field


# --- Frame-driven entry points (called by the field) ------------------------

## One liquid CA tick: water rain + flow + sea-fill + evaporation-to-vapor, then the lava step. Called
## from the field's _material_step (throttled by the CA clock).
func step() -> void:
	var water: PackedFloat32Array = _f._mat_array(Mat.WATER)

	# RAIN — uniform depth input driven by the current rate.
	if _rain_rate > 0.0:
		var add: float = _rain_rate * _f.STEP_DT
		if add > 0.0:
			for idx in range(_f._cell_count):
				if _f._sampled[idx] != 0:
					water[idx] += add

	# FLOW (frozen cells hold solid), then ocean fill + evaporation.
	_flow_liquid(water, FLOW_FACTOR, true)
	var any_wet: bool = false
	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0:
			continue
		var nd: float = water[idx]
		var floor_h: float = _f._terrain_h[idx]
		if floor_h < _f.sea_level:
			var target: float = _f.sea_level - floor_h
			if nd < target:
				nd = move_toward(nd, target, SEA_FILL_RATE)
		if nd > 0.0 and _f._temp[idx] >= FREEZE_TEMP:          # frozen water doesn't evaporate
			# Evaporate faster from warm water; the lost depth becomes airborne VAPOR (not deleted),
			# which is what later condenses into cloud/fog. Cold water barely steams.
			var ef: float = clampf(1.0 + _f.EVAP_TEMP_GAIN * (_f._temp[idx] - _f.EVAP_TEMP_REF), 0.15, 3.0)
			var evap: float = minf(nd, EVAP_PER_STEP * 1.3 * ef)
			nd -= evap
			_f._vapor[idx] += evap
			if nd < 0.0:
				nd = 0.0
		water[idx] = nd
		if nd >= RenderScript.RENDER_THRESHOLD:
			any_wet = true

	# Rebuild the surface while wet, plus one extra pass to clear it when it dries out.
	_f._liquid_dirty = any_wet or (_f._render._surface_mesh != null and _f._render._surface_mesh.get_surface_count() > 0)

	# LAVA (a slow, hot liquid) flows, heats, and freezes to rock — the same machinery as water.
	if _f._mats.has(Mat.LAVA):
		_lava_step()


## Throttled + capped rock-melting check (owns its cooldown). Called every frame from the field.
func melt_tick(delta: float) -> void:
	_melt_cd -= delta
	if _melt_cd <= 0.0:
		_melt_cd = MELT_CHECK_INTERVAL
		_melt_step()


# --- Public API (delegated from the field) ----------------------------------

## Set the uniform WATER rain rate (depth metres per SECOND), applied each step scaled by STEP_DT.
func add_rain(amount_per_sec: float) -> void:
	if is_nan(amount_per_sec) or is_inf(amount_per_sec):
		return
	_rain_rate = maxf(0.0, amount_per_sec)


## Dump WATER depth at a world point (a spring / test source). No-op outside the grid / unsampled.
func add_source(world_pos: Vector3, amount: float) -> void:
	_f.add_material(world_pos, Mat.WATER, amount, 0.0)


func lava_cell_count() -> int:
	return _lava_cells_last


func lava_peak() -> int:
	return _lava_peak


# --- Liquid movement (WATER + LAVA reuse this with different params) ----------

## Generic shallow-water redistribution of a liquid array by SURFACE head (terrain_h + own depth).
## Accumulates net change in the field's _mdelta and applies it. `freeze_aware` skips frozen cells
## (temp < 0°C) as sources so a frozen lake sits solid. Used by both WATER and (slow) LAVA.
func _flow_liquid(arr: PackedFloat32Array, flow_factor: float, freeze_aware: bool) -> void:
	var dim: int = _f._dim
	for idx in range(_f._cell_count):
		_f._mdelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _f._sampled[idx] == 0:
				continue
			var d: float = arr[idx]
			if d <= 0.0:
				continue
			if freeze_aware and _f._temp[idx] < FREEZE_TEMP:
				continue                                    # frozen solid — does not flow
			var head: float = _f._terrain_h[idx] + d
			var n0: int = -1
			var n1: int = -1
			var n2: int = -1
			var n3: int = -1
			var dh0: float = 0.0
			var dh1: float = 0.0
			var dh2: float = 0.0
			var dh3: float = 0.0
			var total_diff: float = 0.0
			if i > 0:
				var li: int = idx - 1
				if _f._sampled[li] != 0:
					var lh: float = _f._terrain_h[li] + arr[li]
					if lh < head:
						n0 = li
						dh0 = head - lh
						total_diff += dh0
			if i < dim - 1:
				var ri: int = idx + 1
				if _f._sampled[ri] != 0:
					var rh: float = _f._terrain_h[ri] + arr[ri]
					if rh < head:
						n1 = ri
						dh1 = head - rh
						total_diff += dh1
			if j > 0:
				var di: int = idx - dim
				if _f._sampled[di] != 0:
					var dhh: float = _f._terrain_h[di] + arr[di]
					if dhh < head:
						n2 = di
						dh2 = head - dhh
						total_diff += dh2
			if j < dim - 1:
				var ui: int = idx + dim
				if _f._sampled[ui] != 0:
					var uh: float = _f._terrain_h[ui] + arr[ui]
					if uh < head:
						n3 = ui
						dh3 = head - uh
						total_diff += dh3
			if total_diff <= 0.0:
				continue
			var move_total: float = minf(d, total_diff * flow_factor)
			if move_total <= 0.0:
				continue
			var scale: float = move_total / total_diff
			if n0 >= 0:
				var f0: float = minf(dh0 * scale, dh0 * MAX_PAIR_FRACTION)
				_f._mdelta[idx] -= f0
				_f._mdelta[n0] += f0
			if n1 >= 0:
				var f1: float = minf(dh1 * scale, dh1 * MAX_PAIR_FRACTION)
				_f._mdelta[idx] -= f1
				_f._mdelta[n1] += f1
			if n2 >= 0:
				var f2: float = minf(dh2 * scale, dh2 * MAX_PAIR_FRACTION)
				_f._mdelta[idx] -= f2
				_f._mdelta[n2] += f2
			if n3 >= 0:
				var f3: float = minf(dh3 * scale, dh3 * MAX_PAIR_FRACTION)
				_f._mdelta[idx] -= f3
				_f._mdelta[n3] += f3
	for idx in range(_f._cell_count):
		if _f._sampled[idx] != 0:
			arr[idx] = maxf(0.0, arr[idx] + _f._mdelta[idx])


# LAVA: flow (slow) + sustain heat + solidify to rock. Same machinery as water, different params.
func _lava_step() -> void:
	var lava: PackedFloat32Array = _f._mats[Mat.LAVA]
	_flow_liquid(lava, LAVA_FLOW, false)
	var any_lava: bool = false
	var edits: int = 0
	for idx in range(_f._cell_count):
		if _f._sampled[idx] == 0:
			continue
		var d: float = lava[idx]
		if d < _f.LAVA_MIN:
			if d > 0.0:
				lava[idx] = 0.0
			continue
		# Molten lava sustains heat UP TO its molten temperature (never hotter — no runaway). Thick
		# flows top back up to molten each step and stay liquid; thin edges can't keep up with cooling
		# and crust over. The cap also means lava (<=1150°C) never re-melts rock (which needs 1200°C).
		if _f._temp[idx] < LAVA_EMPLACE_TEMP:
			_f._temp[idx] = minf(LAVA_EMPLACE_TEMP, _f._temp[idx] + LAVA_HEAT_PER_DEPTH * d * _f.STEP_DT)
		if _f._temp[idx] < SOLIDIFY_TEMP and edits < MELT_MAX_EDITS and _f._terrain != null and _f._terrain.has_method("fill_sphere"):
			# Cooled: freeze to rock — the flow builds new terrain where it stops.
			var i: int = idx % _f._dim
			var j: int = idx / _f._dim
			_f._terrain.fill_sphere(Vector3(_f._cell_x(i), _f._terrain_h[idx] + d, _f._cell_z(j)), clampf(d, 0.6, _f._cell_size))
			_f._terrain_h[idx] = _f._terrain_h[idx] + d * 0.7
			lava[idx] = 0.0
			edits += 1
		elif lava[idx] > 0.0:
			any_lava = true
	_f._lava_dirty = any_lava or (_f._render._lava_mesh != null and _f._render._lava_mesh.get_surface_count() > 0)
	_lava_cells_last = _material_cell_count_arr(lava, _f.LAVA_MIN)
	if _lava_cells_last > _lava_peak:
		_lava_peak = _lava_cells_last


# Surface rock at extreme temperature (a big meteor, a volcano vent) MELTS to lava: carve the SDF and
# emplace molten material, unless water is there to quench it. Deterministic (every cell over the melt
# temperature gives way) but capped + cursor-rotated so a single step never edits the whole map.
func _melt_step() -> void:
	if _f._terrain == null or not _f._terrain.has_method("carve_sphere"):
		return
	var lava: PackedFloat32Array = _f._mat_array(Mat.LAVA)
	var has_water: bool = _f._mats.has(Mat.WATER)
	var water: PackedFloat32Array = _f._mats[Mat.WATER] if has_water else PackedFloat32Array()
	var edits: int = 0
	var scanned: int = 0
	while scanned < _f._cell_count and edits < MELT_MAX_EDITS:
		var idx: int = _melt_cursor
		_melt_cursor += 1
		if _melt_cursor >= _f._cell_count:
			_melt_cursor = 0
		scanned += 1
		if _f._sampled[idx] == 0 or _f._temp[idx] < MELT_TEMP:
			continue
		if has_water and water[idx] > _f.WATER_THRESHOLD:
			continue
		var i: int = idx % _f._dim
		var j: int = idx / _f._dim
		_f._terrain.carve_sphere(Vector3(_f._cell_x(i), _f._terrain_h[idx], _f._cell_z(j)), MELT_RADIUS)
		_f._terrain_h[idx] = _f._terrain_h[idx] - MELT_RADIUS * 0.7
		lava[idx] = lava[idx] + MELT_RADIUS * 0.7
		edits += 1


func _material_cell_count_arr(arr: PackedFloat32Array, min_amount: float) -> int:
	var n: int = 0
	for idx in range(_f._cell_count):
		if _f._sampled[idx] != 0 and arr[idx] >= min_amount:
			n += 1
	return n
