class_name LAGameSettings
extends Resource

## LAGameSettings — the game's front-end configuration, held as a typed Resource (not a loose
## dictionary) so every consumer reads named, typed fields. It carries FOUR groups the player picks on
## the settings screen, and — the point of this file — keeps the two performance categories SEPARATE so a
## player can trade GPU cost and CPU cost independently:
##   - difficulty        → a preset (peaceful/normal/harsh) plus two continuous knobs (disaster frequency,
##                         climate harshness) the preset seeds and the player can nudge (gameplay, not perf);
##   - graphics (GPU)    → a five-step preset (potato/low/medium/high/ultra) plus the individual GPU knobs
##                         it maps to: field/render resolution, particle/effects density, shadow quality,
##                         ambient occlusion, bloom/glow, ocean water quality, atmospheric fog, vegetation
##                         density and draw distance. Potato is the weak/integrated-GPU floor;
##   - simulation / AI   → a SEPARATE four-step preset (low/medium/high/ultra) plus the CPU knobs it maps
##                         to: creature population budget, AI/cognition tick rate, LLM call cadence and
##                         field update cadence;
##   - audio             → master / music / sfx linear volumes (0..1).
## Changing any individual graphics or simulation knob flips that category's preset to CUSTOM (the preset
## enums carry a trailing CUSTOM member the UI shows when the knobs no longer match a named preset).
##
## Persistence is a human-editable ConfigFile at `user://game_settings.cfg` (load_or_default / save).
##
## APPLICATION INTERFACE: the sim consumes a settings object through `LAGameMode.apply(settings)`, which
## stores it and emits `LAGameMode.settings_applied(settings)`. LAVoxelSettingsApplier reads the concrete
## knobs off this resource and pushes them into the field/spawn/render systems. This file only DEFINES and
## PERSISTS the values; it never reaches into simulation code. (Explicit types only — no ':=' inferred typing.)

enum Difficulty { PEACEFUL, NORMAL, HARSH }
enum GraphicsPreset { POTATO, LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
enum SimPreset { LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
enum EffectsLevel { LOW, MEDIUM, HIGH }
enum ShadowQuality { OFF, LOW, HIGH }
enum OceanQuality { OPAQUE, TRANSLUCENT }

const SAVE_PATH: String = "user://game_settings.cfg"

# --- Difficulty (gameplay, not performance) ---
@export var difficulty: Difficulty = Difficulty.NORMAL
@export var disaster_frequency: float = 0.5   ## 0 = calm .. 1 = frequent disasters
@export var climate_harshness: float = 0.5    ## 0 = mild .. 1 = extreme climate swings

# --- Graphics / GPU ---
@export var graphics_preset: GraphicsPreset = GraphicsPreset.MEDIUM
@export var grid_resolution: int = 72                              ## field cells per axis budget (÷3 = cells/face)
@export var effects_level: EffectsLevel = EffectsLevel.MEDIUM      ## particle / effects density
@export var shadow_quality: ShadowQuality = ShadowQuality.OFF      ## sun shadow map (off/low/high)
@export var ssao_enabled: bool = false                            ## screen-space ambient occlusion (post FX)
@export var glow_enabled: bool = false                            ## HDR bloom / glow (post FX)
@export var ocean_quality: OceanQuality = OceanQuality.OPAQUE      ## opaque (cheap) vs translucent (overdraw)
@export var fog_enabled: bool = true                              ## atmospheric distance fog (cheap)
@export var vegetation_density: float = 1.0                        ## plant/foliage density scale (0.3..1.5)
@export var draw_distance: float = 8000.0                          ## camera far-plane budget in metres

# --- Simulation / AI / CPU ---
@export var sim_preset: SimPreset = SimPreset.MEDIUM
@export var actor_budget: int = 120           ## max concurrent creatures (spawn-count scale)
@export var ai_tick_frames: int = 3           ## creatures re-decide every N frames (larger = cheaper CPU)
@export var llm_cadence: float = 12.0         ## seconds between LLM cognition / narration calls
@export var field_cadence: int = 1            ## field substrate steps every N frames (larger = cheaper CPU)

# --- Audio (linear 0..1) ---
@export var master_volume: float = 0.9
@export var music_volume: float = 0.7
@export var sfx_volume: float = 0.8

# --- Controls ---
@export var invert_rotate_x: bool = false   ## flip the horizontal drag direction when rotating the planet
@export var invert_rotate_y: bool = false   ## flip the vertical drag direction when rotating the planet

# Difficulty preset → (disaster_frequency, climate_harshness). The preset seeds the knobs; the player may
# then fine-tune the two sliders independently.
const DIFFICULTY_PRESETS: Dictionary = {
	Difficulty.PEACEFUL: {"disaster_frequency": 0.10, "climate_harshness": 0.15},
	Difficulty.NORMAL: {"disaster_frequency": 0.50, "climate_harshness": 0.50},
	Difficulty.HARSH: {"disaster_frequency": 0.85, "climate_harshness": 0.85},
}

# Graphics preset → concrete GPU knobs. grid_resolution ÷3 is the field's cells-per-face and is the single
# biggest frame cost (a per-cell GPU CA + per-step readback), so it dominates the frame-rate: Potato runs the
# coarsest 8 cells/face on the weakest hardware, Ultra the fine 43 cells/face. The fill-rate killers
# (translucent ocean overdraw, SSAO + glow full-screen passes, sun shadow map) stay OFF below High so the
# default is playable and only strong GPUs pay for the full look.
const GRAPHICS_PRESETS: Dictionary = {
	GraphicsPreset.POTATO: {
		"grid_resolution": 24, "effects_level": EffectsLevel.LOW, "shadow_quality": ShadowQuality.OFF,
		"ssao_enabled": false, "glow_enabled": false, "ocean_quality": OceanQuality.OPAQUE,
		"fog_enabled": false, "vegetation_density": 0.40, "draw_distance": 4000.0,
	},
	GraphicsPreset.LOW: {
		"grid_resolution": 48, "effects_level": EffectsLevel.LOW, "shadow_quality": ShadowQuality.OFF,
		"ssao_enabled": false, "glow_enabled": false, "ocean_quality": OceanQuality.OPAQUE,
		"fog_enabled": true, "vegetation_density": 0.65, "draw_distance": 6000.0,
	},
	GraphicsPreset.MEDIUM: {
		"grid_resolution": 72, "effects_level": EffectsLevel.MEDIUM, "shadow_quality": ShadowQuality.OFF,
		"ssao_enabled": false, "glow_enabled": false, "ocean_quality": OceanQuality.OPAQUE,
		"fog_enabled": true, "vegetation_density": 1.0, "draw_distance": 8000.0,
	},
	GraphicsPreset.HIGH: {
		"grid_resolution": 96, "effects_level": EffectsLevel.HIGH, "shadow_quality": ShadowQuality.LOW,
		"ssao_enabled": true, "glow_enabled": true, "ocean_quality": OceanQuality.TRANSLUCENT,
		"fog_enabled": true, "vegetation_density": 1.20, "draw_distance": 12000.0,
	},
	GraphicsPreset.ULTRA: {
		"grid_resolution": 128, "effects_level": EffectsLevel.HIGH, "shadow_quality": ShadowQuality.HIGH,
		"ssao_enabled": true, "glow_enabled": true, "ocean_quality": OceanQuality.TRANSLUCENT,
		"fog_enabled": true, "vegetation_density": 1.50, "draw_distance": 16000.0,
	},
}

# Simulation preset → concrete CPU knobs. More population + more frequent thinking / LLM calls + field every
# frame all cost CPU, so Low is the light-CPU floor and Ultra the busiest world.
# field_cadence stays 1 at every tier: measured, stepping the field LESS often does NOT help fps (it batches +
# catches up, so a field frame just runs multiple steps at once — spikier, slightly slower). The processor
# slider's real levers are actor_budget (fewer creatures = less animation/render/AI) and ai_tick_frames.
# Reducing the field cost needs activity-LOD (step only the active cells), not temporal cadence.
const SIM_PRESETS: Dictionary = {
	SimPreset.LOW: {"actor_budget": 48, "ai_tick_frames": 6, "llm_cadence": 24.0, "field_cadence": 1},
	SimPreset.MEDIUM: {"actor_budget": 120, "ai_tick_frames": 3, "llm_cadence": 12.0, "field_cadence": 1},
	SimPreset.HIGH: {"actor_budget": 240, "ai_tick_frames": 2, "llm_cadence": 8.0, "field_cadence": 1},
	SimPreset.ULTRA: {"actor_budget": 360, "ai_tick_frames": 1, "llm_cadence": 5.0, "field_cadence": 1},
}


## Apply a difficulty preset: set the enum and seed the two continuous knobs from the table.
func apply_difficulty_preset(preset: Difficulty) -> void:
	difficulty = preset
	var row: Dictionary = DIFFICULTY_PRESETS.get(preset, DIFFICULTY_PRESETS[Difficulty.NORMAL])
	disaster_frequency = float(row["disaster_frequency"])
	climate_harshness = float(row["climate_harshness"])


## Apply a graphics preset: set the enum and every concrete GPU knob it maps to.
func apply_graphics_preset(preset: GraphicsPreset) -> void:
	if preset == GraphicsPreset.CUSTOM:
		graphics_preset = GraphicsPreset.CUSTOM
		return
	var row: Dictionary = GRAPHICS_PRESETS.get(preset, GRAPHICS_PRESETS[GraphicsPreset.MEDIUM])
	grid_resolution = int(row["grid_resolution"])
	effects_level = int(row["effects_level"]) as EffectsLevel
	shadow_quality = int(row["shadow_quality"]) as ShadowQuality
	ssao_enabled = bool(row["ssao_enabled"])
	glow_enabled = bool(row["glow_enabled"])
	ocean_quality = int(row["ocean_quality"]) as OceanQuality
	fog_enabled = bool(row["fog_enabled"])
	vegetation_density = float(row["vegetation_density"])
	draw_distance = float(row["draw_distance"])
	graphics_preset = preset


## Apply a simulation preset: set the enum and every concrete CPU knob it maps to.
func apply_sim_preset(preset: SimPreset) -> void:
	if preset == SimPreset.CUSTOM:
		sim_preset = SimPreset.CUSTOM
		return
	var row: Dictionary = SIM_PRESETS.get(preset, SIM_PRESETS[SimPreset.MEDIUM])
	actor_budget = int(row["actor_budget"])
	ai_tick_frames = int(row["ai_tick_frames"])
	llm_cadence = float(row["llm_cadence"])
	field_cadence = int(row["field_cadence"])
	sim_preset = preset


## Re-derive `graphics_preset` from the current knobs: the named preset whose whole table matches, else
## CUSTOM. Call after any individual graphics knob changes so the UI reflects "matches a preset" vs custom.
func resolve_graphics_preset() -> void:
	graphics_preset = _match_preset(GRAPHICS_PRESETS, _graphics_knobs()) as GraphicsPreset


## Re-derive `sim_preset` from the current knobs the same way.
func resolve_sim_preset() -> void:
	sim_preset = _match_preset(SIM_PRESETS, _sim_knobs()) as SimPreset


func _graphics_knobs() -> Dictionary:
	return {
		"grid_resolution": grid_resolution, "effects_level": int(effects_level),
		"shadow_quality": int(shadow_quality), "ssao_enabled": ssao_enabled,
		"glow_enabled": glow_enabled, "ocean_quality": int(ocean_quality),
		"fog_enabled": fog_enabled, "vegetation_density": vegetation_density,
		"draw_distance": draw_distance,
	}


func _sim_knobs() -> Dictionary:
	return {
		"actor_budget": actor_budget, "ai_tick_frames": ai_tick_frames,
		"llm_cadence": llm_cadence, "field_cadence": field_cadence,
	}


# Return the enum index of the preset in `table` whose every value equals `knobs`, else the CUSTOM index
# (the last member — one past the named presets). Numeric values compare with a small epsilon.
func _match_preset(table: Dictionary, knobs: Dictionary) -> int:
	var custom_index: int = table.size()
	for preset in table:
		var row: Dictionary = table[preset]
		var all_equal: bool = true
		for key in row:
			if not _knob_equal(row[key], knobs.get(key)):
				all_equal = false
				break
		if all_equal:
			return int(preset)
	return custom_index


func _knob_equal(a: Variant, b: Variant) -> bool:
	if a is float or b is float:
		return absf(float(a) - float(b)) < 0.001
	return a == b


## Load the persisted settings, or a fresh defaults instance if none exist / the file is unreadable.
static func load_or_default() -> LAGameSettings:
	var settings: LAGameSettings = LAGameSettings.new()
	var config: ConfigFile = ConfigFile.new()
	var err: int = config.load(SAVE_PATH)
	if err != OK:
		return settings
	settings.difficulty = int(config.get_value("difficulty", "preset", settings.difficulty)) as Difficulty
	settings.disaster_frequency = float(config.get_value("difficulty", "disaster_frequency", settings.disaster_frequency))
	settings.climate_harshness = float(config.get_value("difficulty", "climate_harshness", settings.climate_harshness))
	settings.graphics_preset = int(config.get_value("graphics", "preset", settings.graphics_preset)) as GraphicsPreset
	settings.grid_resolution = int(config.get_value("graphics", "grid_resolution", settings.grid_resolution))
	settings.effects_level = int(config.get_value("graphics", "effects_level", settings.effects_level)) as EffectsLevel
	settings.shadow_quality = int(config.get_value("graphics", "shadow_quality", settings.shadow_quality)) as ShadowQuality
	settings.ssao_enabled = bool(config.get_value("graphics", "ssao_enabled", settings.ssao_enabled))
	settings.glow_enabled = bool(config.get_value("graphics", "glow_enabled", settings.glow_enabled))
	settings.ocean_quality = int(config.get_value("graphics", "ocean_quality", settings.ocean_quality)) as OceanQuality
	settings.fog_enabled = bool(config.get_value("graphics", "fog_enabled", settings.fog_enabled))
	settings.vegetation_density = float(config.get_value("graphics", "vegetation_density", settings.vegetation_density))
	settings.draw_distance = float(config.get_value("graphics", "draw_distance", settings.draw_distance))
	settings.sim_preset = int(config.get_value("simulation", "preset", settings.sim_preset)) as SimPreset
	settings.actor_budget = int(config.get_value("simulation", "actor_budget", settings.actor_budget))
	settings.ai_tick_frames = int(config.get_value("simulation", "ai_tick_frames", settings.ai_tick_frames))
	settings.llm_cadence = float(config.get_value("simulation", "llm_cadence", settings.llm_cadence))
	settings.field_cadence = int(config.get_value("simulation", "field_cadence", settings.field_cadence))
	settings.master_volume = float(config.get_value("audio", "master_volume", settings.master_volume))
	settings.music_volume = float(config.get_value("audio", "music_volume", settings.music_volume))
	settings.sfx_volume = float(config.get_value("audio", "sfx_volume", settings.sfx_volume))
	settings.invert_rotate_x = bool(config.get_value("controls", "invert_rotate_x", settings.invert_rotate_x))
	settings.invert_rotate_y = bool(config.get_value("controls", "invert_rotate_y", settings.invert_rotate_y))
	return settings


## Persist to the ConfigFile. Returns OK on success.
func save() -> int:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("difficulty", "preset", int(difficulty))
	config.set_value("difficulty", "disaster_frequency", disaster_frequency)
	config.set_value("difficulty", "climate_harshness", climate_harshness)
	config.set_value("graphics", "preset", int(graphics_preset))
	config.set_value("graphics", "grid_resolution", grid_resolution)
	config.set_value("graphics", "effects_level", int(effects_level))
	config.set_value("graphics", "shadow_quality", int(shadow_quality))
	config.set_value("graphics", "ssao_enabled", ssao_enabled)
	config.set_value("graphics", "glow_enabled", glow_enabled)
	config.set_value("graphics", "ocean_quality", int(ocean_quality))
	config.set_value("graphics", "fog_enabled", fog_enabled)
	config.set_value("graphics", "vegetation_density", vegetation_density)
	config.set_value("graphics", "draw_distance", draw_distance)
	config.set_value("simulation", "preset", int(sim_preset))
	config.set_value("simulation", "actor_budget", actor_budget)
	config.set_value("simulation", "ai_tick_frames", ai_tick_frames)
	config.set_value("simulation", "llm_cadence", llm_cadence)
	config.set_value("simulation", "field_cadence", field_cadence)
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.set_value("controls", "invert_rotate_x", invert_rotate_x)
	config.set_value("controls", "invert_rotate_y", invert_rotate_y)
	return config.save(SAVE_PATH)


## A compact human-readable snapshot (for logs / the settings-saved confirmation line).
func summary() -> String:
	return "diff=%d dis=%.2f cli=%.2f | gfx=%d grid=%d fx=%d shadow=%d ssao=%s glow=%s ocean=%d fog=%s veg=%.2f draw=%.0f | sim=%d actors=%d ai=%d llm=%.1f field=%d | vol[m=%.2f mu=%.2f s=%.2f] | ctrl[invx=%s invy=%s]" % [
		int(difficulty), disaster_frequency, climate_harshness,
		int(graphics_preset), grid_resolution, int(effects_level), int(shadow_quality),
		str(ssao_enabled), str(glow_enabled), int(ocean_quality), str(fog_enabled),
		vegetation_density, draw_distance,
		int(sim_preset), actor_budget, ai_tick_frames, llm_cadence, field_cadence,
		master_volume, music_volume, sfx_volume,
		str(invert_rotate_x), str(invert_rotate_y),
	]
