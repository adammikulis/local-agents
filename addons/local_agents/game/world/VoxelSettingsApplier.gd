class_name LAVoxelSettingsApplier
extends Node


const GRID_RES_DIVISOR: float = 3.0
const GRID_EDGE_MIN: int = 8
const GRID_EDGE_MAX: int = 64

## actor_budget that maps to spawn_scale == 1.0 (the Medium preset). Low (48) → 0.4, High (240) → 2.0.
const BASELINE_ACTOR_BUDGET: float = 120.0
const SPAWN_SCALE_MIN: float = 0.15
const SPAWN_SCALE_MAX: float = 4.0

var _settings: LAGameSettings = null

# Live-binding refs (set in bind(), after the terrain/particle systems exist).
var _world: Node = null
var _terrain = null
var _water: Node = null                                  # kept so a live settings re-apply can re-push effects density

var _bound: bool = false


## Resolve the active settings from the GameMode autoload, or persisted defaults when it is absent.
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


## Plant / foliage density scale (Graphics).
func vegetation_scale() -> float:
	return clampf(settings().vegetation_density, 0.1, 2.0)


## Camera far-plane budget in metres (Graphics).
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


## Publish the graphics + simulation knobs that are consumed by systems this module does not own.
func publish_globals() -> void:
	Engine.set_meta("la_vegetation_scale", vegetation_scale())
	Engine.set_meta("la_draw_distance", draw_distance())
	Engine.set_meta("la_ai_tick_frames", ai_tick_frames())
	Engine.set_meta("la_llm_cadence", llm_cadence())
	Engine.set_meta("la_field_cadence", field_cadence())
	Engine.set_meta("la_effects_scale", particle_scale())   # quality-scaled effects budget (ejecta pool, …)


## Wire the live systems once they exist (called near the end of VoxelWorld._ready).
func bind(world: Node, terrain, water: Node) -> void:
	_world = world
	_terrain = terrain
	_water = water
	if water != null and water.has_method("set_density_scale"):
		water.set_density_scale(particle_scale())
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.has_signal("settings_applied"):
		var cb: Callable = Callable(self, "_on_settings_applied")
		if not gm.is_connected("settings_applied", cb):
			gm.settings_applied.connect(cb)
	_bound = true
	var ro: Dictionary = render_opts()
	print("SETTINGS_APPLIED={grid_res:%d, grid_edge:%d, effects:%d, actor_budget:%d, spawn_scale:%.2f, particle:%.2f, ssao:%s, glow:%s, shadows:%s, ocean_transparent:%s, fog:%s, veg:%.2f, draw:%.0f, ai_tick:%d, llm_cadence:%.1f, field_cadence:%d}" % [
		settings().grid_resolution, grid_cells_per_edge(), int(settings().effects_level),
		settings().actor_budget, spawn_scale(), particle_scale(),
		str(ro["ssao"]), str(ro["glow"]), str(ro["sun_shadows"]), str(ro["ocean_transparent"]), str(ro["fog"]),
		vegetation_scale(), draw_distance(), ai_tick_frames(), llm_cadence(), field_cadence()])


func _on_settings_applied(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		_settings = new_settings
	publish_globals()
	# Push the live-adjustable effects density so a mid-game Graphics change reaches the systems.
	if _water != null and is_instance_valid(_water) and _water.has_method("set_density_scale"):
		_water.set_density_scale(particle_scale())
