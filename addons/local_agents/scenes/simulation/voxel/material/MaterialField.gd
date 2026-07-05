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

# --- Heat model (temperature is a relative scalar; ambient ~0, disasters inject spikes) ------
## Fraction of a cell's temperature gradient conducted to its 4 neighbours per step.
const CONDUCT_FRACTION: float = 0.16
## How fast a cell relaxes toward its ambient temperature per step (radiative equilibrium).
const AMBIENT_RELAX: float = 0.06
## Temperatures are real degrees CELSIUS. Radiative night floor (°C the ground relaxes toward with
## zero sun) — a cool but non-freezing night.
const AMBIENT_NIGHT: float = 6.0
## Ambient warming (°C) per unit of incoming solar (light_energy * elevation). Tuned so a clear noon
## (solar ~1.4) lands ambient near 28°C; clouds/storms dimming the sun genuinely cool the ground.
const SOLAR_WARMTH: float = 16.0
## Altitude cooling: temperature drops by LAPSE_RATE °C per world-unit above LAPSE_REF, so high peaks
## fall below 0°C and grow snow/ice emergently.
const LAPSE_RATE: float = 0.42
const LAPSE_REF: float = 15.0
## New cells start at a mild temperature (not 0°C) so nothing freezes before the field settles.
const INITIAL_TEMP: float = 15.0
## Pull (°C toward ambient per second) on WET cells — big water heat capacity keeps rivers/lakes near
## ambient even beside a fire, so they act as firebreaks emergently.
const WATER_COOL: float = 300.0
## Diagnostic default: a cell at/above this °C counts as "hot" (well above any natural ambient).
const HOT_THRESHOLD: float = 60.0

# --- Granular gravity (angle of repose). When ground is DISTURBED, columns that overhang a lower
# neighbour by more than a loose slope can hold slump downhill under gravity until stable — this is
# how "landslides" happen: not a scripted system, just soil moving under gravity. Applied to the
# terrain SDF (carve where a column drops, fill where it rises).
const REPOSE_TAN: float = 0.7             # max stable rise/run for loose soil (~35°)
const REPOSE_PASSES: int = 6              # relaxation iterations over the disturbed patch
const REPOSE_MIN_MOVE: float = 0.4        # height change below this makes no SDF edit
const REPOSE_MAX_EDITS: int = 140         # cap SDF edits per disturbance (keeps the hitch bounded)
var _slumps: int = 0                       # diagnostic: SDF columns moved by slumping

# --- Combustion (folded in — there is NO separate fire system). A flammable actor (tree/plant =
# WOOD) whose cell crosses WOOD's ignition temperature catches fire; it pumps heat back into the
# field so fire SPREADS through the temperature grid, glows (flame FX), burns down, then is consumed
# (topples + ash reseeds a plant). Rivers/wet cells stay cool → firebreaks emerge for free. ---
const FLAMMABLE_GROUPS: Array = ["tree", "plant"]
const BURN_TIME_MIN: float = 6.0
const BURN_TIME_MAX: float = 11.0
const BURN_HEAT_PER_SEC: float = 1000.0   # °C/s a burning actor injects into its cell (flame heat)
const BURN_HEAT_RADIUS: float = 5.0
const IGNITE_SCAN_INTERVAL: float = 0.4
const FIRE_SCARE_INTERVAL: float = 1.3
const FIRE_SCARE_RADIUS: float = 9.0
var _ecology = null                        # LAEcologyService (topple/seed_plant_at/broadcast_scare)
var _fires: Array = []                      # [{node, life, scare_cd, fx}]
var _ignite_cd: float = 0.0

# Boiling: where WATER sits on a cell above 100°C it flashes to steam (puff FX + sizzle sound), and
# the water is rapidly cooled/evaporated. Emergent wherever hot meets water (crater rim, lava, fire).
const BOIL_TEMP: float = 100.0
const BOIL_CHECK_INTERVAL: float = 0.4
const BOIL_SAMPLES: int = 220              # random cells probed per check (cheap)
const BOIL_MAX_PUFFS: int = 4              # cap steam puffs spawned per check
var _boil_cd: float = 0.0

# --- Liquid CA (ported verbatim from the retired LAWaterFieldSystem; WATER is now a material here).
# The shallow-water redistribution is generic over liquids — WATER uses these constants; LAVA (later)
# runs the same rule with a much smaller flow factor and no evaporation/sea-fill.
const FLOW_FACTOR: float = 0.25
const MAX_PAIR_FRACTION: float = 0.5
const EVAP_PER_STEP: float = 0.0035
const SEA_FILL_RATE: float = 0.6
const RENDER_THRESHOLD: float = 0.05
const WATER_THRESHOLD: float = 0.02
const SPLASH_DROPLETS: int = 6
const SPLASH_LIFETIME: float = 2.0
const SPLASH_RADIUS: float = 0.12

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

# --- Grid state (flat arrays; index = j * _dim + i) --------------------------
var _terrain = null
var _half_extent: float = 0.0
var _cell_size: float = 1.0
var _dim: int = 0
var _cell_count: int = 0

var _terrain_h: PackedFloat32Array = PackedFloat32Array()
var _sampled: PackedByteArray = PackedByteArray()

var _temp: PackedFloat32Array = PackedFloat32Array()      # temperature per cell
var _tdelta: PackedFloat32Array = PackedFloat32Array()    # scratch for conduction

## Per-cell quantity of each MOBILE material, keyed by material id. Created lazily (a material's
## array is allocated the first time it is injected), so an all-water-and-heat world never pays for
## gas/lava arrays. Solid materials are NOT stored here — they live in the voxel SDF.
var _mats: Dictionary = {}                                # id -> PackedFloat32Array
var _mdelta: PackedFloat32Array = PackedFloat32Array()    # shared scratch for a material's movement

var _sample_cursor: int = 0
var _sampled_count: int = 0
var _ready: bool = false
var _step_accum: float = 0.0

## The real scene sun (DirectionalLight3D). The field reads its live energy + orientation each step to
## derive incoming solar — the one genuinely external forcing. Rain/wind/pressure EMERGE, never
## injected; even cloud/storm dimming of the sun's energy cooling the ground is a real feedback.
var _sun_light = null
var _solar: float = 0.0                                  # cached incoming solar (energy * elevation)

## Sea level (world Y). WATER cells whose ground is below this fill toward it (oceans).
var sea_level: float = 0.0
var _rain_rate: float = 0.0                              # WATER depth-per-second input (add_rain)

# Rendered water surface (one animated translucent quad per wet cell; rebuilt each step).
var _surface_mi: MeshInstance3D = null
var _surface_mesh: ArrayMesh = null
var _water_material: ShaderMaterial = null
var _liquid_dirty: bool = false                          # a step changed WATER → rebuild surface

# Temperature baked into an R-float texture (one texel per cell) so the terrain shader can sample
# it by world position and glow incandescently where hot — and drive the temp debug view. Updated
# in place each step (same texture object) so consumers wire it once.
var _heat_img: Image = null
var _heat_tex: ImageTexture = null


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
	_tdelta = PackedFloat32Array()
	_tdelta.resize(_cell_count)
	_mdelta = PackedFloat32Array()
	_mdelta.resize(_cell_count)
	_mats = {}

	_sample_cursor = 0
	_sampled_count = 0
	_ready = false
	_step_accum = 0.0

	_build_surface_node()
	_build_heat_texture()


# Create the R-float temperature texture (one texel per grid cell). Seeded to INITIAL_TEMP so the
# ground doesn't read as ice-cold before the field settles.
func _build_heat_texture() -> void:
	var seed: PackedFloat32Array = PackedFloat32Array()
	seed.resize(_cell_count)
	seed.fill(INITIAL_TEMP)
	_heat_img = Image.create_from_data(_dim, _dim, false, Image.FORMAT_RF, seed.to_byte_array())
	_heat_tex = ImageTexture.create_from_image(_heat_img)


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
		_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_surface_mi)


## Ecology ref so combustion can topple/reseed/scare the actors it consumes (set by set_material_field).
func set_ecology(e) -> void:
	_ecology = e


## Wire the real scene sun (the DirectionalLight3D) once; the field reads its live transform +
## light_energy each step. The SUN is the one genuinely external driver — air heating, evaporation,
## pressure, wind and rain all emerge from how its energy moves through the field.
func set_sun(light) -> void:
	_sun_light = light


## Incoming solar at flat ground = the sun's real energy times its downward elevation (angle of
## incidence). Zero at night (sun below horizon), weak at dawn/dusk, peak at noon; dimmed by clouds.
func _solar_input() -> float:
	if _sun_light == null:
		return 0.0
	var travel: Vector3 = -_sun_light.global_transform.basis.z   # direction photons move
	var elevation: float = maxf(0.0, -travel.y)                  # how straight-down the light is
	return elevation * maxf(0.0, _sun_light.light_energy)


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
			_rebuild_water_surface()
			_liquid_dirty = false
		_update_heat_texture()
	# Combustion runs every frame (smooth burn/spread), not gated by the CA throttle.
	_combustion_step(delta)
	# Boiling: wherever hot ground/lava/fire meets water, it steams — emergent, throttled.
	_boil_cd -= delta
	if _boil_cd <= 0.0:
		_boil_cd = BOIL_CHECK_INTERVAL
		_boil_step()


# Re-upload the temperature grid into the heat texture (in place). The ground shader samples it for
# incandescent glow, and the temp debug view renders it directly.
func _update_heat_texture() -> void:
	if _heat_tex == null or _heat_img == null:
		return
	_heat_img.set_data(_dim, _dim, false, Image.FORMAT_RF, _temp.to_byte_array())
	_heat_tex.update(_heat_img)


## The live temperature texture (R = °C per cell). Wire once into the terrain shader; it updates in
## place each step. Also drives the temperature debug view.
func heat_texture() -> Texture2D:
	return _heat_tex


## World-space XZ extent the heat texture covers: min corner and size, for the shader's UV mapping.
func heat_world_min() -> Vector2:
	return Vector2(-_half_extent, -_half_extent)


func heat_world_size() -> Vector2:
	return Vector2(2.0 * _half_extent, 2.0 * _half_extent)


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
		_sampled[idx] = 1
		_sampled_count += 1

	if not _ready and _sampled_count >= int(float(_cell_count) * READY_FRACTION):
		_ready = true


func is_ready() -> bool:
	return _ready


# --- The unified step -------------------------------------------------------

## One CA tick: heat exchange, then (once materials exist) phase reactions + movement + combustion.
## Order-independent via scratch buffers, exactly like the water solver.
func _material_step() -> void:
	if _cell_count <= 0:
		return
	_heat_exchange_step()
	_liquid_step()
	# Phase reactions, gas convection and combustion attach here as those materials/fuel come online
	# (Phase 2+); they are no-ops until the relevant materials are injected.


## CONDUCTION + AMBIENT RELAX + water/rain cooling. (Convection — heat carried by rising hot gas —
## is applied in the gas-movement rule once gases are injected; see _material_step.)
func _heat_exchange_step() -> void:
	var dim: int = _dim
	var water: PackedFloat32Array = _mat_array(Mat.WATER)

	# 1) CONDUCTION — share a fraction of each cell/neighbour difference into _tdelta (symmetric,
	# order-independent). Only sampled cells participate.
	for idx in range(_cell_count):
		_tdelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _sampled[idx] == 0:
				continue
			var t: float = _temp[idx]
			# Right + up neighbours only, applying the flux to BOTH cells → every pair counted once.
			if i < dim - 1:
				var ri: int = idx + 1
				if _sampled[ri] != 0:
					var f: float = (t - _temp[ri]) * CONDUCT_FRACTION * 0.25
					_tdelta[idx] -= f
					_tdelta[ri] += f
			if j < dim - 1:
				var ui: int = idx + dim
				if _sampled[ui] != 0:
					var f2: float = (t - _temp[ui]) * CONDUCT_FRACTION * 0.25
					_tdelta[idx] -= f2
					_tdelta[ui] += f2

	# 2) Apply conduction, then relax toward ambient (with altitude lapse), then extra cooling on
	# wet cells so rivers keep fires in check emergently. Ambient is driven by the REAL sun energy.
	_solar = _solar_input()
	var day_base: float = AMBIENT_NIGHT + SOLAR_WARMTH * _solar
	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var t: float = _temp[idx] + _tdelta[idx]
		var altitude: float = _terrain_h[idx]
		var ambient: float = day_base - LAPSE_RATE * maxf(0.0, altitude - LAPSE_REF)
		t = t + (ambient - t) * AMBIENT_RELAX
		# Cooling where wet / raining: WATER cells + rain pull toward ambient faster than open
		# ground, so rivers/lakes/flood become firebreaks and rain suppresses fire emergently.
		if water[idx] > WATER_THRESHOLD:
			t = move_toward(t, ambient, WATER_COOL * STEP_DT)
		_temp[idx] = t


# --- Liquid movement (WATER now; LAVA later reuses this with different params) ---------------

## Shallow-water redistribution of the WATER material by SURFACE head difference (terrain_h + depth),
## plus rain input, evaporation and sub-sea-level ocean fill. Ported verbatim from the retired water
## field — rivers, lakes and oceans EMERGE from this alone. Net change accumulates in _mdelta so the
## step is order-independent.
func _liquid_step() -> void:
	var water: PackedFloat32Array = _mat_array(Mat.WATER)
	var dim: int = _dim

	# 1) RAIN — uniform depth input driven by the current rate.
	if _rain_rate > 0.0:
		var add: float = _rain_rate * STEP_DT
		if add > 0.0:
			for idx in range(_cell_count):
				if _sampled[idx] != 0:
					water[idx] += add

	# 2) FLOW — gather the four orthogonal LOWER neighbours by surface head, move at most
	# FLOW_FACTOR of the summed difference, split proportionally, each transfer capped at
	# MAX_PAIR_FRACTION so a cell can never overshoot a neighbour (anti-oscillation).
	for idx in range(_cell_count):
		_mdelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _sampled[idx] == 0:
				continue
			var d: float = water[idx]
			if d <= 0.0:
				continue
			var head: float = _terrain_h[idx] + d

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
					var lh: float = _terrain_h[li] + water[li]
					if lh < head:
						n0 = li
						dh0 = head - lh
						total_diff += dh0
			if i < dim - 1:
				var ri: int = idx + 1
				if _sampled[ri] != 0:
					var rh: float = _terrain_h[ri] + water[ri]
					if rh < head:
						n1 = ri
						dh1 = head - rh
						total_diff += dh1
			if j > 0:
				var di: int = idx - dim
				if _sampled[di] != 0:
					var dhh: float = _terrain_h[di] + water[di]
					if dhh < head:
						n2 = di
						dh2 = head - dhh
						total_diff += dh2
			if j < dim - 1:
				var ui: int = idx + dim
				if _sampled[ui] != 0:
					var uh: float = _terrain_h[ui] + water[ui]
					if uh < head:
						n3 = ui
						dh3 = head - uh
						total_diff += dh3

			if total_diff <= 0.0:
				continue
			var move_total: float = minf(d, total_diff * FLOW_FACTOR)
			if move_total <= 0.0:
				continue
			var scale: float = move_total / total_diff
			if n0 >= 0:
				var f0: float = minf(dh0 * scale, dh0 * MAX_PAIR_FRACTION)
				_mdelta[idx] -= f0
				_mdelta[n0] += f0
			if n1 >= 0:
				var f1: float = minf(dh1 * scale, dh1 * MAX_PAIR_FRACTION)
				_mdelta[idx] -= f1
				_mdelta[n1] += f1
			if n2 >= 0:
				var f2: float = minf(dh2 * scale, dh2 * MAX_PAIR_FRACTION)
				_mdelta[idx] -= f2
				_mdelta[n2] += f2
			if n3 >= 0:
				var f3: float = minf(dh3 * scale, dh3 * MAX_PAIR_FRACTION)
				_mdelta[idx] -= f3
				_mdelta[n3] += f3

	# 3) Apply flow, then ocean fill (ground below sea_level) and evaporation.
	var any_wet: bool = false
	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var nd: float = water[idx] + _mdelta[idx]
		if nd < 0.0:
			nd = 0.0
		var floor_h: float = _terrain_h[idx]
		if floor_h < sea_level:
			var target: float = sea_level - floor_h
			if nd < target:
				nd = move_toward(nd, target, SEA_FILL_RATE)
		if nd > 0.0:
			nd -= EVAP_PER_STEP
			if nd < 0.0:
				nd = 0.0
		water[idx] = nd
		if nd >= RENDER_THRESHOLD:
			any_wet = true

	# Rebuild the surface while wet, plus one extra pass to clear it when it dries out.
	_liquid_dirty = any_wet or (_surface_mesh != null and _surface_mesh.get_surface_count() > 0)


func _rebuild_water_surface() -> void:
	if _surface_mesh == null:
		return
	if _surface_mesh.get_surface_count() > 0:
		_surface_mesh.clear_surfaces()
	if not _mats.has(Mat.WATER):
		return
	var water: PackedFloat32Array = _mats[Mat.WATER]

	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var hc: float = _cell_size * 0.5
	var up: Vector3 = Vector3.UP
	var base: int = 0

	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var d: float = water[idx]
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
	if radius <= 0.0:
		var idx: int = _index_at(world_pos.x, world_pos.z)
		if idx >= 0 and _sampled[idx] != 0:
			arr[idx] += amount
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


# --- Water convenience inputs (back-compat with the retired water field) -----

## Set the uniform WATER rain rate (depth metres per SECOND), applied each step scaled by STEP_DT.
func add_rain(amount_per_sec: float) -> void:
	if is_nan(amount_per_sec) or is_inf(amount_per_sec):
		return
	_rain_rate = maxf(0.0, amount_per_sec)


## Dump WATER depth at a world point (a spring / test source). No-op outside the grid / unsampled.
func add_source(world_pos: Vector3, amount: float) -> void:
	add_material(world_pos, Mat.WATER, amount, 0.0)


# --- Granular gravity: disturbed ground slumps to its angle of repose -------

## Shake the ground over a region: any column that overhangs a lower neighbour beyond the angle of
## repose sheds material downhill under gravity until the local slope is stable, editing the terrain
## SDF (carve high, fill low). Flat ground does nothing. `strength` (~0..3, e.g. meteor size) scales
## how much of each overhang gives way. This is the ONLY landslide mechanism — pure material physics.
func disturb_terrain(world_pos: Vector3, radius: float, strength: float) -> void:
	if _terrain == null or not _terrain.has_method("surface_height"):
		return
	if not _terrain.has_method("carve_sphere") or not _terrain.has_method("fill_sphere"):
		return
	var s: float = clampf(strength, 0.1, 3.0)
	var cells: int = int(ceil(radius / _cell_size))
	var ci: int = int(round((world_pos.x + _half_extent) / _cell_size))
	var cj: int = int(round((world_pos.z + _half_extent) / _cell_size))
	var r2: float = radius * radius

	# Collect the disturbed columns and their CURRENT surface heights (sampled fresh from the SDF).
	var region: Array = []                       # idx list
	var h0: Dictionary = {}                       # idx -> original height
	var h: Dictionary = {}                        # idx -> working height
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
			var gy = _terrain.surface_height(cx, cz)
			if typeof(gy) != TYPE_FLOAT and typeof(gy) != TYPE_INT:
				continue
			var gyf: float = float(gy)
			if is_nan(gyf) or is_inf(gyf):
				continue
			var idx: int = j * _dim + i
			region.append(idx)
			h0[idx] = gyf
			h[idx] = gyf

	if region.size() < 2:
		return

	# Relax toward the angle of repose: repeatedly push a column's overhang down to its lowest
	# in-region neighbour. Order-tolerant enough over several passes (gravity settles a pile).
	var max_step: float = REPOSE_TAN * _cell_size
	var move_frac: float = clampf(0.5 * s, 0.25, 0.9)
	for pass_i in range(REPOSE_PASSES):
		for idx in region:
			var hi: float = h[idx]
			var i2: int = idx % _dim
			var j2: int = idx / _dim
			var low_idx: int = -1
			var low_h: float = hi
			var neighbours: Array = [idx - 1 if i2 > 0 else -1, idx + 1 if i2 < _dim - 1 else -1,
				idx - _dim if j2 > 0 else -1, idx + _dim if j2 < _dim - 1 else -1]
			for nb in neighbours:
				if nb >= 0 and h.has(nb) and float(h[nb]) < low_h:
					low_h = float(h[nb])
					low_idx = nb
			if low_idx < 0:
				continue
			var excess: float = (hi - low_h) - max_step
			if excess > 0.0:
				var m: float = excess * 0.5 * move_frac
				h[idx] = hi - m
				h[low_idx] = float(h[low_idx]) + m

	# Apply the net height change to the terrain SDF (carve where it dropped, fill where it rose).
	var edits: int = 0
	for idx in region:
		if edits >= REPOSE_MAX_EDITS:
			break
		var dh: float = float(h[idx]) - float(h0[idx])
		if absf(dh) < REPOSE_MIN_MOVE:
			continue
		var i3: int = idx % _dim
		var j3: int = idx / _dim
		var cx2: float = _cell_x(i3)
		var cz2: float = _cell_z(j3)
		var sphere_r: float = clampf(absf(dh) * 0.9, 0.6, _cell_size)
		if dh < 0.0:
			_terrain.carve_sphere(Vector3(cx2, float(h0[idx]), cz2), sphere_r)
		else:
			_terrain.fill_sphere(Vector3(cx2, float(h[idx]), cz2), sphere_r)
		if _sampled[idx] != 0:
			_terrain_h[idx] = float(h[idx])          # keep cached altitude consistent (lapse/temp)
		edits += 1
		_slumps += 1


func slump_count() -> int:
	return _slumps


# --- Combustion (the fire mechanism lives here, not in a separate system) ----

func active_fire_count() -> int:
	return _fires.size()


func is_burning(node) -> bool:
	for f in _fires:
		if f["node"] == node:
			return true
	return false


func _is_flammable(node) -> bool:
	for group in FLAMMABLE_GROUPS:
		if node.is_in_group(group):
			return true
	return false


## Set a flammable actor alight (flame FX + track it). No-op for non-flammable / already-burning.
func ignite(node) -> void:
	if node == null or not is_instance_valid(node) or not (node is Node3D):
		return
	if not _is_flammable(node) or is_burning(node):
		return
	var n3: Node3D = node as Node3D
	var fx: Node3D = _make_fire_fx(n3)
	n3.add_child(fx)
	_fires.append({
		"node": n3,
		"life": randf_range(BURN_TIME_MIN, BURN_TIME_MAX),
		"scare_cd": randf_range(0.2, FIRE_SCARE_INTERVAL),
		"fx": fx,
	})


func _combustion_step(delta: float) -> void:
	# IGNITION sweep (throttled): light any flammable actor whose cell crossed WOOD's ignition temp
	# and isn't wet. Runs even with no active fire, so a meteor/lightning heat spike or a drought
	# ignites vegetation with nothing pre-burning — emergent from the temperature field alone.
	_ignite_cd -= delta
	if _ignite_cd <= 0.0:
		_ignite_cd = IGNITE_SCAN_INTERVAL
		_scan_ignitions()

	if _fires.is_empty():
		return
	var survivors: Array = []
	for f in _fires:
		var node = f["node"]
		if node == null or not is_instance_valid(node):
			continue
		var pos: Vector3 = (node as Node3D).global_position
		# Pump flame heat back into the field so neighbours cross the ignition temp → SPREAD emerges.
		add_heat(pos, BURN_HEAT_PER_SEC * delta, BURN_HEAT_RADIUS)
		f["life"] = float(f["life"]) - delta
		if float(f["life"]) <= 0.0:
			_consume(node as Node3D)
			continue
		f["scare_cd"] = float(f["scare_cd"]) - delta
		if float(f["scare_cd"]) <= 0.0:
			f["scare_cd"] = FIRE_SCARE_INTERVAL
			if _ecology != null and _ecology.has_method("broadcast_scare"):
				_ecology.broadcast_scare(pos, FIRE_SCARE_RADIUS, 0.6)
		survivors.append(f)
	_fires = survivors


func _scan_ignitions() -> void:
	var ignite_temp: float = Mat.ignite_temp(Mat.WOOD)
	for group in FLAMMABLE_GROUPS:
		for a in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(a) or not (a is Node3D) or is_burning(a):
				continue
			var p: Vector3 = (a as Node3D).global_position
			if temp_at(p.x, p.z) < ignite_temp:
				continue
			if is_water_at(p.x, p.z):
				continue
			ignite(a)


# Fully consumed: topple as it collapses, leave ash that seeds a new plant, then remove.
func _consume(node: Node3D) -> void:
	var pos: Vector3 = node.global_position
	if node.has_method("topple"):
		node.call("topple", Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0))
	if _ecology != null and _ecology.has_method("seed_plant_at"):
		_ecology.seed_plant_at(pos)
	node.queue_free()


# Flame parented to the burning actor (frees with it). Shared with creature combustion (LAFlameFX).
func _make_fire_fx(host: Node3D) -> Node3D:
	return LAFlameFX.make()


# --- Boiling: hot water flashes to steam (emergent wherever hot meets water) -

func _boil_step() -> void:
	if not _mats.has(Mat.WATER) or not is_inside_tree():
		return
	var water: PackedFloat32Array = _mats[Mat.WATER]
	var puffs: int = 0
	for n in range(BOIL_SAMPLES):
		if puffs >= BOIL_MAX_PUFFS:
			break
		var idx: int = randi() % _cell_count
		if _sampled[idx] == 0 or water[idx] < WATER_THRESHOLD or _temp[idx] < BOIL_TEMP:
			continue
		var i: int = idx % _dim
		var j: int = idx / _dim
		var pos: Vector3 = Vector3(_cell_x(i), _terrain_h[idx] + water[idx], _cell_z(j))
		_spawn_steam_puff(pos)
		# Boiling carries heat away fast and evaporates a little water (latent heat sink).
		_temp[idx] = maxf(BOIL_TEMP - 5.0, _temp[idx] - 40.0)
		water[idx] = maxf(0.0, water[idx] - 0.05)
		LocalAgentsAudioDirector.emit(get_tree(), "sizzle", pos)
		puffs += 1


func _spawn_steam_puff(pos: Vector3) -> void:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 10
	p.lifetime = 1.4
	p.explosiveness = 0.4
	p.global_position = pos + Vector3(0.0, 0.2, 0.0)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.92, 0.95, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = mat
	p.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.4
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.5
	pm.gravity = Vector3(0.0, 1.2, 0.0)              # steam rises
	pm.scale_min = 0.6
	pm.scale_max = 1.8
	pm.color = Color(0.92, 0.94, 0.97, 0.4)
	p.process_material = pm
	add_child(p)
	var t: SceneTreeTimer = get_tree().create_timer(1.8)
	t.timeout.connect(func(): if is_instance_valid(p): p.queue_free())


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
	return material_cell_count(Mat.WATER, RENDER_THRESHOLD)


## Spawn a few short-lived rigidbody droplets flung up/out from world_pos — the physical splash
## accent. Guarded so a bad call can never crash the sim; droplets auto-free after SPLASH_LIFETIME.
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
		var ang: float = randf() * TAU
		var out: float = randf_range(1.0, 2.5) * s
		var upv: float = randf_range(2.5, 4.5) * s
		body.linear_velocity = Vector3(cos(ang) * out, upv, sin(ang) * out)
		body.angular_velocity = Vector3(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
		var timer: SceneTreeTimer = tree.create_timer(SPLASH_LIFETIME)
		timer.timeout.connect(_free_droplet.bind(body))


func _free_droplet(body: Node) -> void:
	if is_instance_valid(body):
		body.queue_free()


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
