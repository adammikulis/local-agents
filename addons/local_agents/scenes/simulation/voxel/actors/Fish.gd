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
const SPECIES_GROUP: String = "aquatic"    # shared "all aquatic life" group (schooling base). NOT "species_fish":
# that collides with the per-species group of the species literally named "fish", which made _tick_aquatic count
# ALL aquatic actors against fish's pop_cap so fish never bred + SimReport mislabelled the whole pop as fish.

const DEFAULT_SUBMERGE: float = 0.35  # how far below the surface a swimmer rides (config: "submerge")
const GILL_SUBMERGE_MARGIN: float = 0.15  # keep a gill-breather's top this far under the sea shell so it stays submerged
const SCHOOL_RADIUS: float = 6.0
const SCHOOL_WEIGHT: float = 0.8
const BASK_DURATION: float = 6.0      # seconds a basking species rests hauled out on the beach
const BASK_COOLDOWN: float = 14.0     # min seconds between bask outings
const BASK_CHANCE: float = 0.05       # per-eligible-frame chance to haul out when at the water's edge
const THINK_STRIDE: int = 3            # recompute the swim intention (wander + schooling) every N frames

var terrain = null                    # LAVoxelTerrainService (surface_height)
var material = null                      # LAMaterialField (splash on entry)
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

# --- Foraging (config-driven, same idea as LACreature's preys_on): a swimmer with a non-empty preys_on is
# an insectivore/planktivore — it steers toward the nearest edible prey in its own sense radius and eats it
# on contact, giving the aquatic food web a real bottom (fish → bugs/shrimp → the algae/biomass base). An
# empty preys_on (whales aside) leaves the pure config-band swimmer behaviour unchanged. No per-species
# branch: WHAT a swimmer eats is entirely the `preys_on` list in its data file. ---
var diet: String = ""                 # informational ("insectivore"/"filter_feeder"/…); behaviour keys off preys_on
var preys_on: PackedStringArray = PackedStringArray()   # species this swimmer forages (e.g. ["bug","shrimp"])
const FORAGE_WEIGHT: float = 1.1      # how hard the prey-attraction pulls vs. wander/schooling
# One shared frame-stamped spatial index over the prey groups, rebuilt at most once/frame/group across ALL
# swimmers (the same O(active) lookup LACreatureSenses uses) so foraging stays sub-quadratic with many bugs.
static var _forage_index: LASpatialIndex = LASpatialIndex.new()

# --- health / HP: fish are fragile; a small pool of HP so a bolt's current kills them near the
# strike but graded damage lets edge-of-range fish survive. 0 HP = death. ---
var health: float = 12.0
var max_health: float = 12.0

# --- Breathing (config-driven, same 3D submersion read as land animals): "water" = GILLS (breathe underwater,
# suffocate in air — a beached fish); "air" = LUNGS (an aquatic air-breather like a whale/turtle: lives in the
# water but must SURFACE to breathe, diving down while it holds its reserve and drowning if it runs out). No
# hardcoded per-species behavior — the dive/surface cycle emerges from `breathes` + the breath reserve. ---
var breathes: String = "water"
var breath_capacity: float = 12.0     # seconds of held breath (out of medium); big lungs (whale) = long dives
var dive_depth: float = 0.0           # air-breathers forage this far down, then rise to breathe (0 = use submerge)
var _breath: float = 12.0
const BREATH_REFILL: float = 25.0     # breath reserve refilled per sec while in the breathing medium

var age: float = 0.0
var state: String = "swim"
var _dying: bool = false

var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _think_phase: int = -1             # per-instance stagger for the throttled swim-intention update
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
	breathes = String(config.get("breathes", breathes))
	breath_capacity = float(config.get("breath_capacity", breath_capacity))
	dive_depth = float(config.get("dive_depth", dive_depth))
	_breath = breath_capacity
	model_id = String(config.get("model", species))
	body_shape = String(config.get("body", "fish"))
	basks = bool(config.get("basks", false))
	diet = String(config.get("diet", diet))
	preys_on = PackedStringArray(config.get("preys_on", PackedStringArray()))
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
		"bug": _build_bug_body()
		"shrimp": _build_shrimp_body()
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


# A tiny single-mesh speck — the base of the aquatic web (surface midges / water bugs). Kept to ONE low-poly
# mesh because bugs are numerous; the whole point is a cheap, plentiful food particle for the fish/birds.
func _build_bug_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	mat.metallic = 0.0
	_mesh = MeshInstance3D.new()
	var body: SphereMesh = SphereMesh.new()
	body.radius = size
	body.height = size * 2.0
	body.radial_segments = 5
	body.rings = 3
	_mesh.mesh = body
	_mesh.scale = Vector3(0.8, 0.6, 1.2)          # a stubby little bug
	_mesh.material_override = mat
	add_child(_mesh)


# A small curved crustacean — one slim body mesh plus a short tail flick. A bottom-shell grazer (the second
# aquatic base). Cheap: two primitives, since shrimp are also plentiful prey.
func _build_shrimp_body() -> void:
	var mat: StandardMaterial3D = _body_material()
	_mesh = MeshInstance3D.new()
	var body: SphereMesh = SphereMesh.new()
	body.radius = size
	body.height = size * 2.0
	body.radial_segments = 6
	body.rings = 3
	_mesh.mesh = body
	_mesh.scale = Vector3(0.5, 0.5, 1.6)          # slim and elongated
	_mesh.material_override = mat
	add_child(_mesh)
	var tail: MeshInstance3D = MeshInstance3D.new()
	var fan: SphereMesh = SphereMesh.new()
	fan.radius = size * 0.5
	fan.height = size
	tail.mesh = fan
	tail.scale = Vector3(1.0, 0.2, 0.6)
	tail.material_override = mat
	tail.position = Vector3(0.0, 0.0, size * 1.4)
	add_child(tail)


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
	LASimReport.event("death", {"cause": _cause, "species": species})
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


# Camera position, fetched once per physics frame and shared across all fish (one get_camera_3d()
# lookup per frame, not one per fish). INF when there is no active camera. Mirrors LACreature's cache.
static var _cam_frame: int = -1
static var _cam_pos: Vector3 = Vector3(INF, INF, INF)

const MID_THINK_STRIDE: int = 10           # mid-distance schooling/wander recompute (~6 Hz)
const FAR_THINK_STRIDE: int = 30           # far/off-screen recompute (~2 Hz)
const NEAR_LOD_D2: float = 900.0           # <30 m from camera → full THINK_STRIDE rate
const MID_LOD_D2: float = 4900.0           # <70 m → MID rate; beyond → FAR rate


func _camera_pos() -> Vector3:
	var f: int = int(Engine.get_physics_frames())
	if f != _cam_frame:
		_cam_frame = f
		var vp: Viewport = get_viewport()
		var cam: Camera3D = vp.get_camera_3d() if vp != null else null
		_cam_pos = cam.global_position if cam != null else Vector3(INF, INF, INF)
	return _cam_pos


# Distance LOD for the O(n) schooling recompute: near fish re-plan every THINK_STRIDE frames, distant
# ones far less often. The per-frame habitability correction + movement below are UNAFFECTED, so a fish
# never glides onto land regardless of distance — only the discretionary steer is throttled.
func _think_stride() -> int:
	var cam: Vector3 = _camera_pos()
	if is_inf(cam.x):
		return THINK_STRIDE
	var d2: float = global_position.distance_squared_to(cam)
	if d2 < NEAR_LOD_D2:
		return THINK_STRIDE
	if d2 < MID_LOD_D2:
		return MID_THINK_STRIDE
	return FAR_THINK_STRIDE


func _physics_process(delta: float) -> void:
	if LAAblate.off("fish"):
		return
	if _dying:
		return
	age += delta
	if _think_phase < 0:
		_think_phase = int(get_instance_id())                  # raw id; the think stagger is (id % stride)
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
	# Local "up": radial on a planet, +Y on the flat island. Used for every up-reference below.
	var up: Vector3 = terrain.up_at(pos) if terrain != null else Vector3.UP

	# BREATHE YOUR MEDIUM (same 3D head-cell read as land animals). GILLS ("water") breathe underwater and
	# suffocate in air; LUNGS ("air") breathe at the surface and drown if their reserve runs out underwater.
	# Basking species (handled above) are exempt while hauled out. The "head" is one body-radius up.
	# Submerged = the top of the body stays below the spherical sea shell.
	var body_r: float = pos.distance_to(terrain.planet_center())
	var submerged: bool = (terrain.sea_radius() - (body_r + size)) > 0.0
	var in_medium: bool = submerged if breathes == "water" else not submerged
	if in_medium:
		_breath = minf(_breath + BREATH_REFILL * delta, breath_capacity)
	else:
		_breath -= delta
		if _breath <= 0.0:
			die("drowned" if breathes == "air" else "suffocated")
			return

	# DECISION THROTTLE: recompute the swim intention (wander jitter + the O(n) schooling steer) only
	# every THINK_STRIDE frames, instance-staggered. Between updates the fish keeps its last _heading —
	# the habitability correction + movement below still run EVERY frame, so it never glides onto land.
	var desired: Vector3 = _heading
	var stride: int = _think_stride()
	var do_think: bool = (int(Engine.get_physics_frames()) + _think_phase) % stride == 0
	if do_think:
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = randf_range(1.0, 2.5)
			# Isotropic 3D jitter; the tangent-plane projection below keeps it in the swim plane
			# (identical to the old flat (x,0,z) jitter when up == +Y).
			var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0) * 0.7
			desired = _heading + jitter
		desired += _school_steer(pos, up)
		# Insectivore/planktivore swimmers steer toward (and eat) the nearest prey — the aquatic web's bottom.
		if not preys_on.is_empty():
			desired += _forage_steer(pos, up)
	# Flatten the intention into the local tangent plane (was desired.y = 0.0 for the flat +Y world).
	desired = desired - up * desired.dot(up)

	# Test the step: if it would leave habitable water (dry, OR water outside this species' salinity /
	# depth band), steer back toward the nearest habitable cell. This ONE rule self-sorts every species.
	var candidate: Vector3 = desired.normalized() if desired.length() > 0.001 else _heading
	var step_len: float = speed * delta

	# Swim tangentially inside the spherical water shell; the helper sets global_position.
	if _swim_planet(pos, candidate, step_len, up):
		return                     # hauled out to bask this frame

	# Face the swim heading; "up" is radial on a planet, +Y on the flat island.
	if _heading.length() > 0.01:
		var look: Vector3 = global_position + _heading
		if not look.is_equal_approx(global_position):
			look_at(look, up)


# Loose schooling with nearby SAME-SPECIES swimmers: cohesion + alignment (same shared idea as creature
# flocking). Scanning the PER-SPECIES group ("species_<kind>") — not the shared "aquatic life" group — keeps
# this O(own-species²) instead of O(all-aquatic²): a school only ever considers its own kind, so a big sea
# (many species) never makes each fish sweep every other swimmer. (Same result the species filter gave.)
func _school_steer(pos: Vector3, up: Vector3) -> Vector3:
	var mates: Array = get_tree().get_nodes_in_group("species_%s" % species)
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
	# Keep cohesion + alignment in the local tangent plane (was .y = 0.0 for the flat +Y world).
	cohesion = cohesion - up * cohesion.dot(up)
	align = align - up * align.dot(up)
	var steer: Vector3 = Vector3.ZERO
	if cohesion.length() > 0.001:
		steer += cohesion.normalized() * 0.5
	if align.length() > 0.001:
		steer += align.normalized() * 0.5
	return steer * SCHOOL_WEIGHT


# FORAGING: steer toward the nearest edible prey (config `preys_on`) inside the sense radius, and EAT it on
# contact. The aquatic mirror of a land predator's hunt, but simpler — a swimmer has no metabolism, so eating
# just removes the prey (bounding its numbers) and gives the fish a real reason to chase the bug/shrimp
# clouds. Returns a tangent-plane steer toward the prey (ZERO when there is none, or right after eating one).
func _forage_steer(pos: Vector3, up: Vector3) -> Vector3:
	var prey: Node3D = _nearest_prey(pos)
	if prey == null:
		return Vector3.ZERO
	var to_prey: Vector3 = prey.global_position - pos
	var reach: float = maxf(size + 0.5, 0.7)
	if to_prey.length() <= reach:
		_eat_prey(prey)
		return Vector3.ZERO
	# Keep the pull in the local swim (tangent) plane, exactly like schooling/wander.
	var steer: Vector3 = to_prey - up * to_prey.dot(up)
	if steer.length() > 0.001:
		return steer.normalized() * FORAGE_WEIGHT
	return Vector3.ZERO


# Nearest visible prey of any species in `preys_on`, within sense_radius, via the shared frame-stamped
# spatial index (rebuilt once/frame/group across every swimmer — O(active), not an O(n²) group sweep).
func _nearest_prey(pos: Vector3) -> Node3D:
	var groups: Array = []
	for sp in preys_on:
		groups.append("species_" + String(sp))
	_forage_index.rebuild_if_stale(get_tree(), Engine.get_physics_frames(), groups)
	var best: Node3D = null
	var best_d: float = sense_radius
	for sp in preys_on:
		for cand in _forage_index.query("species_" + String(sp), pos, best_d):
			if cand == self or not is_instance_valid(cand):
				continue
			var d: float = pos.distance_to((cand as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = cand as Node3D
	return best


# Consume a prey actor: kill it through its own death path (bugs/shrimp are LAFish → die() splashes + frees).
# No energy transfer — swimmers have no metabolism; the point is that eating BOUNDS the prey population.
func _eat_prey(prey: Node3D) -> void:
	if prey == null or not is_instance_valid(prey):
		return
	var prey_species: String = String(prey.get("species")) if "species" in prey else ""
	LASimReport.event("predation", {"species": species, "prey": prey_species})
	if prey.has_method("die"):
		prey.die("eaten")
	elif prey.has_method("queue_free"):
		prey.queue_free()


# Species submerge depth for this frame. Gill-breathers ride at the fixed submerge. An air-breather cycles
# emergently: dive to forage while it has breath, then rise so its head breaks the surface once the reserve
# runs low — the "dive down, come up to breathe" behavior falls out of the breath reserve, no scripted timer.
func _eff_submerge() -> float:
	var eff_submerge: float = submerge
	if breathes == "air":
		if _breath < breath_capacity * 0.35:
			eff_submerge = -size * 0.6                       # low on air → surface (head above water) to breathe
		elif dive_depth > 0.0:
			eff_submerge = dive_depth                        # plenty of air → dive deep to forage
	return eff_submerge


# --- PLANET (radial) swimming --------------------------------------------------
# The spherical analogue of the flat step logic above: the fish swims tangentially inside the WATER SHELL
# (between the solid surface_radius floor and the sea_radius surface), riding `submerge` below the sea
# shell exactly as the flat fish rides `submerge` below the sea plane. Sets global_position; returns true
# only when a basking species hauled out (so the caller returns for this frame). Same steer/correct/hold
# structure as flat — only the coordinate frame differs.
func _swim_planet(pos: Vector3, candidate: Vector3, step_len: float, up: Vector3) -> bool:
	var center: Vector3 = terrain.planet_center()
	var sea: float = terrain.sea_radius()
	var next_pos: Vector3 = pos + candidate * step_len
	var next_dir: Vector3 = (next_pos - center).normalized()
	if not _habitable_dir(next_dir):
		if basks and _bask_cd <= 0.0 and randf() < BASK_CHANCE and _try_bask_planet(next_dir):
			return true
		var back: Vector3 = _find_habitable_dir_planet(pos, up)
		if back != Vector3.ZERO:
			candidate = back
			state = "seek"
		else:
			candidate = -_heading         # no habitable water found near: turn around
			state = "swim"
		next_pos = pos + candidate * step_len
		next_dir = (next_pos - center).normalized()
		# If even the corrective step is unhabitable, hold position this frame (edge of a shrinking sea).
		if not _habitable_dir(next_dir):
			next_pos = pos
			next_dir = (next_pos - center).normalized()
	else:
		state = "swim"

	_heading = candidate if candidate.length() > 0.001 else _heading

	# Ride `eff_submerge` below the spherical sea shell; never sink below the solid sea floor (Rule 5).
	var eff_submerge: float = _eff_submerge()
	var target_r: float = sea - eff_submerge
	var sr: float = terrain.surface_radius(next_dir)
	if not is_nan(sr):
		target_r = maxf(target_r, sr + size)               # never sink through the solid floor
	# Gills must NEVER be lifted above the sea shell: keep a water-breather's top (target_r + size) a margin
	# below the surface even where the floor clamp above would otherwise push it up into air. That air-clamp
	# in thin shoreline water is exactly what suffocates gill fish in the shallows. Air-breathers are exempt —
	# their eff_submerge deliberately breaches the surface so they can breathe (whale/turtle/bug).
	if breathes == "water":
		target_r = minf(target_r, sea - size - GILL_SUBMERGE_MARGIN)
	global_position = center + next_dir * target_r
	return false


# PLANET: true where a WATER SHELL exists along `dir` — the solid surface radius sits below the sea shell.
# (The planet substrate has no 2.5D salinity/depth band, so shell presence is the habitability rule here.)
func _habitable_dir(dir: Vector3) -> bool:
	var sr: float = terrain.surface_radius(dir)
	if is_nan(sr):
		return false                     # unmeshed patch: treat as non-habitable so the fish turns back
	var sea: float = terrain.sea_radius()
	if sr >= sea:
		return false                     # dry land above the waterline
	# Gill (water) breathers need a column deep enough to hold the whole body under the surface; thin
	# shoreline water would clamp them up into air and suffocate them, so it is NOT habitable for gills and
	# the correction steers them back toward deeper water. Air-breathers surface to breathe, so any water
	# shell is fine for them — their habitability stays plain shell-presence.
	if breathes == "water" and (sea - sr) < size * 2.0:
		return false
	return true


# PLANET: probe tangent directions (rings, like the flat version) for the nearest column that still has a
# water shell; return a tangent unit heading toward it. Pulls a strayed fish back over open sea.
func _find_habitable_dir_planet(pos: Vector3, up: Vector3) -> Vector3:
	var center: Vector3 = terrain.planet_center()
	var fwd: Vector3 = _heading - up * _heading.dot(up)
	if fwd.length() < 0.001:
		fwd = up.cross(Vector3.RIGHT)
		if fwd.length() < 0.001:
			fwd = up.cross(Vector3.FORWARD)
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(up).normalized()
	var radii: Array = [size * 3.0, sense_radius, sense_radius * 2.0]
	var dirs: int = 10
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var tdir: Vector3 = (fwd * cos(ang) + right * sin(ang)).normalized()
			var probe: Vector3 = pos + tdir * float(r)
			if _habitable_dir((probe - center).normalized()):
				return tdir
	return Vector3.ZERO


# PLANET: haul out onto the narrow dry beach band just above the waterline (surface_radius within 2 m of
# sea_radius). Mirrors the flat _try_bask, in radii instead of world-Y. Returns true if basking started.
func _try_bask_planet(dir: Vector3) -> bool:
	var sr: float = terrain.surface_radius(dir)
	if is_nan(sr):
		return false
	var sea: float = terrain.sea_radius()
	if sr < sea or sr > sea + 2.0:
		return false
	global_position = terrain.planet_center() + dir.normalized() * sr
	_bask_timer = BASK_DURATION
	_bask_cd = BASK_COOLDOWN + BASK_DURATION
	state = "bask"
	return true


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
