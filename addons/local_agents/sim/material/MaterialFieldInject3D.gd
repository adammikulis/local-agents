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

## Emitted every time something splashes water at a world point (meteor / tornado / fish / thrown rock /
## flood / plant). The water-surface renderer (LAMaterialFieldRender3D) connects here to spawn an expanding
## impact ripple on the fluid shader, so the same splash that flings droplets also rings the water, with
## zero coupling from this module to the renderer type. `strength` matches the droplet strength (0.1..4).
signal splashed(world_pos: Vector3, strength: float)


func setup(field) -> void:
	_f = field


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
## molten spike, a fire's heat, a storm's surface warming. Edits `_temp` directly — re-uploaded every step.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount == 0.0 or _f._temp.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		_f._temp[c] = _f._temp[c] + amount
	# BUG FIX: `fire` is a SITUATIONAL (demand-gated) readback channel with no dedicated actor to ever request
	# it hot (fire is fully emergent — dissolved into the substrate, no `FireActor` node) — so `fire_cells()`/
	# `fire_peak` read a permanently-stale CPU array (frozen at its zero seed) even while real combustion is
	# happening on the GPU. ANY heat injection can plausibly push a fuelled cell over the ignition threshold
	# (a meteor, a real lightning strike via MaterialCharge3D, ignite_area, even disease fever), so this is the
	# one choke point that should wake it — cheap (measured: gating all 4 situational channels saves ~0.5ms
	# total, a rounding error) and self-expires (CHANNEL_HOLD_DRAINS) once nothing is igniting anymore.
	if amount > 0.0 and _f._gpu != null:
		_f._gpu.request_channel("fire")

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
## ISLAND — nothing here says "island"; it is eruption + water-quench + accretion + SDF growth composing. Unlike
## add_lava (a CONSERVING bedrock->lava phase move that leaves the lava trapped in dry rock), this is a genuine mantle
## SOURCE: the deep reservoir is effectively infinite, so mineral_total rises by exactly the mass injected. Returns
## the mass actually erupted (0 if the column is solid to the grid's outer edge). All emergence is downstream on GPU.
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
	_f._lava[cell] += amount
	_f._lava_dirty = true
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


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta). Sphere-
## native: re-run is_solid per linear cell in the bubble around the edit (O(k), not the whole grid).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _f._terrain == null or not _f._terrain.has_method("is_solid") or _f._solid.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		_f._solid[c] = 1 if _f._terrain.is_solid(_f.cell_world_pos_linear(c)) else 0


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
