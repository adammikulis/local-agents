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

var species: String = "plant"
var color: Color = Color(0.30, 0.65, 0.22)
var grow_time: float = 12.0
var max_scale: float = 1.0
var seed_period: float = 8.0
var edible: bool = true

var age: float = 0.0
var _seed_timer: float = 0.0
var _seed_ready: bool = false
var _mesh: MeshInstance3D = null
var _base_height: float = 1.2


func setup(_terrain, _config: Dictionary) -> void:
	terrain = _terrain
	config = _config.duplicate(true)
	species = String(config.get("species", species))
	color = config.get("color", color)
	grow_time = maxf(float(config.get("grow_time", grow_time)), 0.1)
	max_scale = float(config.get("max_scale", max_scale))
	seed_period = maxf(float(config.get("seed_period", seed_period)), 0.5)
	edible = bool(config.get("edible", edible))

	collision_layer = 2
	collision_mask = 0
	_seed_timer = seed_period
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_PLANT)
	_orient_to_ground()
	_apply_growth()


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


func _build_body() -> void:
	# Prefer the Kenney bush model (base-anchored so it grows up from the ground; the node's
	# growth scale in _apply_growth scales the model with it). Fall back to the stem + foliage.
	var built_model: bool = false
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

	var shape: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.25
	cyl.height = _base_height
	shape.shape = cyl
	shape.position = Vector3(0.0, _base_height * 0.5, 0.0)
	add_child(shape)


## Wire the shared material field so this plant grows faster on the emergent biomass it reads. Injected by
## LAEcologyService at spawn, exactly like creatures get set_material_field.
func set_material_field(m) -> void:
	_material = m


func _physics_process(delta: float) -> void:
	var growth_boost: float = _biomass_boost()
	age += delta * (1.0 + growth_boost)
	_apply_growth()
	if _grown_fraction() >= 1.0:
		_seed_timer -= delta
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


# --- seeding API used by LAEcologyService ---
func has_seed() -> bool:
	return _seed_ready


func consume() -> void:
	# service took the seed; reset the timer
	_seed_ready = false
	_seed_timer = seed_period


func is_edible() -> bool:
	return edible


# Unified food model: a plant is living CARBS. (See LAFood — diet decides who can eat it.)
func food_profile() -> Dictionary:
	return {"type": "carbs", "state": "living", "value": 32.0}


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
