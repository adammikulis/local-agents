class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D: the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

var queue: LAMaterialFieldInjectQueue3D = QueueScript.new()

# CRATER TELEMETRY: cells the most recent excavation opened, re-read live at report time.
const CRATER_WATCH_MAX: int = 256
var _crater_watch: PackedInt32Array = PackedInt32Array()
var _crater_seen: Dictionary = {}        # cell -> true, so overlapping craters do not watch a cell twice
var _crater_opened: int = 0              # cumulative cells this run whose derived solidity went rock -> void
var _crater_mass: float = 0.0            # cumulative mineral volume fraction excavation uncemented
var _crater_sea: int = 0                 # cumulative opened cells that were under the water line and flooded

var _flood_unsourced: int = 0            # below-sea crater cells left DRY because no live water was in reach

signal splashed(world_pos: Vector3, strength: float)


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
	if joules == 0.0 or _f._e.size() != _f._cell_count:
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
			_f._e[c] = _f._e[c] + dh
		return
	var deltas: PackedFloat32Array = PackedFloat32Array()
	deltas.resize(cells.size())
	deltas.fill(dh)
	queue.queue_h(cells, deltas)
	if dh > 0.0 and _f._gpu != null:
		_f._gpu.request_channel("fire")

# --- Organic matter: the seam between the field's carbon channels and the actors ----------------------------
const ORGANIC_TAKE_FRAC: float = 0.5

func take_biomass(world_pos: Vector3, want: float) -> float:
	if want <= 0.0 or _f._biomass.size() != _f._cell_count or not _device_ready():
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return 0.0
	var avail: float = _f._biomass[c] * ORGANIC_TAKE_FRAC
	if avail <= 0.0:
		return 0.0
	var take: float = minf(want, avail)
	queue.transfer("biomass", PackedInt32Array([c]), PackedFloat32Array([take]),
		"biomass", PackedInt32Array([-1]))
	return take


## Impact ejecta landing: debris the parcel carried out of `src_cell` arrives at `world_pos`. One conserving
## move of one channel between two cells — the flight is latency, not a source of matter.
func land_ejecta(src_cell: int, world_pos: Vector3, mass: float) -> void:
	if mass <= 0.0 or src_cell < 0 or src_cell >= _f._cell_count or not _device_ready():
		return
	if _f._silicate.size() != _f._cell_count:
		return
	var dst: int = _f.world_to_cell(world_pos)
	if dst < 0 or dst >= _f._cell_count:
		return
	queue.transfer("silicate", PackedInt32Array([src_cell]), PackedFloat32Array([mass]),
		"silicate", PackedInt32Array([dst]))
	_uncement(PackedInt32Array([dst]))


## Loose mineral arriving at a point. What lands is grains, so the cell's consolidated share goes with it.
func deposit_sediment(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _f._silicate.size() != _f._cell_count or not _device_ready():
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	queue.add("silicate", PackedInt32Array([c]), PackedFloat32Array([amount]))
	_uncement(PackedInt32Array([c]))


## Drain the consolidated share of these cells to zero. `cement` is a fraction, not matter, so this moves
## nothing and mints nothing — it records that the rock fabric is gone.
func _uncement(cells: PackedInt32Array) -> void:
	if cells.size() == 0:
		return
	queue.discard("cement", cells)


## Hand mass an actor was holding back to the field as DEAD ORGANIC MATTER at `world_pos` — an uprooted plant,
## a shed leaf. The decomposer loop (fungus → CO₂ + fertility) picks it up from there, which is what closes
## the circle: matter an actor took out of the biosphere re-enters it instead of disappearing with the node.
func return_detritus(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _f._detritus.size() != _f._cell_count or not _device_ready():
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	queue.add("detritus", PackedInt32Array([c]), PackedFloat32Array([amount]))


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
	if amount <= 0.0 or _f._h2o.size() != _f._cell_count or not _device_ready():
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
	var have_moisture: bool = _f._h2o.size() == _f._cell_count
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
	if _f._solid.size() != _f._cell_count or _f._silicate.size() != _f._cell_count:
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
	var rock: PackedFloat32Array = _f._silicate
	var solid: PackedByteArray = _f._solid
	var src: PackedInt32Array = PackedInt32Array()
	var was_rock: PackedInt32Array = PackedInt32Array()   # cells the field held as derived-solid bedrock
	var sea_cells: PackedInt32Array = PackedInt32Array()
	var sea_r: float = 0.0
	if _f._terrain.has_method("sea_radius"):
		sea_r = float(_f._terrain.sea_radius())
	for c in cells:
		if _f._terrain.is_solid(_f.cell_world_pos_linear(c)):
			continue                                   # still rock — the edit did not reach this cell
		var rf: float = rock[c]
		if rf <= 0.0 and solid[c] == 0:
			continue                                   # already void in the substrate — nothing was excavated
		if solid[c] != 0:
			was_rock.append(c)                         # this cell is the claim: derived-solid rock -> open
		# EXCAVATION MOVES NO MASS. The rock is pulverised where it stands, so what changes is the fabric:
		# the cell keeps its mineral and loses its cement, and the loose grains leave by transport.
		src.append(c)
		_crater_mass += rf
		if sea_r > 0.0 \
				and (_f.cell_world_pos_linear(c) - _f.centre()).length() < sea_r:
			sea_cells.append(c)
	if sea_cells.size() > 0:
		_flood_from_sea(sea_cells)
		_crater_sea += sea_cells.size()
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



## SINK: water_sphere3d.glsl skips any cell whose `static` flag is set when it gathers outflow, so a static sea
func _flood_from_sea(cells: PackedInt32Array) -> void:
	if _f._grid == null or _f._h2o.size() != _f._cell_count:
		return
	var solid: PackedByteArray = _f._solid
	var srcs: PackedInt32Array = PackedInt32Array()
	var dsts: PackedInt32Array = PackedInt32Array()
	var amounts: PackedFloat32Array = PackedFloat32Array()
	var unsourced: int = 0
	for c in cells:
		var src: int = _nearest_water(c, 2)
		if src >= 0:
			srcs.append(src)
			dsts.append(c)
			amounts.append(_f.MAX_MASS)
		else:
			unsourced += 1
	if srcs.size() > 0:
		queue.transfer("h2o", srcs, amounts, "h2o", dsts, _f.MAX_MASS)
	if unsourced > 0:
		_flood_unsourced += unsourced


func _nearest_water(from: int, rings: int) -> int:
	var grid: LAVoxelGrid = _f._grid
	var solid: PackedByteArray = _f._solid
	var seen: Dictionary = {from: true}
	var frontier: PackedInt32Array = PackedInt32Array([from])
	for _ring in range(rings):
		var next: PackedInt32Array = PackedInt32Array()
		for c in frontier:
			for f in range(grid.slot_begin(c, 0), grid.slot_begin(c, LAVoxelGrid.SLOTS)):
				var nb: int = grid.neighbours[f]
				if nb < 0 or nb >= _f._cell_count or seen.has(nb):
					continue
				seen[nb] = true
				if solid[nb] != 0:
					continue
				if _f._queries.liquid_at(nb) >= _f.MAX_MASS * 0.5:
					return nb
				next.append(nb)
		frontier = next
	return -1


func crater_report() -> Dictionary:
	var open_now: int = 0
	var below_sea: int = 0
	var rock_now: float = 0.0
	var water: float = 0.0
	var watch: int = _crater_watch.size()
	if _f != null and watch > 0 and _f._cement.size() == _f._cell_count:
		var sea_r: float = 0.0
		if _f._terrain != null and _f._terrain.has_method("sea_radius"):
			sea_r = float(_f._terrain.sea_radius())
		var has_water: bool = _f._h2o.size() == _f._cell_count
		for c in _crater_watch:
			rock_now += _f._cement[c]
			if _f._solid.size() == _f._cell_count and _f._solid[c] == 0:
				open_now += 1
			if sea_r > 0.0 and (_f.cell_world_pos_linear(c) - _f.centre()).length() < sea_r:
				below_sea += 1
			if has_water:
				water += _f._queries.liquid_at(c)
	return {
		"crater_cells": _crater_opened,
		"crater_mass": snappedf(_crater_mass, 0.01),
		"crater_watch": watch,
		"crater_open_now": open_now,
		"crater_rock_now": snappedf(rock_now, 0.01),
		"crater_below_sea": below_sea,
		"crater_sea": _crater_sea,
		"crater_water": snappedf(water, 0.01),
		# Below-sea cells a strike opened that the surrounding sea could not reach within two rings, and which
		# are therefore left DRY rather than filled from nothing. A rising number here is a real gap in the
		# water kernel's ability to flow into a fresh hole, and it is now visible instead of being papered over.
		"crater_dry_pockets": _flood_unsourced,
	}


# --- Physical splash droplets (FX) ------------------------------------------

## A few short-lived rigidbody droplets flung from a world point — the splash accent an impact calls.
func splash(world_pos: Vector3, strength: float) -> void:
	if not _f.is_inside_tree() or is_nan(world_pos.x):
		return
	var s: float = clampf(strength, 0.1, 4.0)
	splashed.emit(world_pos, s)                          # ring the fluid surface (renderer listens); droplets below
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.6, 0.9, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	for n in range(5):
		var body: RigidBody3D = RigidBody3D.new()
		body.mass = 0.05
		body.collision_mask = 1
		body.collision_layer = 0
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)
		_f.add_child(body)
		var rng: LASimRng = LASimRng.shared()
		body.global_position = world_pos + Vector3(rng.randf_range(-0.15, 0.15), 0.1, rng.randf_range(-0.15, 0.15))
		var ang: float = rng.randf() * TAU
		body.linear_velocity = Vector3(cos(ang) * rng.randf_range(1.0, 2.5) * s, rng.randf_range(2.5, 4.5) * s, sin(ang) * rng.randf_range(1.0, 2.5) * s)
		var tm: SceneTreeTimer = _f.get_tree().create_timer(2.0)
		tm.timeout.connect(func(): if is_instance_valid(body): body.queue_free())
