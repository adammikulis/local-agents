class_name LAVoxelSettingsApplier
extends Node


const GRID_RES_DIVISOR: float = 3.0
const GRID_EDGE_MIN: int = 8
const GRID_EDGE_MAX: int = 64

## actor_budget that maps to spawn_scale == 1.0 (the Medium preset). Low (48) → 0.4, High (240) → 2.0.
const BASELINE_ACTOR_BUDGET: float = 120.0
const SPAWN_SCALE_MIN: float = 0.15
const SPAWN_SCALE_MAX: float = 4.0

const DISASTER_INTERVAL_FAST: float = 180.0
const DISASTER_INTERVAL_SLOW: float = 2400.0
const DISASTER_FREQ_OFF: float = 0.03
const DISASTER_JITTER: float = 0.35        # ± fraction of the interval added as randomness (seeded)

var _settings: LAGameSettings = null

# Live-binding refs (set in bind(), after the disaster/terrain/particle systems exist).
var _world: Node = null
var _disasters: Node = null
var _terrain = null
var _water: Node = null                                  # kept so a live settings re-apply can re-push effects density

var _disaster_interval: float = DISASTER_INTERVAL_SLOW
var _disaster_accum: float = 0.0
var _disaster_next: float = 0.0
var _ambient_enabled: bool = false
var _bound: bool = false


## Resolve the active settings from the GameMode autoload (or persisted defaults when it is absent, e.g. a
## direct-scene test). Call this FIRST, before the field/spawn build reads the grid/actor queries.
func read_settings() -> void:
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.get("settings") != null:
		_settings = gm.get("settings")
	if _settings == null:
		_settings = LAGameSettings.load_or_default()
	_apply_smoke_overrides()
	_apply_quality_override()
	publish_globals()


func _apply_smoke_overrides() -> void:
	if not (Engine.has_meta("la_smoke") and bool(Engine.get_meta("la_smoke"))):
		return
	var smoke: LAGameSettings = _settings.duplicate() if _settings != null else LAGameSettings.new()
	smoke.apply_graphics_preset(LAGameSettings.GraphicsPreset.POTATO)
	smoke.apply_sim_preset(LAGameSettings.SimPreset.LOW)
	smoke.disaster_frequency = 0.0
	_settings = smoke


func _apply_quality_override() -> void:
	if not Engine.has_meta("la_quality"):
		return
	var name: String = String(Engine.get_meta("la_quality"))
	var preset_map: Dictionary = {
		"potato": LAGameSettings.GraphicsPreset.POTATO, "low": LAGameSettings.GraphicsPreset.LOW,
		"medium": LAGameSettings.GraphicsPreset.MEDIUM, "high": LAGameSettings.GraphicsPreset.HIGH,
		"ultra": LAGameSettings.GraphicsPreset.ULTRA,
	}
	if not preset_map.has(name):
		push_warning("VoxelSettingsApplier: unknown --quality=%s (expected potato/low/medium/high/ultra), ignoring" % name)
		return
	var q: LAGameSettings = _settings.duplicate() if _settings != null else LAGameSettings.new()
	q.apply_graphics_preset(preset_map[name])
	_settings = q


func settings() -> LAGameSettings:
	if _settings == null:
		read_settings()
	return _settings


## Field cells along one edge of the box, from the quality grid_resolution budget.
func grid_cells_per_edge() -> int:
	return clampi(int(round(float(settings().grid_resolution) / GRID_RES_DIVISOR)), GRID_EDGE_MIN, GRID_EDGE_MAX)


## Multiplier the initial-spawn controller applies to its base actor counts.
func spawn_scale() -> float:
	return clampf(float(settings().actor_budget) / BASELINE_ACTOR_BUDGET, SPAWN_SCALE_MIN, SPAWN_SCALE_MAX)


## Particle-density scale (0..1) from the effects level — Low runs far fewer atmosphere particles.
func particle_scale() -> float:
	match settings().effects_level:
		LAGameSettings.EffectsLevel.LOW:
			return 0.35
		LAGameSettings.EffectsLevel.HIGH:
			return 1.0
		_:
			return 0.65


func render_opts() -> Dictionary:
	var s: LAGameSettings = settings()
	return {
		"ssao": s.ssao_enabled,
		"glow": s.glow_enabled,
		"sun_shadows": s.shadow_quality != LAGameSettings.ShadowQuality.OFF,
		"ocean_transparent": s.ocean_quality == LAGameSettings.OceanQuality.TRANSLUCENT,
		"fog": s.fog_enabled,
	}


## Plant / foliage density scale (Graphics). Default 1.0 leaves the ecosystem balance untouched; the spawn
## controller multiplies its base plant count by this. GPU-side detail, not creature population.
func vegetation_scale() -> float:
	return clampf(settings().vegetation_density, 0.1, 2.0)


## Camera far-plane budget in metres (Graphics). Published for the camera rig; also returned here so a
## consumer can query it directly.
func draw_distance() -> float:
	return maxf(1000.0, settings().draw_distance)


## Creatures re-decide every N frames (larger = cheaper CPU).
func ai_tick_frames() -> int:
	return clampi(settings().ai_tick_frames, 1, 60)


## Seconds between local-LLM cognition / narration calls (shorter = heavier CPU).
func llm_cadence() -> float:
	return clampf(settings().llm_cadence, 1.0, 120.0)


## Field substrate steps every N frames (larger = cheaper CPU).
func field_cadence() -> int:
	return clampi(settings().field_cadence, 1, 60)


## Publish the graphics + simulation knobs that are consumed by systems this module does not own, as Engine
## metadata globals (a single well-known seam) so those systems read the player's choice without this module
## reaching into their code. Called on boot and re-called when settings are re-applied mid-game.
func publish_globals() -> void:
	Engine.set_meta("la_vegetation_scale", vegetation_scale())
	Engine.set_meta("la_draw_distance", draw_distance())
	Engine.set_meta("la_ai_tick_frames", ai_tick_frames())
	Engine.set_meta("la_llm_cadence", llm_cadence())
	Engine.set_meta("la_field_cadence", field_cadence())
	Engine.set_meta("la_effects_scale", particle_scale())   # quality-scaled effects budget (ejecta pool, …)


## Wire the live systems once they exist (called near the end of VoxelWorld._ready). Applies the particle
## density, arms the ambient-disaster cadence, and subscribes to GameMode.settings_applied so a mid-game
## Save re-applies the live knobs.
func bind(world: Node, disasters: Node, terrain, water: Node) -> void:
	_world = world
	_disasters = disasters
	_terrain = terrain
	_water = water
	if water != null and water.has_method("set_density_scale"):
		water.set_density_scale(particle_scale())
	_recompute_disaster_cadence()
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.has_signal("settings_applied"):
		var cb: Callable = Callable(self, "_on_settings_applied")
		if not gm.is_connected("settings_applied", cb):
			gm.settings_applied.connect(cb)
	_bound = true
	var ro: Dictionary = render_opts()
	print("SETTINGS_APPLIED={grid_res:%d, grid_edge:%d, effects:%d, actor_budget:%d, spawn_scale:%.2f, particle:%.2f, ssao:%s, glow:%s, shadows:%s, ocean_transparent:%s, fog:%s, veg:%.2f, draw:%.0f, ai_tick:%d, llm_cadence:%.1f, field_cadence:%d, disaster_freq:%.2f, disaster_interval:%.1f, climate:%.2f, ambient:%s}" % [
		settings().grid_resolution, grid_cells_per_edge(), int(settings().effects_level),
		settings().actor_budget, spawn_scale(), particle_scale(),
		str(ro["ssao"]), str(ro["glow"]), str(ro["sun_shadows"]), str(ro["ocean_transparent"]), str(ro["fog"]),
		vegetation_scale(), draw_distance(), ai_tick_frames(), llm_cadence(), field_cadence(),
		settings().disaster_frequency, _disaster_interval, settings().climate_harshness, str(_ambient_enabled)])


func _on_settings_applied(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		_settings = new_settings
	publish_globals()
	# Push the live-adjustable effects density so a mid-game Graphics change (e.g. from the pause menu) shows
	# up immediately in the rain/spray particle budget. Grid resolution + shadow maps are build-time only and
	# take effect on the next world load — the pause settings panel says so.
	if _water != null and is_instance_valid(_water) and _water.has_method("set_density_scale"):
		_water.set_density_scale(particle_scale())
	_recompute_disaster_cadence()


func _recompute_disaster_cadence() -> void:
	var freq: float = clampf(settings().disaster_frequency, 0.0, 1.0)
	_ambient_enabled = freq > DISASTER_FREQ_OFF and not OS.has_environment("LA_NO_AMBIENT_DISASTERS")
	_disaster_interval = lerpf(DISASTER_INTERVAL_SLOW, DISASTER_INTERVAL_FAST, freq)
	# First seed lands at roughly half the interval so a harsh world proves its cadence early.
	_disaster_next = _disaster_interval * 0.5
	_disaster_accum = 0.0


# The ambient director seeds into the field, so its cadence runs on the fixed physics tick, the clock the
# field steps on. The readiness gate below asks whether the world is BUILT; it never reads a population.
func _physics_process(delta: float) -> void:
	if not _bound or not _ambient_enabled or _disasters == null:
		return
	if get_tree() == null or _world == null:
		return
	if _world.has_method("world_ready") and not bool(_world.world_ready()):
		return
	_disaster_accum += delta
	if _disaster_accum < _disaster_next:
		return
	_disaster_accum = 0.0
	_disaster_next = _disaster_interval * (1.0 + LASimRng.for_domain("planet").randf_range(-DISASTER_JITTER, DISASTER_JITTER))
	_seed_ambient_disaster()


## Seed one disaster, its kind weighted by climate_harshness, at a fitting site. Uses only the camera-neutral
## VoxelDisasters spawns (no camera-hijacking auto-cast), so an ambient event never yanks the player's view.
func _seed_ambient_disaster() -> void:
	var kind: String = _pick_disaster_kind(clampf(settings().climate_harshness, 0.0, 1.0))
	match kind:
		"thunderstorm":
			if _disasters.has_method("spawn_thunderstorm"):
				_disasters.spawn_thunderstorm(_random_surface_point())
		"tornado":
			if _disasters.has_method("spawn_tornado"):
				_disasters.spawn_tornado(_random_surface_point())
		"hurricane":
			if _disasters.has_method("spawn_hurricane"):
				_disasters.spawn_hurricane(_random_surface_point())
		"volcano":
			if _disasters.has_method("spawn_default_volcano"):
				_disasters.spawn_default_volcano()
	print("AMBIENT_DISASTER={type:%s, climate:%.2f, interval:%.1f}" % [kind, settings().climate_harshness, _disaster_interval])


func _pick_disaster_kind(climate: float) -> String:
	var weights: Dictionary = {
		"thunderstorm": 2.0,
		"tornado": 1.0 + 2.0 * climate,
		"hurricane": 0.5 + 2.5 * climate,
		"volcano": 0.3 + 1.5 * climate,
	}
	var total: float = 0.0
	for k in weights:
		total += float(weights[k])
	var roll: float = LASimRng.for_domain("planet").randf() * total
	for k in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			return String(k)
	return "thunderstorm"


## A random world-space point on the planet surface (falls back to a point above the centre if unmeshed).
## Seeded (LASimRng) so an ambient event lands at a reproducible site for a given LA_SIM_SEED.
func _random_surface_point() -> Vector3:
	var dir: Vector3 = LASimRng.for_domain("planet").rand_dir()
	if dir.length_squared() < 1.0e-4:
		dir = Vector3.UP
	dir = dir.normalized()
	if _terrain != null and _terrain.has_method("surface_point"):
		var sp: Vector3 = _terrain.surface_point(dir)
		if not is_nan(sp.x):
			return sp
	var center: Vector3 = _terrain.planet_center() if _terrain != null and _terrain.has_method("planet_center") else Vector3.ZERO
	var sea_r: float = _terrain.sea_radius() if _terrain != null and _terrain.has_method("sea_radius") else 250.0
	return center + dir * sea_r
