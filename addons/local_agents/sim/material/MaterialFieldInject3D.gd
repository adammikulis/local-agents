class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D: the write-side injection API of the dense 3D MaterialField3D.

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

var queue: LAMaterialFieldInjectQueue3D = QueueScript.new()

# CRATER TELEMETRY: cells the most recent excavation opened, re-read live at report time.
const CRATER_WATCH_MAX: int = 256
var _crater_watch: PackedInt32Array = PackedInt32Array()
var _crater_seen: Dictionary = {}        # cell -> true, so overlapping craters do not watch a cell twice
var _crater_opened: int = 0              # cumulative cells this run whose derived solidity went rock -> void
var _crater_mass: float = 0.0            # cumulative mineral volume fraction excavation uncemented


func setup(field) -> void:
	_f = field
	# The grid the queue sizes cross-cell transfers in mass with. Without it flush() drops every op.
	queue.setup(field._grid)
	# Terrain-destruction telemetry as a registered provider (the LASimReport.register plugin seam), so the
	# crater proof is polled at snapshot time, when the mirrors hold the freshest readback, instead of
	# being scanned every frame.
	LASimReport.register(crater_report)


## True when this field is running on a driver that can apply the queue's sparse device edits (the cubed-sphere
## GPU driver). The box/CPU field has no such driver and nothing flushes the queue there, so its injectors must
## not park ops that would accumulate forever.
func _device_ready() -> bool:
	return _f != null and _f._gpu != null and _f._gpu.has_method("queue_sparse")


# --- Local field injection (add_heat_energy) -----------------------------------------

func add_heat_energy(world_pos: Vector3, joules: float, radius: float = 0.0) -> float:
	if joules == 0.0 or not _f._mirrors.has("e_j_m3"):
		return 0.0
	return _inject_energy(_cells_within(world_pos, radius), joules)


## Spread `joules` over `cells` as a uniform rise in enthalpy DENSITY, so each cell takes the share its own
## volume buys. Returns the J/m^3 added. Temperature is what the ladder later reads off it.
func _inject_energy(cells: PackedInt32Array, joules: float) -> float:
	if cells.size() == 0:
		return 0.0
	var vol: PackedFloat32Array = _f._grid.cell_volumes() if _f._grid != null else PackedFloat32Array()
	if vol.size() < _f._cell_count:
		return 0.0
	var total_vol: float = 0.0
	for c in cells:
		total_vol += vol[c]
	if total_vol <= 0.0:
		return 0.0
	var dh: float = joules / total_vol
	queue.note_energy(joules)
	_apply_h(cells, dh)
	return dh


func _apply_h(cells: PackedInt32Array, dh: float) -> void:
	if not _device_ready():
		# The box/CPU reference field has no device and nothing flushes the queue there, so the mirror IS the
		# field.
		for c in cells:
			_f._mirrors.add_at("e_j_m3", c, dh)
		return
	var deltas: PackedFloat32Array = PackedFloat32Array()
	deltas.resize(cells.size())
	deltas.fill(dh)
	queue.queue_h(cells, deltas)
	if dh > 0.0 and _f._gpu != null:
		_f._gpu.request_channel("fire")

## Impact ejecta landing: debris the parcel carried out of `src_cell` arrives at `world_pos`. One conserving
## move of one channel between two cells — the flight is latency, not a source of matter.
func land_ejecta(src_cell: int, world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or src_cell < 0 or src_cell >= _f._cell_count or not _device_ready():
		return
	var dst: int = _f.world_to_cell(world_pos)
	if dst < 0 or dst >= _f._cell_count:
		return
	queue.transfer("silicate", PackedInt32Array([src_cell]), PackedFloat32Array([mass]),
		"silicate", PackedInt32Array([dst]))
	_uncement(PackedInt32Array([dst]))


## Drain the consolidated share of these cells to zero. `cement` is a fraction, not matter, so this moves
## nothing and mints nothing — it records that the rock fabric is gone.
func _uncement(cells: PackedInt32Array) -> void:
	if cells.size() == 0:
		return
	queue.discard("cement", cells)


## Packed arrays are copy-on-write VALUE types in GDScript — an in-place helper would scale a copy and leave
## the caller's array untouched — so this returns the scaled array instead of mutating an argument.
func _scaled(arr: PackedFloat32Array, k: float) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = arr[i] * k
	return out

## Gather the linear cell indices within `radius` world-units of `world_pos` (the centre cell always included).
## Bounded neighbour-BFS over the grid's precomputed 6-neighbour table — O(k) in the bubble, never the whole
## grid. radius <= 0 (or no grid) collapses to the single centre cell.
func _cells_within(world_pos: Vector3, radius: float) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var c0: int = _f.world_to_cell(world_pos)
	if c0 < 0 or c0 >= _f._cell_count:
		return out
	out.append(c0)
	if radius <= 0.0 or _f._grid == null:
		return out
	var r2: float = radius * radius
	var grid: LAVoxelGrid = _f._grid
	var seen: Dictionary = {c0: true}
	var frontier: PackedInt32Array = PackedInt32Array([c0])
	# Cap the walk so a huge radius can't run away; the bubble is small by design.
	var max_cells: int = 512
	while frontier.size() > 0 and out.size() < max_cells:
		var next: PackedInt32Array = PackedInt32Array()
		for c in frontier:
			for f in range(grid.slot_begin(c, 0), grid.slot_begin(c, LAVoxelGrid.SLOTS)):
				var nb: int = grid.neighbours[f]
				if nb < 0 or seen.has(nb):
					continue
				seen[nb] = true
				if (_f.cell_world_pos_linear(nb) - world_pos).length_squared() <= r2:
					out.append(nb)
					next.append(nb)
		frontier = next
	return out


# --- Injection API (the impact actor calls these) ---------------------------

## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside). 3D analogue of the 2.5D add_water_pooled.
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	if amount <= 0.0 or not _device_ready():
		return
	var center_r: float = (center - _f.centre()).length()
	var cells: PackedInt32Array = _cells_within(center, radius)
	var fill_cells: PackedInt32Array = PackedInt32Array()
	for c in cells:
		if _f._solid[c] != 0:
			continue
		if (_f.cell_world_pos_linear(c) - _f.centre()).length() <= center_r + _f._cell_size:
			fill_cells.append(c)
	if fill_cells.size() == 0:
		return
	# The moisture to condense is gathered from the WHOLE bubble, not only the cells being filled — a raincloud
	# is wider than the puddle it makes — and spread over the fill cells in proportion to what each source
	# held. The device clamps every take to the live value, so a stale mirror can only under-deliver.
	var src_cells: PackedInt32Array = PackedInt32Array()
	var takes: PackedFloat32Array = PackedFloat32Array()
	var dsts: PackedInt32Array = PackedInt32Array()
	var have_moisture: bool = _f._mirrors.has("h2o")
	var i: int = 0
	var offer: float = 0.0
	if have_moisture:
		for c in cells:
			if _f._solid[c] != 0 or _f._queries.vapour_at(c) <= 0.0:
				continue
			var av: float = _f._queries.vapour_at(c)
			if av <= 0.0:
				continue
			src_cells.append(c)
			takes.append(av)
			dsts.append(fill_cells[i % fill_cells.size()])
			offer += av
			i += 1
	var want: float = amount * float(fill_cells.size())
	if offer > want and offer > 0.0:
		takes = _scaled(takes, want / offer)
	queue.transfer("h2o", src_cells, takes, "h2o", dsts, _f.MAX_MASS)


func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _f == null or _f._terrain == null or not _f._terrain.has_method("is_solid"):
		return
	if _f._solid.size() != _f._cell_count or not _f._mirrors.has("silicate"):
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return
	# NO DEVICE (the box/CPU field, the headless reference oracle). Nothing evolves on a GPU to be
	# authoritative there and nothing flushes the queue, so `_solid` IS the mask.
	if not _device_ready():
		var mask: PackedByteArray = _f._solid
		for c in cells:
			mask[c] = 1 if _f._terrain.is_solid(_f.cell_world_pos_linear(c)) else 0
		_f._solid = mask
		return
	var solid: PackedByteArray = _f._solid
	var src: PackedInt32Array = PackedInt32Array()
	var was_rock: PackedInt32Array = PackedInt32Array()   # cells the field held as derived-solid bedrock
	for c in cells:
		if _f._terrain.is_solid(_f.cell_world_pos_linear(c)):
			continue                                   # still rock — the edit did not reach this cell
		var rf: float = _f._mirrors.at("silicate", c)
		if rf <= 0.0 and solid[c] == 0:
			continue                                   # already void in the substrate — nothing was excavated
		if solid[c] != 0:
			was_rock.append(c)                         # this cell is the claim: derived-solid rock -> open
		# EXCAVATION MOVES NO MASS. The rock is pulverised where it stands, so what changes is the fabric:
		# the cell keeps its mineral and loses its cement, and the loose grains leave by transport.
		src.append(c)
		_crater_mass += rf
	if src.size() == 0:
		return
	_uncement(src)
	_crater_opened += was_rock.size()
	for c in was_rock:
		if _crater_watch.size() >= CRATER_WATCH_MAX:
			break
		if _crater_seen.has(c):
			continue
		_crater_seen[c] = true
		_crater_watch.append(c)


func crater_report() -> Dictionary:
	var open_now: int = 0
	var rock_now: float = 0.0
	var water: float = 0.0
	var watch: int = _crater_watch.size()
	if _f != null and watch > 0 and _f._mirrors.has("cement"):
		var has_water: bool = _f._mirrors.has("h2o")
		for c in _crater_watch:
			rock_now += _f._mirrors.at("cement", c)
			if _f._solid.size() == _f._cell_count and _f._solid[c] == 0:
				open_now += 1
			if has_water:
				water += _f._queries.liquid_at(c)
	return {
		"crater_cells": _crater_opened,
		"crater_mass": snappedf(_crater_mass, 0.01),
		"crater_watch": watch,
		"crater_open_now": open_now,
		"crater_rock_now": snappedf(rock_now, 0.01),
		"crater_water": snappedf(water, 0.01),
	}

