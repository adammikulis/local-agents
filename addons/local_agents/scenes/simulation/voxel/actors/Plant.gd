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

const GROUP_SELECTABLE := "selectable"
const GROUP_PLANT := "plant"

var terrain = null                       # LAVoxelTerrainService (injected)
var config: Dictionary = {}

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
	_apply_growth()


func _build_body() -> void:
	var mesh := MeshInstance3D.new()
	var cone := CylinderMesh.new()             # tapered stem
	cone.top_radius = 0.06
	cone.bottom_radius = 0.34
	cone.height = _base_height
	mesh.mesh = cone
	mesh.position = Vector3(0.0, _base_height * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mesh.material_override = mat
	add_child(mesh)
	_mesh = mesh

	# Leafy foliage blob on top so the plant reads clearly at distance.
	var foliage := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.42
	ball.height = 0.84
	foliage.mesh = ball
	foliage.position = Vector3(0.0, _base_height + 0.15, 0.0)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = color.lightened(0.12)
	fmat.roughness = 0.9
	foliage.material_override = fmat
	add_child(foliage)

	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.25
	cyl.height = _base_height
	shape.shape = cyl
	shape.position = Vector3(0.0, _base_height * 0.5, 0.0)
	add_child(shape)


func _physics_process(delta: float) -> void:
	age += delta
	_apply_growth()
	if _grown_fraction() >= 1.0:
		_seed_timer -= delta
		if _seed_timer <= 0.0:
			_seed_ready = true


func _grown_fraction() -> float:
	# Start visibly grown (0.4) so a freshly spawned plant reads immediately.
	return clampf(age / grow_time, 0.4, 1.0)


func _apply_growth() -> void:
	var f := _grown_fraction()
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


func is_mature() -> bool:
	return _grown_fraction() >= 1.0


func get_inspector_payload() -> Dictionary:
	var stage := "mature" if is_mature() else "growing"
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
