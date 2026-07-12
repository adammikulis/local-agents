class_name LAVoxelSpawnController
extends Node

## LAVoxelSpawnController — owns the INITIAL ecology/actor spawning: the "terrain ready" gate, the starting
## counts, forest/rock population, aquatic stocking, the geothermal core seed, and the persistent river
## springs (seed_water). Factored out of LAVoxelWorld so the "more actors / forests" concern is one file.
## The world composition root ticks try_spawn() each frame until the surface has meshed. (Explicit types.)

# A visibly BUSY world: land herbivores forage the emergent forests, predators/scavengers scale with the
# prey/carrion base, birds fill the sky. Far actors self-throttle via the creatures' distance-graded think
# LOD (Creature._think_stride), so a populous world stays playable — raise counts, don't cap the world small.
# Predator↔prey ratio: foxes ≈ rabbits/5, vultures track the bird/carrion base. The mix is a PYRAMID —
# lots of vegetation + small herbivores (rabbit, mouse) + mid consumers (bird, swallow insectivore), fewer
# predators (fox) / scavengers (vulture). The aquatic web base (bug/shrimp) is stocked separately, in water.
# The LAND-invertebrate base — cheap/numerous insects (beetle/ant/grasshopper ground herbivores; butterfly/
# fly/bee flyers) — broadens the web bottom and feeds the birds; flowers + a shrub add vegetation variety and
# the nectar bees pollinate. All are ordinary config species (diet/plant data files); no special spawn code.
const INITIAL_COUNTS: Dictionary = {
	"plant": 260, "shrub": 28, "flower_daisy": 36, "flower_clover": 26,
	# TOXIC vegetation is a deliberate MINORITY (nightshade/deathcap) among the wholesome majority above — enough
	# for a grazer to meet, learn from, and avoid, without denting a herd that thrives on the wholesome plants.
	"nightshade": 14, "deathcap": 10,
	"rabbit": 90, "mouse": 12, "fox": 10, "bird": 55, "swallow": 10, "villager": 12, "vulture": 12,
	"beetle": 10, "ant": 12, "grasshopper": 10, "butterfly": 10, "fly": 12, "bee": 14,
}
# Vegetation kinds (density-scaled by the graphics foliage knob, like the base plant) — flowers + shrub + the
# toxic plants all ride it too (they are ordinary config vegetation; only their `toxic` data value differs).
const VEG_KINDS: Array = ["plant", "shrub", "flower_daisy", "flower_clover", "nightshade", "deathcap"]
const ROCK_COUNT: int = 60
# Many forest SEEDS scattered onto the best (warm/fertile) ground; groves then DENSIFY emergently over the
# run wherever photosynthesis has built biomass (see LAEcologyService._tick_tree_seeding), thinning at the
# cold/snowy poles where the treeline gate blocks germination. Forests are a consequence of the chemistry.
const FOREST_CLUSTERS: int = 16

# CAMPAIGN start drops the player right in with a single RABBIT HERD and nothing else living — no plants, no
# trees (rabbit ≤ HERD_CLUSTER_SIZE ⇒ exactly one founder cluster, so the herd is all in one place), so the
# player opens face-to-face with the animals they are responsible for and grows the vegetation/world from a
# clean slate (every plant/population objective genuinely begins below its threshold). Sandbox keeps the full
# founding ecology (INITIAL_COUNTS above). Data-driven — tune these counts, no spawner rewrite.
const CAMPAIGN_INITIAL_COUNTS: Dictionary = {
	"rabbit": 12,
}
const CAMPAIGN_ROCK_COUNT: int = 10
const CAMPAIGN_FOREST_CLUSTERS: int = 0

var _world: Node = null
var _body: Node3D = null
var _terrain = null
var _ecology: Node = null
var _camera: Camera3D = null
var _material: Node = null
var _hud: CanvasLayer = null
var _disasters: Node = null

var _spawned_initial: bool = false
var _ready_wait_ticks: int = 0
# Multiplier on the base counts below, set from the quality actor_budget (VoxelSettingsApplier.spawn_scale).
# 1.0 == the Medium preset; Low shrinks the world, High grows it. Weak GPUs run fewer actors.
var _spawn_scale: float = 1.0


func setup(world: Node, body: Node3D, terrain, ecology: Node, camera: Camera3D, material: Node, hud: CanvasLayer, disasters: Node) -> void:
	_world = world
	_body = body
	_terrain = terrain
	_ecology = ecology
	_camera = camera
	_material = material
	_hud = hud
	_disasters = disasters


func is_spawned() -> bool:
	return _spawned_initial


## SAVE-LOAD: mark the initial population as already spawned so try_spawn() is a no-op. A loaded world already
## carries its own creatures/vegetation (restored by LAWorldSaveController) — seeding a fresh founding stock on
## top would double the population and desync it from the restored kinship/field.
func suppress_initial_spawn() -> void:
	_spawned_initial = true


## Scale factor applied to the base spawn counts (from the quality actor_budget). Set before the surface
## meshes so the first (and only) spawn uses it.
func set_spawn_scale(scale: float) -> void:
	_spawn_scale = maxf(0.05, scale)


## Spawn the starting ecology once terrain has streamed + collided at the surface. Idempotent — returns
## immediately once spawned. Called each frame from the world's _process. The planet is the SOLE world, so
## the old flat-island branch (caves, flat spring seeding, scripted volcano, vista framing) is gone — the
## unused view-mode params are kept only for the world's fixed call signature.
func try_spawn(_overview: bool, _farview: bool, _auto_meteor: bool, _auto_select: bool) -> void:
	if _spawned_initial or _body == null:
		return
	# Gate on the surface being meshed. On a planet, "ready" = the top-of-planet patch has collided.
	var ready_probe: Vector3 = _body.center() + Vector3.UP * (_body.radius() + 30.0)
	if not _body.is_ready_at(ready_probe):
		return
	_ready_wait_ticks += 1
	if _ready_wait_ticks <= 6:
		return
	LASimReport.reset()
	# Radial world: ecology places life ON the sphere (surface_point spawn), fish in the sea shell; the
	# orbit camera frames the body; the planet centre is pinned hot for the radial geothermal gradient.
	if _is_campaign():
		# Ground-level start: one rabbit herd and nothing else living — no plants/trees (the player grows the
		# vegetation) and no aquatic stocking (fish are a locked spawn). The camera opens ON the herd below.
		_ecology.spawn_initial(CAMPAIGN_INITIAL_COUNTS)
		_ecology.populate_environment(CAMPAIGN_ROCK_COUNT, CAMPAIGN_FOREST_CLUSTERS)
	else:
		_ecology.spawn_initial(_scaled_counts())
		# Forest seed clusters scale by BOTH the actor budget and the graphics vegetation-density knob
		# (la_vegetation_scale), so a low-foliage setting thins the groves and a high one densifies them.
		_ecology.populate_environment(ROCK_COUNT, maxi(1, int(round(float(FOREST_CLUSTERS) * _spawn_scale * _vegetation_scale()))))
		if _ecology.has_method("stock_initial_aquatic"):
			_ecology.stock_initial_aquatic()
	if _camera.has_method("set_orbit_target"):
		_camera.set_orbit_target(_body.center(), _body.radius())
	# CAMPAIGN opens looking AT the herd: aim the orbit camera at the rabbit cluster (the close approach arc then
	# frames them at eye level). orient_toward clears the deferred sunnyside so the herd aim wins.
	if _is_campaign() and _camera.has_method("orient_toward"):
		var herd_dir: Vector3 = _campaign_herd_dir()
		if herd_dir != Vector3.ZERO:
			_camera.orient_toward(herd_dir)
	if _material.has_method("add_magma_source"):
		# Geothermal core pin — a genuinely HOT magma core (deep mantle temperature) so deep melt + emergent
		# volcanoes are dramatic. This coexists with a temperate habitable surface because the field ThermalPass
		# now insulates: heat_sphere3d.glsl conducts through SOLID rock ~6× slower than through open air/water
		# (per-bond ROCK_CONDUCT vs VOID_CONDUCT), so the core heat rises through the crust SLOWLY (a steep
		# geothermal gradient near the core, gentle near the surface) while the outermost open cells shed their
		# heat to space via the solar/radiative pass — the surface equilibrates to the ~15-30°C ambient band,
		# well under creatures' 50°C lethal-heat limit. (Was pinned to 150°C as an interim fix when the crust
		# conducted uniformly and a hot core baked the surface to ~110°C, killing the ecosystem.)
		_material.add_magma_source(_body.center(), 1300.0, 0.6)
	_seed_diseases()
	_spawned_initial = true
	_hud.set_status("World ready — spawn things, click to inspect, press V for scent.")


# Seed a few PATIENT-ZERO infections so outbreaks are part of the living world (they then spread, cull, and
# leave immune survivors — all emergent from LACreatureDisease). Sandbox seeds a handful; campaign seeds none
# by default (the player's small starter herd grows disease-free until a pest/contact introduces it). Override
# with LA_DISEASE_SEED=N (0 disables — e.g. for a clean perf run). Each seed infects a random creature with a
# random strain the strain library knows; host-incompatible picks are simply shrugged off by infect().
const DISEASE_SEED_SANDBOX: int = 3

func _seed_diseases() -> void:
	var count: int = DISEASE_SEED_SANDBOX if not _is_campaign() else 0
	var env: String = OS.get_environment("LA_DISEASE_SEED")
	if env != "":
		count = maxi(0, int(env))
	if count <= 0:
		return
	var strains: Array = LADiseaseLibrary.known_strains()
	if strains.is_empty():
		return
	var creatures: Array = get_tree().get_nodes_in_group("creature")
	if creatures.is_empty():
		return
	var forced: String = OS.get_environment("LA_DISEASE_STRAIN")   # test hook: seed only this strain
	var seeded: int = 0
	for i in range(count):
		var c = creatures[LASimRng.shared().randi_range(0, creatures.size() - 1)]
		if not is_instance_valid(c) or c.get("disease") == null:
			continue
		var strain_id: String = forced if forced != "" else String(strains[LASimRng.shared().randi_range(0, strains.size() - 1)])
		c.disease.infect(strain_id, 0.6)               # a solid starting dose so the infection establishes
		seeded += 1
	print("DISEASE_SEED={seeded:%d, strains:%d}" % [seeded, strains.size()])


## True in CAMPAIGN mode (progression gating on) — the initial spawn is sparse so the player grows the world.
## Sandbox, or no progression instance at all (isolated tools/tests), keeps the full founding ecology.
func _is_campaign() -> bool:
	var prog: LAGameProgression = LAGameProgression.active()
	return prog != null and not prog.is_sandbox()


## Average world direction (planet centre → creatures) of the freshly-spawned campaign herd, so the camera can
## open looking straight at it. Reads the "creature" group the rabbits joined on spawn; ZERO if none placed yet
## (e.g. a founder site that meshed late and queued) — the caller then just keeps the default framing.
func _campaign_herd_dir() -> Vector3:
	if _body == null:
		return Vector3.ZERO
	var center: Vector3 = _body.center()
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for node in get_tree().get_nodes_in_group("creature"):
		if node is Node3D:
			sum += (node as Node3D).global_position - center
			n += 1
	if n == 0:
		return Vector3.ZERO
	return sum.normalized()


## Graphics vegetation-density knob (la_vegetation_scale, published by LAVoxelSettingsApplier from the
## Graphics settings). Default/missing → 1.0 (untouched ecosystem balance). Only the "plant" spawn count and
## the forest-cluster seeding read this; creature counts are governed solely by the actor budget. Read once
## at spawn time (initial spawning is a one-shot gate).
func _vegetation_scale() -> float:
	var v: float = float(Engine.get_meta("la_vegetation_scale", 1.0)) if Engine.has_meta("la_vegetation_scale") else 1.0
	return clampf(v, 0.1, 2.0)


## The base counts scaled by the quality actor_budget factor (at least one of each). The "plant" count also
## carries the graphics vegetation-density knob, so foliage thins/densifies independently of the actor budget.
func _scaled_counts() -> Dictionary:
	var veg: float = _vegetation_scale()
	var bench: float = LAAblate.spawn_scale()   # LA_SPAWN_SCALE benchmark knob (1.0 unless set)
	if is_equal_approx(_spawn_scale * bench, 1.0) and is_equal_approx(veg, 1.0):
		return INITIAL_COUNTS
	var counts: Dictionary = {}
	var total: int = 0
	for kind in INITIAL_COUNTS:
		var factor: float = _spawn_scale * bench * (veg if VEG_KINDS.has(kind) else 1.0)
		var n: int = maxi(1, int(round(float(INITIAL_COUNTS[kind]) * factor)))
		counts[kind] = n
		total += n
	print("SPAWN_SCALE={factor:%.2f, veg:%.2f, total:%d}" % [_spawn_scale, veg, total])
	return counts
