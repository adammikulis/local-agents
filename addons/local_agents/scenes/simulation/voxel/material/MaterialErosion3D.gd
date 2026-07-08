class_name LAMaterialErosion3D
extends RefCounted

## LAMaterialErosion3D — the 3D HYDRAULIC-EROSION step of the dense LAMaterialField3D. It is the coupling
## that turns the water CA + the granular-slump CA into a landscape sculptor: fast water carves rock into
## SUSPENDED sediment, slow/still water DROPS that sediment as loose granular mass in the shared
## `_f._sediment` channel — which LAMaterialSlump3D then piles to its angle of repose and re-solidifies into
## permanent terrain (deltas at river mouths, beaches along the shore, incised canyons upstream). NOTHING is
## per-feature scripted: canyons, deltas and beaches all FALL OUT of three local rules evaluated per cell
## (see EMERGENCE.md), the exact same "simple local rule" philosophy the fire/slump/wind modules use.
##
## Runs AFTER the water step (so it reads the fresh, just-moved water) and BEFORE slump (so the sediment it
## deposits is piled + solidified the same step). Holds ONE grid array of its own — `_susp`, the SUSPENDED
## sediment carried by the water column (double-buffered as it advects), owned in-module like the combustion
## ash mask. It reuses the field-resident `_f._sediment` channel for what it drops (no new field array).
##
## Local rules (gather form — each cell reads neighbours + writes only itself, so it is order-independent and
## a future erosion3d.glsl port would be bit-for-bit):
##   1) CAPACITY — the water's carrying capacity at a cell is proportional to how fast the water is moving
##      there and how much water is present: cap = K_CAP * speed * water. Flow SPEED is approximated from the
##      WATER-SURFACE GRADIENT (neighbour `_f._water` differences over one cell) — water on a steep surface
##      slope is moving fast (a rapid / a waterfall), water on a flat pool or the sea is slack. (We deliberately
##      do NOT use the per-cell wind velocity: wind is the AIR field, not the water's own motion.)
##   2) EROSION — where capacity exceeds the sediment already suspended (`cap > _susp[i]`) AND there is flowing
##      water sitting against a solid surface (a solid cell directly below / beside — i.e. a river bed or bank),
##      the under-capacity carves a LITTLE rock: a small SDF carve_sphere at the eroding surface converts rock
##      into suspended sediment (mass conserved: what the SDF loses, `_susp` gains). Hard-budgeted + cursor-
##      rotated (SDF edits are the expensive part) exactly like slump's settle() / lava's cooling stamps.
##   3) DEPOSITION — where suspended sediment exceeds capacity (`_susp[i] > cap` — the water slowed into a lake,
##      the sea, or a flat) the excess DROPS into `_f._sediment` for slump to pile. Suspended sediment also
##      SETTLES by gravity in shallow / near-still water (a slow gravitational fallout, independent of capacity)
##      so silt does not ride forever in a barely-moving pool.
## Between erosion and deposition, `_susp` is ADVECTED by the same water motion (down the surface gradient it
## used for speed) so a grain picked up in the rapids travels downstream before it drops — that transport is
## what builds a delta AT THE MOUTH rather than in place.
##
## STABLE + CHEAP by construction: a tiny per-step erosion rate, a hard cap on SDF edits per step, and it only
## touches cells where the water is MEANINGFULLY moving (speed over a floor) — so it must not tank the headless
## smoke framerate. CPU-oracle only (the correctness reference + the headless/no-GPU path); no GLSL kernel yet.
## (Explicit types only — no ':=' inferred typing.)

# --- Erosion / transport tuning. (An erosion3d.glsl port would duplicate these EXACTLY, "must match".) ------
const WATER_MIN: float = 0.05             # below this water mass a cell is effectively dry — no erosion/transport
const SPEED_MIN: float = 0.12             # min surface-gradient "speed" for water to count as MOVING (below = slack).
                                          # Raised so only genuinely fast flow erodes — calm rivers/lakes just carry/deposit,
                                          # keeping erosion a SLOW geological process (not constant terrain churn = perf + realism).
const SPEED_MAX: float = 1.5              # clamp on the surface-gradient speed estimate (stability)
const K_CAP: float = 0.9                  # carrying capacity per unit (speed * water). Higher = hungrier water
const EROSION_RATE: float = 0.05          # fraction of the capacity deficit converted to suspended rock per step (SMALL)
const DEPOSIT_RATE: float = 0.35          # fraction of the over-capacity suspended load dropped to _sediment per step
const SETTLE_RATE: float = 0.06           # extra gravity fallout of suspended silt in shallow/slack water per step
const SETTLE_WATER_MAX: float = 0.6       # water mass under which suspended silt also settles out by gravity
const ADVECT_FRACTION: float = 0.25       # share of suspended load carried to each downhill neighbour per step
const SUSP_MIN: float = 0.0005            # below this a cell holds no meaningful suspended sediment
const EROSION_MAX_EDITS: int = 8          # HARD cap on terrain carve stamps per step (cursor-rotated) — perf gate
const EROSION_PER_EDIT: float = 0.14      # suspended-sediment mass freed per carve stamp (≈ rock the SDF removed)
const SDF_CARVE_SCALE: float = 0.45       # carve radius as a fraction of cell size (small bite; must stay < a cell)
const CARVE_SCAN_BUDGET: int = 8192       # max cells scanned per GPU-tail carve call (perf bound; edits still capped at EROSION_MAX_EDITS)

var _f = null                             # back-reference to the owning LAMaterialField3D
var _susp: PackedFloat32Array = PackedFloat32Array()      # SUSPENDED sediment carried by the water (owned here)
var _scratch: PackedFloat32Array = PackedFloat32Array()   # double buffer for the advection pass
var _erode_cursor: int = 0                # rotating scan cursor so capped SDF carves sweep the whole map over time
var _eroding_last: int = 0                # diagnostic: cells that carved rock on the last step
var _deposited_accum: float = 0.0         # diagnostic: cumulative sediment dropped into _f._sediment


func setup(field) -> void:
	_f = field
	_susp = PackedFloat32Array()
	_susp.resize(_f._cell_count)
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## One hydraulic-erosion step. Order within the step:
##   A) EROSION + DEPOSITION per cell (gather form, into `_susp` directly — capacity is a local read, and both
##      erosion carving and deposition edit only THIS cell's suspended/sediment/terrain), then
##   B) ADVECT the suspended load one cell downhill (double-buffered), so silt travels before it settles.
## Erosion's SDF carves are budgeted (EROSION_MAX_EDITS, cursor-rotated) so a step never rewrites the whole map.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _susp.size() != _f._cell_count:
		_susp.resize(_f._cell_count)
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)
	_erode_and_deposit()
	_advect()


## GPU-path TAIL — runs ONLY the rock CARVE (the budgeted SDF carve_sphere edits that free rock into suspended
## sediment) + diagnostics, because on the GPU-resident path erosion_deposit3d/erosion_advect3d already ran the
## per-cell deposit/settle/advect core on-device and _susp/_f._sediment came back from the readback. Mirrors how
## lava's melt/solidify SDF stamps stay a CPU tail off the GPU flow. Called ONCE per frame on the fresh readback.
func step_scene_only() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _susp.size() != _f._cell_count:
		_susp.resize(_f._cell_count)
	_carve_scene()


## Budgeted rock CARVE (cursor-rotated + scan-bounded): where fast water sits against rock UNDER carrying
## capacity, carve a small SDF bite and turn the freed rock into suspended sediment (mass in ≈ out; the GPU then
## transports/deposits it next frames). Scan-bounded (CARVE_SCAN_BUDGET) + edit-capped (EROSION_MAX_EDITS) so the
## tail stays cheap. Reads the fresh readback water/susp; the added suspended load uploads to the GPU next frame.
func _carve_scene() -> void:
	var can_carve: bool = _f._terrain != null and _f._terrain.has_method("carve_sphere")
	if not can_carve:
		_eroding_last = 0
		return
	var water: PackedFloat32Array = _f._water
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var edits: int = 0
	var scanned: int = 0
	var eroding: int = 0
	while scanned < CARVE_SCAN_BUDGET and edits < EROSION_MAX_EDITS:
		var i: int = _erode_cursor
		_erode_cursor += 1
		if _erode_cursor >= _f._cell_count:
			_erode_cursor = 0
		scanned += 1
		if solid[i] != 0:
			continue
		var w: float = water[i]
		if w < WATER_MIN:
			continue
		var iy: int = i / layer
		var rem: int = i - iy * layer
		var iz: int = rem / dx
		var ix: int = rem % dx
		var speed: float = _surface_speed(i, ix, iz, dx, dz, solid, water)
		if speed < SPEED_MIN:
			continue
		var cap: float = K_CAP * speed * w
		if cap <= _susp[i]:
			continue                                     # not under capacity — GPU already handled deposit/settle
		if not _touches_solid(i, ix, iy, iz, dx, dy, dz, layer, solid):
			continue
		var bite: float = minf(EROSION_PER_EDIT, (cap - _susp[i]) * EROSION_RATE + EROSION_PER_EDIT * EROSION_RATE)
		var cpos: Vector3 = _f.cell_world_pos(ix, iy, iz)
		_f._terrain.carve_sphere(cpos, _f._cell_size * SDF_CARVE_SCALE)
		_f.resample_terrain(cpos, _f._cell_size * SDF_CARVE_SCALE)
		_susp[i] += bite
		edits += 1
		eroding += 1
	_eroding_last = eroding


# --- A) Erosion + deposition ------------------------------------------------

## Per non-solid cell: estimate the water flow speed from the local water-surface gradient, form the carrying
## capacity, then either CARVE (under capacity + water on a solid surface → rock becomes suspended sediment,
## budgeted) or DROP (over capacity → suspended sediment falls into `_f._sediment` for slump), plus a gravity
## settle-out of silt in shallow/slack water. Reads neighbours, writes only this cell (+ the tiny local SDF).
func _erode_and_deposit() -> void:
	var water: PackedFloat32Array = _f._water
	var sediment: PackedFloat32Array = _f._sediment
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var can_carve: bool = _f._terrain != null and _f._terrain.has_method("carve_sphere")
	var edits: int = 0
	var eroding: int = 0

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var w: float = water[i]
				if w < WATER_MIN:
					# No water: any stranded silt just drops (a receding flood leaves its load behind).
					if _susp[i] > SUSP_MIN:
						sediment[i] += _susp[i]
						_deposited_accum += _susp[i]
						_susp[i] = 0.0
					continue

				# Flow SPEED ≈ max surface-height drop to a lower open neighbour (the water-surface gradient).
				# Steep surface slope = fast water (rapids / falls); flat pool or sea = slack. Not the wind field.
				var speed: float = _surface_speed(i, ix, iz, dx, dz, solid, water)
				var cap: float = K_CAP * speed * w

				if cap > _susp[i]:
					# UNDER capacity — the water can carry more, so it ERODES if it is flowing over rock (a bed
					# or bank: a solid cell below or laterally adjacent). Budgeted SDF carves; the cursor makes
					# the eligible set rotate so carving sweeps the whole riverbed over many steps, not at once.
					if speed >= SPEED_MIN and _touches_solid(i, ix, iy, iz, dx, dy, dz, layer, solid):
						if edits < EROSION_MAX_EDITS and can_carve and i >= _erode_cursor:
							# Carve a small bite of rock at this cell and turn it into suspended load (mass in ≈ out).
							# The rate keeps the bite small: a fully under-capacity fast cell frees at most EROSION_PER_EDIT.
							var bite: float = minf(EROSION_PER_EDIT, (cap - _susp[i]) * EROSION_RATE + EROSION_PER_EDIT * EROSION_RATE)
							var cpos: Vector3 = _f.cell_world_pos(ix, iy, iz)
							_f._terrain.carve_sphere(cpos, _f._cell_size * SDF_CARVE_SCALE)
							_f.resample_terrain(cpos, _f._cell_size * SDF_CARVE_SCALE)
							_susp[i] += bite
							edits += 1
							eroding += 1
				else:
					# OVER capacity — the water slowed (a lake / the sea / a flat), so it DROPS the excess load
					# into the loose-sediment channel for slump to pile into a delta / beach.
					var excess: float = (_susp[i] - cap) * DEPOSIT_RATE
					if excess > 0.0:
						_susp[i] -= excess
						sediment[i] += excess
						_deposited_accum += excess

				# GRAVITY SETTLE — in shallow / near-still water, suspended silt falls out regardless of capacity
				# (fine sediment cannot ride forever in a barely-moving pool). Builds the bed of a calm lake.
				if _susp[i] > SUSP_MIN and (w < SETTLE_WATER_MAX or speed < SPEED_MIN):
					var drop: float = _susp[i] * SETTLE_RATE
					_susp[i] -= drop
					sediment[i] += drop
					_deposited_accum += drop

	# Advance the carve cursor so next step's budget starts where this one stopped (rotates over the whole grid).
	if edits >= EROSION_MAX_EDITS:
		_erode_cursor = _erode_cursor + layer
		if _erode_cursor >= _f._cell_count:
			_erode_cursor = 0
	else:
		_erode_cursor = 0
	_eroding_last = eroding


## Water flow "speed" at cell `i`: the largest water-surface height DROP to a lower open lateral neighbour,
## i.e. the local surface gradient (fast where the surface is steep — a rapid or a falls — slack on a flat
## pool). Clamped to SPEED_MAX for stability. This is the emergent stand-in for the water's velocity that
## drives both capacity and the advection direction, computed purely from the shared `_f._water` snapshot.
func _surface_speed(i: int, ix: int, iz: int, dx: int, dz: int, solid: PackedByteArray, water: PackedFloat32Array) -> float:
	var here: float = water[i]
	var drop: float = 0.0
	if ix > 0:
		var n: int = i - 1
		if solid[n] == 0:
			drop = maxf(drop, here - water[n])
	if ix < dx - 1:
		var n2: int = i + 1
		if solid[n2] == 0:
			drop = maxf(drop, here - water[n2])
	if iz > 0:
		var n3: int = i - dx
		if solid[n3] == 0:
			drop = maxf(drop, here - water[n3])
	if iz < dz - 1:
		var n4: int = i + dx
		if solid[n4] == 0:
			drop = maxf(drop, here - water[n4])
	return clampf(drop, 0.0, SPEED_MAX)


## True if this open water cell sits against ROCK — a solid cell directly below (a river bed) or beside it
## (a bank). Only such cells can erode (there must be rock to carve); open water in mid-air erodes nothing.
func _touches_solid(i: int, ix: int, iy: int, iz: int, dx: int, dy: int, dz: int, layer: int, solid: PackedByteArray) -> bool:
	if iy > 0 and solid[i - layer] != 0:
		return true
	if ix > 0 and solid[i - 1] != 0:
		return true
	if ix < dx - 1 and solid[i + 1] != 0:
		return true
	if iz > 0 and solid[i - dx] != 0:
		return true
	if iz < dz - 1 and solid[i + dx] != 0:
		return true
	return false


# --- B) Advection -----------------------------------------------------------

## Carry suspended sediment one cell DOWNHILL along the same water-surface gradient that set its speed, so a
## grain picked up in the rapids travels downstream before it deposits (that transport is what forms a delta at
## the river MOUTH, and grades a beach along the shore, rather than dumping the load where it was torn loose).
## Gather-safe via the `_scratch` double buffer: reads the stable `_susp` snapshot, writes `_scratch`, swaps.
func _advect() -> void:
	var water: PackedFloat32Array = _f._water
	var solid: PackedByteArray = _f._solid
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	for i in range(_f._cell_count):
		_scratch[i] = _susp[i]

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					continue
				var s: float = _susp[i]
				if s < SUSP_MIN:
					continue
				var here: float = water[i]
				# Push a share toward each strictly-lower open lateral neighbour (down the water surface).
				if ix > 0:
					_push(i, i - 1, here, water, solid, s)
				if ix < dx - 1:
					_push(i, i + 1, here, water, solid, s)
				if iz > 0:
					_push(i, i - dx, here, water, solid, s)
				if iz < dz - 1:
					_push(i, i + dx, here, water, solid, s)

	var tmp: PackedFloat32Array = _susp
	_susp = _scratch
	_scratch = tmp


## Move a fraction of source cell `si`'s suspended load to a lower open neighbour `ni` (edits `_scratch` only).
func _push(si: int, ni: int, here: float, water: PackedFloat32Array, solid: PackedByteArray, s: float) -> void:
	if solid[ni] != 0:
		return
	var diff: float = here - water[ni]
	if diff <= 0.0:
		return
	var move: float = s * ADVECT_FRACTION
	if move < SUSP_MIN:
		return
	_scratch[si] -= move
	_scratch[ni] += move


# --- Diagnostics ------------------------------------------------------------

## Cells that carved rock into suspended sediment on the last step (a river is actively incising while > 0).
func eroding_cells() -> int:
	return _eroding_last


## Total suspended sediment currently riding the water column (in transit between erosion and deposition).
func suspended_total() -> float:
	if _f == null:
		return 0.0
	var s: float = 0.0
	for i in range(_f._cell_count):
		s += _susp[i]
	return s


## Cumulative sediment dropped into the shared `_f._sediment` channel (deltas/beaches build from this).
func deposited_total() -> float:
	return _deposited_accum
