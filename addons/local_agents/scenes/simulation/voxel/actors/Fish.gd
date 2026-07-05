class_name LAFish
extends CharacterBody3D

## A material-bound aquatic animal. It lives inside the shared material field (LAMaterialField): it
## swims just under the surface, loosely schools with its OWN species, and turns back whenever its
## next step would leave water OR enter water outside its tolerated salinity / depth band. Nothing
## scripts where it goes — it simply stays in cells that match its config band, so freshwater fish keep
## to lakes/rivers, salt species keep to the open sea, brackish species hug the coast and river mouths,
## and schools form and follow wherever the matching water actually is. All differentiation is CONFIG
## (salinity_min/max, depth_min/max, size, speed, body shape, basks) — one general rule, no per-species
## branches. Drives EVERY aquatic species (fish variants, turtle, crab, whale, jellyfish); every one
## works with no external asset via a procedural fallback body. (Explicit types only — no ':=' typing.)

const GROUP_SELECTABLE: String = "selectable"
const GROUP_FISH: String = "fish"
const SPECIES_GROUP: String = "species_fish"    # shared "aquatic life" group (debug overlay + schooling base)

const DEFAULT_SUBMERGE: float = 0.35  # how far below the surface a swimmer rides (config: "submerge")
const SCHOOL_RADIUS: float = 6.0
const SCHOOL_WEIGHT: float = 0.8
const BASK_DURATION: float = 6.0      # seconds a basking species rests hauled out on the beach
const BASK_COOLDOWN: float = 14.0     # min seconds between bask outings
const BASK_CHANCE: float = 0.05       # per-eligible-frame chance to haul out when at the water's edge

var terrain = null                    # LAVoxelTerrainService (surface_height)
var material = null                      # LAMaterialField (is_water_at / surface_y_at / salinity_at)
var config: Dictionary = {}

var species: String = "fish"
var speed: float = 2.6
var size: float = 0.35
var color: Color = Color(0.62, 0.70, 0.82)
var sense_radius: float = 9.0
var maturity_age: float = 12.0
var food_value: float = 26.0
var max_age: float = 130.0

# --- Habitat band: the ONE rule that self-sorts species into fresh / brackish / salt water and into
# shallow vs deep. Read from config; the movement rule keeps the animal inside this band emergently. ---
var salinity_min: float = 0.0         # 0 = fresh .. ~0.5 brackish .. 1 = salt
var salinity_max: float = 1.0
var depth_min: float = 0.0            # tolerated water-column depth (m); shallow dwellers cap depth_max low
var depth_max: float = 999.0
var submerge: float = DEFAULT_SUBMERGE
var model_id: String = "fish"         # LAActorModels row for the display model ("" = procedural only)
var body_shape: String = "fish"       # procedural fallback silhouette (fish/crab/turtle/whale/jellyfish)
var basks: bool = false               # can haul out to rest on the beach (turtles, crabs)
var _bask_timer: float = 0.0          # >0 while resting on the beach
var _bask_cd: float = 0.0             # cooldown before the next haul-out

# --- health / HP: fish are fragile; a small pool of HP so a bolt's current kills them near the
# strike but graded damage lets edge-of-range fish survive. 0 HP = death. ---
var health: float = 12.0
var max_health: float = 12.0

var age: float = 0.0
var state: String = "swim"
var _dying: bool = false

var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _mesh: MeshInstance3D = null
var _model_root: Node3D = null


func setup(_terrain, _material, _config: Dictionary) -> void:
	terrain = _terrain
	material = _material
	config = _config.duplicate(true)
	species = String(config.get("species", species))
	speed = float(config.get("speed", speed))
	size = float(config.get("size", size))
	color = config.get("color", color)
	sense_radius = float(config.get("sense_radius", sense_radius))
	maturity_age = float(config.get("maturity_age", maturity_age))
	food_value = float(config.get("food_value", food_value))
	max_age = float(config.get("max_age", max_age))
	# Habitat band + presentation, all config — never a per-species branch.
	salinity_min = float(config.get("salinity_min", salinity_min))
	salinity_max = float(config.get("salinity_max", salinity_max))
	depth_min = float(config.get("depth_min", depth_min))
	depth_max = float(config.get("depth_max", depth_max))
	submerge = float(config.get("submerge", submerge))
	model_id = String(config.get("model", species))
	body_shape = String(config.get("body", "fish"))
	basks = bool(config.get("basks", false))
	# Fragile: HP scales gently with size, but fish die easily to a strike near the bolt.
	max_health = float(config.get("max_health", 8.0 + size * 20.0))
	health = max_health

	collision_layer = 2                # pickable via the same layer-2 query as other actors
	collision_mask = 0                 # movement is manual
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_FISH)
	add_to_group(SPECIES_GROUP)
	add_to_group("species_%s" % species)     # per-species group so stocking caps count each kind
	_heading = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0).normalized()
	if _heading == Vector3.ZERO:
		_heading = Vector3.FORWARD


func _build_body() -> void:
	# Prefer a rigged model when the species has one; otherwise build a config-selected procedural body
	# (every species works with NO external asset). Same call for a minnow or a whale — config decides.
	_build_model()
	if _model_root == null:
		_build_procedural_body()

	var shape: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = maxf(size, 0.2)
	shape.shape = sph
	add_child(shape)


func _body_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.4
	mat.metallic = 0.3                              # a little aquatic sheen
	return mat


# Dispatch the procedural silhouette on the config "body" tag. Each is a small assembly of primitives —
# the mesh analog of the ActorModels data table, not a behaviour branch. All face -Z (the heading).
func _build_procedural_body() -> void:
	match body_shape:
		"crab": _build_crab_body()
		"turtle": _build_turtle_body()
		"whale": _build_whale_body()
		"jellyfish": _build_jellyfish_body()
		_: _build_fish_body()


# Slim streamlined ellipsoid + a tail fin — the classic fish silhouette (also the generic fallback).
func _build_fish_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	_mesh = MeshInstance3D.new()
	var body: SphereMesh = SphereMesh.new()
	body.radius = size
	body.height = size * 2.0
	body.radial_segments = 8
	body.rings = 4
	_mesh.mesh = body
	_mesh.scale = Vector3(0.7, 0.5, 1.5)          # slim, streamlined, longer front-to-back
	_mesh.material_override = mat
	add_child(_mesh)

	var tail: MeshInstance3D = MeshInstance3D.new()
	var fin: CylinderMesh = CylinderMesh.new()
	fin.top_radius = size * 0.7
	fin.bottom_radius = 0.0
	fin.height = size * 0.9
	fin.radial_segments = 3
	tail.mesh = fin
	tail.material_override = mat
	tail.position = Vector3(0.0, 0.0, -size * 1.4)
	tail.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(tail)


# Flat rounded carapace + splayed legs from thin cylinders (a bottom-crawling crab).
func _build_crab_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	_mesh = MeshInstance3D.new()
	var shell: SphereMesh = SphereMesh.new()
	shell.radius = size
	shell.height = size * 2.0
	shell.radial_segments = 8
	shell.rings = 4
	_mesh.mesh = shell
	_mesh.scale = Vector3(1.3, 0.4, 1.0)          # wide and flat
	_mesh.material_override = mat
	add_child(_mesh)
	# Three legs per side, angled out and down.
	for s in [-1.0, 1.0]:
		for k in range(3):
			var leg: MeshInstance3D = MeshInstance3D.new()
			var cyl: CylinderMesh = CylinderMesh.new()
			cyl.top_radius = size * 0.08
			cyl.bottom_radius = size * 0.08
			cyl.height = size * 1.1
			cyl.radial_segments = 4
			leg.mesh = cyl
			leg.material_override = mat
			leg.position = Vector3(s * size * 0.9, -size * 0.15, (float(k) - 1.0) * size * 0.5)
			leg.rotation_degrees = Vector3(0.0, 0.0, s * 60.0)
			add_child(leg)


# Flattened dome shell + four flipper paddles (a sea turtle).
func _build_turtle_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	_mesh = MeshInstance3D.new()
	var shell: SphereMesh = SphereMesh.new()
	shell.radius = size
	shell.height = size * 2.0
	shell.radial_segments = 10
	shell.rings = 6
	_mesh.mesh = shell
	_mesh.scale = Vector3(1.0, 0.45, 1.25)        # domed and slightly long
	_mesh.material_override = mat
	add_child(_mesh)
	# Head out front.
	var head: MeshInstance3D = MeshInstance3D.new()
	var hs: SphereMesh = SphereMesh.new()
	hs.radius = size * 0.3
	hs.height = size * 0.6
	head.mesh = hs
	head.material_override = mat
	head.position = Vector3(0.0, 0.0, -size * 1.25)
	add_child(head)
	# Four flippers.
	for s in [-1.0, 1.0]:
		for z in [-0.55, 0.55]:
			var flip: MeshInstance3D = MeshInstance3D.new()
			var fm: SphereMesh = SphereMesh.new()
			fm.radius = size * 0.35
			fm.height = size * 0.7
			flip.mesh = fm
			flip.scale = Vector3(0.4, 0.2, 1.0)
			flip.material_override = mat
			flip.position = Vector3(s * size * 0.9, -size * 0.1, z * size)
			flip.rotation_degrees = Vector3(0.0, s * -35.0, 0.0)
			add_child(flip)


# Big elongated ellipsoid body + a horizontal tail fluke (a whale).
func _build_whale_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	_mesh = MeshInstance3D.new()
	var body: SphereMesh = SphereMesh.new()
	body.radius = size
	body.height = size * 2.0
	body.radial_segments = 12
	body.rings = 8
	_mesh.mesh = body
	_mesh.scale = Vector3(0.5, 0.6, 1.9)          # long torpedo body
	_mesh.material_override = mat
	add_child(_mesh)
	# Tail fluke: two flattened lobes at the rear.
	for s in [-1.0, 1.0]:
		var fluke: MeshInstance3D = MeshInstance3D.new()
		var fm: SphereMesh = SphereMesh.new()
		fm.radius = size * 0.5
		fm.height = size
		fluke.mesh = fm
		fluke.scale = Vector3(1.0, 0.12, 0.5)
		fluke.material_override = mat
		fluke.position = Vector3(s * size * 0.5, 0.0, size * 1.7)
		add_child(fluke)


# Translucent bell dome + a few trailing tentacle cylinders (a drifting jellyfish).
func _build_jellyfish_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.55)
	_mesh = MeshInstance3D.new()
	var bell: SphereMesh = SphereMesh.new()
	bell.radius = size
	bell.height = size * 2.0
	bell.radial_segments = 10
	bell.rings = 6
	bell.is_hemisphere = true
	_mesh.mesh = bell
	_mesh.scale = Vector3(1.0, 0.8, 1.0)
	_mesh.material_override = mat
	add_child(_mesh)
	for k in range(5):
		var tent: MeshInstance3D = MeshInstance3D.new()
		var cyl: CylinderMesh = CylinderMesh.new()
		cyl.top_radius = size * 0.05
		cyl.bottom_radius = size * 0.02
		cyl.height = size * 1.4
		cyl.radial_segments = 4
		tent.mesh = cyl
		tent.material_override = mat
		var ang: float = TAU * float(k) / 5.0
		tent.position = Vector3(cos(ang) * size * 0.4, -size * 0.9, sin(ang) * size * 0.4)
		add_child(tent)


# Build the display model from the config model row (if any) and start its (looping) swim clip. A
# swimmer is always swimming, so there is no per-frame animation logic — just play once at spawn. When
# a variant reuses a shared mesh (finned fish share fish.glb), its config colour is passed as a flat
# tint so trout / reef fish / mullet still read as distinct.
func _build_model() -> void:
	if model_id.is_empty():
		return
	var def: Dictionary = LAActorModels.get_def(model_id)
	if String(def.get("path", "")).is_empty():
		return
	var target_h: float = size * 2.4
	var tint: Color = color if bool(config.get("tint_model", false)) else Color(0, 0, 0, 0)
	var model: Node3D = LAModelVisual.build(def["path"], target_h, "center", float(def.get("yaw", 0.0)), tint)
	if model == null:
		return
	add_child(model)
	_model_root = model
	var anim: AnimationPlayer = LAModelVisual.find_anim(model)
	var anims: Dictionary = def.get("anims", {})
	if anim != null:
		var clip: String = String(anims.get("move", ""))
		if not clip.is_empty() and anim.has_animation(clip):
			anim.play(clip)


# A thrown rock / bite killed me, or I aged out.
func die(_cause: String = "", _impulse: Vector3 = Vector3.ZERO) -> void:
	# `_impulse` is accepted (and ignored) so a meteor's die(cause, impulse) call doesn't crash on fish.
	if _dying:
		return
	_dying = true
	if material != null and material.has_method("splash"):
		material.splash(global_position, 0.6)
	queue_free()


func on_struck() -> void:
	die("struck")


# Deterministic HP damage (electrocution, blast). Dies via the normal death path at 0 HP.
func take_damage(amount: float, cause: String = "", _impulse: Vector3 = Vector3.ZERO) -> void:
	if _dying or amount <= 0.0:
		return
	health -= amount
	if health <= 0.0:
		die(cause)


func is_mature() -> bool:
	return age >= maturity_age


func _physics_process(delta: float) -> void:
	if _dying:
		return
	age += delta
	if age >= max_age:
		die("old age")
		return
	if material == null:
		return

	# Basking species haul out onto the beach and rest at the surface for a spell (turtles/crabs).
	_bask_cd -= delta
	if _bask_timer > 0.0:
		_bask_timer -= delta
		state = "bask"
		return

	var pos: Vector3 = global_position
	_wander_timer -= delta

	var desired: Vector3 = _heading
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(1.0, 2.5)
		var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0) * 0.7
		desired = _heading + jitter
	desired += _school_steer(pos)
	desired.y = 0.0

	# Test the step: if it would leave habitable water (dry, OR water outside this species' salinity /
	# depth band), steer back toward the nearest habitable cell. This ONE rule self-sorts every species.
	var candidate: Vector3 = desired.normalized() if desired.length() > 0.001 else _heading
	var step_len: float = speed * delta
	var next_x: float = pos.x + candidate.x * step_len
	var next_z: float = pos.z + candidate.z * step_len
	if not _habitable(next_x, next_z):
		# A basking species at the water's edge may instead haul out onto the beach to rest.
		if basks and _bask_cd <= 0.0 and randf() < BASK_CHANCE and _try_bask(next_x, next_z):
			return
		var back: Vector3 = _find_habitable_dir(pos)
		if back != Vector3.ZERO:
			candidate = back
			state = "seek"
		else:
			candidate = -_heading         # no habitable water found near: turn around
			state = "swim"
		next_x = pos.x + candidate.x * step_len
		next_z = pos.z + candidate.z * step_len
		# If even the corrective step is unhabitable, hold position this frame (edge of a shrinking pool).
		if not _habitable(next_x, next_z):
			next_x = pos.x
			next_z = pos.z
	else:
		state = "swim"

	_heading = candidate if candidate.length() > 0.001 else _heading

	# Ride below the surface at the species' submerge depth (fall back to terrain if the query is NAN).
	var surf_y: float = material.surface_y_at(next_x, next_z)
	if is_nan(surf_y):
		var ground: float = float(terrain.surface_height(next_x, next_z)) if terrain != null and terrain.has_method("surface_height") else NAN
		if is_nan(ground):
			return
		surf_y = ground
	global_position = Vector3(next_x, surf_y - submerge, next_z)

	if _heading.length() > 0.01:
		var look: Vector3 = global_position + _heading
		if not look.is_equal_approx(global_position):
			look_at(look, Vector3.UP)


# True where this species can live: water present AND its salinity within [salinity_min, salinity_max]
# AND its water-column depth within [depth_min, depth_max]. Salinity/depth checks are skipped only when
# the field returns no reading (NAN) so a fish never gets trapped by a momentary bad sample.
func _habitable(x: float, z: float) -> bool:
	if not material.is_water_at(x, z):
		return false
	var s: float = material.salinity_at(x, z)
	if not is_nan(s) and (s < salinity_min or s > salinity_max):
		return false
	var d: float = _water_depth_at(x, z)
	if not is_nan(d) and (d < depth_min or d > depth_max):
		return false
	return true


# Water-column depth (surface Y minus the ground below) at (x, z); NAN if either query is unavailable.
func _water_depth_at(x: float, z: float) -> float:
	var surf: float = material.surface_y_at(x, z)
	if is_nan(surf):
		return NAN
	if terrain == null or not terrain.has_method("surface_height"):
		return NAN
	var ground: float = float(terrain.surface_height(x, z))
	if is_nan(ground):
		return NAN
	return surf - ground


# Haul out to rest on the beach at (bx, bz) if it's dry land right at the shoreline (just above sea
# level). Sits at the terrain surface for BASK_DURATION. Returns true if basking started.
func _try_bask(bx: float, bz: float) -> bool:
	if terrain == null or not terrain.has_method("surface_height"):
		return false
	var ground: float = float(terrain.surface_height(bx, bz))
	if is_nan(ground):
		return false
	var sea: float = float(material.sea_level)
	# Only the narrow dry beach band just above the waterline — not up a hillside.
	if ground < sea or ground > sea + 2.0:
		return false
	global_position = Vector3(bx, ground, bz)
	_bask_timer = BASK_DURATION
	_bask_cd = BASK_COOLDOWN + BASK_DURATION
	state = "bask"
	return true


# Loose schooling with nearby SAME-SPECIES swimmers: cohesion + alignment (same shared idea as creature
# flocking). Filtering by species keeps a whale from schooling with minnows — schools stay per-species.
func _school_steer(pos: Vector3) -> Vector3:
	var mates: Array = get_tree().get_nodes_in_group(SPECIES_GROUP)
	var center: Vector3 = Vector3.ZERO
	var align: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in mates:
		if m == self or not is_instance_valid(m):
			continue
		var lm: LAFish = m as LAFish
		if lm == null or lm.species != species:
			continue
		var d: float = pos.distance_to(lm.global_position)
		if d > SCHOOL_RADIUS or d < 0.0001:
			continue
		center += lm.global_position
		align += lm._heading
		n += 1
	if n == 0:
		return Vector3.ZERO
	center /= float(n)
	align /= float(n)
	var cohesion: Vector3 = center - pos
	cohesion.y = 0.0
	align.y = 0.0
	var steer: Vector3 = Vector3.ZERO
	if cohesion.length() > 0.001:
		steer += cohesion.normalized() * 0.5
	if align.length() > 0.001:
		steer += align.normalized() * 0.5
	return steer * SCHOOL_WEIGHT


# Probe rings for the nearest HABITABLE cell (water in this species' salinity + depth band); return a
# flat unit heading toward it. Seeking habitable (not just any) water is what pulls a strayed fish back
# into its own band — a freshwater fish toward the lake, a salt fish back out to sea.
func _find_habitable_dir(pos: Vector3) -> Vector3:
	if material == null or not material.has_method("is_water_at"):
		return Vector3.ZERO
	var radii: Array = [size * 3.0, sense_radius, sense_radius * 2.0]
	var dirs: int = 10
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var px: float = pos.x + cos(ang) * float(r)
			var pz: float = pos.z + sin(ang) * float(r)
			if _habitable(px, pz):
				var d: Vector3 = Vector3(px - pos.x, 0.0, pz - pos.z)
				if d.length() > 0.001:
					return d.normalized()
	return Vector3.ZERO


func get_inspector_payload() -> Dictionary:
	var stage: String = "adult" if is_mature() else "juvenile"
	var doing: String = "swimming"
	if state == "seek":
		doing = "heading for water"
	elif state == "bask":
		doing = "basking on the beach"
	var band: String = "fresh"
	if salinity_min >= 0.55:
		band = "salt"
	elif salinity_max > 0.25:
		band = "brackish"
	return {
		"title": species.capitalize(),
		"lines": [
			"Species: %s (%s)" % [species, stage],
			"Doing: %s" % doing,
			"Water: %s (salinity %.2f–%.2f, depth %.0f–%.0f)" % [band, salinity_min, salinity_max, depth_min, depth_max],
			"Age: %.0fs / %.0fs" % [age, max_age],
		],
	}
