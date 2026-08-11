class_name LAEcologyService
extends Node

# Drives the living world: spawning, predator-prey population dynamics, breeding
# with population caps, herd cohesion (delegated to creatures), and plant seeding.
# Every actor is placed on the terrain surface via LAVoxelTerrainService.

const CreatureScript: GDScript = preload("res://addons/local_agents/creatures/Creature.gd")
const PlantScript: GDScript = preload("res://addons/local_agents/sim/actors/Plant.gd")
const RockScript: GDScript = preload("res://addons/local_agents/sim/actors/Rock.gd")
const TreeScript: GDScript = preload("res://addons/local_agents/sim/actors/Tree.gd")
const FishScript: GDScript = preload("res://addons/local_agents/creatures/Fish.gd")
const TrackSystemScript: GDScript = preload("res://addons/local_agents/sim/TrackSystem.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "fish", "rock", "tree"]

# Every creature/fish this service spawns joins this group, which is the default `adopt_group` of
# LocalAgentCognitionScheduler. That is what lets a scheduler dropped into a scene from the inspector
# wire itself to the whole population with no code (this service also injects its own directly).
const COGNITION_GROUP: StringName = &"la_creatures"

# A LIVING sea: scale every aquatic species' starting count AND its population cap by this factor so the
# ocean/lakes teem instead of trickling. Data files stay the single source of the per-species ratios; this
# is the one owned dial that makes the water busy without editing eight species files.
const AQUATIC_STOCK_MULT: float = 2.6

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _tracks = null                       # LATrackSystem (observer; footprints)
var _material = null                      # LAMaterialField — the ONE substrate (water/heat/materials)
var _cognition_sched = null              # LocalAgentCognitionScheduler (shared slow-brain budget/queue)
var _llm_service = null                  # shared LocalAgentLlmService node; null/offline = teacher-only
var _veg_renderer = null                 # LAVegetationRenderer — plants/trees render through its batched MultiMesh
# Extracted single-owner modules this thin hub delegates to (it stays a facade + step-orchestration):
var _stimulus: LAEcologyStimulus = null  # stimulus/broadcast bus (disturb/seismic/blast/scare/call/wind)
var _spawner: LAEcologySpawner = null    # spawn/population placement (spawn, initial seeding, forests, nests)
var _breeding: LAEcologyBreeding = null  # reproduction/population dynamics (land + aquatic breeding, lineage)
var _plants: LAEcologyPlants = null      # vegetation seeding (plant spread + forest succession)
var _aquatic: LAEcologyAquatic = null    # non-repro aquatic placement (initial stock + depth-band sampler)

# NIGHT IS A PLACE, NOT A CLOCK. On a sphere lit by a real sun there is no global "time of day": half the
# world is lit and half is dark at every instant, and which half you are in depends on where you stand.
#
# This replaced a global `time_of_day: float = 0.3` plus an `is_night()` that compared it to dusk/dawn
# thresholds. That scalar was FROZEN AT ITS SEED VALUE FOR THE WHOLE RUN: LAVoxelSkyCycle latches
# `_planet_mode` permanently and its `_update_day_night()` returns before `_advance_clocks(delta)` is ever
# reached, because in planet mode day/night is supposed to come from the planet turning under a fixed sun.
# So `is_night()` answered FALSE forever, and the damage was silent and everywhere:
#   * diurnal animals never entered a rest period, and nocturnal ones never left one (Creature._rest_period)
#   * the night sense multiplier (nocturnal 1.4 / diurnal 0.7) never applied to anyone
#   * the `night` bit in the learned-policy signature was a constant, so half the signature space was
#     unreachable and every heuristic any creature ever learned was a daytime heuristic
#   * LACreatureLod's cost model documents "a fraction of the population is always asleep". It was not.
#
# The terminator was physical the whole time: LASystemOrbits computes the planet->sun vector, and the field's
# solar kernel already lights cells with max(0, dot(cell_radial, sun_dir)). This asks the same question the
# substrate already answers, per creature, and keeps no state that can go stale.
var _sun_dir: Vector3 = Vector3.ZERO      # unit planet-centre -> sun; zero length = no sun known yet
var _sun_centre: Vector3 = Vector3.ZERO   # the body the local `up` is measured from


## Publish the real sun geometry (the world calls this each frame). `dir` is the unit vector from the planet
## centre toward the star, `centre` is that planet centre. A flat or sunless world simply never calls it and
## every query below answers "day" — the right default for a world with no terminator.
func set_sun(dir: Vector3, centre: Vector3) -> void:
	_sun_dir = dir
	_sun_centre = centre


## Is `pos` on the dark side? Local up is the outward radial from the planet centre, so this is exactly "is
## the sun below my horizon". Dusk and dawn need no thresholds — the dot product crosses zero by itself.
func is_night_at(pos: Vector3) -> bool:
	if _sun_dir.length_squared() < 0.0001:
		return false
	var up: Vector3 = pos - _sun_centre
	if up.length_squared() < 0.000001:
		return false
	return up.normalized().dot(_sun_dir) < 0.0

# pending spawns whose surface wasn't ready yet: [{kind, pos, tries}]
var _pending: Array = []
var _seed_timer: float = 0.0
var _fish_timer: float = 0.0
var _tree_timer: float = 0.0             # forest succession: groves densify on biomass-rich ground
# THE ACTOR-SIDE CLOCK, published so the world's two halves can be compared instead of argued about. Every
# node in the tree (this service, every creature, every plant) is handed the full physics delta; the
# substrate is handed the same delta and keeps only what its own step ceiling allows. A clock mismatch shows
# up as `eco_sim_s` here running ahead of `field_sim_s` (LAMaterialFieldSphereStep3D).
var _eco_s: float = 0.0
var _phys_frames: int = 0
var _aquatic_kinds_cache: Array = []     # aquatic species ids (config aquatic:true), indexed once
var _aquatic_indexed: bool = false
var _land_kinds_cache: Array = []        # land creature species ids (has diet, not aquatic), indexed once
var _land_indexed: bool = false
# Permanent kinship graph backing every creature's family_id. A family is a connected component; family_id is
# its stable label. Founder clusters allocate a fresh label (LAKinshipGraph.new_family) and offspring inherit
# their parent's component at birth — bonds are recorded once, never rewritten. Updated only on the
# founding/birth/death events (never per frame); kin recognition reads the cheap family_id, not the graph.
var _kinship: LAKinshipGraph = LAKinshipGraph.new()


# The permanent kinship graph (owned here; the field/world hubs stay extract-only).
func kinship() -> LAKinshipGraph:
	return _kinship


## Wipe the live population + registries back to the fresh-but-initialized state, so a saved snapshot can be
## restored IN PLACE (no scene reload) — used by the timeline rewind/fork. Frees every actor node (creatures,
## fish, vegetation, rocks, nests, disaster markers — all carry GROUP_SELECTABLE) and resets the kinship graph;
## vegetation actors release their renderer slots on _exit_tree, so the batched MultiMesh recycles them. The
## field is restored separately by the caller. Lazy species-kind caches are left (immutable, config-derived).
func reset_world() -> void:
	if actors_root == null:
		return
	var tree: SceneTree = actors_root.get_tree()
	if tree == null:
		return
	var seen: Dictionary = {}
	for grp in ["creature", "fish", "selectable"]:
		for a in tree.get_nodes_in_group(grp):
			if a is Node and is_instance_valid(a) and not seen.has(a.get_instance_id()):
				seen[a.get_instance_id()] = true
				a.queue_free()
	# Fresh kinship graph — apply_actors rebuilds families from the snapshot's saved edges.
	_kinship = LAKinshipGraph.new()
	# Drop any queued spawn work so it can't spawn into the restored world.
	_pending.clear()

# --- Seismic / shock stimulus (emergent camera shake) ------------------------
# Ground disturbances now inject into the field's PROPAGATING shock wave (LAMaterialShock3D); the camera
# reads seismic_energy_at() (→ field.shock_at) and shakes. No local ring — the wave carries it (see below).


# --- species / plant configs ------------------------------------------------
func _species_config(kind: String) -> Dictionary:
	# Species stats live in per-type DATA files under data/species/<class>/<kind>.json, kept OUT of
	# this business logic so a creature can be retuned by editing one small file (see LASpeciesLibrary).
	return LASpeciesLibrary.load_config(kind)


# Every species whose data file is flagged `aquatic: true` (fish variants, turtle, crab, whale, …).
# Indexed once from the species library; drives all aquatic stocking generically — no hardcoded list.
func _aquatic_kinds() -> Array:
	if _aquatic_indexed:
		return _aquatic_kinds_cache
	_aquatic_indexed = true
	_aquatic_kinds_cache = []
	for kind in LASpeciesLibrary.known_kinds():
		var cfg: Dictionary = LASpeciesLibrary.load_config(String(kind))
		if bool(cfg.get("aquatic", false)):
			_aquatic_kinds_cache.append(String(kind))
	return _aquatic_kinds_cache


# Every LAND creature species (has a `diet`, not flagged aquatic) — the set the population-dynamics breeding
# loop drives. Indexed once from the species library so a NEW land species (its JSON dropped in) breeds and
# recovers automatically, with no hardcoded roster to edit. Aquatic species are stocked separately (below);
# plants/rocks/trees have no `diet` and are excluded.
func _land_kinds() -> Array:
	if _land_indexed:
		return _land_kinds_cache
	_land_indexed = true
	_land_kinds_cache = []
	for kind in LASpeciesLibrary.known_kinds():
		var cfg: Dictionary = LASpeciesLibrary.load_config(String(kind))
		if not bool(cfg.get("aquatic", false)) and cfg.has("diet"):
			_land_kinds_cache.append(String(kind))
	return _land_kinds_cache


func _plant_config() -> Dictionary:
	return {
		"species": "plant", "color": Color(0.30, 0.66, 0.24),
		"grow_time": 6.0, "max_scale": 2.0, "seed_period": 6.0,
		"edible": true, "pop_cap": 220,
	}


# Plant-family routing: a species DATA file flagged `plant: true` (flowers, shrubs, …) is instanced as an
# LAPlant from its own config — so new vegetation drops in as data, with no _instance_actor type-branch per kind.
func _is_plant_kind(kind: String) -> bool:
	return bool(_species_config(kind).get("plant", false))


# Every vegetation kind that must pass the germination gate + stand radially: trees, the generic plant, and any
# data-flagged plant (flowers/shrubs).
func _is_veg_kind(kind: String) -> bool:
	return kind == "plant" or kind == "tree" or _is_plant_kind(kind)


# The config an LAPlant is built from: the fast hardcoded default for the generic "plant", else the species
# DATA file for a flagged vegetation kind (flowers/shrubs carry their own colour/nectar/pop_cap).
func _veg_config(kind: String) -> Dictionary:
	if kind == "plant":
		return _plant_config()
	var cfg: Dictionary = _species_config(kind)
	return cfg if not cfg.is_empty() else _plant_config()


func setup(_terrain, _actors_root: Node3D) -> void:
	terrain = _terrain
	actors_root = _actors_root
	# Stimulus/broadcast bus (a Node child so it can scan scene groups) + spawn/population placement
	# module (a plain helper reaching back for shared state). Both single-owner; this hub forwards to them.
	_stimulus = LAEcologyStimulus.new()
	_stimulus.name = "EcologyStimulus"
	add_child(_stimulus)
	_stimulus.set_material_field(_material)
	_spawner = LAEcologySpawner.new()
	_spawner.setup(self)
	# Reproduction, vegetation seeding, and non-repro aquatic placement are single-owner helper modules
	# (plain RefCounted, reaching back for shared state); this hub forwards its per-tick calls to them.
	_breeding = LAEcologyBreeding.new()
	_breeding.setup(self)
	_plants = LAEcologyPlants.new()
	_plants.setup(self)
	_aquatic = LAEcologyAquatic.new()
	_aquatic.setup(self)
	# The biosphere's OFF-FIELD carbon, as a registered SIM_REPORT source. Mass a plant node draws out of the
	# field's `biomass` channel into its own tissue leaves the substrate's carbon ledger (`carbon_total` sums
	# co2 + biomass + detritus in the FIELD only), so without these gauges a perfectly conserving draw would
	# read as carbon destroyed and a leak would be indistinguishable from ordinary uptake.
	LASimReport.register(Callable(self, "vegetation_report"))
	_tracks = TrackSystemScript.new()
	_tracks.name = "TrackSystem"
	add_child(_tracks)
	_tracks.setup(terrain)
	# Shared System-2 slow brain (FunctionGemma) with a global call budget; creatures escalate to
	# it rarely and asynchronously. Loaded by path + guarded so the sim still runs on pure fast
	# heuristics + social learning if the scheduler script or model is unavailable.
	var sched_script: GDScript = load("res://addons/local_agents/creatures/cognition/CognitionScheduler.gd")
	if sched_script != null:
		_cognition_sched = sched_script.new()
		_cognition_sched.name = "CognitionScheduler"
		add_child(_cognition_sched)
		if _cognition_sched.has_method("setup"):
			# Route the slow brain through the shared LocalAgentLlmService (set by VoxelWorld via
			# set_llm_service before this setup runs). When it is null or reports itself offline — no
			# model installed, or the service is switched off — the scheduler falls back to the built-in
			# heuristic teacher for every escalation.
			_cognition_sched.setup({"llm_service": _llm_service})


# The ONE substrate: water (creatures drink, fish live in it), heat/temperature (fire + comfort),
# and every material. Disasters inject heat/material; everything else reads it.
func set_material_field(m) -> void:
	_material = m
	if _stimulus != null:
		_stimulus.set_material_field(m)          # the stimulus bus injects ground disturbance / shock into the field
	# The field owns combustion (no separate fire system) and needs to reach back for
	# topple/reseed/scare when it consumes a burning actor.
	if _material != null and _material.has_method("set_ecology"):
		_material.set_ecology(self)


## Wire the shared GPU-instanced vegetation renderer (set by VoxelWorld). Plants/trees register with it at
## spawn instead of owning a MeshInstance, so all vegetation of a type draws in one batched MultiMesh.
func set_vegetation_renderer(r) -> void:
	_veg_renderer = r


func material_field():
	return _material


# Back-compat accessor: fire lives in the material field now (combustion folded in).
func fire_system():
	return _material


# Ground-disturbance + seismic-pulse stimuli live in LAEcologyStimulus (the broadcast bus); these stay
# as thin forwarders for the disaster actors that call them on the service.
func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	_stimulus.disturb_ground(world_pos, radius, strength)


func broadcast_seismic(world_pos: Vector3, magnitude: float) -> void:
	_stimulus.broadcast_seismic(world_pos, magnitude)


# Shock energy felt at world_pos — the propagated field value (proximity + terrain muffling emerge from
# the wave). The camera rig queries this and shakes in proportion.
func seismic_energy_at(world_pos: Vector3) -> float:
	return _material.shock_at(world_pos) if _material != null and _material.has_method("shock_at") else 0.0


# Scene-wide shock intensity (peak) for the energy graph / streamer.
func total_seismic_energy() -> float:
	return _material.shock_peak() if _material != null and _material.has_method("shock_peak") else 0.0


func cognition_scheduler():
	return _cognition_sched


## Inject the shared LocalAgentLlmService BEFORE setup() so the slow-brain scheduler is built with it.
## Null (or an offline service) = the scheduler runs pure heuristic-teacher fallback.
func set_llm_service(service) -> void:
	_llm_service = service


## SIM_REPORT source: where the biosphere's carbon is when it is not in the field.
##
##   veg_food_held    — reserve standing in live plant nodes right now. Add it to `carbon_biomass` for the
##                      planet's real standing crop.
##   veg_food_drawn   — cumulative mass plant nodes have taken OUT of the field's biomass channel.
##   veg_food_returned— cumulative mass handed BACK as detritus when a plant node was removed.
##   veg_seed_cost    — cumulative parent reserve spent on germination (a seedling is built from its parent).
##
## `drawn - returned - (what herbivores ate)` is what is currently standing in plant tissue, so `held` and the
## other three are the closure check: held should never exceed drawn, and returned should never exceed drawn.
func vegetation_report() -> Dictionary:
	var led: LAVegLedger = LAVegLedger.of(_material)
	return {
		"veg_food_held": snappedf(led.food_held, 0.0001),
		"veg_food_drawn": snappedf(led.food_drawn, 0.0001),
		"veg_food_returned": snappedf(led.food_returned, 0.0001),
		"veg_seed_cost": snappedf(led.seed_cost, 0.0001),
	}


# AN IGNITION SOURCE IS NOT A HEAT SOURCE. This used to be `add_heat(world_pos, 900.0, radius)` — nine
# hundred degrees over every cell in the radius, from nothing — and its only caller is
# `VoxelDisasters.gd:245-246`, which fires it at a meteor's impact point the same frame the meteor itself
# deposits its own energy at that point. So it was a SECOND heat source for one event, on top of the first,
# and the comment justifying it ("~3x wood's 300 °C ignition temp") was reasoning about a threshold, not about
# where the energy came from.
#
# It is now a no-op that keeps the call site alive: the impactor's kinetic + thermal energy (Meteor.gd
# `_impact_energy_j`) is the whole heat budget of a strike, and whether it crosses the fuel's ignition
# temperature is for the substrate to decide. If a future caller genuinely needs to start a fire from a
# NAMED store — a dropped torch, a magma contact — it should debit that store and call
# `LAMaterialFieldInject3D.add_heat_energy` with the joules.
func ignite_area(_world_pos: Vector3, _radius: float) -> void:
	pass


# Emergent growth CONDITION (not a hardcoded elevation): a seed only takes where the ground is warm enough
# and not under snow. Because the temperature field cools with altitude (LAPSE) and snow forms on the cold
# summits, this makes the treeline + the bare snow cap EMERGE from the climate — a warm coast forests over,
# frozen peaks stay bare, and the line MOVES if the climate warms/cools. GROW_MIN_TEMP is the germination
# threshold (a property of vegetation, tunable), read against the field — never an elevation number.
const GROW_MIN_TEMP: float = 7.5          # °C below which the ground is too cold for a seed to germinate
const GROW_SNOW_MAX: float = 0.02         # snowpack depth above which the ground is snow-covered (no germination)


# The SKY-EXPOSED open cell one voxel ABOVE a ground point (offset outward along the radial). Biomass,
# snow and near-surface temperature live in that open surface cell, NOT in the solid cell a base-anchored
# actor's exact position maps to — so every climate read below samples here to get the real values.
const SURFACE_PROBE_UP: float = 6.0     # a little over one 5-unit field cell, into the open surface layer
func _air_point(pos: Vector3) -> Vector3:
	if terrain != null and terrain.has_method("up_at"):
		var u: Vector3 = terrain.up_at(pos)
		if u.length() > 0.0001:
			return pos + u.normalized() * SURFACE_PROBE_UP
	return pos + Vector3.UP * SURFACE_PROBE_UP


# Can vegetation take root at `placed`? Reads the field CONDITIONS (temperature + snow cover) in the TRUE
# 3D sky-exposed surface cell (three-d-always — the 2.5D x,z form returns safe defaults on a sphere and never
# gates), so the treeline is emergent: warm snow-free ground greens over, frozen/snow-capped poles stay bare
# and the line MOVES with the climate. True when there is no material field wired yet (boot spawns aren't blocked).
func _can_grow_here(placed: Vector3) -> bool:
	if _material == null:
		return true
	var air: Vector3 = _air_point(placed)
	if _material.has_method("temp_at") and _material.temp_at(air) < GROW_MIN_TEMP:
		return false   # too cold — above the emergent treeline
	if _material.has_method("snow_depth_at") and _material.snow_depth_at(air) > GROW_SNOW_MAX:
		return false   # snow-covered ground
	return true


# Living BIOMASS at a surface point — the emergent photosynthesis product right there (lit, warm, CO₂-rich,
# WATERED ground fixes the most). Forests gate on this so groves densify where the chemistry is most productive
# and stay sparse on cold, dark or dry ground. 0 when no field is wired yet.
#
# This used to reach up the radial to the SHELL TOP (`_shell_top_radius`, r = depth-1, ~78 world-units above the
# terrain) and sample there instead, because R19 photosynthesis was gated GATE_SURFACE and deposited a whole
# column's biomass into its sky-exposed outermost cell. That was a workaround for a misplaced reaction, and it
# forced this query to be a per-COLUMN 2.5D lookup: two points on opposite sides of a ridge, or in and out of a
# valley, read the SAME biomass because they shared a radial. R19 now runs on the ground (GATE_NEAR_GROUND), so
# the honest reading — the biomass at this point — is also the correct one, and it varies point to point.
func _biomass_at(pos: Vector3) -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 0.0
	return _material.biomass_at(pos.x, pos.y, pos.z)


# Spawning + population placement live in LAEcologyStimulus's sibling, LAEcologySpawner. These stay as
# thin forwarders: the public spawn API for external callers, plus the surface/tangent helpers the
# per-tick breeding/seeding below still reuse.
func spawn(kind: String, world_pos: Vector3) -> Node:
	return _spawner.spawn(kind, world_pos)


func spawn_initial(counts: Dictionary) -> void:
	_spawner.spawn_initial(counts)


## SAVE-RESTORE instancing: place an actor at an EXACT saved transform (no surface projection / no water-body
## gate — a saved creature already lived there, so its transform is authoritative). Reuses the normal
## _instance_actor path (so a creature still gets its body, cognition scheduler, material field wiring and the
## tree_exited→kinship.forget hook), then stamps the full saved transform over the placement position. Kinship
## membership is reconstructed separately by the world-save restore (grouped by family), so `family_id` is set
## on the node here but NOT registered as a founder cluster. Returns the node, or null if the kind is unknown.
func restore_actor(kind: String, xform: Transform3D, genome = null, family_id: int = -1) -> Node:
	var node: Node = _instance_actor(kind, xform.origin, genome, -1, true)
	if node != null and node is Node3D:
		(node as Node3D).global_transform = xform
		if family_id >= 0 and "family_id" in node:
			node.set("family_id", family_id)
	return node


func _place_on_surface(world_pos):
	return _spawner._place_on_surface(world_pos)


func _tangent_offset_point(anchor: Vector3, u: float, v: float) -> Vector3:
	return _spawner._tangent_offset_point(anchor, u, v)


# Orient a spawned static actor (tree/plant/rock) so its local +Y points along the radial up at its
# position — otherwise everything would stand parallel to world +Y and lean over as you round the
# globe. Preserves the node's current scale.
func _orient_to_surface(node: Node3D, pos: Vector3) -> void:
	if node == null:
		return
	var up: Vector3 = terrain.up_at(pos)
	if up.length() < 0.001:
		return
	up = up.normalized()
	if node.has_method("set_up"):
		node.set_up(up)
		return
	var ref: Vector3 = Vector3.RIGHT
	if absf(up.dot(ref)) > 0.99:
		ref = Vector3.FORWARD
	var right: Vector3 = ref.cross(up).normalized()
	var fwd: Vector3 = up.cross(right).normalized()
	var scl: Vector3 = node.scale
	node.global_transform = Transform3D(Basis(right, up, fwd), pos)
	node.scale = scl


# True when `placed` sits in water — inside the planet's sea shell (at or below the sea radius).
func _is_water_pos(placed: Vector3) -> bool:
	return (placed - terrain.planet_center()).length() <= terrain.sea_radius()


func _instance_actor(kind: String, placed: Vector3, genome = null, family_id: int = -1, force_place: bool = false) -> Node:
	var node: Node = null
	if kind == "plant" or _is_plant_kind(kind):
		var plant: PlantScript = PlantScript.new()
		actors_root.add_child(plant)
		plant.global_position = placed
		if _veg_renderer != null and plant.has_method("set_vegetation_renderer"):
			plant.set_vegetation_renderer(_veg_renderer)   # render through the batched MultiMesh, not a model child
		plant.setup(terrain, _veg_config(kind))          # generic plant | flower | shrub — all config-driven
		if plant.has_method("set_material_field"):
			plant.set_material_field(_material)          # so it can photosynthesize (fix CO₂ → O₂) into the field
		node = plant
	elif kind == "rock":
		var rock: RockScript = RockScript.new()
		actors_root.add_child(rock)
		rock.global_position = placed
		rock.setup(terrain)
		if rock.has_method("set_material_field"):
			rock.set_material_field(_material)          # so a thrown rock lands as a real amount of sediment
		node = rock
	elif kind == "tree":
		var tree: TreeScript = TreeScript.new()
		actors_root.add_child(tree)
		tree.global_position = placed
		if _veg_renderer != null and tree.has_method("set_vegetation_renderer"):
			tree.set_vegetation_renderer(_veg_renderer)    # render through the batched MultiMesh, not a model child
		tree.setup(terrain, _tree_config())
		if tree.has_method("set_material_field"):
			tree.set_material_field(_material)          # so its growth tracks the carbon its ground fixes
		node = tree
	else:
		var cfg: Dictionary = _species_config(kind)
		if cfg.is_empty():
			push_warning("LAEcologyService: unknown kind '%s'" % kind)
			return null
		# Aquatic species (config aquatic:true) are all driven by the ONE LAFish script — a fish, turtle,
		# crab or whale differ only by config (salinity/depth band, body, speed). They exist only in water.
		if bool(cfg.get("aquatic", false)):
			# force_place (save-restore) skips the water gate: the fish already lived at this exact point (a
			# basking turtle/crab hauled onto the beach, or a swimmer at the waterline) — its transform is
			# authoritative, so re-instance it there rather than dropping it for being momentarily out of the sea.
			if not force_place and not _is_water_pos(placed):
				return null
			var fish: FishScript = FishScript.new()
			# Join the cognition group so a scene-placed scheduler can find it. The ecology injects its own
			# scheduler explicitly below; the group is what lets a scheduler the USER dropped in adopt it.
			fish.add_to_group(COGNITION_GROUP)
			actors_root.add_child(fish)
			fish.global_position = placed
			fish.setup(terrain, _material, cfg)
			# Fish are now living creatures on the SHARED cognition stack — inject the same ecology + slow-brain
			# scheduler land creatures get (is_night for the signature, escalation budget for the fast/slow brain).
			if fish.has_method("set_ecology"):
				fish.set_ecology(self)
			if fish.has_method("set_cognition_scheduler"):
				fish.set_cognition_scheduler(_cognition_sched)
			return fish
		# Founder clusters share a family_id (permanent kin bond). Only applies to the ancestral (null-genome)
		# path — a bred offspring carries its inherited family_id in the genome's base_config instead.
		if family_id >= 0 and genome == null:
			cfg["family_id"] = family_id
		var creature: CreatureScript = CreatureScript.new()
		# Join the cognition group so a scene-placed scheduler can find it. The ecology injects its own
		# scheduler explicitly below; the group is what lets a scheduler the USER dropped in adopt it.
		creature.add_to_group(COGNITION_GROUP)
		actors_root.add_child(creature)
		creature.global_position = placed
		creature.setup(terrain, cfg, genome)          # genome (if bred) drives traits + instincts
		if creature.has_method("set_ecology"):
			creature.set_ecology(self)
		if creature.has_method("set_material_field"):
			creature.set_material_field(_material)
		if creature.has_method("set_cognition_scheduler"):
			creature.set_cognition_scheduler(_cognition_sched)
		# Back family_id with the kinship graph. Founder-cluster members (family_id >= 0) join their shared
		# family component; an offspring already carries its inherited label (registered at the breeding site).
		# On removal (death), the creature forgets itself so the graph stays bounded (event-driven, O(degree)).
		var cid: int = int(creature.get_instance_id())
		if family_id >= 0:
			_kinship.add_member(family_id, cid)
		creature.tree_exited.connect(func() -> void: _kinship.forget(cid))
		node = creature
	# Stand static vegetation/rocks up along the radial on a planet (no-op on flat terrain).
	if node != null and (_is_veg_kind(kind) or kind == "rock"):
		_orient_to_surface(node as Node3D, placed)
	return node


func _tree_config() -> Dictionary:
	var pine: bool = LASimRng.shared().randf() < 0.4
	return {"species": "pine" if pine else "oak"}


# Ambient rock + forest scatter lives in LAEcologySpawner; thin forwarder for the world spawn controller.
func populate_environment(rock_count: int, forest_clusters: int) -> void:
	_spawner.populate_environment(rock_count, forest_clusters)


# Point-blast + area terror/wind stimuli live in LAEcologyStimulus; thin forwarders for the disasters.
func damage_sphere(world_pos: Vector3, radius: float, base_damage: float = 1000.0) -> void:
	_stimulus.damage_sphere(world_pos, radius, base_damage)


func broadcast_scare(world_pos: Vector3, radius: float, base_intensity: float = 1.0) -> void:
	_stimulus.broadcast_scare(world_pos, radius, base_intensity)


func apply_wind_force(world_pos: Vector3, radius: float, force_fn: Callable, delta: float = 0.0) -> void:
	_stimulus.apply_wind_force(world_pos, radius, force_fn, delta)


func _physics_process(delta: float) -> void:
	if LAAblate.off("ecology"):
		return
	if terrain == null or actors_root == null:
		return
	# Publish the actor-side clock (see _eco_s). phys_dt's min/max come free from the gauge, which is how
	# we read what Engine.time_scale actually does to the physics delta at each --fast multiplier.
	_eco_s += delta
	_phys_frames += 1
	LASimReport.gauge("eco_sim_s", _eco_s)
	LASimReport.gauge("phys_dt", delta)
	LASimReport.gauge("phys_frames", float(_phys_frames))
	_process_pending()
	# Land reproduction is no longer a god-tick: each creature decides to breed for itself
	# (LACreatureReproduction, courtship + energy-costed gestation) and calls birth_offspring() at term.
	# Only the aquatic school still runs a population tick below.
	_seed_timer -= delta
	if _seed_timer <= 0.0:
		_seed_timer = 1.5
		_plants._tick_plant_seeding()
	_fish_timer -= delta
	if _fish_timer <= 0.0:
		_fish_timer = 2.5
		_breeding._tick_aquatic()
	_tree_timer -= delta
	if _tree_timer <= 0.0:
		_tree_timer = 1.4
		_plants._tick_tree_seeding()


func _process_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for entry in _pending:
		var placed = _place_on_surface(entry["pos"])
		if placed != null:
			var k: String = String(entry["kind"])
			if _is_veg_kind(k) and not _can_grow_here(placed):
				continue   # surface resolved somewhere too cold / snowy for vegetation — drop it
			var node = _instance_actor(k, placed, null, int(entry.get("family_id", -1)))
			if bool(entry.get("elder", false)):
				_spawner._seed_elder(node)   # a founder whose centre wasn't meshed at boot still becomes its band's elder
		else:
			entry["tries"] = int(entry["tries"]) + 1
			if int(entry["tries"]) < 300:      # keep retrying ~ a few seconds
				still.append(entry)
	_pending = still


# Land + aquatic reproduction/population dynamics live in LAEcologyBreeding; _physics_process forwards its
# breed/aquatic-breed ticks there. debug_seed_family below reuses the module's genome + nest helpers.

# HARNESS AID (--debug-family): deterministically produce a small family through the REAL reproduction path so
# the family-tree inspector has something to draw. Finds the first species with >=2 mature adults, breeds that
# pair twice (recording parent->child + the mate bond through the shared breeding helpers), then kills one child so a
# dead/greyed kin appears in the lineage. Returns a parent to root the tree on (null if no mature pair exists).
func debug_seed_family() -> Node:
	for kind in ["rabbit", "fox", "bird", "villager", "vulture"]:
		var adults: Array = []
		for m in get_tree().get_nodes_in_group("species_%s" % kind):
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		var pa: Node3D = adults[0] as Node3D
		var pb: Node3D = adults[1] as Node3D
		var kids: Array = []
		for i in range(2):
			var placed = _place_on_surface(_tangent_offset_point(pa.global_position, LASimRng.shared().randf_range(-2.0, 2.0), LASimRng.shared().randf_range(-2.0, 2.0)))
			if placed == null:
				continue
			var child = _instance_actor(kind, placed, _breeding._breed_genome(pa, pb))
			if child != null and is_instance_valid(child):
				_breeding._inherit_nest(pa, child)
				_kinship.add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
				_kinship.add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))
				kids.append(child)
		# Grey one branch: kill a child so the tree shows a dead kin while the lineage persists.
		if kids.size() >= 2 and kids[1].has_method("die"):
			kids[1].die("debug_family")
		return pa
	return null


# Per-creature reproduction (LACreatureReproduction) forwarders — the DECISION to breed lives on the
# individual, but the pop_cap ceiling check and the offspring heredity/lineage machinery stay in
# LAEcologyBreeding (one owner). A gestating creature calls birth_offspring() at term; a courting one gates
# conception on can_species_breed() so a species never conceives past its cap.
func can_species_breed(kind: String) -> bool:
	return _breeding.species_below_cap(kind)


func birth_offspring(kind: String, bearer: Node3D, mate: Node3D) -> Node:
	return _breeding.birth_child(kind, bearer, mate)


# Nest placement lives in LAEcologySpawner; thin forwarder for the nesting creature that establishes a home.
func spawn_nest(site: Vector3, nest_species: String, owner_family: int, in_tree: bool):
	return _spawner.spawn_nest(site, nest_species, owner_family, in_tree)


# Animal-call relay lives in LAEcologyStimulus (the broadcast bus); thin forwarder for the caller creature.
func broadcast_call(world_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	_stimulus.broadcast_call(world_pos, from_species, call_type, caller)


# Grow a plant at world_pos if the plant population is under its cap. Called by wildfire ash regrowth. (It
# also claimed LAMaterialScent3D called it where soil fertility is richest. That module never called this.)
func seed_plant_at(world_pos: Vector3) -> void:
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if get_tree().get_nodes_in_group("plant").size() >= cap:
		return
	spawn("plant", world_pos)


# Initial aquatic stock + the depth-band sampler live in LAEcologyAquatic; these stay as thin forwarders:
# stock_initial_aquatic is the public call the spawn controller makes once the sea level is locked, and
# _random_aquatic_point is reused by the aquatic-breeding tick (LAEcologyBreeding) through this hub.
func stock_initial_aquatic() -> void:
	_aquatic.stock_initial_aquatic()


func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	return _aquatic._random_aquatic_point(cfg)
