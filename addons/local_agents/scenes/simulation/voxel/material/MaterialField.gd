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
## New cells start with a little ambient humidity (air is never bone-dry), so clouds/fog can form from
## the first cool night instead of needing a full day of evaporation to charge the atmosphere first.
const INITIAL_VAPOR: float = 0.035
## Pull (°C toward ambient per second) on WET cells — big water heat capacity keeps rivers/lakes near
## ambient even beside a fire, so they act as firebreaks emergently.
const WATER_COOL: float = 300.0
## Diagnostic default: a cell at/above this °C counts as "hot" (well above any natural ambient).
const HOT_THRESHOLD: float = 60.0

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

# --- Atmosphere: the emergent vapor -> cloud -> rain cycle. Evaporation off warm water/wet ground
# feeds a per-cell water-VAPOR layer; vapor diffuses and drifts downwind; where the air is cool
# enough that vapor exceeds its (temperature-dependent) saturation it CONDENSES into CLOUD density;
# thick cloud RAINS water back onto the ground and SHADES the sun below it, cooling that ground.
# Clouds forming over cool peaks / at night, drifting off warm water, and rain feeding rivers all
# fall out of these local rules — nothing is scripted per-case.
const EVAP_TEMP_REF: float = 22.0        # °C at which evaporation runs at ~1x
const EVAP_TEMP_GAIN: float = 0.055      # per-°C change in evaporation rate (warm water steams more)
const VAPOR_DIFFUSE: float = 0.14        # isotropic vapor spread per step
const CLOUD_DIFFUSE: float = 0.06        # clouds spread a little too
const SAT_BASE: float = 0.035            # saturation vapor at EVAP_TEMP_REF (lower -> clouds form sooner)
const SAT_TEMP_GAIN: float = 0.055       # warmer air holds exponentially more vapor before condensing
const CONDENSE_RATE: float = 0.30        # fraction of super-saturated vapor -> cloud per step
const CLOUD_REEVAP_RATE: float = 0.08    # fraction of cloud -> vapor per step when air is sub-saturated
const CLOUD_DECAY: float = 0.002         # baseline cloud dissipation per step (keeps it from piling up)
const RAIN_CLOUD_THRESHOLD: float = 0.45 # cloud density above which it precipitates
const RAIN_RATE: float = 0.16            # fraction of above-threshold cloud -> ground water per step
const CLOUD_SHADE_GAIN: float = 3.0      # cloud density -> fraction of solar blocked below it
const CLOUD_SHADE_MAX: float = 0.75      # a cell's cloud can block at most this much of its solar
const CLOUD_BASE_ABOVE_SEA: float = 62.0 # world-Y of the rendered cloud sheet, above sea level
## Air at cloud base is this many °C cooler than the surface — clouds condense from vapor that only
## the cooler air aloft can't hold. When the SURFACE air itself is saturated (cool valleys/water at
## dawn), that condensate pools at ground level as FOG instead. Same vapor, two outcomes.
const CLOUD_AIR_COOLING: float = 7.0
const FOG_MAX_TEMP: float = 12.0         # only surfaces cooler than this (°C) pool ground fog
const FOG_BASE_ABOVE_SEA: float = 6.0    # world-Y of the ground-hugging fog sheet, above sea level

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

# --- Atmosphere layers (the vapor -> cloud/fog -> rain cycle) ---
var _vapor: PackedFloat32Array = PackedFloat32Array()     # airborne water vapor (humidity) per cell
var _cloud: PackedFloat32Array = PackedFloat32Array()     # condensed cloud density (rendered aloft)
var _fog: PackedFloat32Array = PackedFloat32Array()       # condensed fog density (ground-hugging)
var _adelta: PackedFloat32Array = PackedFloat32Array()    # scratch for vapor/cloud transport
var _wind: Vector2 = Vector2.ZERO                         # world XZ wind (from weather) drifting vapor
var _cloud_cover: float = 0.0                             # cached mean cloud density (sun dimming/HUD)
var _fog_cover: float = 0.0                               # cached mean fog density

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
	_vapor = PackedFloat32Array()
	_vapor.resize(_cell_count)
	_cloud = PackedFloat32Array()
	_cloud.resize(_cell_count)
	_fog = PackedFloat32Array()
	_fog.resize(_cell_count)
	_adelta = PackedFloat32Array()
	_adelta.resize(_cell_count)
	_mats = {}

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
		_surface_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_surface_mi)


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
	if steps > 0 and _liquid_dirty:
		_rebuild_water_surface()
		_liquid_dirty = false


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


# --- The unified step -------------------------------------------------------

## One CA tick: heat exchange, then (once materials exist) phase reactions + movement + combustion.
## Order-independent via scratch buffers, exactly like the water solver.
func _material_step() -> void:
	if _cell_count <= 0:
		return
	_heat_exchange_step()
	_liquid_step()
	_atmosphere_step()
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
	var solar_warmth: float = SOLAR_WARMTH * _solar
	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var t: float = _temp[idx] + _tdelta[idx]
		var altitude: float = _terrain_h[idx]
		# Cloud overhead shades this cell's sunlight, so cloudy/foggy ground warms less — the
		# emergent "clouds cool the ground below them" feedback.
		var shade: float = minf(CLOUD_SHADE_MAX, (_cloud[idx] + _fog[idx]) * CLOUD_SHADE_GAIN)
		var day_base: float = AMBIENT_NIGHT + solar_warmth * (1.0 - shade)
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
			# Evaporate faster from warm water; the lost depth becomes airborne VAPOR (not deleted),
			# which is what later condenses into cloud/fog. Cold water barely steams.
			var ef: float = clampf(1.0 + EVAP_TEMP_GAIN * (_temp[idx] - EVAP_TEMP_REF), 0.15, 3.0)
			var evap: float = minf(nd, EVAP_PER_STEP * 1.3 * ef)
			nd -= evap
			_vapor[idx] += evap
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


# --- Atmosphere: vapor -> cloud/fog -> rain (the emergent water cycle) --------

## Move vapor/cloud/fog: isotropic diffusion (symmetric, order-independent, right+up pairs) plus,
## optionally, first-order upwind advection by the wind. Accumulates into _adelta then applies.
func _transport_field(arr: PackedFloat32Array, diffuse_frac: float, wind_gain: float) -> void:
	var dim: int = _dim
	for idx in range(_cell_count):
		_adelta[idx] = 0.0
	for j in range(dim):
		var row: int = j * dim
		for i in range(dim):
			var idx: int = row + i
			if _sampled[idx] == 0:
				continue
			var q: float = arr[idx]
			if i < dim - 1:
				var ri: int = idx + 1
				if _sampled[ri] != 0:
					var f: float = (q - arr[ri]) * diffuse_frac * 0.25
					_adelta[idx] -= f
					_adelta[ri] += f
			if j < dim - 1:
				var ui: int = idx + dim
				if _sampled[ui] != 0:
					var f2: float = (q - arr[ui]) * diffuse_frac * 0.25
					_adelta[idx] -= f2
					_adelta[ui] += f2
	if wind_gain > 0.0 and (_wind.x != 0.0 or _wind.y != 0.0):
		var ax: float = clampf(absf(_wind.x) * wind_gain * STEP_DT / _cell_size, 0.0, 0.5)
		var az: float = clampf(absf(_wind.y) * wind_gain * STEP_DT / _cell_size, 0.0, 0.5)
		var sx: int = 1 if _wind.x > 0.0 else -1
		var sz: int = 1 if _wind.y > 0.0 else -1
		for j2 in range(dim):
			var row2: int = j2 * dim
			for i2 in range(dim):
				var idx2: int = row2 + i2
				if _sampled[idx2] == 0:
					continue
				var q2: float = arr[idx2]
				if q2 <= 0.0:
					continue
				if ax > 0.0:
					var ni: int = i2 + sx
					if ni >= 0 and ni < dim:
						var nidx: int = row2 + ni
						if _sampled[nidx] != 0:
							var mv: float = q2 * ax
							_adelta[idx2] -= mv
							_adelta[nidx] += mv
				if az > 0.0:
					var nj: int = j2 + sz
					if nj >= 0 and nj < dim:
						var nidx2: int = nj * dim + i2
						if _sampled[nidx2] != 0:
							var mv2: float = q2 * az
							_adelta[idx2] -= mv2
							_adelta[nidx2] += mv2
	for idx3 in range(_cell_count):
		if _sampled[idx3] == 0:
			continue
		var v: float = arr[idx3] + _adelta[idx3]
		if v < 0.0:
			v = 0.0
		arr[idx3] = v


## Vapor drifts/spreads, then per cell: vapor the cool air aloft can't hold CONDENSES into cloud
## (the share the surface air also can't hold pools as ground FOG); sub-saturated air lets cloud/fog
## re-evaporate; thick cloud RAINS water back to the ground. Clouds over cool peaks, fog in valleys
## at dawn, and rain feeding rivers all fall out of this — no per-case scripting.
func _atmosphere_step() -> void:
	if _cell_count <= 0:
		return
	# Wind carries everything AIRBORNE/AERATED — vapor (gas), cloud and fog (suspended droplets) all
	# drift downwind; liquid WATER is not advected here (it flows by gravity in _liquid_step). Fog
	# hugging the ground drifts a little slower (ground drag) via a lower wind gain.
	_transport_field(_vapor, VAPOR_DIFFUSE, 1.0)
	_transport_field(_cloud, CLOUD_DIFFUSE, 1.0)
	_transport_field(_fog, CLOUD_DIFFUSE * 0.5, 0.5)

	var water: PackedFloat32Array = _mat_array(Mat.WATER)
	var cloud_sum: float = 0.0
	var fog_sum: float = 0.0
	var rained: bool = false
	for idx in range(_cell_count):
		if _sampled[idx] == 0:
			continue
		var t: float = _temp[idx]
		var vap: float = _vapor[idx]
		# Saturation the surface air holds, and the (colder) air at cloud base holds. When the SURFACE
		# air itself saturates, condensation happens at ground level as FOG; when only the cooler air
		# aloft saturates, it forms CLOUD at the base. Same vapor, height decided by where it saturates.
		var sat_surface: float = SAT_BASE * exp(SAT_TEMP_GAIN * (t - EVAP_TEMP_REF))
		var sat_aloft: float = SAT_BASE * exp(SAT_TEMP_GAIN * ((t - CLOUD_AIR_COOLING) - EVAP_TEMP_REF))
		# Fog is a COOL-air phenomenon: warm saturated air over water is just humid (its vapor rises
		# and clouds aloft instead), so only genuinely cool surfaces pool ground fog.
		var cool: float = t < FOG_MAX_TEMP
		if cool and vap > sat_surface:
			var fcond: float = (vap - sat_surface) * CONDENSE_RATE
			_vapor[idx] = vap - fcond
			_fog[idx] += fcond
		else:
			# Surface sub-saturated: any ground fog re-evaporates back to vapor.
			var fr: float = _fog[idx] * CLOUD_REEVAP_RATE
			_fog[idx] -= fr
			vap = vap + fr
			if vap > sat_aloft:
				var ccond: float = (vap - sat_aloft) * CONDENSE_RATE
				_vapor[idx] = vap - ccond
				_cloud[idx] += ccond
			else:
				var cr: float = _cloud[idx] * CLOUD_REEVAP_RATE
				_cloud[idx] -= cr
				_vapor[idx] = vap + cr
		# Baseline dissipation so condensate never piles up forever.
		_cloud[idx] *= (1.0 - CLOUD_DECAY)
		_fog[idx] *= (1.0 - CLOUD_DECAY)
		# Precipitation: thick cloud rains water back to the ground, closing the cycle.
		if _cloud[idx] > RAIN_CLOUD_THRESHOLD:
			var rain: float = (_cloud[idx] - RAIN_CLOUD_THRESHOLD) * RAIN_RATE
			_cloud[idx] -= rain
			water[idx] += rain
			rained = true
		cloud_sum += _cloud[idx]
		fog_sum += _fog[idx]
	var denom: float = maxf(1.0, float(_sampled_count))
	_cloud_cover = cloud_sum / denom
	_fog_cover = fog_sum / denom
	if rained:
		_liquid_dirty = true


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


## Set the current wind (world XZ) so vapor/cloud drift downwind. Fed from the weather each frame.
func set_wind(w: Vector2) -> void:
	if is_nan(w.x) or is_nan(w.y) or is_inf(w.x) or is_inf(w.y):
		return
	_wind = w


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


# --- Atmosphere queries + render feeds (CloudLayer reads the grids to build density textures) ---

func cloud_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	return _cloud[idx] if idx >= 0 else 0.0


func fog_at(x: float, z: float) -> float:
	var idx: int = _index_at(x, z)
	return _fog[idx] if idx >= 0 else 0.0


## Mean cloud / fog density over sampled cells — drives global sun dimming and HUD/diagnostics.
func avg_cloud_cover() -> float:
	return _cloud_cover


func avg_fog_cover() -> float:
	return _fog_cover


func wind() -> Vector2:
	return _wind


## Grid geometry so a renderer can map cell (i, j) <-> world XZ exactly like the field does.
func grid_dim() -> int:
	return _dim


func grid_half_extent() -> float:
	return _half_extent


## World Y of the two rendered condensate sheets.
func cloud_base_y() -> float:
	return sea_level + CLOUD_BASE_ABOVE_SEA


func fog_base_y() -> float:
	return sea_level + FOG_BASE_ABOVE_SEA


## The raw density grids (flat, index = j*dim+i) for building render textures. Returned by reference;
## the renderer only reads them.
func cloud_grid() -> PackedFloat32Array:
	return _cloud


func fog_grid() -> PackedFloat32Array:
	return _fog


## Diagnostic: cells whose cloud density is at least min_density.
func cloud_cell_count(min_density: float = 0.05) -> int:
	var n: int = 0
	for idx in range(_cell_count):
		if _sampled[idx] != 0 and _cloud[idx] >= min_density:
			n += 1
	return n


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
