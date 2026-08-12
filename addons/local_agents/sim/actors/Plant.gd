class_name LAPlant
extends StaticBody3D


const GROUP_SELECTABLE: String = "selectable"
const GROUP_PLANT: String = "plant"

var terrain = null                       # LAVoxelTerrainService (injected)
var _material = null                      # LAMaterialField3D — the shared field (biomass-growth coupling)
var config: Dictionary = {}

const BIOMASS_GROWTH_GAIN: float = 4.0   # growth-speed multiplier per unit local field biomass
const BIOMASS_GROWTH_MAX: float = 2.0    # cap on the biomass growth boost

const BIOMASS_PER_FOOD: float = 1.8e-4
const FOOD_CAPACITY: float = 46.0        # ceiling on the reserve a full-grown plant may hold (food-energy units)
const FOOD_UPTAKE_RATE: float = 8.0      # food-energy/second the plant may draw from its cell's standing
                                         # biomass — a RATE LIMIT on uptake, not a source: it can only take
                                         # what the field has, and takes nothing where the field has nothing.
const FOOD_MIN_EDIBLE: float = 5.0       # below this the plant is grazed-down and not worth targeting (recovers)
var _food: float = 0.0                   # current edible reserve — earned from the field, never granted

static var food_held_total: float = 0.0      # mass currently standing in every live plant node's reserve
static var food_drawn_total: float = 0.0     # cumulative mass drawn out of the field into plant tissue
static var food_returned_total: float = 0.0  # cumulative mass handed back to the field as detritus

# THE CONTROL (LA_MINT_PLANT_FOOD=1). Restores the old behaviour exactly — a full 0.6 reserve at birth and
# `FOOD_UPTAKE_RATE`/s of regrowth with no debit anywhere — so the fix can be switched OFF and the aggregates
# compared. A conservation fix that cannot be disabled cannot be shown to be doing anything.
static var _mint_food: int = -1
static func mint_food() -> bool:
	if _mint_food < 0:
		_mint_food = 1 if OS.has_environment("LA_MINT_PLANT_FOOD") else 0
	return _mint_food == 1

var species: String = "plant"
var color: Color = Color(0.30, 0.65, 0.22)
var grow_time: float = 12.0
var max_scale: float = 1.0
var seed_period: float = 8.0
var edible: bool = true

var toxic: float = 0.0

const ROOT_BASE: float = 1.5
const ROOT_PER_SCALE: float = 3.0
var root_strength: float = 3.0

var flower: bool = false
var nectar: float = FOOD_CAPACITY          # edible reserve cap of a full-grown flower (config "nectar")
var _pollination: float = 0.0              # decaying pollen load; each visit adds POLLINATE_PER_VISIT
const POLLINATE_PER_VISIT: float = 1.0     # pollen deposited by one flower visit (a feed() bite)
const POLLINATE_DECAY: float = 0.10        # pollen lost per second (a flower must be re-visited to stay pollinated)
const POLLINATE_MAX: float = 4.0           # cap on the pollen load (bounded)
const POLLINATE_SEED_BOOST: float = 7.0    # a fully-pollinated flower seeds this many × faster than an un-visited one
static var pollination_events: int = 0     # global running count of flower visits (SIM_REPORT bee-activity proxy)
const POLLINATOR_SPECIES: Array = ["bee", "butterfly"]
const POLLEN_RADIUS: float = 10.0          # a pollinator within this range deposits pollen (bees cruise ~5 m up, so
                                           # this reaches a bee/butterfly passing overhead, not only one landed alongside)
const POLLEN_SCAN_PERIOD: float = 0.5      # seconds between a flower's cheap pollinator-proximity checks
static var _pollinator_index: LASpatialIndex = LASpatialIndex.new()
var _pollen_scan_t: float = 0.0

var age: float = 0.0
var _seed_timer: float = 0.0
var _seed_ready: bool = false
var _mesh: MeshInstance3D = null
var _base_height: float = 1.2

# GPU-instanced rendering: instead of owning a MeshInstance/model child, the plant registers with the shared
# LAVegetationRenderer and pushes its transform WHILE it is growing. Once mature it stops (settled → zero
# per-frame render cost). Falls back to a procedural mesh child if no renderer is wired (headless tests).
const RENDER_TYPE: String = "plant"
var _veg = null                          # LAVegetationRenderer (injected before setup)
var _veg_slot: int = -1
var _render_settled: bool = false


func setup(_terrain, _config: Dictionary) -> void:
	terrain = _terrain
	config = _config.duplicate(true)
	species = String(config.get("species", species))
	color = config.get("color", color)
	grow_time = maxf(float(config.get("grow_time", grow_time)), 0.1)
	max_scale = float(config.get("max_scale", max_scale))
	seed_period = maxf(float(config.get("seed_period", seed_period)), 0.5)
	edible = bool(config.get("edible", edible))
	toxic = clampf(float(config.get("toxic", 0.0)), 0.0, 1.0)
	flower = bool(config.get("flower", flower))
	nectar = float(config.get("nectar", FOOD_CAPACITY))
	# Root strength: explicit config, else scaled from mature size (already read above) so bigger plants hold on.
	root_strength = maxf(0.2, float(config.get("root_strength", ROOT_BASE + ROOT_PER_SCALE * max_scale)))
	_food = _food_capacity() * 0.6 if mint_food() else 0.0
	food_held_total += _food * BIOMASS_PER_FOOD

	collision_layer = 2
	collision_mask = 0
	_seed_timer = seed_period
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_PLANT)
	add_to_group("species_%s" % species)     # per-species group so seeding caps count each vegetation kind
	_orient_to_ground()
	_apply_growth()
	_sync_render()   # push the initial (freshly-grown) pose into the instanced batch


## Stand radially and sit on the solid surface: snap onto the surface along our radial ray and align
## local +Y to the radial "up".
func _orient_to_ground() -> void:
	if terrain == null:
		return
	var center: Vector3 = terrain.planet_center()
	var up: Vector3 = (global_position - center).normalized()
	var surf: Vector3 = terrain.surface_point(up)         # world point on the solid surface along our ray
	if not is_nan(surf.x):
		global_position = surf
	# Build a radial basis: local +Y = up, with an arbitrary (stable) tangent frame.
	var ref: Vector3 = Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right: Vector3 = up.cross(ref).normalized()
	var fwd: Vector3 = right.cross(up).normalized()
	global_transform.basis = Basis(right, up, fwd)


# Injected by LAEcologyService before setup(): the shared GPU-instanced vegetation renderer. When present
# the plant renders through a batched MultiMesh (one draw for all plants) instead of owning a model child.
func set_vegetation_renderer(r) -> void:
	_veg = r


func _build_body() -> void:
	# Flowers get a small, colourful procedural bloom (a thin stem + a bright petal head in the config colour)
	# — NOT the shared green bush prototype — so they read clearly as flowers and the added life is visible.
	if flower:
		_build_flower_body()
		_add_collision_shape()
		return
	# Prefer the shared instanced renderer (one batched draw for every plant). Register a slot; the model is
	# drawn by the MultiMesh, so no per-plant MeshInstance/model child is built.
	if _veg != null:
		_veg_slot = _veg.register(RENDER_TYPE)
	# Prefer the Kenney bush model (base-anchored so it grows up from the ground; the node's
	# growth scale in _apply_growth scales the model with it). Fall back to the stem + foliage.
	var built_model: bool = _veg_slot >= 0
	if not built_model:
		var def: Dictionary = LAActorModels.get_def("plant")
		if not String(def.get("path", "")).is_empty():
			var model: Node3D = LAModelVisual.build(def["path"], _base_height, "base", float(def.get("yaw", 0.0)), LAActorModels.tint("plant"))
			if model != null:
				add_child(model)
				built_model = true
	if not built_model:
		var mesh: MeshInstance3D = MeshInstance3D.new()
		var cone: CylinderMesh = CylinderMesh.new()             # tapered stem
		cone.top_radius = 0.06
		cone.bottom_radius = 0.34
		cone.height = _base_height
		mesh.mesh = cone
		mesh.position = Vector3(0.0, _base_height * 0.5, 0.0)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.95
		mesh.material_override = mat
		add_child(mesh)
		_mesh = mesh

		# Leafy foliage blob on top so the plant reads clearly at distance.
		var foliage: MeshInstance3D = MeshInstance3D.new()
		var ball: SphereMesh = SphereMesh.new()
		ball.radius = 0.42
		ball.height = 0.84
		foliage.mesh = ball
		foliage.position = Vector3(0.0, _base_height + 0.15, 0.0)
		var fmat: StandardMaterial3D = StandardMaterial3D.new()
		fmat.albedo_color = color.lightened(0.12)
		fmat.roughness = 0.9
		foliage.material_override = fmat
		add_child(foliage)

	_add_collision_shape()


# Pickable collision cylinder shared by the bush and flower bodies (layer-2 selection like every actor).
func _add_collision_shape() -> void:
	var shape: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.25
	cyl.height = _base_height
	shape.shape = cyl
	shape.position = Vector3(0.0, _base_height * 0.5, 0.0)
	add_child(shape)


# A small flower: a thin green stem topped by a bright petal head (config colour). Kept to TWO primitives
# with shadow-casting OFF — flowers are numerous, so the render cost per bloom must stay tiny. The node's
# growth scale in _apply_growth scales it with the plant as it matures.
func _build_flower_body() -> void:
	var stem: MeshInstance3D = MeshInstance3D.new()
	var stalk: CylinderMesh = CylinderMesh.new()
	stalk.top_radius = 0.03
	stalk.bottom_radius = 0.05
	stalk.height = _base_height * 0.7
	stalk.radial_segments = 5
	stem.mesh = stalk
	stem.position = Vector3(0.0, _base_height * 0.35, 0.0)
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var smat: StandardMaterial3D = StandardMaterial3D.new()
	smat.albedo_color = Color(0.24, 0.5, 0.2)
	smat.roughness = 0.95
	stem.material_override = smat
	add_child(stem)
	_mesh = stem

	# Bright petal head in the config colour so daisies/clover read as distinct blooms.
	var bloom: MeshInstance3D = MeshInstance3D.new()
	var head: SphereMesh = SphereMesh.new()
	head.radius = 0.18
	head.height = 0.30
	head.radial_segments = 7
	head.rings = 4
	bloom.mesh = head
	bloom.scale = Vector3(1.0, 0.5, 1.0)                 # a flat, splayed flower head
	bloom.position = Vector3(0.0, _base_height * 0.72, 0.0)
	bloom.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bmat: StandardMaterial3D = StandardMaterial3D.new()
	bmat.albedo_color = color
	bmat.roughness = 0.7
	bloom.material_override = bmat
	add_child(bloom)


## Wire the shared material field so this plant grows faster on the emergent biomass it reads. Injected by
## LAEcologyService at spawn, exactly like creatures get set_material_field.
func set_material_field(m) -> void:
	_material = m


const PLANT_SETTLE_STRIDE: int = 24   # a settled plant runs its body ~every 24 frames (catch-up dt) — Big-O by relevance
var _settle_accum: float = 0.0
var _settle_phase: int = -1

func _physics_process(delta: float) -> void:
	if LAAblate.off("plants"):
		return
	var growing: bool = _grown_fraction() < 1.0
	# A fully-grown plant has only slow LINEAR timers left (food regrow, seed timer, flower-pollen decay), so
	# advance it on a coarse STAGGERED cadence with a catch-up delta rather than every frame — hundreds of settled
	# plants stop each running the body 60x/s. The timers are dt-linear, so the accumulated-dt outcome is unchanged.
	if not growing:
		if _settle_phase < 0:
			_settle_phase = int(get_instance_id())
		_settle_accum += delta
		if not LALodStride.should_run(int(Engine.get_physics_frames()), _settle_phase, PLANT_SETTLE_STRIDE):
			return
		delta = _settle_accum
		_settle_accum = 0.0
	if _material != null and _material.has_method("is_water_at") and _material.is_water_at(global_position):
		if _material.has_method("water_force_at") and _material.water_force_at(global_position).length() > root_strength:
			_uproot()
			return
	var growth_boost: float = _biomass_boost() if growing else 0.0
	age += delta * (1.0 + growth_boost)
	_apply_growth()
	# Push the growing pose into the instanced batch; stop once mature (settled → no per-frame render cost).
	if not _render_settled:
		_sync_render()
		if _grown_fraction() >= 1.0:
			_render_settled = true
	# UPTAKE, not regrowth. The plant draws its reserve out of the standing biomass photosynthesis put in this
	# cell; the debit is resolved on device, so it can only credit itself mass the planet actually had. A plant
	# on ground the chemistry never greened takes nothing, which is the coupling the old `+= rate * dt` lacked.
	var cap: float = _food_capacity() * _grown_fraction()
	if _food < cap:
		_uptake(minf(FOOD_UPTAKE_RATE * (1.0 + growth_boost) * delta, cap - _food))
	# Pollen decays: a flower loses its pollinated state unless visitors (bees) keep topping it up.
	if flower and _pollination > 0.0:
		_pollination = maxf(0.0, _pollination - POLLINATE_DECAY * delta)
	# Proximity pollination: pick up pollen from any pollinator nearby (throttled + cheap via the 3D index).
	if flower:
		_pollen_scan_t -= delta
		if _pollen_scan_t <= 0.0:
			_pollen_scan_t = POLLEN_SCAN_PERIOD
			_pollinate_from_nearby()
	if _grown_fraction() >= 1.0:
		# A flower's seed timer runs FASTER the more it has been pollinated — so a well-visited flower reaches
		# seed-ready (and thus spreads) far sooner than an un-visited one. Flower spread RATE therefore tracks
		# pollinator (bee) activity; a neglected flower still seeds, but only on its slow base period.
		var seed_rate: float = 1.0
		if flower:
			seed_rate = 1.0 + POLLINATE_SEED_BOOST * clampf(_pollination / POLLINATE_MAX, 0.0, 1.0)
		_seed_timer -= delta * seed_rate
		if _seed_timer <= 0.0:
			_seed_ready = true


func _uptake(want_food: float) -> void:
	if want_food <= 0.0:
		return
	if mint_food():
		# CONTROL PATH (LA_MINT_PLANT_FOOD=1): the old behaviour, food from nowhere, for the A/B.
		_food += want_food
		food_held_total += want_food * BIOMASS_PER_FOOD
		return
	if _material == null or _material._inject == null or not _material._inject.has_method("take_biomass"):
		return
	var got_mass: float = _material._inject.take_biomass(global_position, want_food * BIOMASS_PER_FOOD)
	if got_mass <= 0.0:
		return
	_food += got_mass / BIOMASS_PER_FOOD
	food_held_total += got_mass
	food_drawn_total += got_mass


func _biomass_boost() -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 0.0
	var pos: Vector3 = global_position
	var b: float = _material.biomass_at(pos.x, pos.y, pos.z)
	return clampf(b * BIOMASS_GROWTH_GAIN, 0.0, BIOMASS_GROWTH_MAX)


func _grown_fraction() -> float:
	# Start visibly grown (0.4) so a freshly spawned plant reads immediately.
	return clampf(age / grow_time, 0.4, 1.0)


func _apply_growth() -> void:
	var f: float = _grown_fraction()
	scale = Vector3.ONE * (f * max_scale)


# Write our current pose into the shared instanced batch. The prototype mesh is height-normalized to 1, so
# we scale by the plant's base height; our node transform already carries orientation + growth scale.
func _sync_render() -> void:
	if _veg_slot < 0 or _veg == null:
		return
	var b: Basis = transform.basis.scaled(Vector3.ONE * _base_height)
	_veg.set_xform(RENDER_TYPE, _veg_slot, Transform3D(b, transform.origin))


func _uproot() -> void:
	if _material != null and _material.has_method("splash"):
		_material.splash(global_position, 1.2)
	queue_free()


func _exit_tree() -> void:
	if _veg_slot >= 0 and _veg != null:
		_veg.release(RENDER_TYPE, _veg_slot)
		_veg_slot = -1
	if _food > 0.0:
		var mass: float = _food * BIOMASS_PER_FOOD
		food_held_total = maxf(0.0, food_held_total - mass)
		if _material != null and _material._inject != null and _material._inject.has_method("return_detritus"):
			_material._inject.return_detritus(global_position, mass)
			food_returned_total += mass
		_food = 0.0


# Deposit pollen if a pollinator (bee/butterfly) is within POLLEN_RADIUS — the emergent "a bee visited this
# bloom" event. One pollinator's pollen per scan is enough; the pollen load (and thus the seed-rate boost)
# then reflects how often pollinators pass by, so denser bee traffic → faster-spreading flowers.
func _pollinate_from_nearby() -> void:
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var groups: Array = []
	for sp in POLLINATOR_SPECIES:
		groups.append("species_" + String(sp))
	_pollinator_index.rebuild_if_stale(tree, Engine.get_physics_frames(), groups)
	var pos: Vector3 = global_position
	for g in groups:
		for cand in _pollinator_index.query(String(g), pos, POLLEN_RADIUS):
			if cand != null and is_instance_valid(cand) and pos.distance_to((cand as Node3D).global_position) <= POLLEN_RADIUS:
				_pollination = minf(POLLINATE_MAX, _pollination + POLLINATE_PER_VISIT)
				pollination_events += 1
				return


# Edible-reserve capacity: a flower's is its (richer) nectar; an ordinary plant's is the base capacity.
func _food_capacity() -> float:
	return nectar if flower else FOOD_CAPACITY


func is_flower() -> bool:
	return flower


func has_seed() -> bool:
	return _seed_ready


func consume() -> void:
	# service took the seed; reset the timer
	_seed_ready = false
	_seed_timer = seed_period


func credit_reserve(amount: float) -> void:
	if amount <= 0.0:
		return
	_food += amount
	food_held_total += amount * BIOMASS_PER_FOOD


func food_mass_per_unit() -> float:
	return BIOMASS_PER_FOOD


func is_edible() -> bool:
	return edible and _food >= FOOD_MIN_EDIBLE   # grazed-down plants recover before they're worth eating again


func feed(amount: float) -> float:
	var take: float = clampf(amount, 0.0, _food)
	_food -= take
	food_held_total = maxf(0.0, food_held_total - take * BIOMASS_PER_FOOD)
	# A visit to a flower deposits pollen (POLLINATION): the visitor — bees dominate flower visits — carries
	# pollen between blooms, so a fed-on flower becomes/stays seed-ready. This is the mutualism, no scripting.
	if flower and take > 0.0:
		_pollination = minf(POLLINATE_MAX, _pollination + POLLINATE_PER_VISIT)
		pollination_events += 1
	return take


# Unified food model: a plant is living CARBS whose worth is its current edible reserve, so a herbivore
# prefers a lush plant over a grazed-down one. (See LAFood — diet decides who can eat it.)
func food_profile() -> Dictionary:
	# `toxicity` rides along on the profile so a bite carries its poison signature into the eating path and the
	# taste-learning: a toxic plant is still living carbs (any herbivore can forage it), it just tastes of poison.
	return {"type": "carbs", "state": "living", "value": maxf(_food, 0.0), "toxicity": toxic}


func is_mature() -> bool:
	return _grown_fraction() >= 1.0


func get_inspector_payload() -> Dictionary:
	var stage: String = "mature" if is_mature() else "growing"
	return {
		"title": species.capitalize(),
		"lines": [
			"Species: %s" % species,
			"Type: plant",
			"Age: %.1fs (%s)" % [age, stage],
			"Growth: %d%%" % int(_grown_fraction() * 100.0),
			"Edible: %s" % ("yes" if edible else "no"),
			"Toxic: %s" % ("%d%%" % int(toxic * 100.0) if toxic > 0.0 else "no"),
			"Seed ready: %s" % ("yes" if _seed_ready else "no"),
		],
	}
