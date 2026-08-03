class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D: the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored
## out so the field node stays a thin simulation/composition core (and under the file-size gate). Holds
## NO state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the shared per-cell arrays
## (`_solid`/`_water`/…), geometry (`_cell_size`, `_origin`), the terrain SDF (`_terrain`), and the field's
## sphere-native cell seam (`world_to_cell` / `cell_world_pos_linear` + the local `_cells_within` neighbour-BFS
## bubble), exactly as the heat / atmosphere / lava concern modules do. The field owns these as its real
## injection surface.
## (This is the same split as MaterialFieldQueries3D / MaterialFieldRender3D, not a compat layer.)
## (Explicit types only, no ':=' inferred typing.)

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

## Pending sparse DEVICE edits + the H₂O injection ledger. Every CPU-side write into a GPU-resident channel
## goes through here so it ADDS to live state instead of re-uploading a stale mirror over it, and so every
## credit names the source it was taken from. Flushed by LAMaterialFieldSphereStep3D just before dispatch;
## also written by LAMineralStamp3D (the water a growing rock cell has to hand off). Public on purpose — this
## is the write-side API's own queue, not private state.
var queue: LAMaterialFieldInjectQueue3D = QueueScript.new()

# EVAPORATION SOURCING (add_vapor). A storm lifts water that is THERE: the liquid in its footprint and the
# water table under it. These bound how hard one injection may pull, so a cell is thinned rather than punched
# empty — a storm sitting on the sea must not open a hole in it.
const EVAP_KEEP_LIQUID: float = 0.1      # liquid below this is not available to a storm (film left behind)
const EVAP_TAKE_FRAC: float = 0.5        # fraction of a source cell's AVAILABLE contents one injection may lift
const SOIL_SEARCH_SHELLS: int = 4        # permeable shells to search inward for the water table (= REGOLITH_CELLS)

# EXCAVATION (resample_terrain). Fraction of destroyed bedrock that goes AIRBORNE as dust instead of settling
# as loose sediment in the cell it came from. A hypervelocity strike pulverises a real share of what it digs
# out. This is a MATERIAL property of shattering rock, not a per-disaster constant: a meteor, the player's
# brush, and any future dig all get the same split because they all go through the same call.
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
                                         # agree. (It used to say `mineral_inject_credited`, which was the VENT's
                                         # counter and could never have matched — see MaterialFieldInjectQueue3D's
                                         # mineral ledger note. Corrected 2026-08-03.)
var _crater_sea: int = 0                 # cumulative opened cells that were under the water line and flooded

## Emitted every time something splashes water at a world point (meteor / tornado / fish / thrown rock /
## flood / plant). The water-surface renderer (LAMaterialFieldRender3D) connects here to spawn an expanding
## impact ripple on the fluid shader, so the same splash that flings droplets also rings the water, with
## zero coupling from this module to the renderer type. `strength` matches the droplet strength (0.1..4).
signal splashed(world_pos: Vector3, strength: float)


func setup(field) -> void:
	_f = field
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
# The real, unstubbed local-injection primitives. Each writes a channel amount into the sphere GPU field at
# a world cell (and a small radius of its neighbours), following the round-trip discipline the GPU driver
# already uses for temp/lava:
#   • TEMPERATURE is re-uploaded from the CPU `_temp` array EVERY begin_frame, so add_heat simply edits `_temp`
#     — no dirty flag needed; it round-trips into the GPU next step and back on readback.
#   • MOISTURE and CHARGE are GPU-resident (uploaded only when the CPU dirties them, like lava). add_vapor /
#     add_charge edit the read-back CPU array + raise a dirty flag; the sphere-step loop pushes them via
#     set_field before the next step (mirroring the lava/rock_fill dirty-gated upload).
# Big-O: injection touches only the O(k) cells inside `radius` gathered by a bounded neighbour-BFS from the
# centre cell (grid.neighbours), never the whole grid — a stimulus wakes a small bubble, not a full-grid sweep.

## Raise the temperature of the cell at `world_pos` (and cells within `radius`) by `amount` °C. A meteor's
## molten spike, a fire's heat, a storm's surface warming. Edits the CPU `_temp` mirror directly, so it
## MARKS IT DIRTY: begin_frame no longer re-uploads temp unconditionally (the geothermal core stopped
## being a CPU-side pin and became a GPU flux boundary), and injection is now the only CPU writer left.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount == 0.0 or _f._temp.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		_f._temp[c] = _f._temp[c] + amount
	if _f._gpu != null and _f._gpu.has_method("mark_temp_dirty"):
		_f._gpu.mark_temp_dirty()
	# BUG FIX: `fire` is a SITUATIONAL (demand-gated) readback channel with no dedicated actor to ever request
	# it hot (fire is fully emergent — dissolved into the substrate, no `FireActor` node) — so `fire_cells()`/
	# `fire_peak` read a permanently-stale CPU array (frozen at its zero seed) even while real combustion is
	# happening on the GPU. ANY heat injection can plausibly push a fuelled cell over the ignition threshold
	# (a meteor, a real lightning strike via MaterialCharge3D, ignite_area, even disease fever), so this is the
	# one choke point that should wake it — cheap (measured: gating all 4 situational channels saves ~0.5ms
	# total, a rounding error) and self-expires (CHANNEL_HOLD_DRAINS) once nothing is igniting anymore.
	if amount > 0.0 and _f._gpu != null:
		_f._gpu.request_channel("fire")

## A VENT ERUPTING: the bedrock just beneath it melts to lava. Conserving by construction — `rock_fill -= a;
## lava += a` — so mineral_total stays flat and an eruption RELOCATES mineral instead of creating it.
##
## IT MUST BE A SPARSE DEVICE TRANSFER, AND IT USED TO BE A MIRROR EDIT, WHICH MINTED ROCK. The old body (on
## LAMaterialField3D) wrote `_rock_fill[cell] -= a; _lava[cell] += a` on the CPU and raised `_rock_fill_dirty` /
## `_lava_dirty`, which make MaterialFieldSphereStep3D.gd:204-209 push the WHOLE mirror back over the live GPU
## buffer with `set_field`. Both channels are GPU-evolved, and the rock_fill mirror is a DEMAND-GATED readback,
## so that upload rewound every on-device change either channel had accumulated since the mirror was last
## refreshed — and credited the difference as new matter.
##
## The hazard was already documented in CLAUDE.md ("add_lava and the fuel seed push WHOLE mirrors back with
## set_field, so mirror staleness decides how much GPU-evolved mass that upload rewinds") and already visible
## as a small standing mint. What made it unmissable was plate transport: once rock_fill evolves on the GPU in
## EVERY cell every step, the stale mirror differs from the device everywhere, and each eruption restored the
## continents to where they had been. Measured, seed 4242 at 600 frames: `mineral_inject_minted` 1859.2 and
## `mineral_total` 33707.6 against a 31978.0 start — 5.4 % of the planet's mineral conjured by four eruptions.
##
## The mirror is still read, but ONLY to LOCATE the bedrock (walk radially inward to the first cell that holds
## rock). Staleness there can pick a slightly wrong cell; it cannot mint, because `move_field_sparse` reads the
## LIVE bedrock and takes what is actually present — the same property that makes `resample_terrain` honest.
## `request_channel("rock_fill")` keeps that mirror warm, which is a legitimate call here: this is a simulation
## WRITE path reading the mirror to decide where to act, not a gauge.
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


## EVAPORATE airborne water vapor (humidity) into the air over `world_pos` (within `radius`) — a storm's LOCAL
## moisture source. This is a TRANSFER, not a source. It used to do `_moisture[c] += amount` for every open cell
## in the bubble and set a dirty flag, which (a) created that mass out of nothing — every storm minted water —
## and (b) made the step re-upload the whole stale moisture mirror over the live GPU buffer, discarding a step
## of atmosphere. Both are gone: the mass is lifted out of the liquid water and the soil water INSIDE the same
## bubble, exactly the water→moisture debit atmos_evap_sphere3d already performs, and the edit is applied to the
## live device buffer.
##
## Sources, in the order a real storm draws them:
##   • LIQUID in the footprint (sea, lake, river, puddle) — evaporates into its OWN cell, where atmos_evap puts
##     it too; a static-sea cell is a legitimate source, and debiting it is what keeps `h2o_closed_total` closed
##     rather than moving the mint into the reservoir the ledger does not count.
##   • SOIL water under the footprint (evapotranspiration) — surfaces in the open cell radially above the rock.
## Whatever the footprint cannot supply is recorded as an explicit shortfall and reported in SIM_REPORT. A dry
## footprint therefore yields a weak storm; it does not conjure rain.
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or _f._moisture.size() != _f._cell_count or _f._water.size() != _f._cell_count:
		return
	if not _device_ready():
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	if cells.size() == 0:
		return
	# DEMAND is unchanged from the minting version (`amount` per open cell in the bubble), so `h2o_inject_demand`
	# in SIM_REPORT is exactly the mass this call used to create from nothing.
	var open_n: int = 0
	for c in cells:
		if _f._solid[c] == 0:
			open_n += 1
	if open_n == 0:
		return
	var want: float = amount * float(open_n)
	queue.note_demand(want)

	# Source per SURFACE COLUMN, not per bubble cell. Evaporation is a surface process — it happens at the top of
	# the water or the top of the wet ground, and the moisture enters the air directly above it — and keying on
	# the column makes that independent of exactly where the injection blob's centre landed. That matters here:
	# the storm actors aim with a cartesian `+Y` offset from a ground point, which on a sphere puts the blob a
	# couple of cells off the surface at most latitudes, and a per-cell scan then found a bubble full of bedrock
	# and reported a 100% shortfall that was about the AIM, not about the ground being dry. Walking the column
	# makes a reported shortfall mean what it says.
	#
	# The CPU mirrors read here are a readback old, but they only SIZE the ask: move_field_sparse clamps every
	# take to the live device value, so a stale over-estimate cannot mint, it comes back as shortfall.
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
			# Dry column: transpire the WATER TABLE instead. Walk the permeable band inward from the surface
			# rather than reading only the topmost shell — groundwater is gravity-driven, so the top shell of a
			# column that has not rained recently is drained and the table sits one or more shells lower. Reading
			# only the surface shell found nothing at all on this map (measured: soil_total 3441 planet-wide and
			# still zero available under the storm).
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


## Packed arrays are copy-on-write VALUE types in GDScript — an in-place helper would scale a copy and leave
## the caller's array untouched — so this returns the scaled array instead of mutating an argument.
func _scaled(arr: PackedFloat32Array, k: float) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = arr[i] * k
	return out

## Inject electrification charge into the air cell at `world_pos` (and within `radius`) — an explicit charge
## seed (a storm's charge source, or an ionising impact). The charge channel is GPU-resident + evolves in
## place, so mark it dirty for the sphere-step re-upload; the charge module then reads it back + may break down.
func add_charge(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or _f._charge.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		if _f._solid[c] == 0:
			_f._charge[c] = maxf(0.0, _f._charge[c] + amount)
	_f._charge_dirty = true
	_f._charge_woke = true                                # wake the breakdown scan — a small injected blob can
	                                                      # slip between the strided probe's samples otherwise


## Discharge (drain) the electrification charge across a radius around a lightning strike — a bolt empties
## the local capacitor, not just the single leader cell, so the whole struck storm CORE goes flat and must
## fully rebuild its charge before it can strike again. This is the emergent per-storm cooldown (no timer):
## without it, the neighbours of a fired cell sit at breakdown and re-fire next step (the firehose). Every
## cell in the bubble is knocked down to `residual`; the channel is GPU-resident, so mark it dirty.
func deplete_charge(world_pos: Vector3, radius: float, residual: float) -> void:
	if _f._charge.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		if _f._charge[c] > residual:
			_f._charge[c] = residual
	_f._charge_dirty = true


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

## SEABED MAGMA SOURCE — the volcano's ONLY authored action (the seabed-island capstone). Extrude `amount` of molten
## lava from the deep mantle into the OPEN cell at the growing surface front along the vent column: the first
## non-bedrock cell (rock_fill < 0.5) walking OUTWARD from `world_pos`. Underwater that cell holds seeded seawater, so
## the erupted lava QUENCHES on the GPU next step (the marine-lava heat sink), the M5 record freezes it to rock_fill,
## and Stage C stamps the terrain UP a cell. Repeat and the cone climbs until it BREACHES the sea surface = a new
## ISLAND — nothing here says "island"; it is eruption + water-quench + accretion + SDF growth composing.
##
## ===== IT USED TO CREATE THE ROCK OUT OF NOTHING. IT NOW MELTS ROCK THAT IS ACTUALLY THERE. ================
##
## This docstring used to end: "this is a genuine mantle SOURCE: the deep reservoir is effectively infinite, so
## mineral_total rises by exactly the mass injected", and the code was `queue.add("lava", ...)` — an edit with
## no debit anywhere in the field. Stated plainly, every island this simulation has ever built was made of
## matter that did not exist. It was not hidden: the queue counted it in `mineral_inject_minted` and the
## mineral ledger subtracted it before reporting drift, so the books balanced by declaring the source
## legitimate. A ledger that exempts its own leak measures nothing.
##
## A volcano does not import matter into the planet. Magma is rock that was ALREADY in the planet and melted,
## and the chamber it comes from is finite — which is why real volcanoes go extinct and why calderas collapse
## into the void their chamber left. So the supply is now drawn from the DEEPEST BEDROCK OF THE VENT'S OWN
## COLUMN (core side, i.e. mantle rather than crust) and transferred to the erupting cell: a conserving
## rock_fill -> lava move, exactly like add_lava, differing only in that source and destination are different
## cells. `move_field_sparse` takes what is really there, so a column that has given up all its rock simply
## erupts nothing and the cone stops growing — a finite magma chamber, which is the correct behaviour rather
## than a limitation.
##
## Returns the mass actually erupted (0 if the column is solid to the grid's outer edge, or has no rock left).
## All emergence is downstream on GPU.
func erupt_source(world_pos: Vector3, amount: float) -> float:
	if amount <= 0.0 or _f._lava.size() != _f._cell_count or _f._rock_fill.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return 0.0
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
	# SPARSE DEVICE TRANSFER, not a mirror edit — the same correction add_water_pooled already carries, for the
	# same reason, but the consequences here were worse because nothing ever refreshed this mirror.
	#
	# This used to be `_f._lava[cell] += amount; _f._lava_dirty = true`, which made the step upload the WHOLE
	# `_lava` array over the live buffer. `lava` is demand-gated (SITUATIONAL_CHANNELS) and this path never
	# called request_channel, so the readback scatter's `size() == n` guard never fired and `_lava` was NEVER
	# refreshed from the device: it stayed a monotonic running total of every deposit ever made, and that total
	# was written over the GPU's live lava every single step. Two things died there.
	#   • M5 SOLIDIFY (lava -> rock_fill, a conserving transfer) was UNDONE each step — lava it had just frozen
	#     into bedrock was restored at full value, so the vent MINTED mineral and its column plugged at the
	#     speed of the upload rather than the speed of the supply. Every vent height ever measured, including
	#     the one ISLAND_FREEBOARD was tuned against, was measuring that.
	#   • lava_flow's lateral spread was ANNIHILATED each step: every cell outside the deposit set was reset to
	#     the mirror's value, so a pile could only grow straight up, one cell per supply tick. That is the "ten
	#     one-cell columns with visible gaps" the screenshots show, and it also explains why adding a downslope
	#     leg to lava_flow moved neither height nor shape — its output was overwritten before it could compound.
	# The queue applies to the LIVE device buffers and is flushed AFTER the set_field block, which is the
	# direction the driver's own note ("only moving add_lava onto move_field_sparse would") calls safe. `lava`
	# is in the queue's MINERAL_CHANNELS, so this books into the mineral ledger as a MOVE, not a mint.
	queue.transfer("rock_fill", PackedInt32Array([chamber]), PackedFloat32Array([amount]),
		"lava", PackedInt32Array([cell]))
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
	# Sphere-native basin fill: deposit into open cells within the bubble that sit AT/BELOW the centre's
	# altitude (radius from the planet centre), so a surge pools into the low ground and the field's own
	# gravity-driven flow runs it downhill — never up a hillside. No vertical XZ column. O(k) over the bubble
	# via the neighbour-BFS.
	#
	# This is a SOURCELESS add (a scripted surge really does conjure its water), so it goes through the queue's
	# `add` and lands in the reported `h2o_inject_minted` — visible rather than hidden. What it must NOT do is
	# what it used to: edit the CPU mirror and mark the whole water channel dirty, which made begin_frame
	# re-upload a one-to-two-step-old snapshot of the ENTIRE channel over the live GPU water, discarding a step
	# of flow/rain/infiltration everywhere on the planet to deliver a puddle. The sparse device add touches only
	# the bubble.
	var center_r: float = (center - _f._origin).length()
	var cells: PackedInt32Array = _cells_within(center, radius)
	var fill_cells: PackedInt32Array = PackedInt32Array()
	var fill_amt: PackedFloat32Array = PackedFloat32Array()
	for c in cells:
		if _f._solid[c] != 0:
			continue
		if (_f.cell_world_pos_linear(c) - _f._origin).length() <= center_r + _f._cell_size:
			fill_cells.append(c)
			fill_amt.append(amount)
	queue.add("water", fill_cells, fill_amt, _f.MAX_MASS)


## THE OTHER HALF OF A TERRAIN EDIT — call this straight after destroying terrain (`carve_sphere`).
##
## `VoxelTerrainService.carve_sphere` moves the godot_voxel SDF, which is the MESH and the COLLISION. It is not
## the physics. The field's authoritative bedrock is `rock_fill` (rock unification Stage B: `solid` is a DERIVED
## view that SolidDerivePass recomputes from rock_fill at the top of EVERY step, before any other kernel reads
## it). So a meteor crater used to be a hole you could stand in and fall through that water would not pool into
## and air would not fill, because the substrate still believed the rock was there. This closes that.
##
## It is a MASS MOVE, not a delete. Excavated bedrock does not leave the planet — it is shattered and thrown —
## so it lands in the two LOOSE mineral phases the substrate already carries and already moves:
##   • `sediment` — crushed breccia on the crater floor, which the slump/erosion kernels then run downhill,
##     water re-suspends into `susp`, and lithification can cement back to bedrock.
##   • `dust` — the lofted share, which the wind advects and which dims insolation through avg_atmos_dust.
##     "Impact winter" is that one line and nothing else; there is no impact-winter system to write.
## Both are counted legs of mineral_total(), so a strike moves mass between phases instead of destroying it.
##
## MECHANISM. The SDF is only the SHAPE ORACLE: it says which cells the edit opened, whatever shape it had (a
## crater, a brush, a tunnel), so nothing here knows what a crater is.
##
## The debit and the credit are ONE conserving device move per cell (`queue.transfer` → `move_field_sparse`),
## which reads the live bedrock, takes what is actually there, and credits exactly that. Debit and credit are
## therefore the same number by construction: this cannot mint, and it cannot destroy.
##
## The CPU rock_fill mirror is deliberately left alone. Writing it looks tempting — rock_fill's only other CPU
## writer, `add_lava`, edits the mirror and raises `_rock_fill_dirty`, which re-uploads the WHOLE channel at
## MaterialFieldSphereStep3D.gd:152, ahead of the queue flush at :182 — but going through that path here
## destroys mass. Measured 2026-07-30 on a barrage of 18: zeroing the mirror debited 175.0 of bedrock (the cells
## really did open: crater_open_now 174/175) while the matching credit landed 0.0, because `add_field_sparse`,
## the only primitive that can credit a channel with no upload path, applies nothing in this build — 1515
## per-cell add edits reached it and it returned 0.0 for every one. (That is a live bug in
## LAMaterialSphereGPU3D, not in this module: `move_field_sparse` on the same buffers works, which is why the
## conserving transfer is the right call regardless. It also means `add_water_pooled`'s flood surge has never
## actually delivered its water.) Leaving the mirror to the readback keeps this module's honesty testable too:
## `crater_open_now` then reports what the DEVICE says about those cells, not what this function just wrote.
##
## The REVERSE direction (the SDF grew, so the field should gain rock) is deliberately NOT handled here:
## LAMineralStamp3D owns field→SDF growth, and re-importing its own stamp would mint mineral on every eruption.
## Sphere-native + O(k): one is_solid probe per cell in the bubble around the edit, never the whole grid.
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
	                                                      # >= 0.5) at this instant — the "before" side of the proof
	# Cells the edit opened BELOW SEA LEVEL. Breaching the seabed floods: the hole is under the ocean, so it is
	# ocean. That is not a rule invented for craters — it is exactly `_seed_sphere_sea`'s rule ("every open cell
	# at/below sea_radius is static sea"), which until now only ran at world-gen, so anything that opened a cell
	# afterwards left a dry pocket under the water line. The static sea is a one-way sink in water_sphere3d.glsl
	# (dynamic water pours in and is absorbed; a static cell never pushes any back out), so without this a seabed
	# crater could not fill from its neighbours no matter how long it sat there.
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
		# NEITHER `_rock_fill` NOR `_solid` is written here, and the second one is as deliberate as the first.
		# They are read TOGETHER by LAMineralStamp3D, which treats `_solid` as the last-stamped state and fires a
		# stamp on any disagreement with rock_fill. Clearing `_solid` while the rock_fill mirror still reads 1.0
		# (it is refreshed only by readback) is precisely a void->solid crossing, so the stamp's very next scan
		# would call fill_rock and put the crater back. Left alone, the pair stays consistent until the readback
		# lands, and then the stamp sees the real solid->void crossing and clears `_solid` itself — the designed
		# Stage C path, which also re-carves the SDF idempotently and costs a few frames of CPU-mask lag.
		# A CRATER BELOW THE WATER LINE FLOODS. IT DOES NOT BECOME "STATIC SEA".
		#
		# This block used to also do `stat[c] = 1`, re-creating the static mask on every impact. That mask was
		# deleted from world-gen on 2026-07-30 because it was measured MINTING +6263 units of water: a static
		# cell evaporates into the air (atmos_evap adds with no debit) AND absorbs inflow (water_sphere3d calls
		# the sea below "an infinite sink" and passes the cell through unchanged), so it is a source and a sink
		# at once, and rain falling on it vanishes. Removing it from `_seed_sphere_sea` left every
		# `static_cells[]` branch in every kernel dead at t=0 — and this line quietly resurrected them, a few
		# cells at a time, on every meteor.
		#
		# That mint is INVISIBLE to `h2o_inject_minted`, because it happens inside the kernels rather than
		# through the injection queue. Only LA_H2O_BUDGET's per-pass `legs_all` would catch it, and the runs
		# that measured "0.0000 for all twelve passes" were taken on worlds whose static count was still zero.
		# So the conservation result everyone has been quoting was measured on the one condition under which
		# this bug cannot fire.
		#
		# The flood itself is kept and is real: `_flood_from_sea` moves EXISTING water from live neighbours
		# through the queue, so a new hole fills from the sea around it and the books stay closed.
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
	# ACCUMULATE the watch across every excavation in the run (bounded), rather than keeping only the newest —
	# otherwise the proof covers whichever crater happened to land last instead of all of them.
	# Overlapping craters (a barrage) re-excavate cells a previous strike already opened, and until the readback
	# lands they still look like bedrock here, so dedupe or the "before" side counts the same cell twice.
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


## Fill freshly opened below-sea cells from the sea NEXT TO them — the crater floods.
##
## It has to be pulled in from a neighbour rather than simply switched on, because the calm sea is a ONE-WAY
## SINK: water_sphere3d.glsl skips any cell whose `static` flag is set when it gathers outflow, so a static sea
## cell absorbs every river that reaches it and never pushes a drop back out. A hole opened under the water line
## therefore stays dry forever on its own, however long it sits there, which is why breaching the seabed used to
## leave a dry pocket beneath the ocean. This is a CONSERVING transfer (the neighbour is debited exactly what
## the crater is credited), and the sea's own evaporation source tops the reservoir back up, which is the same
## bargain the static-sea model already makes everywhere else.
func _flood_from_sea(cells: PackedInt32Array) -> void:
	if _f._sphere == null or _f._water.size() != _f._cell_count:
		return
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var solid: PackedByteArray = _f._solid
	var srcs: PackedInt32Array = PackedInt32Array()
	var dsts: PackedInt32Array = PackedInt32Array()
	var amounts: PackedFloat32Array = PackedFloat32Array()
	var unsourced: PackedInt32Array = PackedInt32Array()
	for c in cells:
		# Slot order is LASphereGrid's: 0 inward, 1 outward, 2..5 lateral. Prefer OUTWARD — the sea is above the
		# floor we just broke, so that is where the water actually comes from.
		var found: bool = false
		for d in [1, 2, 3, 4, 5, 0]:
			var nb: int = nbr[c * 6 + d]
			if nb < 0 or nb >= _f._cell_count or solid[nb] != 0:
				continue
			if _f._water[nb] < _f.MAX_MASS * 0.5:
				continue                               # not a full sea cell — nothing here to pour in
			srcs.append(nb)
			dsts.append(c)
			amounts.append(_f.MAX_MASS)
			found = true
			break
		if not found:
			unsourced.append(c)
	if srcs.size() > 0:
		queue.transfer("water", srcs, amounts, "water", dsts, _f.MAX_MASS)
	if unsourced.size() > 0:
		# NO LIVE NEIGHBOUR TO DRAW FROM, and this cell has just been flagged `static` — it is sea now. A static
		# cell is skipped by water_sphere3d.glsl's outflow gather AND by everything that would flow into it, so a
		# dry static cell is a permanent hole in the ocean that nothing can ever fill: not the tide, not a river,
		# not the next strike. That is the state a breached seabed used to be left in whenever the strike opened a
		# pocket whose neighbours were all still rock (or were themselves fresh crater cells the CPU mirror had
		# not caught up on yet), which is most of a deep crater's floor.
		#
		# So the top-up is SOURCELESS, and that is the correct physics for this model rather than a shortcut: the
		# static sea is already an infinite reservoir by construction (it absorbs every river forever and its
		# evaporation source refills it without depleting — see the note above), so taking a cell's worth out of
		# it is exactly the bargain the rest of the static-sea model makes. It goes through the queue's `add`, so
		# it lands in the reported `h2o_inject_minted` and is visible rather than hidden inside the channel.
		var fill: PackedFloat32Array = PackedFloat32Array()
		fill.resize(unsourced.size())
		fill.fill(_f.MAX_MASS)
		queue.add("water", unsourced, fill, _f.MAX_MASS)


## SIM_REPORT provider: the proof that terrain destruction reached the SUBSTRATE, not just the mesh.
##
## `crater_watch` is the BEFORE side — cells the field held as derived-solid bedrock (rock_fill >= 0.5) at the
## instant something excavated them. `crater_open_now` and `crater_rock_now` are the AFTER side, re-read from
## the LIVE rock_fill readback: had the carve touched only the SDF, every one of those cells would still be
## >= 0.5 here, `open_now` would be 0 and `rock_now` would equal `watch`. `crater_water` is the same cells'
## liquid — where a crater that bottoms out below sea level shows that it took water.
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
