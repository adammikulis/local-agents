class_name LAPlant
extends StaticBody3D

# A plant: grows over time (scale), is edible, and periodically drops a seed the
# EcologyService uses to seed neighbouring plants. StaticBody3D so it is pickable
# on collision_layer 2.
#
# Config shape (see LAEcologyService):
#   {
#     "species":     String,   # e.g. "plant" / "grass" / "shrub"
#     "color":       Color,    # foliage albedo
#     "grow_time":   float,    # seconds to reach full size
#     "max_scale":   float,    # full-grown scale multiplier
#     "seed_period": float,    # seconds between seed readiness (once mature)
#     "edible":      bool,     # can herbivores eat it
#   }

const GROUP_SELECTABLE: String = "selectable"
const GROUP_PLANT: String = "plant"

var terrain = null                       # LAVoxelTerrainService (injected)
var _material = null                      # LAMaterialField3D — the shared field (biomass-growth coupling)
var config: Dictionary = {}

# --- Growth coupling to the emergent BIOMASS field. Photosynthesis itself (CO₂ + light → biomass + O₂) is no
# longer CPU actor code: it is dissolved into MaterialReactions3D records R19/R20 and runs on the GPU across the
# whole field. This visual plant node simply grows FASTER where the field has grown biomass (fertile, sunlit,
# CO₂-rich ground) — a field→node read, so a plant downwind of a fire where CO₂ settled shoots up, emergent.
const BIOMASS_GROWTH_GAIN: float = 4.0   # growth-speed multiplier per unit local field biomass
const BIOMASS_GROWTH_MAX: float = 2.0    # cap on the biomass growth boost

# RENEWABLE PASTURE — a plant is a living food source, not a single-use item. A herbivore takes a BITE
# (feed(), like a scavenger biting a carcass) which draws down the plant's edible reserve; the plant
# survives and REGROWS that reserve via photosynthesis. This dissolves overgrazing extinction: a grazed
# patch shrinks then recovers instead of the plant node vanishing, so a herd can sustain on a pasture the
# way real grazing does. The reserve regrows toward FOOD_CAPACITY × grown-fraction (bigger plants feed
# more), faster where the emergent biomass field is rich (the same fertile ground that speeds growth).
const FOOD_CAPACITY: float = 46.0        # max edible reserve of a full-grown plant (energy)
const FOOD_REGROW: float = 8.0           # reserve regrown per second (photosynthesis; boosted by field biomass).
                                         # Raised from 5 so a pasture sustains the broader herbivore community
                                         # (rabbits + birds + the new insects) without the added grazers
                                         # out-competing the flyers off the plants — carrying capacity, not more nodes.
const FOOD_MIN_EDIBLE: float = 5.0       # below this the plant is grazed-down and not worth targeting (recovers)
var _food: float = FOOD_CAPACITY * 0.6   # current edible reserve (starts partway; regrows in)

var species: String = "plant"
var color: Color = Color(0.30, 0.65, 0.22)
var grow_time: float = 12.0
var max_scale: float = 1.0
var seed_period: float = 8.0
var edible: bool = true

# --- Flowers + pollination mutualism. A plant flagged `flower` carries a richer NECTAR reserve (so foraging
# pollinators prefer it via the shared food-value ranking) and is POLLINATED by visits: every bite (feed(),
# whose dominant flower visitor is the bee) deposits decaying pollen, and the more recent pollen a flower
# holds the FASTER its seed timer runs — so a well-visited flower spreads far sooner than a neglected one.
# Flower spread RATE therefore TRACKS pollinator activity — more bees → more visits → faster seeding → more
# flowers + nectar. Pure emergence, config + this node only (no per-species code, no Creature/Cognition edit). ---
var flower: bool = false
var nectar: float = FOOD_CAPACITY          # edible reserve cap of a full-grown flower (config "nectar")
var _pollination: float = 0.0              # decaying pollen load; each visit adds POLLINATE_PER_VISIT
const POLLINATE_PER_VISIT: float = 1.0     # pollen deposited by one flower visit (a feed() bite)
const POLLINATE_DECAY: float = 0.10        # pollen lost per second (a flower must be re-visited to stay pollinated)
const POLLINATE_MAX: float = 4.0           # cap on the pollen load (bounded)
const POLLINATE_SEED_BOOST: float = 7.0    # a fully-pollinated flower seeds this many × faster than an un-visited one
static var pollination_events: int = 0     # global running count of flower visits (SIM_REPORT bee-activity proxy)
# PROXIMITY pollination: a pollinator flying NEAR a bloom carries pollen to it, so a flower is pollinated by
# pollinator PRESENCE (not only by being eaten — the creature AI has no food-seeking, so eating a specific
# flower is rare). Which species pollinate is a small data list of nectar-foragers (not a behaviour branch);
# the shared 3D spatial hash makes each flower's check O(local), rebuilt once per frame per group, and a
# flower only scans on a slow cadence. This is what makes flower spread TRACK bee/butterfly activity.
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
	flower = bool(config.get("flower", flower))
	nectar = float(config.get("nectar", FOOD_CAPACITY))
	_food = _food_capacity() * 0.6           # start partway; regrows toward the (nectar-scaled) capacity

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


func _physics_process(delta: float) -> void:
	if LAAblate.off("plants"):
		return
	# The field biomass read (biomass_at) only matters WHILE growing — a mature plant's grown_fraction is capped
	# at 1, so its growth boost is moot. Skipping the per-frame biomass sample once mature drops the dominant
	# per-plant cost (a whole pasture of settled plants no longer each hit the field every frame). Big-O by relevance.
	var growing: bool = _grown_fraction() < 1.0
	var growth_boost: float = _biomass_boost() if growing else 0.0
	age += delta * (1.0 + growth_boost)
	_apply_growth()
	# Push the growing pose into the instanced batch; stop once mature (settled → no per-frame render cost).
	if not _render_settled:
		_sync_render()
		if _grown_fraction() >= 1.0:
			_render_settled = true
	# Regrow the edible reserve (photosynthesis) toward this plant's size-scaled capacity, faster on
	# fertile (biomass-rich) ground — the renewable-pasture recovery that makes grazing sustainable.
	var cap: float = _food_capacity() * _grown_fraction()
	if _food < cap:
		_food = minf(cap, _food + FOOD_REGROW * (1.0 + growth_boost) * delta)
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


# Growth-speed BOOST from the emergent field biomass at this plant's cell (0 with no field / no local biomass).
# Photosynthesis is now GPU chemistry (MaterialReactions3D R19); the plant just grows toward where the field has
# fixed carbon into biomass — fertile, sunlit, CO₂-rich ground. No CPU CO₂/O₂ writes (they were GPU-invisible).
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


func _exit_tree() -> void:
	if _veg_slot >= 0 and _veg != null:
		_veg.release(RENDER_TYPE, _veg_slot)
		_veg_slot = -1


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


# --- seeding API used by LAEcologyService ---
func has_seed() -> bool:
	return _seed_ready


func consume() -> void:
	# service took the seed; reset the timer
	_seed_ready = false
	_seed_timer = seed_period


func is_edible() -> bool:
	return edible and _food >= FOOD_MIN_EDIBLE   # grazed-down plants recover before they're worth eating again


# A herbivore takes a BITE (the same renewable-food contract a scavenger uses on a carcass): draw the bite
# from the edible reserve, shrink the plant a touch, and return the energy actually removed. The plant is
# NOT consumed — it regrows the reserve over time, so a pasture sustains a herd instead of vanishing.
func feed(amount: float) -> float:
	var take: float = clampf(amount, 0.0, _food)
	_food -= take
	# A visit to a flower deposits pollen (POLLINATION): the visitor — bees dominate flower visits — carries
	# pollen between blooms, so a fed-on flower becomes/stays seed-ready. This is the mutualism, no scripting.
	if flower and take > 0.0:
		_pollination = minf(POLLINATE_MAX, _pollination + POLLINATE_PER_VISIT)
		pollination_events += 1
	return take


# Unified food model: a plant is living CARBS whose worth is its current edible reserve, so a herbivore
# prefers a lush plant over a grazed-down one. (See LAFood — diet decides who can eat it.)
func food_profile() -> Dictionary:
	return {"type": "carbs", "state": "living", "value": maxf(_food, 0.0)}


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
			"Seed ready: %s" % ("yes" if _seed_ready else "no"),
		],
	}
