class_name LAWaterFieldSystem
extends Node3D

# LAWaterFieldSystem — EMERGENT rivers, lakes and oceans over voxel terrain.
#
# A 2.5D cellular-automata water field lives on a flat grid that covers the
# world in XZ. Each cell stores the ground height (sampled from the injected
# terrain service) and a water DEPTH. Nothing about rivers or lakes is scripted:
# every frame water obeys three simple local rules —
#
#   1. FLOW   — water moves to lower neighbours by the SURFACE head difference
#               (terrain_h + depth). Downhill channels (rivers) and filled
#               basins (lakes) EMERGE from this alone.
#   2. RAIN   — weather adds depth uniformly (add_rain); it then flows/pools.
#   3. DRAIN  — a tiny per-step evaporation lets puddles dry to equilibrium.
#               Cells whose ground sits below sea_level fill toward it (oceans).
#
# The solver is a stable shallow-water redistribution on flat PackedFloat32Array
# arrays (index math, no per-cell nodes) and is THROTTLED to ~10 Hz via an
# accumulator, so it stays cheap regardless of frame rate. The wet surface is
# rebuilt as a single ArrayMesh (one quad per wet cell) on each CA step and
# drawn with an animated translucent-blue water shader — all generated in code,
# no external assets.
#
# Usage:
#   var water: LAWaterFieldSystem = LAWaterFieldSystem.new()
#   add_child(water)
#   water.setup(terrain_service, 300.0, 4.0)   # terrain: surface_height(x,z)->float
#   water.add_rain(weather.rain() * 0.3)       # drive from weather each step
#   water.add_source(spring_pos, 40.0)         # a spring / test river
#   var d: float = water.depth_at(px, pz)      # query for other systems
#   water.splash(hit_pos, 1.0)                 # rigidbody droplet accent
#
# Contract of the injected terrain service:
#   surface_height(x: float, z: float) -> float
#     World-space ground Y at (x, z), or NAN when the chunk is not yet meshed.
#     NAN cells are simply retried on later frames until they resolve.

# --- Tunables ---------------------------------------------------------------

## CA solver rate. The flow/rain/drain step runs at this frequency via an
## accumulator, decoupled from the render frame rate (keeps it cheap + stable).
const STEP_HZ: float = 10.0
const STEP_DT: float = 1.0 / STEP_HZ
## Never run more than this many catch-up CA steps in one frame (anti-spiral).
const MAX_STEPS_PER_FRAME: int = 3

## Cells sampled from the terrain service per FRAME while filling the grid.
## Bounds the startup cost so setup never blocks; NAN cells are retried later.
const SAMPLE_BUDGET: int = 700
## Fraction of cells that must be sampled before the field reports "ready".
const READY_FRACTION: float = 0.9

## Fraction of each cell->neighbour head difference transferred per CA step.
## Small enough (with the per-pair half-difference cap below) to never oscillate.
const FLOW_FACTOR: float = 0.25
## A single transfer is also capped at this fraction of the head difference so
## a cell can never overshoot a neighbour (the classic anti-oscillation guard).
const MAX_PAIR_FRACTION: float = 0.5
## Water removed from every wet cell each step so puddles dry to equilibrium. Tuned so
## shallow rain on flat/high ground dries off (only basins & flow channels stay wet).
const EVAP_PER_STEP: float = 0.0035
## How fast sub-sea-level cells fill toward sea_level per step (ocean fill).
const SEA_FILL_RATE: float = 0.6

## Depth (m) at/above which a cell contributes a quad to the rendered surface.
const RENDER_THRESHOLD: float = 0.05
## Depth (m) at/above which is_water_at() / surface_y_at() consider a cell wet.
const WATER_THRESHOLD: float = 0.02

## Splash accent tunables.
const SPLASH_DROPLETS: int = 6
const SPLASH_LIFETIME: float = 2.0
const SPLASH_RADIUS: float = 0.12

# --- Grid state (flat arrays; index = j * _dim + i, i=X, j=Z) ----------------

var _terrain = null
var _half_extent: float = 0.0
var _cell_size: float = 1.0
var _dim: int = 0                    # cells per axis (grid is _dim x _dim)
var _cell_count: int = 0

var _terrain_h: PackedFloat32Array = PackedFloat32Array()
var _depth: PackedFloat32Array = PackedFloat32Array()
var _delta: PackedFloat32Array = PackedFloat32Array()   # scratch net-change buffer
var _sampled: PackedByteArray = PackedByteArray()       # 1 once terrain_h is valid

## Sea level (world Y). Cells whose ground is below this fill toward it (oceans).
var sea_level: float = 0.0

var _sample_cursor: int = 0
var _sampled_count: int = 0
var _ready: bool = false

var _rain_rate: float = 0.0          # depth-per-second, set by add_rain()
var _step_accum: float = 0.0

# --- Rendering --------------------------------------------------------------

var _surface_mi: MeshInstance3D = null
var _surface_mesh: ArrayMesh = null
var _water_material: ShaderMaterial = null

const WATER_SHADER: String = """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.16, 0.46, 0.68, 0.55);
uniform vec4 deep_color : source_color = vec4(0.03, 0.16, 0.36, 0.85);
uniform float wave_speed = 0.7;
uniform float wave_scale = 0.5;
uniform float wave_height = 0.12;

varying float v_wave;

void vertex() {
	float w = sin(VERTEX.x * wave_scale + TIME * wave_speed)
			* cos(VERTEX.z * wave_scale + TIME * wave_speed * 0.8);
	v_wave = w;
	VERTEX.y += w * wave_height;
}

void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec4 col = mix(shallow_color, deep_color, clamp(0.5 + v_wave * 0.5, 0.0, 1.0));
	ALBEDO = col.rgb;
	ALPHA = mix(col.a, 1.0, fres * 0.4);
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
"""


# --- Setup ------------------------------------------------------------------

## Build the grid covering XZ in [-half_extent, half_extent] at cell_size.
## Terrain heights are sampled lazily over the following frames (see
## _sample_budget) so setup itself never blocks on an unmeshed world.
func setup(terrain, half_extent: float, cell_size: float) -> void:
	_terrain = terrain
	_half_extent = maxf(1.0, half_extent)
	_cell_size = maxf(0.5, cell_size)

	# +1 so the grid spans the full [-half, +half] inclusive of both edges.
	_dim = int(round((2.0 * _half_extent) / _cell_size)) + 1
	_dim = maxi(_dim, 2)
	_cell_count = _dim * _dim

	_terrain_h = PackedFloat32Array()
	_terrain_h.resize(_cell_count)
	_depth = PackedFloat32Array()
	_depth.resize(_cell_count)
	_delta = PackedFloat32Array()
	_delta.resize(_cell_count)
	_sampled = PackedByteArray()
	_sampled.resize(_cell_count)
	# resize() zero-fills; depth/delta/sampled all start at 0 which is correct.

	_sample_cursor = 0
	_sampled_count = 0
	_ready = false
	_step_accum = 0.0

	_build_surface_node()


func _build_surface_node() -> void:
	if _water_material == null:
		var shader: Shader = Shader.new()
		shader.code = WATER_SHADER
		_water_material = ShaderMaterial.new()
		_water_material.shader = shader

	if _surface_mesh == null:
		_surface_mesh = ArrayMesh.new()

	if _surface_mi == null:
		_surface_mi = MeshInstance3D.new()
		_surface_mi.name = "WaterSurface"
		_surface_mi.mesh = _surface_mesh
		# Translucent glow surface: never an occluder or shadow caster.
		_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_surface_mi)


# --- Grid index helpers -----------------------------------------------------

func _clampi_local(v: int, lo: int, hi: int) -> int:
	if v < lo:
		return lo
	if v > hi:
		return hi
	return v


## World-space center X of column i.
func _cell_x(i: int) -> float:
	return -_half_extent + float(i) * _cell_size


## World-space center Z of row j.
func _cell_z(j: int) -> float:
	return -_half_extent + float(j) * _cell_size


## Nearest cell index for a world (x, z), or -1 when outside the grid.
func _index_at(x: float, z: float) -> int:
	if _dim <= 0:
		return -1
	var i: int = int(round((x + _half_extent) / _cell_size))
	var j: int = int(round((z + _half_extent) / _cell_size))
	if i < 0 or i >= _dim or j < 0 or j >= _dim:
		return -1
	return j * _dim + i


# --- Frame loop -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _dim <= 0:
		return
	_sample_step()
	# THROTTLE: accumulate real time and only advance the CA at STEP_HZ. Extra
	# steps are capped so a long frame can never trigger an unbounded catch-up.
	_step_accum += delta
	var steps: int = 0
	while _step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_step_accum -= STEP_DT
		steps += 1
		_ca_step()
	# Drop any backlog beyond the cap so we don't spiral on the next frame.
	if _step_accum > STEP_DT:
		_step_accum = 0.0
	if steps > 0:
		_rebuild_surface()


# --- Lazy terrain sampling --------------------------------------------------

func _sample_step() -> void:
	if _sampled_count >= _cell_count:
		return
	if _terrain == null or not _terrain.has_method("surface_height"):
		return

	var budget: int = SAMPLE_BUDGET
	var scanned: int = 0
	# Sweep the flat array in a ring starting at _sample_cursor. Cells that come
	# back NAN (chunk not meshed yet) are left unsampled and revisited on a later
	# sweep, so the grid fills in as the world meshes without ever blocking.
	while budget > 0 and scanned < _cell_count:
		var idx: int = _sample_cursor
		_sample_cursor += 1
		if _sample_cursor >= _cell_count:
			_sample_cursor = 0
		scanned += 1
		if _sampled[idx] != 0:
			continue
		budget -= 1
		var i: int = idx % _dim
		var j: int = idx / _dim
		var h = _terrain.surface_height(_cell_x(i), _cell_z(j))
		if typeof(h) != TYPE_FLOAT and typeof(h) != TYPE_INT:
			continue
		var hf: float = float(h)
		if is_nan(hf) or is_inf(hf):
			continue
		_terrain_h[idx] = hf
		_sampled[idx] = 1
		_sampled_count += 1

	if not _ready and _sampled_count >= int(float(_cell_count) * READY_FRACTION):
		_ready = true


## True once at least READY_FRACTION of cells have valid terrain heights.
func is_ready() -> bool:
	return _ready


# --- Cellular-automata step -------------------------------------------------

func _ca_step() -> void:
	if _cell_count <= 0:
		return

	# 1) RAIN — uniform depth input driven by the current rate (see add_rain).
	if _rain_rate > 0.0:
		var add: float = _rain_rate * STEP_DT
		if add > 0.0:
			for idx in range(_cell_count):
				if _sampled[idx] != 0:
					_depth[idx] += add

	# 2) FLOW — stable shallow-water redistribution by SURFACE head difference.
	# Net change per cell is accumulated in _delta and applied afterwards so the
	# step is order-independent (no bias from array traversal direction).
	for idx in range(_cell_count):
		_delta[idx] = 0.0

	var dim: int = _dim
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _sampled[idx] == 0:
				continue
			var d: float = _depth[idx]
			if d <= 0.0:
				continue
			var head: float = _terrain_h[idx] + d

			# Gather the four orthogonal neighbours that sit LOWER in surface head.
			# Diffs are kept small local temporaries — no allocation per cell.
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
				if _sampled[li] != 0:
					var lh: float = _terrain_h[li] + _depth[li]
					if lh < head:
						n0 = li
						dh0 = head - lh
						total_diff += dh0
			if i < dim - 1:
				var ri: int = idx + 1
				if _sampled[ri] != 0:
					var rh: float = _terrain_h[ri] + _depth[ri]
					if rh < head:
						n1 = ri
						dh1 = head - rh
						total_diff += dh1
			if j > 0:
				var di: int = idx - dim
				if _sampled[di] != 0:
					var dhh: float = _terrain_h[di] + _depth[di]
					if dhh < head:
						n2 = di
						dh2 = head - dhh
						total_diff += dh2
			if j < dim - 1:
				var ui: int = idx + dim
				if _sampled[ui] != 0:
					var uh: float = _terrain_h[ui] + _depth[ui]
					if uh < head:
						n3 = ui
						dh3 = head - uh
						total_diff += dh3

			if total_diff <= 0.0:
				continue

			# We move at most FLOW_FACTOR of the summed head difference this step,
			# and never more water than the cell actually holds.
			var move_total: float = minf(d, total_diff * FLOW_FACTOR)
			if move_total <= 0.0:
				continue
			var scale: float = move_total / total_diff

			# Split proportionally to each neighbour's head deficit. Each transfer
			# is also capped at MAX_PAIR_FRACTION of that pair's difference so a
			# cell can never overshoot a neighbour and set up an oscillation.
			if n0 >= 0:
				var f0: float = minf(dh0 * scale, dh0 * MAX_PAIR_FRACTION)
				_delta[idx] -= f0
				_delta[n0] += f0
			if n1 >= 0:
				var f1: float = minf(dh1 * scale, dh1 * MAX_PAIR_FRACTION)
				_delta[idx] -= f1
				_delta[n1] += f1
			if n2 >= 0:
				var f2: float = minf(dh2 * scale, dh2 * MAX_PAIR_FRACTION)
				_delta[idx] -= f2
				_delta[n2] += f2
			if n3 >= 0:
				var f3: float = minf(dh3 * scale, dh3 * MAX_PAIR_FRACTION)
				_delta[idx] -= f3
				_delta[n3] += f3

	# Apply accumulated flow, then 3) DRAIN — evaporation + sub-sea-level fill.
	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var nd: float = _depth[idx] + _delta[idx]
		if nd < 0.0:
			nd = 0.0
		# Ocean fill: ground below sea_level pulls water up toward the sea level.
		var floor_h: float = _terrain_h[idx]
		if floor_h < sea_level:
			var target: float = sea_level - floor_h
			if nd < target:
				nd = move_toward(nd, target, SEA_FILL_RATE)
		# Evaporation: tiny uniform loss so transient puddles dry out.
		if nd > 0.0:
			nd -= EVAP_PER_STEP
			if nd < 0.0:
				nd = 0.0
		_depth[idx] = nd


# --- External inputs --------------------------------------------------------

## Set the current uniform rain rate (depth metres per SECOND). Applied on each
## CA step scaled by STEP_DT, so weather can call this with its live rain value.
func add_rain(amount_per_sec: float) -> void:
	if is_nan(amount_per_sec) or is_inf(amount_per_sec):
		return
	_rain_rate = maxf(0.0, amount_per_sec)


## Dump `amount` of water depth at a world point (a spring, or a test river
## source). No-op if the point is outside the grid or the cell isn't sampled.
func add_source(world_pos: Vector3, amount: float) -> void:
	if amount <= 0.0 or is_nan(amount) or is_inf(amount):
		return
	var idx: int = _index_at(world_pos.x, world_pos.z)
	if idx < 0:
		return
	if _sampled[idx] == 0:
		return
	_depth[idx] += amount


# --- Query API for other systems -------------------------------------------

## Water depth (m) at a world (x, z). Returns 0.0 outside the grid / when dry.
func depth_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	if idx < 0:
		return 0.0
	return _depth[idx]


## True when the cell under (x, z) holds at least WATER_THRESHOLD of water.
func is_water_at(x: float, z: float) -> bool:
	return depth_at(x, z) >= WATER_THRESHOLD


## World Y of the water surface (terrain_h + depth) at (x, z), or NAN when the
## cell is unsampled or effectively dry.
func surface_y_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	if idx < 0 or _sampled[idx] == 0:
		return NAN
	if _depth[idx] < WATER_THRESHOLD:
		return NAN
	return _terrain_h[idx] + _depth[idx]


# --- Rendered surface -------------------------------------------------------

func _rebuild_surface() -> void:
	if _surface_mesh == null:
		return
	# Full rebuild each CA step (~10 Hz): emit one quad per wet cell. At ~150^2
	# cells this is a few thousand quads worst case — cheap and measured. Only
	# cells with depth > RENDER_THRESHOLD contribute, so dry regions cost nothing.
	if _surface_mesh.get_surface_count() > 0:
		_surface_mesh.clear_surfaces()

	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()

	var hc: float = _cell_size * 0.5
	var up: Vector3 = Vector3.UP
	var base: int = 0

	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var d: float = _depth[idx]
		if d < RENDER_THRESHOLD:
			continue
		var i: int = idx % _dim
		var j: int = idx / _dim
		var cx: float = _cell_x(i)
		var cz: float = _cell_z(j)
		var y: float = _terrain_h[idx] + d

		verts.push_back(Vector3(cx - hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz - hc))
		verts.push_back(Vector3(cx + hc, y, cz + hc))
		verts.push_back(Vector3(cx - hc, y, cz + hc))
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		normals.push_back(up)
		indices.push_back(base + 0)
		indices.push_back(base + 1)
		indices.push_back(base + 2)
		indices.push_back(base + 0)
		indices.push_back(base + 2)
		indices.push_back(base + 3)
		base += 4

	if verts.is_empty():
		return

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_surface_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _water_material != null:
		_surface_mesh.surface_set_material(0, _water_material)


## Diagnostics: number of cells currently rendered (depth > RENDER_THRESHOLD).
func wet_cell_count() -> int:
	var n: int = 0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _depth[idx] >= RENDER_THRESHOLD:
			n += 1
	return n


# --- Splash accent ----------------------------------------------------------

## Spawn a few short-lived rigidbody water droplets flung up/out from world_pos —
## the physical "splash" accent for the hybrid. Everything is guarded so a bad
## call can never crash the sim; droplets auto-free after SPLASH_LIFETIME.
func splash(world_pos: Vector3, strength: float) -> void:
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	if is_nan(world_pos.x) or is_nan(world_pos.y) or is_nan(world_pos.z):
		return
	var s: float = clampf(strength, 0.1, 4.0)

	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = SPLASH_RADIUS
	mesh.height = SPLASH_RADIUS * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.6, 0.9, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.1
	mat.metallic = 0.0
	mesh.material = mat

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = SPLASH_RADIUS

	for n in range(SPLASH_DROPLETS):
		var body: RigidBody3D = RigidBody3D.new()
		body.mass = 0.05
		body.gravity_scale = 1.0
		# Hit terrain (layer 1) but ignore each other to stay cheap.
		body.collision_mask = 1
		body.collision_layer = 0

		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)

		var col: CollisionShape3D = CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		add_child(body)
		body.global_position = world_pos + Vector3(
			randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))

		# Fling upward and outward; stronger splashes throw droplets higher/wider.
		var ang: float = randf() * TAU
		var out: float = randf_range(1.0, 2.5) * s
		var upv: float = randf_range(2.5, 4.5) * s
		body.linear_velocity = Vector3(cos(ang) * out, upv, sin(ang) * out)
		body.angular_velocity = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))

		# Auto-free: a one-shot timer queue_frees the droplet after its lifetime.
		var timer: SceneTreeTimer = tree.create_timer(SPLASH_LIFETIME)
		timer.timeout.connect(_free_droplet.bind(body))


func _free_droplet(body: Node) -> void:
	if is_instance_valid(body):
		body.queue_free()
