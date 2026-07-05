class_name LAMaterialField
extends Node3D

## LAMaterialField — the UNIFIED material-flow substrate.
##
## One field holds ALL matter and energy: a temperature layer plus per-cell quantities of every
## MOBILE material (liquids, gases, granular soil). Solids are the voxel SDF (queried/edited via the
## terrain service), so terrain IS the solid phase of this same field. Water, lava, steam, sand,
## snow, and fire fuel are just materials here; disasters are pure injections (add_heat /
## add_material / add_force) and every phenomenon — fire, phase changes, flow, convection, drowning,
## landslides — EMERGES from a small set of local rules in _material_step().
##
## Structure clones LAWaterFieldSystem's proven 2.5D grid (flat PackedFloat32Array, index = j*_dim+i,
## lazy terrain sampling, STEP_HZ-throttled step). Bounded true-3D regions (MaterialRegion3D) are
## spun up around active events later; this file is the global 2.5D bulk + shared queries.
##
## This is built incrementally: the temperature layer + heat exchange land first (fire/creatures read
## it), then WATER moves in, then phase reactions, then lava/gases. Methods for materials exist now
## but stay inert until materials are actually injected. (Explicit types only — no ':=' inferred typing.)

# Material registry (preloaded so cross-file constants resolve without an editor class-scan).
const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")

# --- Throttle (mirrors the water CA) ----------------------------------------
const STEP_HZ: float = 10.0
const STEP_DT: float = 1.0 / STEP_HZ
const MAX_STEPS_PER_FRAME: int = 3

const SAMPLE_BUDGET: int = 700
const READY_FRACTION: float = 0.9

# --- Heat model (temperature is real degrees Celsius). The thermal STEP (conduction + solar/ambient
# relax + cloud shading + wet-cell cooling) lives in its own module now (MaterialHeat.gd); the field
# owns the module + the shared _temp array and reads the real scene sun (_sun_light) for solar input.
const HeatScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialHeat.gd")
var _heat = null                           # LAMaterialHeat (conduction + ambient/solar thermal step)
## New cells start at a mild temperature (not 0°C) so nothing freezes before the field settles.
const INITIAL_TEMP: float = 15.0
## New cells start with a little ambient humidity (air is never bone-dry), so clouds/fog can form from
## the first cool night instead of needing a full day of evaporation to charge the atmosphere first.
const INITIAL_VAPOR: float = 0.022
## Diagnostic default: a cell at/above this °C counts as "hot" (well above any natural ambient).
const HOT_THRESHOLD: float = 60.0

# --- Granular gravity (disturbed ground slumps to its angle of repose = landslides) lives in its own
# module now (MaterialGravity.gd). The field owns the instance; the module edits the terrain SDF via _f.
const GravityScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGravity.gd")
var _gravity = null                        # LAMaterialGravity (granular slump / landslides)

# --- Combustion (fire + boiling logic) lives in its own module now (MaterialCombustion.gd). The
# field keeps _ecology (other code uses it) and owns the module instance; the module reaches back
# through _f for grid state and delegates its public API (see the delegators near the fire section).
const CombustionScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialCombustion.gd")
var _ecology = null                        # LAEcologyService (topple/seed_plant_at/broadcast_scare)
var _combustion = null                     # LAMaterialCombustion (fire + boiling)

# --- Fluids CA (water + lava shallow-water automaton) lives in its own module now (MaterialLiquid.gd).
# The field owns the module instance and the shared grid arrays it operates on; the module reaches back
# through _f for grid state and sets the render dirty flags. WATER_THRESHOLD stays here (shared query).
const LiquidScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialLiquid.gd")
var _liquid = null                         # LAMaterialLiquid (water + lava CA)
const WATER_THRESHOLD: float = 0.02
# Shared with the render module (it thresholds the lava mesh at this depth via _f.LAVA_MIN).
const LAVA_MIN: float = 0.04              # below this a lava cell is spent

# --- Atmosphere: the emergent vapor -> cloud/fog -> rain cycle + wind transport lives in its own
# module now (MaterialAtmosphere.gd). The field keeps the three atmosphere ARRAYS (below — the heat
# step reads _cloud/_fog for sun-shading and the fluids module writes _vapor) plus the shared
# evaporation refs (the fluids module uses them) and the cloud-shade tuning (the heat step uses it);
# the module reaches back through _f for grid state and the field delegates its public API (see the
# atmosphere delegators near the bottom).
const AtmosphereScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere.gd")
var _atmosphere = null                     # LAMaterialAtmosphere (vapor -> cloud/fog -> rain + wind)
const EVAP_TEMP_REF: float = 22.0        # °C at which evaporation runs at ~1x (shared: liquid evap)
const EVAP_TEMP_GAIN: float = 0.055      # per-°C change in evaporation rate (warm water steams more)

# --- Phase changes (temperature-driven) live in the fluids module now (MaterialLiquid.gd): water
# freezes/evaporates, LAVA sustains heat + solidifies to rock, and extreme heat MELTS rock to lava.
# The field keeps only the lava render-dirty flag (read by _physics_process to rebuild the lava mesh).
var _lava_dirty: bool = false

# --- Grid state (flat arrays; index = j * _dim + i) --------------------------
var _terrain = null
var _half_extent: float = 0.0
var _cell_size: float = 1.0
var _dim: int = 0
var _cell_count: int = 0

var _terrain_h: PackedFloat32Array = PackedFloat32Array()
var _sampled: PackedByteArray = PackedByteArray()

var _temp: PackedFloat32Array = PackedFloat32Array()      # temperature per cell

## Per-cell quantity of each MOBILE material, keyed by material id. Created lazily (a material's
## array is allocated the first time it is injected), so an all-water-and-heat world never pays for
## gas/lava arrays. Solid materials are NOT stored here — they live in the voxel SDF.
var _mats: Dictionary = {}                                # id -> PackedFloat32Array
var _mdelta: PackedFloat32Array = PackedFloat32Array()    # shared scratch for a material's movement

# --- Atmosphere layers (the vapor -> cloud/fog -> rain cycle; owned/updated by MaterialAtmosphere.gd,
# but stored here because the heat step reads _cloud/_fog for sun-shading and the fluids module writes
# _vapor via _f). Their setup/resize stays on the field. ---
var _vapor: PackedFloat32Array = PackedFloat32Array()     # airborne water vapor (humidity) per cell
var _cloud: PackedFloat32Array = PackedFloat32Array()     # condensed cloud density (rendered aloft)
var _fog: PackedFloat32Array = PackedFloat32Array()       # condensed fog density (ground-hugging)

var _sample_cursor: int = 0
var _sampled_count: int = 0
var _ready: bool = false
var _step_accum: float = 0.0
var _step_parity: bool = false             # toggles each CA step so the atmosphere runs at half rate

## The real scene sun (DirectionalLight3D). The field reads its live energy + orientation each step to
## derive incoming solar — the one genuinely external forcing. Rain/wind/pressure EMERGE, never
## injected; even cloud/storm dimming of the sun's energy cooling the ground is a real feedback.
var _sun_light = null                                    # DirectionalLight3D — MaterialHeat reads it

## Sea level (world Y). WATER cells whose ground is below this fill toward it (oceans).
var sea_level: float = 0.0

# A step changed WATER → rebuild the rendered surface (kept here; the render module owns the mesh).
var _liquid_dirty: bool = false

# The presentation half — water/lava surface meshes, heat texture, steam/splash FX. Built in setup;
# all rendering is delegated to it (see MaterialRender.gd). Simulation state stays on this field.
const RenderScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialRender.gd")
var _render = null


# --- Setup ------------------------------------------------------------------

## Build the grid covering XZ in [-half_extent, half_extent] at cell_size. Terrain heights are
## sampled lazily over the following frames (never blocks on an unmeshed world).
func setup(terrain, half_extent: float, cell_size: float) -> void:
	_terrain = terrain
	_half_extent = maxf(1.0, half_extent)
	_cell_size = maxf(0.5, cell_size)

	_dim = int(round((2.0 * _half_extent) / _cell_size)) + 1
	_dim = maxi(_dim, 2)
	_cell_count = _dim * _dim

	_terrain_h = PackedFloat32Array()
	_terrain_h.resize(_cell_count)
	_sampled = PackedByteArray()
	_sampled.resize(_cell_count)
	_temp = PackedFloat32Array()
	_temp.resize(_cell_count)
	_mdelta = PackedFloat32Array()
	_mdelta.resize(_cell_count)
	_vapor = PackedFloat32Array()
	_vapor.resize(_cell_count)
	_cloud = PackedFloat32Array()
	_cloud.resize(_cell_count)
	_fog = PackedFloat32Array()
	_fog.resize(_cell_count)
	_mats = {}

	_sample_cursor = 0
	_sampled_count = 0
	_ready = false
	_step_accum = 0.0

	_render = RenderScript.new()
	_render.setup(self)

	_combustion = CombustionScript.new()
	_combustion.setup(self)

	_liquid = LiquidScript.new()
	_liquid.setup(self)

	_atmosphere = AtmosphereScript.new()
	_atmosphere.setup(self)

	_gravity = GravityScript.new()
	_gravity.setup(self)

	_heat = HeatScript.new()
	_heat.setup(self)


## Ecology ref so combustion can topple/reseed/scare the actors it consumes (set by set_material_field).
func set_ecology(e) -> void:
	_ecology = e


## Wire the real scene sun (the DirectionalLight3D) once; the field reads its live transform +
## light_energy each step. The SUN is the one genuinely external driver — air heating, evaporation,
## pressure, wind and rain all emerge from how its energy moves through the field.
func set_sun(light) -> void:
	_sun_light = light


# --- Grid index helpers (identical layout to the water field) ----------------

func _cell_x(i: int) -> float:
	return -_half_extent + float(i) * _cell_size


func _cell_z(j: int) -> float:
	return -_half_extent + float(j) * _cell_size


func _index_at(x: float, z: float) -> int:
	if _dim <= 0:
		return -1
	var i: int = int(round((x + _half_extent) / _cell_size))
	var j: int = int(round((z + _half_extent) / _cell_size))
	if i < 0 or i >= _dim or j < 0 or j >= _dim:
		return -1
	return j * _dim + i


## Lazily-allocated per-cell array for a mobile material id (zero-filled on first use).
func _mat_array(id: int) -> PackedFloat32Array:
	if _mats.has(id):
		return _mats[id]
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(_cell_count)
	_mats[id] = arr
	return arr


# --- Frame loop -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _dim <= 0:
		return
	_sample_step()
	_step_accum += delta
	var steps: int = 0
	while _step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_step_accum -= STEP_DT
		steps += 1
		_material_step()
	if _step_accum > STEP_DT:
		_step_accum = 0.0
	if steps > 0:
		if _liquid_dirty:
			_render.rebuild_water()
			_liquid_dirty = false
		if _lava_dirty:
			_render.rebuild_lava()
			_lava_dirty = false
		_render.update_heat_texture()
	# Combustion (fire ignition/spread/burn + boiling) runs every frame in its own module, not gated
	# by the CA throttle.
	if _combustion != null:
		_combustion.step(delta)
	# Rock melting to lava (extreme heat) — throttled + capped, owned by the fluids module.
	if _liquid != null:
		_liquid.melt_tick(delta)


## The live temperature texture (R = °C per cell). Wire once into the terrain shader; it updates in
## place each step. Also drives the temperature debug view. Delegated to the render module (which
## owns the texture object; identity is stable so consumers wire it once).
func heat_texture() -> Texture2D:
	return _render.heat_texture()


## World-space XZ extent the heat texture covers: min corner and size, for the shader's UV mapping.
func heat_world_min() -> Vector2:
	return _render.heat_world_min()


func heat_world_size() -> Vector2:
	return _render.heat_world_size()


# --- Lazy terrain sampling (copied from the water field) ---------------------

func _sample_step() -> void:
	if _sampled_count >= _cell_count:
		return
	if _terrain == null or not _terrain.has_method("surface_height"):
		return

	var budget: int = SAMPLE_BUDGET
	var scanned: int = 0
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
		_temp[idx] = INITIAL_TEMP
		_vapor[idx] = INITIAL_VAPOR
		_sampled[idx] = 1
		_sampled_count += 1

	if not _ready and _sampled_count >= int(float(_cell_count) * READY_FRACTION):
		_ready = true


func is_ready() -> bool:
	return _ready


## Re-read the terrain surface height for every sampled cell within `radius` of a world XZ point. Call
## after an SDF edit (a volcano crater/conduit, a meteor slump, a lava-built delta) so liquid heights
## track the reshaped ground instead of pooling at the pre-edit level.
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _terrain == null or not _terrain.has_method("surface_height"):
		return
	var cells: int = int(ceil(radius / _cell_size))
	var ci: int = int(round((world_pos.x + _half_extent) / _cell_size))
	var cj: int = int(round((world_pos.z + _half_extent) / _cell_size))
	var r2: float = radius * radius
	for dj in range(-cells, cells + 1):
		var j: int = cj + dj
		if j < 0 or j >= _dim:
			continue
		for di in range(-cells, cells + 1):
			var i: int = ci + di
			if i < 0 or i >= _dim:
				continue
			var cx: float = _cell_x(i)
			var cz: float = _cell_z(j)
			var dx: float = cx - world_pos.x
			var dz: float = cz - world_pos.z
			if dx * dx + dz * dz > r2:
				continue
			var h = _terrain.surface_height(cx, cz)
			if typeof(h) != TYPE_FLOAT and typeof(h) != TYPE_INT:
				continue
			var hf: float = float(h)
			if is_nan(hf) or is_inf(hf):
				continue
			var idx: int = j * _dim + i
			_terrain_h[idx] = hf
			if _sampled[idx] == 0:
				_temp[idx] = INITIAL_TEMP
				_vapor[idx] = INITIAL_VAPOR
				_sampled[idx] = 1
				_sampled_count += 1


# --- The unified step -------------------------------------------------------

## One CA tick: heat exchange, then (once materials exist) phase reactions + movement + combustion.
## Order-independent via scratch buffers, exactly like the water solver.
func _material_step() -> void:
	if _cell_count <= 0:
		return
	_heat.step()
	_liquid.step()
	# The atmosphere (vapor->cloud/fog->rain + 3 wind-transport passes) is the heaviest module by far
	# (~10 grid passes). Weather evolves slowly, so run it every OTHER CA step at double strength —
	# half the cost, indistinguishable result.
	_step_parity = not _step_parity
	if _step_parity:
		_atmosphere.step()
	# Phase reactions and gas convection attach here as those materials come online (Phase 2+);
	# they are no-ops until the relevant materials are injected.


# --- Fluids delegators (water + lava CA live in MaterialLiquid.gd) -----------
# The module owns the shallow-water automaton + lava diagnostics; the field exposes thin public
# delegators for external callers (VoxelWorld/Meteor/Volcano read lava_peak / lava_cell_count).

func lava_cell_count() -> int:
	return _liquid.lava_cell_count() if _liquid != null else 0


func lava_peak() -> int:
	return _liquid.lava_peak() if _liquid != null else 0


# --- External inputs (injection API — what disasters call) -------------------

## Inject a temperature change (ΔT) at a world point. Positive = heat (lightning/lava/meteor),
## negative = cold (blizzard). radius>0 spreads it over a disc with linear falloff.
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void:
	if amount == 0.0 or is_nan(amount) or is_inf(amount):
		return
	if radius <= 0.0:
		var idx: int = _index_at(world_pos.x, world_pos.z)
		if idx >= 0 and _sampled[idx] != 0:
			_temp[idx] += amount
		return
	var cells: int = int(ceil(radius / _cell_size))
	var ci: int = int(round((world_pos.x + _half_extent) / _cell_size))
	var cj: int = int(round((world_pos.z + _half_extent) / _cell_size))
	var r2: float = radius * radius
	for dj in range(-cells, cells + 1):
		var j: int = cj + dj
		if j < 0 or j >= _dim:
			continue
		for di in range(-cells, cells + 1):
			var i: int = ci + di
			if i < 0 or i >= _dim:
				continue
			var idx: int = j * _dim + i
			if _sampled[idx] == 0:
				continue
			var dx: float = _cell_x(i) - world_pos.x
			var dz: float = _cell_z(j) - world_pos.z
			var d2: float = dx * dx + dz * dz
			if d2 > r2:
				continue
			var falloff: float = 1.0 - sqrt(d2) / radius
			_temp[idx] += amount * falloff


## Inject a quantity of a mobile material at a world point (water surge, lava, gas, soil).
func add_material(world_pos: Vector3, mat_id: int, amount: float, radius: float = 0.0) -> void:
	if amount <= 0.0 or is_nan(amount) or is_inf(amount):
		return
	var arr: PackedFloat32Array = _mat_array(mat_id)
	var molten: bool = mat_id == Mat.LAVA          # fresh lava is molten by definition
	if radius <= 0.0:
		var idx: int = _index_at(world_pos.x, world_pos.z)
		if idx >= 0 and _sampled[idx] != 0:
			arr[idx] += amount
			if molten:
				_temp[idx] = maxf(_temp[idx], LiquidScript.LAVA_EMPLACE_TEMP)
		return
	var cells: int = int(ceil(radius / _cell_size))
	var ci: int = int(round((world_pos.x + _half_extent) / _cell_size))
	var cj: int = int(round((world_pos.z + _half_extent) / _cell_size))
	var r2: float = radius * radius
	for dj in range(-cells, cells + 1):
		var j: int = cj + dj
		if j < 0 or j >= _dim:
			continue
		for di in range(-cells, cells + 1):
			var i: int = ci + di
			if i < 0 or i >= _dim:
				continue
			var idx: int = j * _dim + i
			if _sampled[idx] == 0:
				continue
			var dx: float = _cell_x(i) - world_pos.x
			var dz: float = _cell_z(j) - world_pos.z
			if dx * dx + dz * dz > r2:
				continue
			arr[idx] += amount
			if molten:
				_temp[idx] = maxf(_temp[idx], LiquidScript.LAVA_EMPLACE_TEMP)


# --- Water convenience inputs (back-compat with the retired water field) -----

## Set the uniform WATER rain rate (depth metres per SECOND). Delegated to the fluids module.
func add_rain(amount_per_sec: float) -> void:
	if _liquid != null:
		_liquid.add_rain(amount_per_sec)


## Dump WATER depth at a world point (a spring / test source). Delegated to the fluids module.
func add_source(world_pos: Vector3, amount: float) -> void:
	if _liquid != null:
		_liquid.add_source(world_pos, amount)


## Set the current wind (world XZ) so vapor/cloud drift downwind. Fed from the weather each frame.
## Delegated to the atmosphere module.
func set_wind(w: Vector2) -> void:
	if _atmosphere != null:
		_atmosphere.set_wind(w)


# --- Granular gravity delegates to LAMaterialGravity (disturbed ground slumps to its repose angle) --

## Shake the ground over a region — steep/loose columns slump downhill (the landslide mechanism).
func disturb_terrain(world_pos: Vector3, radius: float, strength: float) -> void:
	if _gravity != null:
		_gravity.disturb_terrain(world_pos, radius, strength)


func slump_count() -> int:
	return _gravity.slump_count() if _gravity != null else 0


# --- Combustion delegators (fire + boiling logic live in MaterialCombustion.gd) ----
# The module owns the fire list + ignition/spread/burn + boiling; the field exposes thin public
# delegators for external callers (VoxelWorld's SMOKE reads active_fire_count via fire_system()).

func active_fire_count() -> int:
	return _combustion.active_fire_count() if _combustion != null else 0


func is_burning(node) -> bool:
	return _combustion.is_burning(node) if _combustion != null else false


## Set a flammable actor alight (flame FX + track it). No-op for non-flammable / already-burning.
func ignite(node) -> void:
	if _combustion != null:
		_combustion.ignite(node)


# --- Query API for other systems --------------------------------------------

## Temperature at a world (x, z). 0.0 outside the grid.
func temp_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	if idx < 0:
		return 0.0
	return _temp[idx]


## Quantity of a mobile material at (x, z). 0.0 if none / outside the grid.
func material_depth_at(x: float, z: float, mat_id: int) -> float:
	if not _mats.has(mat_id):
		return 0.0
	var idx: int = _index_at(x, z)
	if idx < 0:
		return 0.0
	var arr: PackedFloat32Array = _mats[mat_id]
	return arr[idx]


## Water-depth shim (Creature/Fish/Meteor read this) — once WATER moves into the field it returns
## the WATER material; until then it's 0 (callers still use the live LAWaterFieldSystem).
func depth_at(x: float, z: float) -> float:
	return material_depth_at(x, z, Mat.WATER)


func is_water_at(x: float, z: float) -> bool:
	return depth_at(x, z) >= WATER_THRESHOLD


## World Y of the WATER surface (terrain_h + depth) at (x, z), or NAN when the cell is unsampled/dry.
func surface_y_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	if idx < 0 or _sampled[idx] == 0:
		return NAN
	var d: float = material_depth_at(x, z, Mat.WATER)
	if d < WATER_THRESHOLD:
		return NAN
	return _terrain_h[idx] + d


## Diagnostic: number of rendered WATER cells (depth >= RENDER_THRESHOLD).
func wet_cell_count() -> int:
	return material_cell_count(Mat.WATER, RenderScript.RENDER_THRESHOLD)


# --- Atmosphere delegators (vapor -> cloud/fog -> rain + wind live in MaterialAtmosphere.gd) ------
# The module owns the water cycle + wind; the field exposes thin public delegators for external callers
# (VoxelWorld and CloudLayer read these on _material to build density textures / drive HUD + sun dimming).

func cloud_at(x: float, z: float) -> float:
	return _atmosphere.cloud_at(x, z) if _atmosphere != null else 0.0


func fog_at(x: float, z: float) -> float:
	return _atmosphere.fog_at(x, z) if _atmosphere != null else 0.0


## Mean cloud / fog density over sampled cells — drives global sun dimming and HUD/diagnostics.
func avg_cloud_cover() -> float:
	return _atmosphere.avg_cloud_cover() if _atmosphere != null else 0.0


func avg_fog_cover() -> float:
	return _atmosphere.avg_fog_cover() if _atmosphere != null else 0.0


func wind() -> Vector2:
	return _atmosphere.wind() if _atmosphere != null else Vector2.ZERO


## Grid geometry so a renderer can map cell (i, j) <-> world XZ exactly like the field does.
func grid_dim() -> int:
	return _dim


func grid_half_extent() -> float:
	return _half_extent


## World Y of the two rendered condensate sheets.
func cloud_base_y() -> float:
	return _atmosphere.cloud_base_y() if _atmosphere != null else sea_level


func fog_base_y() -> float:
	return _atmosphere.fog_base_y() if _atmosphere != null else sea_level


## The raw density grids (flat, index = j*dim+i) for building render textures. Returned by reference;
## the renderer only reads them.
func cloud_grid() -> PackedFloat32Array:
	return _atmosphere.cloud_grid() if _atmosphere != null else _cloud


func fog_grid() -> PackedFloat32Array:
	return _atmosphere.fog_grid() if _atmosphere != null else _fog


## Diagnostic: cells whose cloud density is at least min_density.
func cloud_cell_count(min_density: float = 0.05) -> int:
	return _atmosphere.cloud_cell_count(min_density) if _atmosphere != null else 0


## Spawn a few short-lived rigidbody droplets flung up/out from world_pos — the physical splash
## accent. Delegated to the render module (external callers still invoke it on the field).
func splash(world_pos: Vector3, strength: float) -> void:
	_render.splash(world_pos, strength)


# --- Diagnostics ------------------------------------------------------------

func peak_heat() -> float:
	var m: float = 0.0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _temp[idx] > m:
			m = _temp[idx]
	return m


func coldest() -> float:
	var m: float = 0.0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _temp[idx] < m:
			m = _temp[idx]
	return m


func hot_cell_count(threshold: float = HOT_THRESHOLD) -> int:
	var n: int = 0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _temp[idx] >= threshold:
			n += 1
	return n


func cold_cell_count(threshold: float = -0.5) -> int:
	var n: int = 0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _temp[idx] <= threshold:
			n += 1
	return n


## Cells holding at least `min_depth` of a material (e.g. lava/water) — a spatial diagnostic.
func material_cell_count(mat_id: int, min_depth: float = 0.05) -> int:
	if not _mats.has(mat_id):
		return 0
	var arr: PackedFloat32Array = _mats[mat_id]
	var n: int = 0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and arr[idx] >= min_depth:
			n += 1
	return n
