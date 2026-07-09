class_name LAVoxelSettingsApplier
extends Node

## LAVoxelSettingsApplier — the ONE bridge from the front-end LAGameSettings (carried on the GameMode
## autoload) into the live simulation. VoxelWorld stays a thin composition root; this module owns the
## whole "apply the player's settings" concern so no application logic accretes into the hub.
##
## It reads GameMode.settings on boot and resolves them into concrete sim knobs:
##   • quality → grid_resolution : the cubed-sphere field's per-face cell resolution (build-time — read
##     BEFORE the field is built) so a Low preset runs a smaller grid on weak GPUs.
##   • quality → actor_budget    : a spawn-count scale the initial-spawn controller multiplies its base
##     counts by (fewer actors on Low, more on High).
##   • quality → effects_level   : a particle-density scale pushed to the atmosphere particle system.
##   • difficulty → disaster_frequency : the cadence of an AMBIENT natural-events director that SEEDS the
##     existing VoxelDisasters casts (lightning / storm / tornado / hurricane / volcano). It invents no
##     new physics — the disaster actors are seeds/markers/visuals and the field carries the phenomena;
##     this only decides how often a seed is dropped, scaled by the difficulty.
##   • difficulty → climate_harshness : biases WHICH disaster the director seeds (mild → lightning /
##     storms; extreme → volcano / hurricane / tornado).
##
## Grid resolution + spawn counts can only take effect at world build, so VoxelWorld/SpawnController QUERY
## the resolved values here before building; audio volumes are applied by LAVoxelAudioController; cadence
## and effects apply live and re-apply on GameMode.settings_applied. (Explicit types only — no ':=' .)

## Quality grid_resolution (48/96/128) maps to the field's per-face cell resolution. Medium (96) keeps the
## historical 32 cells/face, so 96/3 == 32 is the pivot; Low → 16, High → ~43.
const GRID_RES_DIVISOR: float = 3.0
const GRID_FACE_MIN: int = 8
const GRID_FACE_MAX: int = 64
const GRID_DEPTH: int = 20                 # radial shell depth (kept constant so the shell spans the same band)

## actor_budget that maps to spawn_scale == 1.0 (the Medium preset). Low (48) → 0.4, High (240) → 2.0.
const BASELINE_ACTOR_BUDGET: float = 120.0
const SPAWN_SCALE_MIN: float = 0.15
const SPAWN_SCALE_MAX: float = 4.0

## Ambient-disaster cadence: mean seconds between seeded events, interpolated by disaster_frequency
## (0..1). At frequency 1 a disaster is seeded roughly every DISASTER_INTERVAL_FAST s, at ~0 every
## DISASTER_INTERVAL_SLOW s; below DISASTER_FREQ_OFF the director is disabled entirely (a calm world).
const DISASTER_INTERVAL_FAST: float = 5.0
const DISASTER_INTERVAL_SLOW: float = 90.0
const DISASTER_FREQ_OFF: float = 0.03
const DISASTER_JITTER: float = 0.35        # ± fraction of the interval added as randomness

var _settings: LAGameSettings = null

# Live-binding refs (set in bind(), after the disaster/terrain/particle systems exist).
var _world: Node = null
var _disasters: Node = null
var _terrain = null

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
	publish_globals()


func settings() -> LAGameSettings:
	if _settings == null:
		read_settings()
	return _settings


# --- Build-time queries (VoxelWorld / SpawnController read these before building) ---

## Cubed-sphere per-face cell resolution from the quality grid_resolution budget.
func grid_res_per_face() -> int:
	return clampi(int(round(float(settings().grid_resolution) / GRID_RES_DIVISOR)), GRID_FACE_MIN, GRID_FACE_MAX)


## Radial shell depth (constant for now — resolution scales laterally only).
func grid_depth() -> int:
	return GRID_DEPTH


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


## Resolved RENDER-QUALITY flags for the heavy full-screen / fill-rate effects, now read from the INDIVIDUAL
## graphics knobs (each is its own control in the Graphics settings section) rather than one bundled level.
## Profiling showed these — NOT the actor count — dominate the default frame time: an alpha-blended
## planet-filling ocean shell (~40 ms of transparent overdraw at 720p), SSAO + HDR glow (full-screen post
## passes that scale with resolution), and PSSM sun shadows (a second scene pass). So the DEFAULT (Medium)
## preset leaves them OFF for a playable frame-rate and only High/Ultra turn them on. Consumed by
## LAVoxelSkyCycle (env/sun) + LAOceanPlane at build time.
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


# --- Simulation / AI (CPU) resolved knobs. These are consumed by systems owned elsewhere (creature
# cognition, the LLM director, the field step), so the applier PUBLISHES them as Engine metadata globals the
# owning systems read, keeping this module free of their code. The queries below also expose them directly. ---

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


# --- Live binding (cadence + effects + re-apply) ---

## Wire the live systems once they exist (called near the end of VoxelWorld._ready). Applies the particle
## density, arms the ambient-disaster cadence, and subscribes to GameMode.settings_applied so a mid-game
## Save re-applies the live knobs.
func bind(world: Node, disasters: Node, terrain, water: Node) -> void:
	_world = world
	_disasters = disasters
	_terrain = terrain
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
	print("SETTINGS_APPLIED={grid_res:%d, grid_face:%d, grid_depth:%d, effects:%d, actor_budget:%d, spawn_scale:%.2f, particle:%.2f, ssao:%s, glow:%s, shadows:%s, ocean_transparent:%s, fog:%s, veg:%.2f, draw:%.0f, ai_tick:%d, llm_cadence:%.1f, field_cadence:%d, disaster_freq:%.2f, disaster_interval:%.1f, climate:%.2f, ambient:%s}" % [
		settings().grid_resolution, grid_res_per_face(), grid_depth(), int(settings().effects_level),
		settings().actor_budget, spawn_scale(), particle_scale(),
		str(ro["ssao"]), str(ro["glow"]), str(ro["sun_shadows"]), str(ro["ocean_transparent"]), str(ro["fog"]),
		vegetation_scale(), draw_distance(), ai_tick_frames(), llm_cadence(), field_cadence(),
		settings().disaster_frequency, _disaster_interval, settings().climate_harshness, str(_ambient_enabled)])


func _on_settings_applied(new_settings: LAGameSettings) -> void:
	if new_settings != null:
		_settings = new_settings
	publish_globals()
	_recompute_disaster_cadence()


func _recompute_disaster_cadence() -> void:
	var freq: float = clampf(settings().disaster_frequency, 0.0, 1.0)
	_ambient_enabled = freq > DISASTER_FREQ_OFF and not OS.has_environment("LA_NO_AMBIENT_DISASTERS")
	_disaster_interval = lerpf(DISASTER_INTERVAL_SLOW, DISASTER_INTERVAL_FAST, freq)
	# First seed lands at roughly half the interval so a harsh world proves its cadence early.
	_disaster_next = _disaster_interval * 0.5
	_disaster_accum = 0.0


# --- Ambient-disaster cadence (the difficulty director) ---

func _process(delta: float) -> void:
	if not _bound or not _ambient_enabled or _disasters == null:
		return
	# Hold the clock until the world is actually alive (initial spawn done) so seeds land in a populated world.
	if get_tree() == null or get_tree().get_nodes_in_group("creature").is_empty():
		return
	_disaster_accum += delta
	if _disaster_accum < _disaster_next:
		return
	_disaster_accum = 0.0
	_disaster_next = _disaster_interval * (1.0 + randf_range(-DISASTER_JITTER, DISASTER_JITTER))
	_seed_ambient_disaster()


## Seed one disaster, its kind weighted by climate_harshness, at a fitting site. Uses only the camera-neutral
## VoxelDisasters spawns (no camera-hijacking auto-cast), so an ambient event never yanks the player's view.
func _seed_ambient_disaster() -> void:
	var kind: String = _pick_disaster_kind(clampf(settings().climate_harshness, 0.0, 1.0))
	match kind:
		"lightning":
			if _disasters.has_method("strike_random_lightning"):
				_disasters.strike_random_lightning()
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


## Weighted pick: mild climates lean to lightning/storms, harsh climates open up the destructive events.
## Config over branches — a new event kind is one row.
func _pick_disaster_kind(climate: float) -> String:
	var weights: Dictionary = {
		"lightning": 3.0,
		"thunderstorm": 2.0,
		"tornado": 1.0 + 2.0 * climate,
		"hurricane": 0.5 + 2.5 * climate,
		"volcano": 0.3 + 1.5 * climate,
	}
	var total: float = 0.0
	for k in weights:
		total += float(weights[k])
	var roll: float = randf() * total
	for k in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			return String(k)
	return "lightning"


## A random world-space point on the planet surface (falls back to a point above the centre if unmeshed).
func _random_surface_point() -> Vector3:
	var dir: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
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
