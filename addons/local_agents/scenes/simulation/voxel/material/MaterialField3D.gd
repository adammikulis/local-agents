class_name LAMaterialField3D
extends Node3D

## LAMaterialField3D — the DENSE 3D material-flow substrate (successor to the 2.5D LAMaterialField).
##
## The 2.5D field stored one column per XZ cell (a surface height + material *depths*). That could not
## represent caves: water can't pool in a cavern, lava can't drain into a tube, a plume can't rise a
## shaft. This field stores a real 3D volume — a temperature + per-material amount for every (x,y,z)
## cell — so all of that EMERGES from local rules that now include the Y axis.
##
## DENSE (not sparse bricks): at the sim's 5-unit resolution the whole volume is ~0.9M cells × a few
## float layers ≈ ~20 MB, so a flat 3D array is the simplest thing that works. Solid rock cells (from
## the terrain SDF via is_solid) hold no fluid and are skipped; an active-cell list keeps the CPU
## oracle cheap without brick machinery. The GPU kernels become a 3D dispatch over the same arrays.
##
## Index layout: idx = (iy * _dim_z + iz) * _dim_x + ix  (X contiguous, then Z, then Y). World position
## of a cell centre = _origin + Vector3(ix, iy, iz) * _cell_size.
## (Explicit types only — no ':=' inferred typing.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

# --- Water CA tuning (finite-volume cellular water: fall, pressurise, spread — mass-conserving and
# stable, and it fills sealed caverns bottom-up + supports pressure so water finds its level). Adapted
# from the classic 2D "finite water cells" scheme, generalised to 3D (down, up-if-compressed, 4 lateral).
const MAX_MASS: float = 1.0               # a cell is "full" at this water mass
const MAX_COMPRESS: float = 0.02          # extra mass a cell can hold per cell of water stacked above it
const MIN_MASS: float = 0.0001            # below this a cell is considered dry
const MAX_FLOW: float = 1.0               # max mass moved out of a cell per step (stability cap)
const MIN_FLOW: float = 0.01              # ignore dribbles smaller than this
const LATERAL_FRACTION: float = 0.5      # share of the level-out flow sent to each lateral neighbour

# --- Grid state -------------------------------------------------------------
var _terrain = null
var _cell_size: float = 5.0
var _origin: Vector3 = Vector3.ZERO       # world position of cell (0,0,0) centre
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0

var _solid: PackedByteArray = PackedByteArray()          # 1 = rock (holds no fluid), 0 = void (air/water)
var _water: PackedFloat32Array = PackedFloat32Array()    # water mass per cell (can exceed 1 under pressure)
var _wnext: PackedFloat32Array = PackedFloat32Array()    # double buffer for the water step
# 1 = calm STATIC sea: seeded once below sea level and left at rest — NOT stepped and NOT meshed (the
# GPU ocean plane draws it). Only DYNAMIC water (springs, rivers, cave pools, splashes) is simulated and
# rendered, so the cost tracks the active water, not the whole seabed. Dynamic water that flows into a
# static cell is absorbed (drains into the sea). This is what keeps the dense 3D field cheap.
var _static: PackedByteArray = PackedByteArray()

# --- Shared 3D field state used by the concern modules (heat / atmosphere / lava). Every cell (rock OR
# void) carries a temperature; the atmosphere layers + lava are per-cell amounts like water. The modules
# reach into these arrays through the field (`_f`), 3D-generalising the 2.5D MaterialHeat/Atmosphere/
# Liquid. INITIAL_TEMP seeds a mild ground so nothing freezes before the field settles.
const INITIAL_TEMP: float = 15.0
var _temp: PackedFloat32Array = PackedFloat32Array()     # temperature °C per cell (rock + void)
var _vapor: PackedFloat32Array = PackedFloat32Array()    # airborne water vapor (humidity) per cell
var _cloud: PackedFloat32Array = PackedFloat32Array()    # condensed cloud density per cell
var _fog: PackedFloat32Array = PackedFloat32Array()      # condensed fog density per cell
var _lava: PackedFloat32Array = PackedFloat32Array()     # lava mass per cell (a hot, viscous liquid)
var _sun_light = null                                    # DirectionalLight3D — solar forcing (top cells)

# Concern modules (3D generalisations of the 2.5D ones), set by activate().
var _heat = null                                         # LAMaterialHeat3D
var _atmosphere = null                                   # LAMaterialAtmosphere3D
var _lava_sim = null                                     # LAMaterialLava3D
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat3D.gd")
const AtmosphereScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere3D.gd")
const LavaScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialLava3D.gd")
const GPUScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3D.gd")
var _gpu = null                                          # LAMaterialGPU3D (local RenderingDevice) or null
var _use_gpu: bool = false


## Wire the real scene sun (DirectionalLight3D); the heat module reads its energy + angle for solar input.
func set_sun(light) -> void:
	_sun_light = light


var sea_level: float = 0.0
var _half_extent: float = 0.0

# --- Frame loop + rendering -------------------------------------------------
const STEP_HZ: float = 10.0
const STEP_DT: float = 1.0 / STEP_HZ
const MAX_STEPS_PER_FRAME: int = 2
const RENDER_MIN: float = 0.08            # min water mass in a cell for its top face to render
const SEA_WAVE_EPS: float = 0.6           # calm-sea top faces within this of sea_level are left to the ocean plane
var _step_accum: float = 0.0
var _ready_sim: bool = false
# Lazy solidity sampling: the field is created before the terrain has finished streaming, so it samples
# rock/void a budget of columns per frame and self-activates (seed sea + build modules) once complete —
# exactly how the old field lazily sampled heights. No blocking, no external init calls.
const SAMPLE_COLS_PER_FRAME: int = 700
var _sampling_done: bool = false
var _sample_cursor: int = 0
var _surface_mi: MeshInstance3D = null
var _surface_mesh: ArrayMesh = null
var _water_mat: Material = null
# Heat texture: the hottest temperature in each XZ column baked to an R-float texture (dim_x × dim_z)
# the terrain shader samples for incandescent glow — so a lava tube or a buried hot cell still lights the
# ground above it. Same interface as the 2.5D field (heat_texture/heat_world_min/heat_world_size).
var _heat_img: Image = null
var _heat_tex: ImageTexture = null
var _heat_col: PackedFloat32Array = PackedFloat32Array()
# Persistent water sources (springs) injected each step: [{pos, rate}].
var _sources: Array = []


# --- Setup ------------------------------------------------------------------

## Build the 3D volume covering XZ in [-half_extent, half_extent] and Y in [y_min, y_max] at cell_size,
## bound to `terrain` (for the is_solid rock/void query). Cells are sampled solid/void lazily.
func setup(terrain, half_extent: float, cell_size: float, y_min: float, y_max: float, sea: float) -> void:
	_terrain = terrain
	_half_extent = maxf(1.0, half_extent)
	_cell_size = maxf(0.5, cell_size)
	sea_level = sea
	var dx: int = int(round((2.0 * _half_extent) / _cell_size)) + 1
	var dy: int = int(round((y_max - y_min) / _cell_size)) + 1
	setup_dims(dx, dy, dx, _cell_size, Vector3(-_half_extent, y_min, -_half_extent))
	# Build the heat texture now (not at activate) so consumers can wire heat_texture() immediately, even
	# while the field is still lazily sampling solidity.
	_build_heat_texture()


## Sample rock/void for every cell from the terrain SDF (is_solid). Eager version — fine at setup for
## the dense grid; a budgeted lazy variant can replace it once wired into the frame loop. Skips the
## per-cell query for cells clearly in open air above the column's surface (cheap win).
func sample_solidity() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	var has_surf: bool = _terrain.has_method("surface_height")
	for iz in range(_dim_z):
		for ix in range(_dim_x):
			var wx: float = _origin.x + float(ix) * _cell_size
			var wz: float = _origin.z + float(iz) * _cell_size
			var surf: float = _terrain.surface_height(wx, wz) if has_surf else NAN
			for iy in range(_dim_y):
				var wy: float = _origin.y + float(iy) * _cell_size
				var i: int = _idx(ix, iy, iz)
				# Well above the surface => open air, no need to query (also handles NAN columns as air).
				if not is_nan(surf) and wy > surf + _cell_size:
					_solid[i] = 0
					continue
				_solid[i] = 1 if _terrain.is_solid(Vector3(wx, wy, wz)) else 0


## Budgeted lazy version of sample_solidity: sample SAMPLE_COLS_PER_FRAME columns per call from the
## terrain SDF, advancing a cursor; sets _sampling_done when the whole volume is covered.
func _sample_step() -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	var has_surf: bool = _terrain.has_method("surface_height")
	var cols: int = _dim_x * _dim_z
	var processed: int = 0
	while processed < SAMPLE_COLS_PER_FRAME and _sample_cursor < cols:
		var ix: int = _sample_cursor % _dim_x
		var iz: int = _sample_cursor / _dim_x
		var wx: float = _origin.x + float(ix) * _cell_size
		var wz: float = _origin.z + float(iz) * _cell_size
		var surf: float = _terrain.surface_height(wx, wz) if has_surf else NAN
		for iy in range(_dim_y):
			var wy: float = _origin.y + float(iy) * _cell_size
			var i: int = _idx(ix, iy, iz)
			if not is_nan(surf) and wy > surf + _cell_size:
				_solid[i] = 0
			else:
				_solid[i] = 1 if _terrain.is_solid(Vector3(wx, wy, wz)) else 0
		_sample_cursor += 1
		processed += 1
	if _sample_cursor >= cols:
		_sampling_done = true


## Seed the ocean: every VOID cell whose centre is below sea level starts full of water. The sea is a
## known level, so we set it directly (fast) instead of CA-filling the whole seabed from empty; the CA
## then only has to handle dynamics (waves, splashes, rivers meeting the sea, water pouring into caves).
func seed_sea() -> void:
	for iy in range(_dim_y):
		var wy: float = _origin.y + float(iy) * _cell_size
		if wy >= sea_level:
			break                                       # layers above sea level: nothing to seed
		for iz in range(_dim_z):
			for ix in range(_dim_x):
				var i: int = _idx(ix, iy, iz)
				if _solid[i] == 0:
					_water[i] = MAX_MASS
					_static[i] = 1                       # calm sea: hold it, don't simulate/mesh it


# --- Setup ------------------------------------------------------------------

## Explicit-dimension setup (used by tests / when the caller knows the volume directly).
func setup_dims(dim_x: int, dim_y: int, dim_z: int, cell_size: float, origin: Vector3) -> void:
	_dim_x = maxi(1, dim_x)
	_dim_y = maxi(1, dim_y)
	_dim_z = maxi(1, dim_z)
	_cell_size = maxf(0.5, cell_size)
	_origin = origin
	_cell_count = _dim_x * _dim_y * _dim_z
	_solid = PackedByteArray()
	_solid.resize(_cell_count)
	_water = PackedFloat32Array()
	_water.resize(_cell_count)
	_wnext = PackedFloat32Array()
	_wnext.resize(_cell_count)
	_static = PackedByteArray()
	_static.resize(_cell_count)
	_temp = PackedFloat32Array()
	_temp.resize(_cell_count)
	_temp.fill(INITIAL_TEMP)
	_vapor = PackedFloat32Array()
	_vapor.resize(_cell_count)
	_cloud = PackedFloat32Array()
	_cloud.resize(_cell_count)
	_fog = PackedFloat32Array()
	_fog.resize(_cell_count)
	_lava = PackedFloat32Array()
	_lava.resize(_cell_count)


# --- Index helpers ----------------------------------------------------------

func _idx(ix: int, iy: int, iz: int) -> int:
	return (iy * _dim_z + iz) * _dim_x + ix


func _in_bounds(ix: int, iy: int, iz: int) -> bool:
	return ix >= 0 and ix < _dim_x and iy >= 0 and iy < _dim_y and iz >= 0 and iz < _dim_z


func cell_world_pos(ix: int, iy: int, iz: int) -> Vector3:
	return _origin + Vector3(float(ix), float(iy), float(iz)) * _cell_size


# --- Authoring (tests + terrain sampling) -----------------------------------

func set_solid(ix: int, iy: int, iz: int, solid: bool) -> void:
	if _in_bounds(ix, iy, iz):
		_solid[_idx(ix, iy, iz)] = 1 if solid else 0


func is_cell_solid(ix: int, iy: int, iz: int) -> bool:
	if not _in_bounds(ix, iy, iz):
		return true                                     # out of bounds reads as wall
	return _solid[_idx(ix, iy, iz)] != 0


func add_water_cell(ix: int, iy: int, iz: int, amount: float) -> void:
	if not _in_bounds(ix, iy, iz):
		return
	var i: int = _idx(ix, iy, iz)
	if _solid[i] != 0:
		return
	_water[i] = maxf(0.0, _water[i] + amount)


func water_at_cell(ix: int, iy: int, iz: int) -> float:
	if not _in_bounds(ix, iy, iz):
		return 0.0
	return _water[_idx(ix, iy, iz)]


func total_water() -> float:
	var s: float = 0.0
	for i in range(_cell_count):
		s += _water[i]
	return s


# --- The 3D water CA --------------------------------------------------------

# Stable amount for the LOWER of two vertically-stacked water cells given their combined mass. Below
# MAX_MASS all the water sits in the lower cell; above that the excess is compressed upward, letting a
# tall column press down (pressure) so water in a connected cavern finds a common level.
func _stable_below(total_mass: float) -> float:
	if total_mass <= MAX_MASS:
		return total_mass
	if total_mass < 2.0 * MAX_MASS + MAX_COMPRESS:
		return (MAX_MASS * MAX_MASS + total_mass * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS)
	return (total_mass + MAX_COMPRESS) * 0.5


## One water step: gravity fall, upward pressure relief, then lateral levelling — mass-conserving via a
## double buffer. Fills caverns bottom-up and lets connected water find its level (rivers, lakes, sea,
## and now underground pools + water pouring into a cave through a shaft).
func step_water() -> void:
	# Start next = current; every transfer edits _wnext so reads stay on the stable _water snapshot.
	for i in range(_cell_count):
		_wnext[i] = _water[i]

	var layer: int = _dim_x * _dim_z
	for iy in range(_dim_y):
		for iz in range(_dim_z):
			for ix in range(_dim_x):
				var i: int = (iy * _dim_z + iz) * _dim_x + ix
				# Skip rock and calm STATIC sea — the expensive flow math only runs on dynamic water.
				if _solid[i] != 0 or _static[i] != 0:
					continue
				var remaining: float = _water[i]
				if remaining < MIN_MASS:
					continue
				var flow: float = 0.0

				# 1) DOWN — gravity. Move toward the stable split with the cell below (drain into sea).
				if iy > 0:
					var ib: int = i - layer
					if _solid[ib] == 0:
						if _static[ib] != 0:
							# The sea below is an infinite sink: water pours in and is absorbed.
							_wnext[i] -= remaining
							remaining = 0.0
						else:
							flow = _stable_below(remaining + _water[ib]) - _water[ib]
							flow = clampf(flow, 0.0, minf(MAX_FLOW, remaining))
							if flow > MIN_FLOW:
								_wnext[i] -= flow
								_wnext[ib] += flow
								remaining -= flow
				if remaining < MIN_MASS:
					continue

				# 2) LATERAL — level out with the 4 side neighbours (only push to lower ones).
				var lat: Array = [
					[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1]
				]
				for pr in lat:
					if remaining < MIN_MASS:
						break
					var nx: int = pr[0]
					var nz: int = pr[1]
					if nx < 0 or nx >= _dim_x or nz < 0 or nz >= _dim_z:
						continue
					var inb: int = _idx(nx, iy, nz)
					if _solid[inb] != 0:
						continue
					if _static[inb] != 0:
						# Reached the sea sideways (a river mouth) — absorb a share and move on.
						var drain: float = clampf(remaining * LATERAL_FRACTION, 0.0, remaining)
						_wnext[i] -= drain
						remaining -= drain
						continue
					var diff: float = remaining - _water[inb]
					if diff > MIN_FLOW:
						var lflow: float = clampf(diff * LATERAL_FRACTION, 0.0, minf(MAX_FLOW, remaining))
						if lflow > MIN_FLOW:
							_wnext[i] -= lflow
							_wnext[inb] += lflow
							remaining -= lflow

				# 3) UP — only overflow (compressed above MAX_MASS) pushes into the cell above.
				if remaining > MAX_MASS and iy < _dim_y - 1:
					var iu: int = i + layer
					if _solid[iu] == 0 and _static[iu] == 0:
						var uflow: float = remaining - _stable_below(remaining + _water[iu])
						uflow = clampf(uflow, 0.0, minf(MAX_FLOW, remaining))
						if uflow > MIN_FLOW:
							_wnext[i] -= uflow
							_wnext[iu] += uflow
							remaining -= uflow

	# Commit the buffer.
	var tmp: PackedFloat32Array = _water
	_water = _wnext
	_wnext = tmp


## Highest world Y that has water in the XZ column at grid (ix, iz), or NAN if the column is dry. Used
## by the surface queries + renderer to find the water surface (open sea/lake OR a cavern pool top).
func column_surface_y(ix: int, iz: int) -> float:
	if ix < 0 or ix >= _dim_x or iz < 0 or iz >= _dim_z:
		return NAN
	for iy in range(_dim_y - 1, -1, -1):
		var m: float = _water[_idx(ix, iy, iz)]
		if m >= MIN_MASS:
			# Surface sits within the top wet cell proportional to its fill.
			var fill: float = clampf(m, 0.0, MAX_MASS)
			return _origin.y + (float(iy) + fill - 0.5) * _cell_size
	return NAN


# --- World-space queries (the 2.5D-compatible API the consumers call) --------

func _col_i(w: float, o: float) -> int:
	return clampi(int(round((w - o) / _cell_size)), 0, _dim_x - 1)


## World Y of the water surface at (x, z) — sea, lake, river, or a cavern pool top. NAN if dry.
func surface_y_at(x: float, z: float) -> float:
	return column_surface_y(_col_i(x, _origin.x), _col_i(z, _origin.z))


func is_water_at(x: float, z: float) -> bool:
	return not is_nan(surface_y_at(x, z))


## Total water column depth at (x, z) in world units (sum of cell fills × cell size). 0 if dry.
func depth_at(x: float, z: float) -> float:
	var ix: int = _col_i(x, _origin.x)
	var iz: int = _col_i(z, _origin.z)
	var d: float = 0.0
	for iy in range(_dim_y):
		d += minf(_water[_idx(ix, iy, iz)], MAX_MASS)
	return d * _cell_size


## Inject water at a world point (a spring, rain, a flood surge, a meteor splash).
func add_water_world(pos: Vector3, amount: float) -> void:
	add_water_cell(_col_i(pos.x, _origin.x), _col_i(pos.y, _origin.y), _col_i(pos.z, _origin.z), amount)


## Register a persistent spring: `rate` water mass per second injected at `pos` each step.
func add_source(pos: Vector3, rate: float) -> void:
	_sources.append({"pos": pos, "rate": rate})


# --- Live frame loop + fluid-surface rendering ------------------------------

## Begin simulating + rendering (called after setup + sample_solidity + seed_sea). Builds the render
## node and starts the throttled step in _physics_process.
func activate() -> void:
	_heat = HeatScript.new()
	_heat.setup(self)
	_atmosphere = AtmosphereScript.new()
	_atmosphere.setup(self)
	_lava_sim = LavaScript.new()
	_lava_sim.setup(self)
	# GPU-RESIDENT backend: persistent SSBOs, the whole heat+water step batched on-GPU, ONE readback per
	# frame (see MaterialGPU3D's frame API). Headless has no local RenderingDevice → CPU oracle.
	if GPUScript.available():
		_gpu = GPUScript.new()
		_gpu.setup(self)
		_use_gpu = true
		# Seed the resident buffers with the initial CPU state (temp/water from setup+seed_sea; the gas +
		# lava layers start empty). vapor/cloud/fog then live fully on the GPU; temp/water/lava re-upload.
		_gpu.set_field("temp", _temp)
		_gpu.set_field("water", _water)
		_gpu.set_field("vapor", _vapor)
		_gpu.set_field("cloud", _cloud)
		_gpu.set_field("fog", _fog)
		_gpu.set_field("lava", _lava)
	_build_render_node()
	_build_heat_texture()
	rebuild_surface()
	_update_heat_texture()
	_ready_sim = true


# --- Heat texture (terrain-glow source) -------------------------------------

func _build_heat_texture() -> void:
	if _heat_tex != null:
		return
	_heat_col = PackedFloat32Array()
	_heat_col.resize(_dim_x * _dim_z)
	_heat_col.fill(INITIAL_TEMP)
	_heat_img = Image.create_from_data(_dim_x, _dim_z, false, Image.FORMAT_RF, _heat_col.to_byte_array())
	_heat_tex = ImageTexture.create_from_image(_heat_img)


# Project the hottest cell in each column into the R-float texture the terrain shader reads.
func _update_heat_texture() -> void:
	if _heat_tex == null:
		return
	var dx: int = _dim_x
	var dz: int = _dim_z
	var layer: int = dx * dz
	for iz in range(dz):
		for ix in range(dx):
			var hottest: float = -1000.0
			var base: int = iz * dx + ix
			for iy in range(_dim_y):
				var t: float = _temp[iy * layer + base]
				if t > hottest:
					hottest = t
			_heat_col[base] = hottest
	_heat_img.set_data(dx, dz, false, Image.FORMAT_RF, _heat_col.to_byte_array())
	_heat_tex.update(_heat_img)


## The live terrain-glow texture (R = hottest °C per column). Wire once into the terrain shader.
func heat_texture() -> Texture2D:
	return _heat_tex

func heat_world_min() -> Vector2:
	return Vector2(-_half_extent, -_half_extent)

func heat_world_size() -> Vector2:
	return Vector2(2.0 * _half_extent, 2.0 * _half_extent)


func _physics_process(delta: float) -> void:
	if not _ready_sim:
		# Still sampling rock/void as the terrain streams; self-activate when the volume is fully sampled.
		if _terrain != null and _terrain.has_method("is_solid"):
			_sample_step()
			if _sampling_done:
				seed_sea()
				activate()
		return
	_step_accum += delta
	var steps: int = 0
	while _step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_step_accum -= STEP_DT
		steps += 1
	if steps <= 0:
		return

	if _use_gpu:
		# GPU-RESIDENT: the WHOLE step (water + heat + atmosphere + lava) runs `steps` times on the GPU
		# with one upload + one readback per frame. temp/water/lava carry CPU injections (springs, disaster
		# heat/lava) so they're re-uploaded each frame; vapor/cloud/fog live fully resident on the GPU.
		for src in _sources:
			add_water_world(src["pos"], float(src["rate"]) * STEP_DT * float(steps))
		var solar: float = _heat._solar() if _heat != null else 0.6
		var w: Vector2 = _atmosphere.wind() if _atmosphere != null and _atmosphere.has_method("wind") else Vector2.ZERO
		_gpu.begin_frame(_temp, _water, solar, w)
		_gpu.set_field("lava", _lava)
		for i in range(steps):
			_gpu.step()
		var out: Dictionary = _gpu.end_frame()
		_temp = out["temp"]
		_water = out["water"]
		_vapor = out["vapor"]
		_cloud = out["cloud"]
		_fog = out["fog"]
		_lava = out["lava"]
	else:
		for i in range(steps):
			# Springs feed the surface (rivers emerge as this water flows downhill in 3D).
			for src in _sources:
				add_water_world(src["pos"], float(src["rate"]) * STEP_DT)
			step_water()
			if _heat != null:
				_heat.step()
			if _atmosphere != null:
				_atmosphere.step()
			if _lava_sim != null:
				_lava_sim.step()
	rebuild_surface()
	_update_heat_texture()


## Temperature °C at a world point (0 outside the grid). The consumer query the 2.5D field also exposes.
func temp_at(x: float, z: float, y: float = NAN) -> float:
	var ix: int = _col_i(x, _origin.x)
	var iz: int = _col_i(z, _origin.z)
	var iy: int = _col_i(y, _origin.y) if not is_nan(y) else _surface_iy(ix, iz)
	if iy < 0:
		return 0.0
	return _temp[(iy * _dim_z + iz) * _dim_x + ix]


# Topmost non-solid cell of a column (its sky-exposed surface), or -1 if the column is solid to the top.
func _surface_iy(ix: int, iz: int) -> int:
	for iy in range(_dim_y - 1, -1, -1):
		if _solid[(iy * _dim_z + iz) * _dim_x + ix] == 0:
			return iy
	return -1


# --- Consumer-facing API (matches the 2.5D LAMaterialField so this is a drop-in on the swap) --------

## True where the ground is below sea level (open ocean under the plane).
func is_ocean_at(x: float, z: float) -> bool:
	var ix: int = _col_i(x, _origin.x)
	var iz: int = _col_i(z, _origin.z)
	# Any static (seeded-sea) or below-sea void cell in the column means this is sea.
	for iy in range(_dim_y):
		if _origin.y + float(iy) * _cell_size >= sea_level:
			break
		var i: int = (iy * _dim_z + iz) * _dim_x + ix
		if _solid[i] == 0:
			return true
	return false


## Salinity 0 (fresh inland water) .. ~0.35-0.65 (brackish shallows) .. 1 (deep salt ocean); NAN if dry.
## Depth-of-sea proxy, matching the 2.5D field so the salinity-banded fish behave identically.
const SALT_FULL_DEPTH: float = 22.0
const BRACKISH_FLOOR: float = 0.35
func salinity_at(x: float, z: float) -> float:
	if is_ocean_at(x, z):
		# Deepest open water is saltiest; the shallow shore band (incl. river mouths) stays brackish.
		var ix: int = _col_i(x, _origin.x)
		var iz: int = _col_i(z, _origin.z)
		var floor_y: float = sea_level
		for iy in range(_dim_y):
			var i: int = (iy * _dim_z + iz) * _dim_x + ix
			if _solid[i] == 0:
				floor_y = _origin.y + float(iy) * _cell_size
				break
		return clampf((sea_level - floor_y) / SALT_FULL_DEPTH, BRACKISH_FLOOR, 1.0)
	if is_water_at(x, z):
		return 0.0                                       # inland CA pool (lake/river) = fresh
	return NAN


# Atmosphere delegators (the 3D atmosphere owns the water cycle + humidity/dewpoint).
func cloud_at(x: float, z: float) -> float:
	return _atmosphere.cloud_at(x, z) if _atmosphere != null else 0.0

func fog_at(x: float, z: float) -> float:
	return _atmosphere.fog_at(x, z) if _atmosphere != null else 0.0

func avg_cloud_cover() -> float:
	return _atmosphere.avg_cloud_cover() if _atmosphere != null else 0.0

func avg_fog_cover() -> float:
	return _atmosphere.avg_fog_cover() if _atmosphere != null else 0.0

func cloud_grid() -> PackedFloat32Array:
	return _atmosphere.cloud_grid() if _atmosphere != null else PackedFloat32Array()

func fog_grid() -> PackedFloat32Array:
	return _atmosphere.fog_grid() if _atmosphere != null else PackedFloat32Array()

func cloud_base_y() -> float:
	return _atmosphere.cloud_base_y() if _atmosphere != null else sea_level + 62.0

func fog_base_y() -> float:
	return _atmosphere.fog_base_y() if _atmosphere != null else sea_level + 6.0

func relative_humidity_at(x: float, z: float) -> float:
	return _atmosphere.relative_humidity_at(x, z) if _atmosphere != null else 0.0

func dewpoint_at(x: float, z: float) -> float:
	return _atmosphere.dewpoint_at(x, z) if _atmosphere != null else NAN

func set_wind(w: Vector2) -> void:
	if _atmosphere != null:
		_atmosphere.set_wind(w)

func wind() -> Vector2:
	return _atmosphere.wind() if _atmosphere != null else Vector2.ZERO

## The cloud/fog grids project to (dim_x × dim_z) so CloudLayer's texture maps 1:1 with the 2.5D field.
func grid_dim() -> int:
	return _dim_x

func grid_half_extent() -> float:
	return _half_extent


# Heat + lava injection (disasters call these) + diagnostics.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if _heat != null:
		_heat.add_heat(world_pos, amount, maxf(0.0, radius))

func add_lava(world_pos: Vector3, amount: float) -> void:
	if _lava_sim != null and _lava_sim.has_method("add_lava"):
		_lava_sim.add_lava(world_pos, amount)

func lava_cell_count() -> int:
	return _lava_sim.lava_cell_count() if _lava_sim != null and _lava_sim.has_method("lava_cell_count") else 0

func wet_cell_count() -> int:
	var n: int = 0
	for i in range(_cell_count):
		if _solid[i] == 0 and _static[i] == 0 and _water[i] >= RENDER_MIN:
			n += 1
	return n


# --- Injection API (disasters/flood/weather call these) ---------------------

## Inject a mobile material at a world point (a water surge, a lava flow). Routes to the right buffer;
## `radius`>0 spreads it over a sphere. Unknown materials are ignored (solids live in the SDF, not here).
func add_material(world_pos: Vector3, mat_id: int, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0:
		return
	if mat_id == Mat.LAVA:
		add_lava(world_pos, amount)
		return
	if mat_id != Mat.WATER:
		return
	if radius <= 0.0:
		add_water_world(world_pos, amount)
		return
	var cs: float = _cell_size
	var cells: int = maxi(0, int(ceil(radius / cs)))
	var ci: int = _col_i(world_pos.x, _origin.x)
	var cj: int = _col_i(world_pos.y, _origin.y)
	var ck: int = _col_i(world_pos.z, _origin.z)
	var r2: float = radius * radius
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _dim_x:
					continue
				if cell_world_pos(ix, iy, iz).distance_squared_to(world_pos) <= r2:
					add_water_cell(ix, iy, iz, amount)


## Uniform rain input: add WATER at the top exposed cell of every column (depth per second, applied
## per step). Precipitation normally EMERGES from the atmosphere; this is the back-compat spray input.
func add_rain(amount_per_sec: float) -> void:
	if amount_per_sec <= 0.0:
		return
	var add: float = amount_per_sec * STEP_DT
	for iz in range(_dim_z):
		for ix in range(_dim_x):
			var iy: int = _surface_iy(ix, iz)
			if iy >= 0:
				add_water_cell(ix, iy, iz, add)


## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside). 3D analogue of the 2.5D add_water_pooled.
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	var ci: int = _col_i(center.x, _origin.x)
	var ck: int = _col_i(center.z, _origin.z)
	var center_ground: float = _column_ground_y(ci, ck)
	var cs: float = _cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var r2: float = radius * radius
	for dk in range(-cells, cells + 1):
		var iz: int = ck + dk
		if iz < 0 or iz >= _dim_z:
			continue
		for di in range(-cells, cells + 1):
			var ix: int = ci + di
			if ix < 0 or ix >= _dim_x:
				continue
			var wx: float = _origin.x + float(ix) * cs
			var wz: float = _origin.z + float(iz) * cs
			var dx: float = wx - center.x
			var dz: float = wz - center.z
			if dx * dx + dz * dz > r2:
				continue
			if _column_ground_y(ix, iz) <= center_ground + 4.0:
				var iy: int = _surface_iy(ix, iz)
				if iy >= 0:
					add_water_cell(ix, iy, iz, amount)


# World Y of the top solid (ground) surface in a column, or the bottom if all void.
func _column_ground_y(ix: int, iz: int) -> float:
	for iy in range(_dim_y - 1, -1, -1):
		if _solid[(iy * _dim_z + iz) * _dim_x + ix] != 0:
			return _origin.y + float(iy) * _cell_size
	return _origin.y


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _terrain == null or not _terrain.has_method("is_solid"):
		return
	var cs: float = _cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var ci: int = _col_i(world_pos.x, _origin.x)
	var cj: int = _col_i(world_pos.y, _origin.y)
	var ck: int = _col_i(world_pos.z, _origin.z)
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _dim_x:
					continue
				var i: int = (iy * _dim_z + iz) * _dim_x + ix
				_solid[i] = 1 if _terrain.is_solid(cell_world_pos(ix, iy, iz)) else 0


func cloud_cell_count(min_density: float = 0.05) -> int:
	return _atmosphere.cloud_cell_count(min_density) if _atmosphere != null and _atmosphere.has_method("cloud_cell_count") else 0


# --- Heat diagnostics -------------------------------------------------------

func peak_heat() -> float:
	var m: float = 0.0
	for i in range(_cell_count):
		if _solid[i] == 0 and _temp[i] > m:
			m = _temp[i]
	return m

func hot_cell_count(threshold: float = 60.0) -> int:
	var n: int = 0
	for i in range(_cell_count):
		if _solid[i] == 0 and _temp[i] >= threshold:
			n += 1
	return n

func lava_peak() -> int:
	return lava_cell_count()


# --- Physical splash droplets (FX) ------------------------------------------
## A few short-lived rigidbody droplets flung from a world point — the splash accent disasters call.
func splash(world_pos: Vector3, strength: float) -> void:
	if not is_inside_tree() or is_nan(world_pos.x):
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
		add_child(body)
		body.global_position = world_pos + Vector3(randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))
		var ang: float = randf() * TAU
		body.linear_velocity = Vector3(cos(ang) * randf_range(1.0, 2.5) * s, randf_range(2.5, 4.5) * s, sin(ang) * randf_range(1.0, 2.5) * s)
		var tm: SceneTreeTimer = get_tree().create_timer(2.0)
		tm.timeout.connect(func(): if is_instance_valid(body): body.queue_free())


# --- Concerns not yet ported to the 3D field (fire spread, granular landslides). Stubbed during the
# 2.5D->3D strong break so consumers don't crash; they are OFFLINE until ported to GPU passes. ---
func set_ecology(_e) -> void:
	pass

func disturb_terrain(_world_pos: Vector3, _radius: float, _strength: float) -> void:
	pass

func slump_count() -> int:
	return 0

func ignite(_node) -> void:
	pass

func is_burning(_node) -> bool:
	return false

func active_fire_count() -> int:
	return 0


const WATER_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/shaders/VoxelWater.gdshader"

func _build_render_node() -> void:
	if _surface_mi != null:
		return
	if _water_mat == null:
		# The proper freshwater surface shader (waves/depth/foam/fresnel) — not a flat plain-blue material.
		var sh: Shader = load(WATER_SHADER_PATH) as Shader
		if sh != null:
			var sm: ShaderMaterial = ShaderMaterial.new()
			sm.shader = sh
			_water_mat = sm
		else:
			var m: StandardMaterial3D = StandardMaterial3D.new()
			m.albedo_color = Color(0.12, 0.42, 0.62, 0.72)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			_water_mat = m
	_surface_mesh = ArrayMesh.new()
	_surface_mi = MeshInstance3D.new()
	_surface_mi.name = "Water3DSurface"
	_surface_mi.mesh = _surface_mesh
	_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_surface_mi)


## Rebuild the dynamic-water surface as ONE smooth WELDED heightfield (not a quad per cell, which reads
## as a grid of blue squares). For each XZ column take the top DYNAMIC water cell's surface height, then
## weld: each grid corner's height is the average of the surface heights of the wet cells touching it, so
## adjacent cells share corners and the surface blends smoothly across them and fades at the shoreline —
## exactly the 2.5D renderer's trick, now driven by the 3D column tops. Calm static sea is left to the
## ocean plane. (Interior cavern-pool surfaces, hidden below the column top, are a later addition.)
func rebuild_surface() -> void:
	if _surface_mesh == null:
		return
	var dx: int = _dim_x
	var dz: int = _dim_z
	var cs: float = _cell_size
	var layer: int = dx * dz

	# 1) Per column, the world Y of the top dynamic-water surface (NAN = nothing to mesh here).
	var col_surf: PackedFloat32Array = PackedFloat32Array()
	col_surf.resize(layer)
	var any: bool = false
	for iz in range(dz):
		for ix in range(dx):
			var found: float = NAN
			for iy in range(_dim_y - 1, -1, -1):
				var i: int = (iy * dz + iz) * dx + ix
				if _solid[i] != 0 or _static[i] != 0:
					continue
				var m: float = _water[i]
				if m < RENDER_MIN:
					continue
				var wy: float = _origin.y + float(iy) * cs + (clampf(m, 0.0, MAX_MASS) - 0.5) * cs
				# A sub-sea cell sitting at ~sea level is calm sea → the plane draws it.
				if _origin.y + float(iy) * cs < sea_level and absf(wy - sea_level) < SEA_WAVE_EPS:
					continue
				found = wy
				break
			col_surf[iz * dx + ix] = found
			if not is_nan(found):
				any = true

	if not any:
		if _surface_mesh.get_surface_count() > 0:
			_surface_mesh.clear_surfaces()
		return

	# 2) Accumulate each wet column's surface into its 4 shared corners ((dx+1)×(dz+1) corner grid).
	var cw: int = dx + 1
	var ccount: int = cw * (dz + 1)
	var ch: PackedFloat32Array = PackedFloat32Array()
	ch.resize(ccount)
	var cn: PackedInt32Array = PackedInt32Array()
	cn.resize(ccount)
	var half: float = cs * 0.5
	var ox: float = _origin.x - half
	var oz: float = _origin.z - half
	for iz in range(dz):
		for ix in range(dx):
			var surf: float = col_surf[iz * dx + ix]
			if is_nan(surf):
				continue
			var c0: int = iz * cw + ix
			var c1: int = c0 + 1
			var c2: int = c0 + cw
			var c3: int = c2 + 1
			ch[c0] += surf; cn[c0] += 1
			ch[c1] += surf; cn[c1] += 1
			ch[c2] += surf; cn[c2] += 1
			ch[c3] += surf; cn[c3] += 1
	for c in range(ccount):
		if cn[c] != 0:
			ch[c] = ch[c] / float(cn[c])

	# 3) Vertex per active corner + a smooth normal from the corner-height gradient.
	var vmap: PackedInt32Array = PackedInt32Array()
	vmap.resize(ccount)
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	for cj in range(dz + 1):
		for ci in range(cw):
			var c: int = cj * cw + ci
			if cn[c] == 0:
				vmap[c] = -1
				continue
			var hh: float = ch[c]
			vmap[c] = verts.size()
			verts.push_back(Vector3(ox + float(ci) * cs, hh, oz + float(cj) * cs))
			var hl: float = ch[c - 1] if (ci > 0 and cn[c - 1] != 0) else hh
			var hr: float = ch[c + 1] if (ci < cw - 1 and cn[c + 1] != 0) else hh
			var hd: float = ch[c - cw] if (cj > 0 and cn[c - cw] != 0) else hh
			var hu: float = ch[c + cw] if (cj < dz and cn[c + cw] != 0) else hh
			normals.push_back(Vector3(hl - hr, 2.0 * cs, hd - hu).normalized())

	# 4) Two triangles per wet column referencing its 4 shared corners.
	var indices: PackedInt32Array = PackedInt32Array()
	for iz in range(dz):
		for ix in range(dx):
			if is_nan(col_surf[iz * dx + ix]):
				continue
			var b0: int = iz * cw + ix
			var v0: int = vmap[b0]
			var v1: int = vmap[b0 + 1]
			var v2: int = vmap[b0 + cw + 1]
			var v3: int = vmap[b0 + cw]
			if v0 < 0 or v1 < 0 or v2 < 0 or v3 < 0:
				continue
			indices.push_back(v0); indices.push_back(v1); indices.push_back(v2)
			indices.push_back(v0); indices.push_back(v2); indices.push_back(v3)

	if _surface_mesh.get_surface_count() > 0:
		_surface_mesh.clear_surfaces()
	if verts.is_empty() or indices.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_surface_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _water_mat != null:
		_surface_mesh.surface_set_material(0, _water_mat)
