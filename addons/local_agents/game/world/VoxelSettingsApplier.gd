class_name LAVoxelSettingsApplier
extends Node


var _settings: LAGameSettings = null

# The views the effects level reaches, re-pushed on a live settings change.
var _water: Node = null
var _ejecta: LAEjectaView = null


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


## Camera far-plane budget in metres (Graphics).
func draw_distance() -> float:
	return maxf(1000.0, settings().draw_distance)


## Creatures re-decide every N frames (larger = cheaper CPU).
func ai_tick_frames() -> int:
	return clampi(settings().ai_tick_frames, 1, 60)


## Seconds between local-LLM cognition / narration calls (shorter = heavier CPU).
func llm_cadence() -> float:
	return clampf(settings().llm_cadence, 1.0, 120.0)


## Publish the simulation knobs that are consumed by systems this module does not own.
func publish_globals() -> void:
	Engine.set_meta("la_ai_tick_frames", ai_tick_frames())
	Engine.set_meta("la_llm_cadence", llm_cadence())


## Wire the views the effects level reaches, once they exist.
func bind(water: Node, ejecta: LAEjectaView) -> void:
	_water = water
	_ejecta = ejecta
	_push_effects()
	var gm: Node = get_node_or_null("/root/GameMode")
	if gm != null and gm.has_signal("settings_applied"):
		var cb: Callable = Callable(self, "_on_settings_applied")
		if not gm.is_connected("settings_applied", cb):
			gm.settings_applied.connect(cb)
	var ro: Dictionary = render_opts()
	print("SETTINGS_APPLIED={effects:%d, particle:%.2f, ssao:%s, glow:%s, shadows:%s, ocean_transparent:%s, fog:%s, draw:%.0f, ai_tick:%d, llm_cadence:%.1f}" % [
		int(settings().effects_level), particle_scale(),
		str(ro["ssao"]), str(ro["glow"]), str(ro["sun_shadows"]), str(ro["ocean_transparent"]), str(ro["fog"]),
		draw_distance(), ai_tick_frames(), llm_cadence()])


func _on_settings_applied(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		_settings = new_settings
	publish_globals()
	_push_effects()


## The effects level onto the particle views: the atmosphere's density, and how many of its embers the
## ejecta view draws out of its MultiMesh.
func _push_effects() -> void:
	if _water != null and is_instance_valid(_water) and _water.has_method("set_density_scale"):
		_water.set_density_scale(particle_scale())
	if _ejecta != null and is_instance_valid(_ejecta):
		_ejecta.max_drawn = int(round(float(_ejecta.multimesh.instance_count) * particle_scale()))
