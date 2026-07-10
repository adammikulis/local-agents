class_name LAEcologyService
extends Node

# Drives the living world: spawning, predator-prey population dynamics, breeding
# with population caps, herd cohesion (delegated to creatures), and plant seeding.
# Every actor is placed on the terrain surface via LAVoxelTerrainService.

const CreatureScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Creature.gd")
const PlantScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Plant.gd")
const RockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Rock.gd")
const TreeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Tree.gd")
const FishScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Fish.gd")
const TrackSystemScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/TrackSystem.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "fish", "rock", "tree"]

# Aquatic sampling budget: tries per placement to land inside a species' salinity/depth band (radial).
const AQUATIC_SAMPLE_TRIES: int = 60
# A LIVING sea: scale every aquatic species' starting count AND its population cap by this factor so the
# ocean/lakes teem instead of trickling. Data files stay the single source of the per-species ratios; this
# is the one owned dial that makes the water busy without editing eight species files.
const AQUATIC_STOCK_MULT: float = 2.6

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _tracks = null                       # LATrackSystem (observer; footprints)
var _material = null                      # LAMaterialField — the ONE substrate (water/heat/materials)
var _cognition_sched = null              # LACognitionScheduler (shared slow-brain budget/queue)
var _veg_renderer = null                 # LAVegetationRenderer — plants/trees render through its batched MultiMesh
# Extracted single-owner modules this thin hub delegates to (it stays a facade + step-orchestration):
var _stimulus: LAEcologyStimulus = null  # stimulus/broadcast bus (disturb/seismic/blast/scare/call/wind)
var _spawner: LAEcologySpawner = null    # spawn/population placement (spawn, initial seeding, forests, nests)

# Shared day/night clock (0=midnight .. 0.5=noon), set by VoxelWorld each frame. Creatures
# read is_night() so nocturnal species behave differently after dark — emergent, not scripted.
var time_of_day: float = 0.3


func set_time_of_day(t: float) -> void:
	time_of_day = t


func is_night() -> bool:
	# Sun is below the horizon between dusk (~0.78) and dawn (~0.22).
	return time_of_day < 0.22 or time_of_day > 0.78

# pending spawns whose surface wasn't ready yet: [{kind, pos, tries}]
var _pending: Array = []
var _breed_timer: float = 0.0
var _seed_timer: float = 0.0
var _fish_timer: float = 0.0
var _tree_timer: float = 0.0             # forest succession: groves densify on biomass-rich ground
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
	# Scent/waste is now an emergent field channel (LAMaterialScent3D in MaterialField3D), not an observer.
	_tracks = TrackSystemScript.new()
	_tracks.name = "TrackSystem"
	add_child(_tracks)
	_tracks.setup(terrain)
	# Shared System-2 slow brain (FunctionGemma) with a global call budget; creatures escalate to
	# it rarely and asynchronously. Loaded by path + guarded so the sim still runs on pure fast
	# heuristics + social learning if the scheduler script or model is unavailable.
	var sched_script: GDScript = load("res://addons/local_agents/scenes/simulation/voxel/cognition/CognitionScheduler.gd")
	if sched_script != null:
		_cognition_sched = sched_script.new()
		_cognition_sched.name = "CognitionScheduler"
		add_child(_cognition_sched)
		if _cognition_sched.has_method("setup"):
			# Point the slow brain at a running FunctionGemma llama-server if one is configured
			# (env FUNCTIONGEMMA_URL); otherwise it uses the built-in heuristic teacher fallback.
			var opts: Dictionary = {}
			var url: String = OS.get_environment("FUNCTIONGEMMA_URL")
			if url != "":
				opts["server_url"] = url
			_cognition_sched.setup(opts)


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


# A hot event "starts a fire" only by depositing heat — vegetation there ignites on the next
# combustion scan because its cell crossed the ignition temperature. Pure emergence, no fire code.
func ignite_area(world_pos: Vector3, radius: float) -> void:
	if _material != null and _material.has_method("add_heat"):
		_material.add_heat(world_pos, 900.0, radius)   # ~3x wood's 300°C ignition temp


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


# Radius of the SKY-EXPOSED top shell cell (r = depth-1), where photosynthesis (MaterialReactions3D R19, gated
# to the outermost open cell that faces space) deposits the biomass for a whole column. Cached from the sphere
# grid; -1 until the field is wired. Biomass is read there, per column, not at the ground.
var _shell_sample_radius: float = -1.0
func _shell_top_radius() -> float:
	if _shell_sample_radius > 0.0:
		return _shell_sample_radius
	if _material != null and _material.has_method("sphere_grid"):
		var g: RefCounted = _material.sphere_grid()
		if g != null:
			_shell_sample_radius = float(g.core_radius) + (float(g.depth) - 0.5) * float(g.cell_size)
	return _shell_sample_radius


# Living BIOMASS above a surface point — the emergent photosynthesis product for that column (warm, sunlit,
# CO₂-rich columns fix the most). Read at the sky-exposed top shell cell along the point's radial, since that
# is where R19 deposits it. Forests gate on this so groves densify under the columns the chemistry made most
# productive (sunlit continents) and stay sparse under cold/polar/night columns. 0 when no field wired yet.
func _biomass_at(pos: Vector3) -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 0.0
	var r: float = _shell_top_radius()
	if r <= 0.0:
		return _material.biomass_at(pos.x, pos.y, pos.z)
	var pc: Vector3 = terrain.planet_center()
	var dir: Vector3 = pos - pc
	if dir.length() < 0.001:
		return 0.0
	var s: Vector3 = pc + dir.normalized() * r
	return _material.biomass_at(s.x, s.y, s.z)


# Spawning + population placement live in LAEcologyStimulus's sibling, LAEcologySpawner. These stay as
# thin forwarders: the public spawn API for external callers, plus the surface/tangent helpers the
# per-tick breeding/seeding below still reuse.
func spawn(kind: String, world_pos: Vector3) -> Node:
	return _spawner.spawn(kind, world_pos)


func spawn_initial(counts: Dictionary) -> void:
	_spawner.spawn_initial(counts)


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


func _instance_actor(kind: String, placed: Vector3, genome = null, family_id: int = -1) -> Node:
	var node: Node = null
	if kind == "plant":
		var plant: PlantScript = PlantScript.new()
		actors_root.add_child(plant)
		plant.global_position = placed
		if _veg_renderer != null and plant.has_method("set_vegetation_renderer"):
			plant.set_vegetation_renderer(_veg_renderer)   # render through the batched MultiMesh, not a model child
		plant.setup(terrain, _plant_config())
		if plant.has_method("set_material_field"):
			plant.set_material_field(_material)          # so it can photosynthesize (fix CO₂ → O₂) into the field
		node = plant
	elif kind == "rock":
		var rock: RockScript = RockScript.new()
		actors_root.add_child(rock)
		rock.global_position = placed
		rock.setup(terrain)
		node = rock
	elif kind == "tree":
		var tree: TreeScript = TreeScript.new()
		actors_root.add_child(tree)
		tree.global_position = placed
		if _veg_renderer != null and tree.has_method("set_vegetation_renderer"):
			tree.set_vegetation_renderer(_veg_renderer)    # render through the batched MultiMesh, not a model child
		tree.setup(terrain, _tree_config())
		node = tree
	else:
		var cfg: Dictionary = _species_config(kind)
		if cfg.is_empty():
			push_warning("LAEcologyService: unknown kind '%s'" % kind)
			return null
		# Aquatic species (config aquatic:true) are all driven by the ONE LAFish script — a fish, turtle,
		# crab or whale differ only by config (salinity/depth band, body, speed). They exist only in water.
		if bool(cfg.get("aquatic", false)):
			if not _is_water_pos(placed):
				return null
			var fish: FishScript = FishScript.new()
			actors_root.add_child(fish)
			fish.global_position = placed
			fish.setup(terrain, _material, cfg)
			return fish
		# Founder clusters share a family_id (permanent kin bond). Only applies to the ancestral (null-genome)
		# path — a bred offspring carries its inherited family_id in the genome's base_config instead.
		if family_id >= 0 and genome == null:
			cfg["family_id"] = family_id
		var creature: CreatureScript = CreatureScript.new()
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
	if node != null and (kind == "plant" or kind == "tree" or kind == "rock"):
		_orient_to_surface(node as Node3D, placed)
	return node


func _tree_config() -> Dictionary:
	var pine: bool = randf() < 0.4
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
	if terrain == null or actors_root == null:
		return
	_process_pending()
	_breed_timer -= delta
	if _breed_timer <= 0.0:
		_breed_timer = 2.0
		_tick_breeding()
	_seed_timer -= delta
	if _seed_timer <= 0.0:
		_seed_timer = 1.5
		_tick_plant_seeding()
	_fish_timer -= delta
	if _fish_timer <= 0.0:
		_fish_timer = 2.5
		_tick_aquatic()
	_tree_timer -= delta
	if _tree_timer <= 0.0:
		_tree_timer = 1.4
		_tick_tree_seeding()


func _process_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for entry in _pending:
		var placed = _place_on_surface(entry["pos"])
		if placed != null:
			var k: String = String(entry["kind"])
			if (k == "tree" or k == "plant") and not _can_grow_here(placed):
				continue   # surface resolved somewhere too cold / snowy for vegetation — drop it
			var node = _instance_actor(k, placed, null, int(entry.get("family_id", -1)))
			if bool(entry.get("elder", false)):
				_spawner._seed_elder(node)   # a founder whose centre wasn't meshed at boot still becomes its band's elder
		else:
			entry["tries"] = int(entry["tries"]) + 1
			if int(entry["tries"]) < 300:      # keep retrying ~ a few seconds
				still.append(entry)
	_pending = still


# A herd that has lost members REBUILDS — births each tick scale with the number of mature breeders, so a
# thinned population recovers toward its carrying capacity (the pop_cap) instead of the old flat one-birth-
# per-species-per-tick that could never replace predation + starvation + old-age losses. Vigorous breeding
# is safe because the cap is the hard ceiling: births stop at cap, so this refills toward equilibrium but
# never explodes past it. Rates are config/const (BREED_* + per-species pop_cap), never scripted counts.
const BREED_FRACTION_PER_TICK: float = 0.16   # fraction of mature adults that may produce young each breed tick
const BREED_MAX_PER_TICK: int = 8             # bound per species per tick (keeps the work + the surge bounded)
func _tick_breeding() -> void:
	for kind in _land_kinds():
		var cfg: Dictionary = _species_config(kind)
		var cap: int = int(cfg.get("pop_cap", 20))
		var group: String = "species_%s" % kind
		var members: Array = get_tree().get_nodes_in_group(group)
		var deficit: int = cap - members.size()
		if members.size() < 2 or deficit <= 0:
			continue
		# count mature adults
		var adults: Array = []
		for m in members:
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		# Births this tick scale with the breeder pool, bounded by the room left under the cap and a hard
		# per-tick ceiling — so a depleted herd rebuilds quickly while a full one stops breeding entirely.
		var births: int = clampi(int(ceil(float(adults.size()) * BREED_FRACTION_PER_TICK)), 1, mini(deficit, BREED_MAX_PER_TICK))
		for i in range(births):
			_birth_one(kind, adults)


# Produce ONE offspring for `kind` from two random mature parents in `adults`: crossover genome + mutation,
# born at a parent's nest (natal philopatry) and recorded in the kinship graph. Factored out of the breed
# loop so a recovering herd can birth several young per tick through the same evolution + lineage path.
func _birth_one(kind: String, adults: Array) -> void:
	var pa: Node3D = adults[randi() % adults.size()] as Node3D
	var pb: Node3D = adults[randi() % adults.size()] as Node3D
	var guard: int = 0
	while pb == pa and guard < 4:
		pb = adults[randi() % adults.size()] as Node3D
		guard += 1
	# Breed AT a parent's nest if it has one — young are born at home and inherit the site.
	var base_pos: Vector3 = pa.global_position
	if bool(pa.get("has_nest")) and not is_inf(float((pa.get("nest_pos") as Vector3).x)):
		base_pos = pa.get("nest_pos")
	var placed = _place_on_surface(_tangent_offset_point(base_pos, randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)))
	if placed == null:
		return
	var child = _instance_actor(kind, placed, _breed_genome(pa, pb))
	_inherit_nest(pa, child)
	# Record the permanent lineage in the kinship graph: the child joins its parent's family component
	# (its family_id, inherited via the genome, is that same component's label) and the mate pair bond
	# is stored. Bonds are added once here and never rewritten.
	if child != null and is_instance_valid(child):
		_kinship.add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
		_kinship.add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))


# HARNESS AID (--debug-family): deterministically produce a small family through the REAL reproduction path so
# the family-tree inspector has something to draw. Finds the first species with >=2 mature adults, breeds that
# pair twice (recording parent->child + the mate bond exactly as _tick_breeding does), then kills one child so a
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
			var placed = _place_on_surface(_tangent_offset_point(pa.global_position, randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)))
			if placed == null:
				continue
			var child = _instance_actor(kind, placed, _breed_genome(pa, pb))
			if child != null and is_instance_valid(child):
				_inherit_nest(pa, child)
				_kinship.add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
				_kinship.add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))
				kids.append(child)
		# Grey one branch: kill a child so the tree shows a dead kin while the lineage persists.
		if kids.size() >= 2 and kids[1].has_method("die"):
			kids[1].die("debug_family")
		return pa
	return null


# Natal philopatry: the offspring adopts a parent's home site, so kin CLUSTER in space over
# generations — which makes vision/sound social learning spread fastest among relatives (culture).
func _inherit_nest(parent, child) -> void:
	if child == null or not is_instance_valid(child):
		return
	if not bool(parent.get("has_nest")):
		return
	var np: Vector3 = parent.get("nest_pos")
	if is_inf(np.x):
		return
	child.set("nest_pos", np)
	child.set("has_nest", true)
	var nn = parent.get("_nest_node")
	if nn != null and is_instance_valid(nn) and nn.has_method("register_young"):
		nn.register_young()


# Nest placement lives in LAEcologySpawner; thin forwarder for the nesting creature that establishes a home.
func spawn_nest(site: Vector3, nest_species: String, owner_family: int, in_tree: bool):
	return _spawner.spawn_nest(site, nest_species, owner_family, in_tree)


# Build a child genome from two parents: rare Baldwin canalization of each parent's deepest lifelong
# habits into the germline, then crossover + mutation. The child inherits one parent's family line so
# kin preferentially learn from each other. Returns null (→ ancestral genome) if parents lack genomes.
func _breed_genome(pa, pb):
	var ga = pa.get_genome() if pa.has_method("get_genome") else null
	var gb = pb.get_genome() if pb.has_method("get_genome") else null
	if ga == null or gb == null:
		return null
	if pa.has_method("get_cognition") and pa.get_cognition() != null:
		ga.maybe_canalize(pa.get_cognition().policy)
	if pb.has_method("get_cognition") and pb.get_cognition() != null:
		gb.maybe_canalize(pb.get_cognition().policy)
	var child = LAGenome.crossover(ga, gb)
	child.mutate()
	# The child's family_id is its parent's connected-component label, sourced from the kinship graph (which
	# equals pa's stable family_id, since components never merge). The parent→child edge itself is recorded at
	# the breeding call site once the child node exists.
	child.base_config["family_id"] = _kinship.family_of(int(pa.get_instance_id()))
	return child


# Animal-call relay lives in LAEcologyStimulus (the broadcast bus); thin forwarder for the caller creature.
func broadcast_call(world_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	_stimulus.broadcast_call(world_pos, from_species, call_type, caller)


# Grow a plant at world_pos if the plant population is under its cap. Called by LAMaterialScent3D where
# soil FERTILITY is richest (dung fertilizes → grass sprouts) and by wildfire ash regrowth.
func seed_plant_at(world_pos: Vector3) -> void:
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if get_tree().get_nodes_in_group("plant").size() >= cap:
		return
	spawn("plant", world_pos)


# Seed a modest starting population of every aquatic species into water matching its band. Called once
# after the sea level is locked. Ongoing recovery is handled by _tick_aquatic; this just makes the sea
# and lakes feel alive from the first frame instead of trickling in.
func stock_initial_aquatic() -> void:
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var initial: int = int(round(float(cfg.get("initial", 0)) * AQUATIC_STOCK_MULT))
		for i in range(initial):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if not is_nan(wet.x):
				_instance_actor(String(kind), wet)


# Keep the water stocked with every aquatic species. Each appears (and recovers) only where water in
# its OWN salinity/depth band exists, so species self-sort: freshwater fish into lakes, salt species out
# in the deep sea, brackish species along the coast — no hand-placed spawn points, all emergent. Each
# under-cap species restocks by its config `restock` rate/tick (default 1 = the old gentle trickle); the
# fast-breeding web BASE (bugs/shrimp) sets a higher rate so it replenishes what the fish/birds eat. The
# per-species pop_cap is still the hard ceiling, so this refills toward equilibrium but never runs away.
func _tick_aquatic() -> void:
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var cap: int = int(round(float(cfg.get("pop_cap", 12)) * AQUATIC_STOCK_MULT))
		var deficit: int = cap - get_tree().get_nodes_in_group("species_%s" % String(kind)).size()
		if deficit <= 0:
			continue
		var restock: int = mini(deficit, maxi(1, int(cfg.get("restock", 1))))
		for i in range(restock):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if is_nan(wet.x):
				break                                # no matching water found this tick; try again next tick
			_instance_actor(String(kind), wet)


# Sample the sea for a point inside a species' depth band: pick a random direction where the GROUND surface
# sits below sea level, then place the individual somewhere in the underwater shell between the seabed and the
# sea radius, inside the species' depth band. Everything is radial (no XZ column reads — three-d-always), so
# species self-sort into the right water with no hand-placed spawn points. NAN-x vector if none found.
func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	var dmin: float = float(cfg.get("depth_min", 0.0))
	var dmax: float = float(cfg.get("depth_max", 999.0))
	var pc: Vector3 = terrain.planet_center()
	var sea_r: float = terrain.sea_radius()
	for i in range(AQUATIC_SAMPLE_TRIES):
		var dir: Vector3 = LAEcologySpawner._random_sphere_dir()
		var ground_r: float = terrain.surface_radius(dir)
		if is_nan(ground_r) or ground_r >= sea_r:
			continue                                  # unmeshed, or dry land poking above sea level
		var lo: float = maxf(ground_r, sea_r - dmax)  # deepest allowed (clamped to just above the seabed)
		var hi: float = sea_r - dmin                  # shallowest allowed (just below the surface)
		if hi <= lo:
			continue
		return pc + dir * randf_range(lo, hi)
	return Vector3(NAN, 0.0, 0.0)


func _tick_plant_seeding() -> void:
	var plants: Array = get_tree().get_nodes_in_group("plant")
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if plants.size() >= cap:
		return
	for p in plants:
		if not is_instance_valid(p):
			continue
		if p.has_method("has_seed") and p.has_seed():
			if randf() > 0.7:
				continue                            # most seed-ready plants spread each tick → pasture densifies
			var placed = _place_on_surface(_tangent_offset_point((p as Node3D).global_position, randf_range(-3.5, 3.5), randf_range(-3.5, 3.5)))
			if placed != null and _can_grow_here(placed):
				_instance_actor("plant", placed)   # seed only takes on warm, snow-free ground (emergent treeline)
			if p.has_method("consume"):
				p.consume()
			if get_tree().get_nodes_in_group("plant").size() >= cap:
				return


# FOREST SUCCESSION — the emergent grove-builder. Each tick a few existing trees standing on biomass-rich
# ground drop a seedling into their tangent neighbourhood, but ONLY where the local biomass the photosynthesis
# chemistry has fixed clears an adaptive threshold (a fraction of the richest grove's biomass). So forests
# THICKEN on the warm fertile continents that grew the most biomass, spread out from existing trees (groves,
# not scatter), and stall at cold/snowy/coastal margins where biomass never crosses the bar or the treeline
# gate blocks germination. Forests are a consequence of the chemistry, not a placement table.
const TREE_POP_CAP: int = 400               # forest carrying capacity (well above the initial seed count)
const TREE_SEED_BIOMASS_FRAC: float = 0.35  # seed only onto ground with >= this fraction of the richest grove's biomass
const TREE_SEED_FLOOR: float = 0.04         # absolute biomass floor so bare/cold ground never seeds
const TREE_SEED_SPREAD: float = 8.0         # how far a seedling lands from its parent (grove tightness, metres)
const TREE_SEEDS_PER_TICK: int = 10         # parents that attempt to seed per tick (bounded work — big-O by tick, not grid)
func _tick_tree_seeding() -> void:
	var trees: Array = get_tree().get_nodes_in_group("tree")
	if trees.is_empty() or trees.size() >= TREE_POP_CAP:
		return
	# The richest grove's biomass sets an ADAPTIVE bar (self-scales to whatever the chemistry produces), so
	# the forest advances onto ground within TREE_SEED_BIOMASS_FRAC of the best fertility.
	var peak: float = 0.0
	for t in trees:
		if is_instance_valid(t):
			peak = maxf(peak, _biomass_at((t as Node3D).global_position))
	var thresh: float = maxf(TREE_SEED_FLOOR, peak * TREE_SEED_BIOMASS_FRAC)
	var seeded: int = 0
	var guard: int = 0
	while seeded < TREE_SEEDS_PER_TICK and guard < TREE_SEEDS_PER_TICK * 4:
		guard += 1
		var parent: Node3D = trees[randi() % trees.size()] as Node3D
		if not is_instance_valid(parent) or _biomass_at(parent.global_position) < thresh:
			continue                                # parent isn't on rich enough ground to spread a grove
		seeded += 1
		var placed = _place_on_surface(_tangent_offset_point(parent.global_position, randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD), randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD)))
		if placed == null or _is_water_pos(placed) or not _can_grow_here(placed):
			continue                                # off the treeline / into the sea — the grove's edge
		if _biomass_at(placed) < thresh:
			continue                                # seedling site not fertile enough — keeps groves dense, not scattered
		_instance_actor("tree", placed)
		if get_tree().get_nodes_in_group("tree").size() >= TREE_POP_CAP:
			return
