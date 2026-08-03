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
# survives and REGROWS that reserve. This dissolves overgrazing extinction: a grazed patch shrinks then
# recovers instead of the plant node vanishing, so a herd can sustain on a pasture the way real grazing does.
#
# ===== THE RESERVE IS BIOMASS THE PLANT TOOK OUT OF THE FIELD. IT USED TO BE MADE UP. ======================
#
# What this replaced: `_food` started at `FOOD_CAPACITY * 0.6` = 27.6 units the instant a plant node was
# created, and then grew by `FOOD_REGROW * (1 + growth_boost) * delta` toward the cap — up to 32 units per
# second, per plant, across ~340 plants, out of nothing. `feed()` honestly decremented it, so the drain was
# real and the source was not. A plant on bare rock regrew exactly as fast as one in a rich meadow, because
# nothing was ever debited; `growth_boost` READ the field's biomass and never touched it.
#
# What it is now: uptake. Photosynthesis is already simulated — it is GPU chemistry (MaterialReactions3D R19)
# fixing CO₂ into the field's `biomass` channel wherever there is light, warmth and CO₂ — and this node's
# tissue IS that biomass. So the plant DRAWS its reserve out of the biomass standing in its own cell
# (`LAMaterialFieldInject3D.take_biomass`, a device-resolved debit), and a plant on ground the chemistry never
# greened gets nothing. Grazing then removes that mass from the biosphere for real, and an uprooted plant
# hands what is left back as detritus instead of deleting it.
#
# ===== THE TWO LEDGERS ARE IN DIFFERENT UNITS, AND THE CONVERSION HAS TO BE PINNED ON SOMETHING ============
#
# The field's `biomass` is a MASS in the substrate's units (MAX_MASS = one full cell). The plant's reserve is
# in the FOOD-ENERGY units the creature side runs on (a bite fills a gut, a gut digests to energy). They are
# not the same quantity and there is no physical constant relating them — the creature's energy scale is a
# game abstraction with no kilogram behind it — so the conversion is a MODEL PARAMETER and it lives here,
# next to the model that uses it, rather than in LAPhysical.
#
# WHAT IT IS PINNED ON: what a plant node MEANS. A plant node stands for one plant's worth of the vegetation
# the field is carrying, so a full-grown one's reserve is one node's share of the planet's standing crop.
# Measured on the 600-frame baseline, seed 4242: `biomass_open_total` 6.45 mass units carried by 477 plant
# nodes and 320 tree nodes, which is 0.0081 mass units per vegetation node. Against FOOD_CAPACITY = 46 that
# is 1.8e-4 mass units per unit of food energy.
#
# THIS IS A UNIT DEFINITION, NOT A FITTED CONSTANT, and the difference matters because getting it wrong looks
# exactly like a result. The first version of this change assumed 1:1 — CreatureDigestion.gd:26 says "biomass
# units == energy units", which is true INSIDE a creature's gut and says nothing about the field — and the
# conclusion was that the substrate produces four orders of magnitude too little to feed anything. Measured
# under that assumption: plants 374 against a baseline 478, trees 254-263 against 298-320, and germination
# stopped completely because no parent could ever afford a seed. None of that was the planet being barren; it
# was a missing conversion between two arbitrary scales.
const BIOMASS_PER_FOOD: float = 1.8e-4
const FOOD_CAPACITY: float = 46.0        # ceiling on the reserve a full-grown plant may hold (food-energy units)
const FOOD_UPTAKE_RATE: float = 8.0      # food-energy/second the plant may draw from its cell's standing
                                         # biomass — a RATE LIMIT on uptake, not a source: it can only take
                                         # what the field has, and takes nothing where the field has nothing.
const FOOD_MIN_EDIBLE: float = 5.0       # below this the plant is grazed-down and not worth targeting (recovers)
var _food: float = 0.0                   # current edible reserve — earned from the field, never granted

# Running totals so the reserve held in plant nodes is VISIBLE — IN THE FIELD'S OWN MASS UNITS, so they read
# straight against `carbon_biomass`. Mass drawn out of the `biomass` channel leaves the substrate's carbon
# ledger (`carbon_total` sums the field's co2 + biomass + detritus only), so without these a perfectly
# conserving draw would read as carbon destroyed. Published by LAEcologyService.vegetation_report.
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

# TOXICITY — a data-driven [0,1] property, NOT a plant subtype. A toxic plant feeds like any other (it is still
# edible carbs), but a bite of it POISONS the grazer (HP loss in the eating path) and the bite carries its
# toxicity in food_profile() so the chemical-affinity system mints an AVERSIVE taste cue. So creatures LEARN
# which vegetation is poison and steer off it — no "if species == nightshade" anywhere; the value does it.
# 0 == wholesome (the vast majority of vegetation); >0 == toxic strength.
var toxic: float = 0.0

# ROOTING — the water-current magnitude this plant's roots withstand before flowing water TEARS IT OUT. A
# data-driven property (config `root_strength`); when unset it scales with the plant's mature size (bigger
# plant, deeper roots), so grass + flowers wash away in a flood/river first and a big shrub holds far longer.
# Trees set their own (much higher) value. This is the plant half of "moving water sweeps weakly-rooted life."
const ROOT_BASE: float = 1.5
const ROOT_PER_SCALE: float = 3.0
var root_strength: float = 3.0

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
	toxic = clampf(float(config.get("toxic", 0.0)), 0.0, 1.0)
	flower = bool(config.get("flower", flower))
	nectar = float(config.get("nectar", FOOD_CAPACITY))
	# Root strength: explicit config, else scaled from mature size (already read above) so bigger plants hold on.
	root_strength = maxf(0.2, float(config.get("root_strength", ROOT_BASE + ROOT_PER_SCALE * max_scale)))
	# A SEEDLING HOLDS NOTHING. It has to take its tissue out of the ground it is standing on, like a real
	# plant. The old line here was `_food = _food_capacity() * 0.6`, which handed 27.6 units of edible matter
	# to every plant node the moment it existed — and germination creates hundreds of them per run.
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
	# The field biomass read (biomass_at) only matters WHILE growing — a mature plant's grown_fraction is capped
	# at 1, so its growth boost is moot. Skipping the per-frame biomass sample once mature drops the dominant
	# per-plant cost (a whole pasture of settled plants no longer each hit the field every frame). Big-O by relevance.
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
	# UPROOTING: moving water tears out a plant whose roots can't hold. Cheap dry early-out (is_water_at is one
	# cell lookup) so a dry pasture pays nothing; only a flooded plant samples the current and compares it to its
	# root strength. The same downhill current that sweeps animals uproots weakly-rooted vegetation — grass +
	# flowers wash out first, deep-rooted plants hold. An uprooted plant dies in place (swept debris).
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


# Draw up to `want_food` units of edible reserve out of the standing biomass in this plant's own cell. The
# field is debited on device for exactly the mass it hands over, so nothing is created; where the cell is bare
# the call returns 0 and the plant simply does not build a reserve. `want_food` is in FOOD-ENERGY units and
# the field deals in MASS, so BIOMASS_PER_FOOD is applied on the way in and taken back off on the way out —
# the plant is credited only what the planet actually gave up.
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


# Torn out by flowing water: a splash accent where it washed away, then remove it (the renderer slot is
# released in _exit_tree). THE PLANT'S TISSUE GOES BACK INTO THE GROUND. The comment that used to sit here
# said "the plant's biomass simply leaves the pasture — no corpse node", which was an accurate description of
# matter being deleted: the reserve the plant was holding vanished with the node. A washed-out plant is dead
# organic matter lying wherever the current dropped it, so it is handed to the `detritus` channel, where the
# decomposer loop (fungus → CO₂ + fertility) picks it up like any other corpse.
func _uproot() -> void:
	if _material != null and _material.has_method("splash"):
		_material.splash(global_position, 1.2)
	queue_free()


func _exit_tree() -> void:
	if _veg_slot >= 0 and _veg != null:
		_veg.release(RENDER_TYPE, _veg_slot)
		_veg_slot = -1
	# Whatever reserve this plant still held returns to the substrate as detritus — however it died (uprooted,
	# burnt out, culled by the LOD governor, freed at shutdown). Doing it in _exit_tree rather than in _uproot
	# is deliberate: every path that removes a plant node goes through here, and only one of them was uprooting.
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


# --- seeding API used by LAEcologyService ---
func has_seed() -> bool:
	return _seed_ready


func consume() -> void:
	# service took the seed; reset the timer
	_seed_ready = false
	_seed_timer = seed_period


# Put mass INTO this plant's reserve that came out of another plant's — the seedling receiving the mass its
# parent spent on the seed, or a parent taking its investment back when there was nowhere to germinate. This
# is the credit half of `feed()`'s debit, and it exists so germination is a MOVE between two nodes rather
# than a new plant appearing with a full larder. It is not a source: the only caller pays first.
func credit_reserve(amount: float) -> void:
	if amount <= 0.0:
		return
	_food += amount
	food_held_total += amount * BIOMASS_PER_FOOD


func is_edible() -> bool:
	return edible and _food >= FOOD_MIN_EDIBLE   # grazed-down plants recover before they're worth eating again


# A herbivore takes a BITE (the same renewable-food contract a scavenger uses on a carcass): draw the bite
# from the edible reserve, shrink the plant a touch, and return the energy actually removed. The plant is
# NOT consumed — it regrows the reserve over time, so a pasture sustains a herd instead of vanishing.
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
