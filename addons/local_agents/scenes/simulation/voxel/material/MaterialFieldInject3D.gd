class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D — the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored
## out so the field node stays a thin simulation/composition core (and under the file-size gate). Holds
## NO state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the shared per-cell arrays
## (`_solid`), geometry (`_dim_x/_dim_y/_dim_z`, `_cell_size`, `_origin`), the terrain SDF (`_terrain`),
## and the field's own cell helpers (`add_water_cell`/`_col_i`/`_surface_iy`/`cell_world_pos`) — exactly as
## the heat / atmosphere / lava concern modules do. The field owns these as its real injection surface
## (this is the same split as MaterialFieldQueries3D / MaterialFieldRender3D, not a compat layer).
## (Explicit types only — no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


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

## Inject airborne water vapor (humidity) into the air cell at `world_pos` (and within `radius`) — a storm's
## LOCAL moisture source. Moisture is GPU-resident, so mark it dirty for the sphere-step re-upload.
func add_vapor(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or _f._moisture.size() != _f._cell_count:
		return
	var cells: PackedInt32Array = _cells_within(world_pos, radius)
	for c in cells:
		if _f._solid[c] == 0:
			_f._moisture[c] = maxf(0.0, _f._moisture[c] + amount)
	_f._vapor_dirty = true

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
	var ci: int = _f._col_i(center.x, _f._origin.x)
	var ck: int = _f._col_i(center.z, _f._origin.z)
	var center_ground: float = _column_ground_y(ci, ck)
	var cs: float = _f._cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var r2: float = radius * radius
	for dk in range(-cells, cells + 1):
		var iz: int = ck + dk
		if iz < 0 or iz >= _f._dim_z:
			continue
		for di in range(-cells, cells + 1):
			var ix: int = ci + di
			if ix < 0 or ix >= _f._dim_x:
				continue
			var wx: float = _f._origin.x + float(ix) * cs
			var wz: float = _f._origin.z + float(iz) * cs
			var dx: float = wx - center.x
			var dz: float = wz - center.z
			if dx * dx + dz * dz > r2:
				continue
			if _column_ground_y(ix, iz) <= center_ground + 4.0:
				var iy: int = _f._surface_iy(ix, iz)
				if iy >= 0:
					_f.add_water_cell(ix, iy, iz, amount)


# World Y of the top solid (ground) surface in a column, or the bottom if all void.
func _column_ground_y(ix: int, iz: int) -> float:
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] != 0:
			return _f._origin.y + float(iy) * _f._cell_size
	return _f._origin.y


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _f._terrain == null or not _f._terrain.has_method("is_solid"):
		return
	var cs: float = _f._cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var ci: int = _f._col_i(world_pos.x, _f._origin.x)
	var cj: int = _f._col_i(world_pos.y, _f._origin.y)
	var ck: int = _f._col_i(world_pos.z, _f._origin.z)
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _f._dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _f._dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _f._dim_x:
					continue
				var i: int = (iy * _f._dim_z + iz) * _f._dim_x + ix
				_f._solid[i] = 1 if _f._terrain.is_solid(_f.cell_world_pos(ix, iy, iz)) else 0


# --- Physical splash droplets (FX) ------------------------------------------

## A few short-lived rigidbody droplets flung from a world point — the splash accent disasters call.
func splash(world_pos: Vector3, strength: float) -> void:
	if not _f.is_inside_tree() or is_nan(world_pos.x):
		return
	var s: float = clampf(strength, 0.1, 4.0)
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
		body.global_position = world_pos + Vector3(randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))
		var ang: float = randf() * TAU
		body.linear_velocity = Vector3(cos(ang) * randf_range(1.0, 2.5) * s, randf_range(2.5, 4.5) * s, sin(ang) * randf_range(1.0, 2.5) * s)
		var tm: SceneTreeTimer = _f.get_tree().create_timer(2.0)
		tm.timeout.connect(func(): if is_instance_valid(body): body.queue_free())
