class_name LAGameSettings
extends Resource

## LAGameSettings — the game's front-end configuration, held as a typed Resource (not a loose
## dictionary) so every consumer reads named, typed fields. It carries three groups the player
## picks on the settings screen:
##   - difficulty      → a preset (peaceful/normal/harsh) plus two continuous knobs (disaster
##                       frequency, climate harshness) the preset seeds and the player can nudge;
##   - quality / perf  → a preset (low/medium/high) plus the concrete budgets it maps to (grid
##                       resolution, actor budget, effects level) so weak GPUs can still run;
##   - audio           → master / music / sfx linear volumes (0..1).
##
## Persistence is a human-editable ConfigFile at `user://game_settings.cfg` (load_or_default / save).
##
## APPLICATION INTERFACE (for a later task — do NOT wire the sim here): the sim consumes a settings
## object through `LAGameMode.apply(settings)`, which stores it as the active settings and emits
## `LAGameMode.settings_applied(settings)`. A future VoxelWorld pass reads `grid_resolution` /
## `actor_budget` / `effects_level` / `disaster_frequency` / `climate_harshness` off the resource
## and pushes them into the field/spawn/disaster systems. This file only DEFINES and PERSISTS the
## values; it never reaches into simulation code. (Explicit types only — no ':=' inferred typing.)

enum Difficulty { PEACEFUL, NORMAL, HARSH }
enum Quality { LOW, MEDIUM, HIGH }
enum EffectsLevel { LOW, MEDIUM, HIGH }

const SAVE_PATH: String = "user://game_settings.cfg"

# --- Difficulty ---
@export var difficulty: Difficulty = Difficulty.NORMAL
@export var disaster_frequency: float = 0.5   ## 0 = calm .. 1 = frequent disasters
@export var climate_harshness: float = 0.5    ## 0 = mild .. 1 = extreme climate swings

# --- Quality / performance ---
@export var quality: Quality = Quality.MEDIUM
@export var grid_resolution: int = 72         ## field cells per axis budget (Medium → 24 cells/face)
@export var actor_budget: int = 120           ## max concurrent actors
@export var effects_level: EffectsLevel = EffectsLevel.MEDIUM

# --- Audio (linear 0..1) ---
@export var master_volume: float = 0.9
@export var music_volume: float = 0.7
@export var sfx_volume: float = 0.8

# Difficulty preset → (disaster_frequency, climate_harshness). The preset seeds the knobs; the
# player may then fine-tune the two sliders independently.
const DIFFICULTY_PRESETS: Dictionary = {
	Difficulty.PEACEFUL: {"disaster_frequency": 0.10, "climate_harshness": 0.15},
	Difficulty.NORMAL: {"disaster_frequency": 0.50, "climate_harshness": 0.50},
	Difficulty.HARSH: {"disaster_frequency": 0.85, "climate_harshness": 0.85},
}

# Quality preset → concrete perf budgets. Low is the weak-GPU floor.
# grid_resolution maps to the cubed-sphere field's cells-per-face (÷3): the field STEP is the single biggest
# frame cost (a per-cell GPU CA + per-step full-grid readback), so this dial dominates the frame-rate. Medium
# was 96 (32 cells/face → ~19 fps at 720p on a mid GPU); 72 (24 cells/face) roughly quadruples that to a
# playable ~85 fps while keeping the ecosystem in the same healthy, renewable regime (verified: population
# still settles ~125-130 with herds + predator-prey + forest succession intact). High keeps the fine grid for
# strong GPUs; Low is the weak-GPU floor.
const QUALITY_PRESETS: Dictionary = {
	Quality.LOW: {"grid_resolution": 48, "actor_budget": 48, "effects_level": EffectsLevel.LOW},
	Quality.MEDIUM: {"grid_resolution": 72, "actor_budget": 120, "effects_level": EffectsLevel.MEDIUM},
	Quality.HIGH: {"grid_resolution": 128, "actor_budget": 240, "effects_level": EffectsLevel.HIGH},
}


## Apply a difficulty preset: set the enum and seed the two continuous knobs from the table.
func apply_difficulty_preset(preset: Difficulty) -> void:
	difficulty = preset
	var row: Dictionary = DIFFICULTY_PRESETS.get(preset, DIFFICULTY_PRESETS[Difficulty.NORMAL])
	disaster_frequency = float(row["disaster_frequency"])
	climate_harshness = float(row["climate_harshness"])


## Apply a quality preset: set the enum and the concrete perf budgets it maps to.
func apply_quality_preset(preset: Quality) -> void:
	quality = preset
	var row: Dictionary = QUALITY_PRESETS.get(preset, QUALITY_PRESETS[Quality.MEDIUM])
	grid_resolution = int(row["grid_resolution"])
	actor_budget = int(row["actor_budget"])
	effects_level = int(row["effects_level"]) as EffectsLevel


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
	settings.quality = int(config.get_value("quality", "preset", settings.quality)) as Quality
	settings.grid_resolution = int(config.get_value("quality", "grid_resolution", settings.grid_resolution))
	settings.actor_budget = int(config.get_value("quality", "actor_budget", settings.actor_budget))
	settings.effects_level = int(config.get_value("quality", "effects_level", settings.effects_level)) as EffectsLevel
	settings.master_volume = float(config.get_value("audio", "master_volume", settings.master_volume))
	settings.music_volume = float(config.get_value("audio", "music_volume", settings.music_volume))
	settings.sfx_volume = float(config.get_value("audio", "sfx_volume", settings.sfx_volume))
	return settings


## Persist to the ConfigFile. Returns OK on success.
func save() -> int:
	var config: ConfigFile = ConfigFile.new()
	config.set_value("difficulty", "preset", int(difficulty))
	config.set_value("difficulty", "disaster_frequency", disaster_frequency)
	config.set_value("difficulty", "climate_harshness", climate_harshness)
	config.set_value("quality", "preset", int(quality))
	config.set_value("quality", "grid_resolution", grid_resolution)
	config.set_value("quality", "actor_budget", actor_budget)
	config.set_value("quality", "effects_level", int(effects_level))
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	return config.save(SAVE_PATH)


## A compact human-readable snapshot (for logs / the settings-saved confirmation line).
func summary() -> String:
	return "difficulty=%d disaster=%.2f climate=%.2f quality=%d grid=%d actors=%d fx=%d vol[m=%.2f mu=%.2f s=%.2f]" % [
		int(difficulty), disaster_frequency, climate_harshness,
		int(quality), grid_resolution, actor_budget, int(effects_level),
		master_volume, music_volume, sfx_volume,
	]
