class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D: the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored

const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")

var _f = null                                            # back-reference to the owning LAMaterialField3D

var queue: LAMaterialFieldInjectQueue3D = QueueScript.new()

signal splashed(world_pos: Vector3, strength: float)


func setup(field) -> void:
	_f = field
	# The grid the queue sizes cross-cell transfers in mass with. Without it flush() drops every op.
	queue.setup(field._grid)


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


## Loose mineral arriving at a point. What lands is grains, so the cell's consolidated share goes with it.
func deposit_sediment(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or not _device_ready():
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


## Cells the test hook marches up from a surface point to find the void over it.
const VOID_MARCH_CELLS: int = 16


## The empty cell over a surface point: up out of the rock, then out of any crust standing loose in the
## open cells over it. -1 when the march leaves the box still in matter.
func void_over(world_pos: Vector3) -> int:
	var at: int = LAFieldGeometry.air_above(_f, _f.world_to_cell(world_pos), VOID_MARCH_CELLS)
	for _k in VOID_MARCH_CELLS:
		if at < 0 or _f._mirrors.at("silicate", at) <= 0.0:
			return at
		at = LAFieldGeometry.above(_f, at)
	return -1


## TEST HOOK (--stamp-test): raise the void cell over `world_pos` to `amount` of consolidated rock. The
## gain is a sourceless add, booked as created. Not used in normal play.
func debug_deposit(world_pos: Vector3, amount: float) -> int:
	var c: int = void_over(world_pos) if _f._mirrors.has("silicate") else -1
	if c < 0:
		push_error("LAMaterialFieldInject3D: no empty cell stands over %v inside this field's box within %d cells, so nothing was deposited."
			% [world_pos, VOID_MARCH_CELLS])
		return -1
	var want: float = clampf(amount, 0.0, 1.0) * LASubstances.full_mol_m3("silicate")
	var have: float = _f._mirrors.at("silicate", c)
	var gain: float = want - have
	_f._mirrors.set_at("silicate", c, maxf(have, want))
	if gain > 0.0:
		queue.add("silicate", PackedInt32Array([c]), PackedFloat32Array([gain]), want)
		queue.add("cement", PackedInt32Array([c]), PackedFloat32Array([1.0]), 1.0)
	return c
