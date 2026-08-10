class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D: the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldHeatQueue3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

var queue: LAMaterialFieldHeatQueue3D = QueueScript.new()

# EVAPORATION SOURCING (add_vapor). A storm lifts water that is THERE: the liquid in its footprint and the
# water table under it. These bound how hard one injection may pull, so a cell is thinned rather than punched
# empty — a storm sitting on the sea must not open a hole in it.
const EVAP_KEEP_LIQUID: float = 0.1      # liquid below this is not available to a storm (film left behind)
const EVAP_TAKE_FRAC: float = 0.5        # fraction of a source cell's AVAILABLE contents one injection may lift
const SOIL_SEARCH_SHELLS: int = 4        # permeable shells to search inward for the water table (= REGOLITH_CELLS)

const EXCAVATED_DUST_FRAC: float = 0.25

# CRATER TELEMETRY (published through the SIM_REPORT provider registered in setup()). `_crater_watch` keeps the
# cells the most recent excavation opened so the report can re-read their LIVE rock_fill: that is the DEVICE-side
# proof the substrate agrees the ground is gone, as opposed to "carve_sphere was called".
const CRATER_WATCH_MAX: int = 256
var _crater_watch: PackedInt32Array = PackedInt32Array()
var _crater_seen: Dictionary = {}        # cell -> true, so overlapping craters do not watch a cell twice
var _crater_opened: int = 0              # cumulative cells this run whose derived solidity went rock -> void
var _crater_mass: float = 0.0            # cumulative bedrock mass ASKED of rock_fill; the matching credit the
                                         # device actually accepted is `mineral_inject_moved`, and the two must
                                         # counter and could never have matched — see MaterialFieldInjectQueue3D's
var _crater_sea: int = 0                 # cumulative opened cells that were under the water line and flooded

# THE MANTLE RESERVOIR — the finite store every volcanic vent draws on. Lazily sized on first eruption
# (the sphere grid is not built when this module is constructed); -1 means "not yet sized".
var _mantle_reserve: float = -1.0
var _mantle_drawn: float = 0.0           # cumulative mass erupted out of it this run
var _mantle_dry_calls: int = 0           # eruption attempts refused because the reservoir was empty
var _flood_unsourced: int = 0            # below-sea crater cells left DRY because no live water was in reach

signal splashed(world_pos: Vector3, strength: float)


func _mantle_capacity() -> float:
	if _f == null or _f._sphere == null:
		return 0.0
	var core_r: float = float(_f._sphere.core_radius)
	var side: float = maxf(float(_f._cell_size), 0.001)
	if core_r <= 0.0:
		return 0.0
	return (4.0 / 3.0) * PI * core_r * core_r * core_r / (side * side * side) * _f.MAX_MASS


## SIM_REPORT provider for the mantle: capacity, what is left, what has been drawn, and how many eruption
## attempts were refused for want of it.
func mantle_report() -> Dictionary:
	var cap: float = _mantle_capacity()
	var left: float = _mantle_reserve if _mantle_reserve >= 0.0 else cap
	return {
		"mantle_capacity": snappedf(cap, 0.01),
		"mantle_reserve": snappedf(left, 0.01),
		"mantle_drawn": snappedf(_mantle_drawn, 0.01),
		"mantle_spent_frac": snappedf(_mantle_drawn / maxf(cap, 0.0001), 0.000001),
		"mantle_dry_calls": _mantle_dry_calls,
	}


func setup(field) -> void:
	_f = field
	LASimReport.register(mantle_report)
	# Terrain-destruction telemetry as a registered provider (the LASimReport.register plugin seam), so the
	# crater proof is polled at snapshot time — when `_rock_fill` holds the freshest readback — instead of
	# being scanned every frame.
	LASimReport.register(crater_report)


## True when this field is running on a driver that can apply the queue's sparse device edits (the cubed-sphere
## GPU driver). The box/CPU field has no such driver and nothing flushes the queue there, so its injectors must
## not park ops that would accumulate forever.
func _device_ready() -> bool:
	return _f != null and _f._gpu != null and _f._gpu.has_method("move_field_sparse")


# --- Local field injection (add_heat / add_vapor / add_charge) --------------------------------------

## (J/m²/K), because the solar kernel applies a surface FLUX to a surface cell, and their formula is
func _cell_heat_capacity(cell: int) -> float:
	var side: float = maxf(float(_f._cell_size), 0.001)
	var volume: float = side * side * side
	return LAHeatCapacity.cell(_rc_channels(), cell) * volume


func _rc_channels() -> Dictionary:
	return {
		"rock_fill": _f._rock_fill, "lava": _f._lava, "sediment": _f._sediment, "susp": _f._susp,
		"dust": _f._dust, "water": _f._water, "soil": _f._soil, "snow": _f._snow,
		"moisture": _f._moisture, "fuel": _f._fuel, "biomass": _f._biomass,
		"detritus": _f._detritus, "fungus": _f._fungus, "porosity": _f._porosity,
	}


func add_heat_energy(world_pos: Vector3, joules: float, radius: float = 0.0) -> float:
	if joules == 0.0 or _f._temp.size() != _f._cell_count:
		return 0.0
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return 0.0
	# Build the carrier table ONCE, not once per cell — it is the same dictionary of the same mirrors for
	# every cell in the bubble, and a meteor's bubble is thousands of them.
	var ch: Dictionary = _rc_channels()
	var side: float = maxf(float(_f._cell_size), 0.001)
	var volume: float = side * side * side
	var total_cap: float = 0.0
	for c in cells:
		total_cap += LAHeatCapacity.cell(ch, c) * volume
	if total_cap <= 0.0:
		return 0.0
	var delta_c: float = joules / total_cap
	queue.note_energy(joules)
	_apply_temp(cells, delta_c)
	return delta_c


func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount == 0.0 or _f._temp.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return
	queue.note_unsourced(absf(amount) * float(cells.size()))
	_apply_temp(cells, amount)


func _apply_temp(cells: PackedInt32Array, delta_c: float) -> void:
	if not _device_ready():
		# The box/CPU reference field has no device and nothing flushes the queue there, so the mirror IS the
		# field — write it, exactly as this function always did.
		for c in cells:
			_f._temp[c] = _f._temp[c] + delta_c
		return
	var deltas: PackedFloat32Array = PackedFloat32Array()
	deltas.resize(cells.size())
	deltas.fill(delta_c)
	queue.queue_temp(cells, deltas)
	if delta_c > 0.0 and _f._gpu != null:
		_f._gpu.request_channel("fire")

func add_lava(world_pos: Vector3, amount: float) -> void:
	if _f == null or amount <= 0.0:
		return
	if _f._rock_fill.size() != _f._cell_count or _f._lava.size() != _f._cell_count:
		return
	if _f._gpu != null:
		_f._gpu.request_channel("lava")          # an active vent → keep the lava readback hot
		_f._gpu.request_channel("rock_fill")     # ...and the bedrock mirror this walk locates the vent with
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	# A vent sits on OPEN ground, so the erupting lava is bedrock melted from just BENEATH it: walk radially
	# inward (lower index = toward the core within the same column) to the first bedrock cell and melt THAT
	# (it then rises by magma buoyancy).
	var depth: int = _f._sphere.depth if _f._sphere != null else 1
	var base: int = c - (c % depth)              # radial index 0 of this surface column (the core-side cell)
	var cell: int = c
	while cell >= base and _f._rock_fill[cell] <= 0.0:
		cell -= 1
	if cell < base:
		return                                   # whole column void (no bedrock to erupt) — nothing to do
	if not _device_ready():
		# NO DEVICE (the box/CPU reference oracle): nothing flushes the queue there and the mirrors ARE the
		# substrate, so the direct edit is the correct write — the same split resample_terrain makes.
		var a: float = minf(amount, _f._rock_fill[cell])
		if a <= 0.0:
			return
		_f._rock_fill[cell] -= a
		_f._lava[cell] += a
		return
	var src: PackedInt32Array = PackedInt32Array([cell])
	queue.transfer("rock_fill", src, PackedFloat32Array([amount]), "lava", src)


func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or _f._moisture.size() != _f._cell_count or _f._water.size() != _f._cell_count:
		return
	if not _device_ready():
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return
	# DEMAND is unchanged from the minting version (`amount` per open cell in the bubble), so `h2o_inject_demand`
	var open_n: int = 0
	for c in cells:
		if _f._solid[c] == 0:
			open_n += 1
	if open_n == 0:
		return
	var want: float = amount * float(open_n)
	queue.note_demand(want)

	var depth: int = _f._sphere.depth if _f._sphere != null else 1
	var have_soil: bool = _f._soil.size() == _f._cell_count and _f._regolith.size() == _f._cell_count
	var wet_cells: PackedInt32Array = PackedInt32Array()
	var wet_take: PackedFloat32Array = PackedFloat32Array()
	var wet_dst: PackedInt32Array = PackedInt32Array()
	var wet_offer: float = 0.0
	var soil_cells: PackedInt32Array = PackedInt32Array()
	var soil_take: PackedFloat32Array = PackedFloat32Array()
	var soil_dst: PackedInt32Array = PackedInt32Array()
	var soil_offer: float = 0.0
	var seen: Dictionary = {}
	for c in cells:
		var col: int = c / depth                          # cell = surf_col*depth + radial layer
		if seen.has(col):
			continue
		seen[col] = true
		var base: int = col * depth
		var ground_r: int = -1                            # outermost SOLID shell = this column's ground surface
		for r in range(depth - 1, -1, -1):
			if _f._solid[base + r] != 0:
				ground_r = r
				break
		# The exposed liquid surface: the outermost open cell above the ground that still holds water (sea, lake,
		# river, puddle), and the air cell directly above it, which is where lifted moisture belongs.
		var top_water: int = -1
		for r in range(ground_r + 1, depth):
			if _f._solid[base + r] != 0:
				break
			if _f._water[base + r] > EVAP_KEEP_LIQUID:
				top_water = base + r
		var air: int = -1
		if top_water >= 0 and (top_water % depth) < depth - 1 and _f._solid[top_water + 1] == 0:
			air = top_water + 1
		elif ground_r >= 0 and ground_r < depth - 1 and _f._solid[base + ground_r + 1] == 0:
			air = base + ground_r + 1
		if top_water >= 0:
			var avail: float = (_f._water[top_water] - EVAP_KEEP_LIQUID) * EVAP_TAKE_FRAC
			if avail > 0.0:
				wet_cells.append(top_water)
				wet_take.append(avail)
				wet_dst.append(air if air >= 0 else top_water)
				wet_offer += avail
		elif have_soil and air >= 0 and ground_r >= 0:
			for d in range(SOIL_SEARCH_SHELLS):
				var sc: int = base + ground_r - d
				if sc < base or _f._regolith[sc] == 0:
					break
				var av: float = _f._soil[sc] * EVAP_TAKE_FRAC
				if av <= 0.0:
					continue
				soil_cells.append(sc)
				soil_take.append(av)
				soil_dst.append(air)
				soil_offer += av
				break
	# Scale both pools down together when the footprint holds more than the storm wants, so a wet storm takes
	# exactly its demand spread across its sources instead of stripping every one of them.
	var offer: float = wet_offer + soil_offer
	if offer > want and offer > 0.0:
		var k: float = want / offer
		wet_take = _scaled(wet_take, k)
		soil_take = _scaled(soil_take, k)
	queue.transfer("water", wet_cells, wet_take, "moisture", wet_dst)
	queue.transfer("soil", soil_cells, soil_take, "moisture", soil_dst)


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
	queue.carbon_transfer("biomass", PackedInt32Array([c]), PackedFloat32Array([take]),
		"biomass", PackedInt32Array([-1]))
	return take


func deposit_sediment(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _f._sediment.size() != _f._cell_count or not _device_ready():
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	queue.add("sediment", PackedInt32Array([c]), PackedFloat32Array([amount]))


## Hand mass an actor was holding back to the field as DEAD ORGANIC MATTER at `world_pos` — an uprooted plant,
## a shed leaf. The decomposer loop (fungus → CO₂ + fertility) picks it up from there, which is what closes
## the circle: matter an actor took out of the biosphere re-enters it instead of disappearing with the node.
func return_detritus(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or _f._detritus.size() != _f._cell_count or not _device_ready():
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	queue.carbon_return("detritus", PackedInt32Array([c]), PackedFloat32Array([amount]))


## Packed arrays are copy-on-write VALUE types in GDScript — an in-place helper would scale a copy and leave
## the caller's array untouched — so this returns the scaled array instead of mutating an argument.
func _scaled(arr: PackedFloat32Array, k: float) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = arr[i] * k
	return out

## Inject electrification charge into the air cell at `world_pos` (and within `radius`) — an explicit charge
## seed (a storm's charge source, or an ionising impact). Queued as a sparse ADD against the live buffer; the
## charge module then reads it back + may break down.
func add_charge(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or _f._charge.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = PackedInt32Array()
	var deltas: PackedFloat32Array = PackedFloat32Array()
	for c in _cells_within(world_pos, radius):
		if _f._solid[c] == 0:
			_f._charge[c] = maxf(0.0, _f._charge[c] + amount)
			cells.append(c)
			deltas.append(amount)
	if _f._inject != null and cells.size() > 0:
		_f._inject.queue.add("charge", cells, deltas)
	_f._charge_woke = true                                # wake the breakdown scan — a small injected blob can
	                                                      # slip between the strided probe's samples otherwise


## Drain each cell in the bubble down to `residual` and return how much came out (the bolt's energy). The drain
## is queued as a NEGATIVE sparse delta sized from the mirror; add_field_sparse clamps at 0, so a device value
## below the mirror empties rather than going negative.
func deplete_charge(world_pos: Vector3, radius: float, residual: float) -> float:
	if _f._charge.size() != _f._cell_count:
		return 0.0
	var cells: PackedInt32Array = PackedInt32Array()
	var deltas: PackedFloat32Array = PackedFloat32Array()
	var drained: float = 0.0
	for c in _cells_within(world_pos, radius):
		if _f._charge[c] > residual:
			var take: float = _f._charge[c] - residual
			drained += take
			_f._charge[c] = residual
			cells.append(c)
			deltas.append(-take)
	if _f._inject != null and cells.size() > 0:
		_f._inject.queue.add("charge", cells, deltas)
	return drained


## Gather the linear cell indices within `radius` world-units of `world_pos` (the centre cell always included).
## Bounded neighbour-BFS over the sphere grid's precomputed 6-neighbour table — O(k) in the bubble, never the
## whole grid. radius <= 0 (or no sphere grid) collapses to the single centre cell.
func _cells_within(world_pos: Vector3, radius: float) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var c0: int = _f.world_to_cell(world_pos)
	if c0 < 0 or c0 >= _f._cell_count:
		return out
	out.append(c0)
	if radius <= 0.0 or _f._sphere == null:
		return out
	var r2: float = radius * radius
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var seen: Dictionary = {c0: true}
	var frontier: PackedInt32Array = PackedInt32Array([c0])
	# Cap the walk so a huge radius can't run away; the bubble is small by design.
	var max_cells: int = 512
	while frontier.size() > 0 and out.size() < max_cells:
		var next: PackedInt32Array = PackedInt32Array()
		for c in frontier:
			for d in range(6):
				var nb: int = nbr[c * 6 + d]
				if nb < 0 or seen.has(nb):
					continue
				seen[nb] = true
				if (_f.cell_world_pos_linear(nb) - world_pos).length_squared() <= r2:
					out.append(nb)
					next.append(nb)
		frontier = next
	return out


# --- Injection API (disasters/flood call these) -----------------------------

func erupt_source(world_pos: Vector3, amount: float) -> float:
	if amount <= 0.0 or _f._lava.size() != _f._cell_count or _f._rock_fill.size() != _f._cell_count:
		return 0.0
	if _mantle_reserve < 0.0:
		_mantle_reserve = _mantle_capacity()
	if _mantle_reserve <= 0.0:
		_mantle_dry_calls += 1
		return 0.0                                    # the mantle this planet was born with is spent
	amount = minf(amount, _mantle_reserve)
	var cell0: int = _f.world_to_cell(world_pos)
	if cell0 < 0 or cell0 >= _f._cell_count:
		return 0.0
	var c: int = cell0
	var depth: int = _f._sphere.depth if _f._sphere != null else 1
	var col_base: int = c - (c % depth)               # radial layer 0 (core side) of this surface column
	var col_top: int = col_base + depth - 1           # outermost radial layer (sky side)
	# Walk OUTWARD to the first OPEN cell (bedrock rock_fill < 0.5) — the water cell just above the current surface,
	# the growing front. Erupt the mantle lava THERE so it emerges INTO the sea (or air, once breached) and quenches.
	var cell: int = c
	while cell <= col_top and _f._rock_fill[cell] >= 0.5:
		cell += 1
	if cell > col_top:
		return 0.0                                    # column solid to the grid's outer edge — nowhere to erupt
	# WHERE THE MAGMA COMES FROM: the deepest bedrock still left in this column, walking OUTWARD from the
	# core-side end. Deep rather than shallow on purpose — that is the mantle end of the column, and melting it
	# leaves its void far below the seabed instead of undermining the cone the vent is building.
	var chamber: int = col_base
	while chamber <= col_top and _f._rock_fill[chamber] <= 0.0:
		chamber += 1
	if chamber >= cell:
		return 0.0                                    # no bedrock below the vent left to melt — the chamber is spent
	queue.transfer("rock_fill", PackedInt32Array([chamber]), PackedFloat32Array([amount]),
		"lava", PackedInt32Array([cell]))
	# The mantle's own budget is a SECOND, independent ledger (its capacity is the core's volume, not this
	# column's bedrock), so decrementing it here does not double-debit the transfer above: one says which
	# matter moved, the other says how much of the planet's original mantle has now been spent.
	_mantle_reserve -= amount
	_mantle_drawn += amount
	# The CPU mirror still has readers — this function's own size guard, lava_total() for SIM_REPORT, and the
	# eruption event detector — so keep its readback hot while a vent is active, exactly as add_lava does.
	if _f._gpu != null:
		_f._gpu.request_channel("lava")
	if _f._stamp != null:
		_f._stamp.arm()                               # wake the SDF stamp — the quenched lava will cross rock_fill 0.5
	return amount


## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside). 3D analogue of the 2.5D add_water_pooled.
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	if amount <= 0.0 or _f._water.size() != _f._cell_count or not _device_ready():
		return
	var center_r: float = (center - _f._origin).length()
	var cells: PackedInt32Array = _cells_within(center, radius)
	var fill_cells: PackedInt32Array = PackedInt32Array()
	for c in cells:
		if _f._solid[c] != 0:
			continue
		if (_f.cell_world_pos_linear(c) - _f._origin).length() <= center_r + _f._cell_size:
			fill_cells.append(c)
	if fill_cells.size() == 0:
		return
	queue.note_demand(amount * float(fill_cells.size()))
	# The moisture to condense is gathered from the WHOLE bubble, not only the cells being filled — a raincloud
	# is wider than the puddle it makes — and spread over the fill cells in proportion to what each source
	# held. `move_field_sparse` clamps every take to the live value, so a stale mirror can only under-deliver.
	var src_cells: PackedInt32Array = PackedInt32Array()
	var takes: PackedFloat32Array = PackedFloat32Array()
	var dsts: PackedInt32Array = PackedInt32Array()
	var have_moisture: bool = _f._moisture.size() == _f._cell_count
	var i: int = 0
	var offer: float = 0.0
	if have_moisture:
		for c in cells:
			if _f._solid[c] != 0 or _f._moisture[c] <= 0.0:
				continue
			var av: float = _f._moisture[c] * EVAP_TAKE_FRAC
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
	queue.transfer("moisture", src_cells, takes, "water", dsts, _f.MAX_MASS)


func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _f == null or _f._terrain == null or not _f._terrain.has_method("is_solid"):
		return
	if _f._solid.size() != _f._cell_count or _f._rock_fill.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return
	# NO DEVICE (the box/CPU field, i.e. the headless reference oracle). There is no rock_fill channel evolving
	# on a GPU to be authoritative there and nothing ever flushes the queue, so `_solid` IS the mask and the
	# direct re-sample is the correct write — which is what this function always did.
	if not _device_ready():
		var mask: PackedByteArray = _f._solid
		for c in cells:
			mask[c] = 1 if _f._terrain.is_solid(_f.cell_world_pos_linear(c)) else 0
		_f._solid = mask
		return
	var rock: PackedFloat32Array = _f._rock_fill
	var solid: PackedByteArray = _f._solid
	var src: PackedInt32Array = PackedInt32Array()
	var to_sediment: PackedFloat32Array = PackedFloat32Array()
	var to_dust: PackedFloat32Array = PackedFloat32Array()
	var was_rock: PackedInt32Array = PackedInt32Array()   # cells the field held as DERIVED-SOLID bedrock (rock_fill
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
		if rf >= 0.5:
			was_rock.append(c)                         # this cell is the claim: derived-solid rock -> open
		# Ask for a WHOLE cell, split by the material fraction. move_field_sparse clamps each take to the live
		# bedrock, so over-asking against a stale mirror cannot mint — it just yields less. The two legs sum to
		# MAX_MASS, so together they drain the cell however much was really in it.
		src.append(c)
		to_sediment.append(_f.MAX_MASS * (1.0 - EXCAVATED_DUST_FRAC))
		to_dust.append(_f.MAX_MASS * EXCAVATED_DUST_FRAC)
		_crater_mass += _f.MAX_MASS
		if sea_r > 0.0 \
				and (_f.cell_world_pos_linear(c) - _f._origin).length() < sea_r:
			sea_cells.append(c)
	if sea_cells.size() > 0:
		_flood_from_sea(sea_cells)
		_crater_sea += sea_cells.size()
	if src.size() == 0:
		return
	# THE MOVE: bedrock out, loose phases in, resolved together on device.
	queue.transfer("rock_fill", src, to_sediment, "sediment", src)
	queue.transfer("rock_fill", src, to_dust, "dust", src)
	_crater_opened += was_rock.size()
	for c in was_rock:
		if _crater_watch.size() >= CRATER_WATCH_MAX:
			break
		if _crater_seen.has(c):
			continue
		_crater_seen[c] = true
		_crater_watch.append(c)
	if _f._gpu != null:
		# Wake the demand-gated readbacks, or the change is invisible: on a calm planet nothing requests
		# rock_fill or dust, so their CPU mirrors (and every gauge computed from them) simply stop updating.
		_f._gpu.request_channel("rock_fill")
		_f._gpu.request_channel("dust")


## SINK: water_sphere3d.glsl skips any cell whose `static` flag is set when it gathers outflow, so a static sea
func _flood_from_sea(cells: PackedInt32Array) -> void:
	if _f._sphere == null or _f._water.size() != _f._cell_count:
		return
	var nbr: PackedInt32Array = _f._sphere.neighbours
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
		queue.transfer("water", srcs, amounts, "water", dsts, _f.MAX_MASS)
	if unsourced > 0:
		_flood_unsourced += unsourced


func _nearest_water(from: int, rings: int) -> int:
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var solid: PackedByteArray = _f._solid
	var seen: Dictionary = {from: true}
	var frontier: PackedInt32Array = PackedInt32Array([from])
	for _ring in range(rings):
		var next: PackedInt32Array = PackedInt32Array()
		for c in frontier:
			for d in [1, 2, 3, 4, 5, 0]:
				var nb: int = nbr[c * 6 + d]
				if nb < 0 or nb >= _f._cell_count or seen.has(nb):
					continue
				seen[nb] = true
				if solid[nb] != 0:
					continue
				if _f._water[nb] >= _f.MAX_MASS * 0.5:
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
	if _f != null and watch > 0 and _f._rock_fill.size() == _f._cell_count:
		var sea_r: float = 0.0
		if _f._terrain != null and _f._terrain.has_method("sea_radius"):
			sea_r = float(_f._terrain.sea_radius())
		var has_water: bool = _f._water.size() == _f._cell_count
		for c in _crater_watch:
			rock_now += _f._rock_fill[c]
			if _f._rock_fill[c] < 0.5:
				open_now += 1
			if sea_r > 0.0 and (_f.cell_world_pos_linear(c) - _f._origin).length() < sea_r:
				below_sea += 1
			if has_water:
				water += _f._water[c]
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

## A few short-lived rigidbody droplets flung from a world point — the splash accent disasters call.
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
