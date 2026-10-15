class_name LATree
extends StaticBody3D


const GROUP_SELECTABLE: String = "selectable"
const GROUP_TREE: String = "tree"

## Years from germination to full stem height for a temperate tree on ground that fixes its whole crop.
const MATURE_YEARS: float = 60.0
const MATURE_SECONDS: float = MATURE_YEARS * LAPhysical.SECONDS_PER_YEAR

const TREE_BIOMASS_FULL: float = 0.0025
const TOPPLE_TIME: float = 1.5       # seconds to fall flat
const TOPPLE_ANGLE: float = 1.483529 # ~85 degrees, avoids clipping through ground

var terrain = null             # terrain service exposing surface_height(x, z)
var _material = null           # LAMaterialField3D — the shared substrate this tree's growth reads (see _growth_rate)
var config: Dictionary = {}


## Wire the shared material field so this tree's growth tracks the carbon its ground actually fixes. Injected
## by LAEcologyService at spawn, exactly as plants and creatures get theirs.
func set_material_field(m) -> void:
	_material = m

const SPECIES: Dictionary = {
	"oak": {
		"height": Vector2(3.0, 5.5),
		"model": "tree_oak",
	},
	"pine": {
		"height": Vector2(5.0, 7.0),
		"model": "tree_pine",
	},
}
const DEFAULT_SPECIES: String = "oak"

var species: String = "oak"
var trunk_height: float = 4.5
var max_scale: float = 1.0

var age: float = 0.0
var toppled: bool = false

var health: float = 100.0
var max_health: float = 100.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _tilt: float = 0.0               # small resting lean of the whole tree
var _upright_basis: Basis = Basis.IDENTITY
var _topple_axis: Vector3 = Vector3.RIGHT
var _topple_t: float = 0.0
var _topple_tween_active: bool = false

# GPU-instanced rendering: the tree pushes its transform to the shared LAVegetationRenderer while growing
# or toppling, then settles. Its visual type is its species.
var _veg = null                      # LAVegetationRenderer (injected before setup)
var _veg_slot: int = -1
var _render_settled: bool = false


func setup(_terrain, _config: Dictionary = {}) -> void:
	terrain = _terrain
	config = _config.duplicate(true)
	var loop: LASimLoop = LASimLoop.active()
	if loop == null:
		push_error("LATree: no simulation loop, so nothing advances this one's growth.")
	else:
		loop.subscribe(_on_sim_step)

	species = String(config.get("species", species)).to_lower()
	if not SPECIES.has(species):
		species = DEFAULT_SPECIES
	if bool(config.get("grown", false)):
		age = MATURE_SECONDS

	# "actors": placement-gated, so this draw count is not reproducible.
	var seed_val: int = int(config.get("seed", LASimRng.for_domain("actors").randi()))
	_rng.seed = seed_val

	var def: Dictionary = _species_def()

	# Base trunk height: config, else this species' random range.
	if config.has("height"):
		trunk_height = maxf(float(config["height"]), 1.0)
	else:
		var span: Vector2 = def["height"]
		trunk_height = _rng.randf_range(span.x, span.y)

	max_scale = maxf(float(config.get("scale", max_scale)), 0.05)

	# Slight resting lean so a stand of trees doesn't look regimented.
	_tilt = _rng.randf_range(-0.06, 0.06)

	# HP scales with trunk height: a big tree survives a blast that fells a sapling.
	max_health = maxf(60.0 + trunk_height * 40.0, 40.0)
	health = max_health

	collision_layer = 2
	collision_mask = 0
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_TREE)
	LAGroupIndex.shared().joined(self)

	# The shared GPU-instanced renderer draws every tree of this species in one batch; without it this
	# tree carries its own model.
	var instanced: bool = false
	if _veg != null:
		_veg_slot = _veg.register(_render_type())
		instanced = _veg_slot >= 0
	if not instanced and not _build_model():
		push_error("LATree: no vegetation renderer and no model for '%s', so this tree has no visual." % species)
	_build_collision()

	_apply_resting_tilt()
	_apply_growth()
	_sync_render()   # push the initial sapling pose into the instanced batch


## This tree's species record, falling back to the default for an unrecognised name. setup() already coerces
## `species` into the table, so the fallback only matters if something writes the field directly.
func _species_def() -> Dictionary:
	return SPECIES.get(species, SPECIES[DEFAULT_SPECIES])


func _build_model() -> bool:
	var id: String = String(_species_def()["model"])
	var def: Dictionary = LAActorModels.get_def(id)
	if String(def.get("path", "")).is_empty():
		return false
	var model: Node3D = LAModelVisual.build(def["path"], trunk_height, "base", float(def.get("yaw", 0.0)), Color(0, 0, 0, 0))
	if model == null:
		return false
	LAModelVisual.recolor(model, def.get("recolor", {}))   # fix Kenney's cyan-shifted foliage
	model.name = "TreeModel"
	add_child(model)
	return true


func _build_collision() -> void:
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "TrunkCollision"
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = maxf(trunk_height * 0.12, 0.3)
	cyl.height = trunk_height
	shape.shape = cyl
	shape.position = Vector3(0.0, trunk_height * 0.5, 0.0)
	add_child(shape)


# Local "up" the tree stands along: radial on a planet, +Y on the flat island (safe both modes).
func _up_axis() -> Vector3:
	if terrain != null and terrain.has_method("up_at"):
		var u: Vector3 = terrain.up_at(global_position)
		if u.length() > 0.0001:
			return u.normalized()
	return Vector3.UP


func _apply_resting_tilt() -> void:
	# Store the upright orientation (with lean) so topple can rotate from it.
	# Stand radially: local +Y = radial up, then apply the small resting lean about a tangent axis.
	var up: Vector3 = _up_axis()
	var ref: Vector3 = Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right: Vector3 = up.cross(ref).normalized()
	var fwd: Vector3 = right.cross(up).normalized()
	_upright_basis = Basis(right, up, fwd).rotated(right, _tilt)
	transform.basis = _upright_basis


const TREE_SETTLE_STRIDE: int = 30   # a mature tree advances age ~every 30 frames (catch-up dt) — Big-O by relevance
var _settle_accum: float = 0.0
var _settle_phase: int = -1

# A falling trunk is a rigid body swinging on the frame clock. Growth is not: see _on_sim_step.
func _physics_process(delta: float) -> void:
	if LAAblate.off("trees") or not toppled:
		return
	if not _topple_tween_active:
		_advance_topple(delta)
	if not _render_settled:
		_sync_render()
		if _topple_t >= 1.0:
			_render_settled = true


## Wood is laid down in SIMULATED seconds, on the same clock as the carbon it is made of.
func _on_sim_step(step: int) -> void:
	if LAAblate.off("trees") or toppled:
		return
	var delta: float = LASimLoop.step_seconds()
	if _render_settled:
		if _settle_phase < 0:
			_settle_phase = int(get_instance_id())
		_settle_accum += delta
		if LALodStride.should_run(step, _settle_phase, TREE_SETTLE_STRIDE):
			age += _settle_accum
			_settle_accum = 0.0
		return
	age += delta * _growth_rate()
	_apply_growth()
	_sync_render()
	if _grown_fraction() >= 1.0:
		_render_settled = true


func _growth_rate() -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 1.0
	var pos: Vector3 = global_position
	var b: float = _material.biomass_at(pos.x, pos.y, pos.z)
	if b <= 0.0 and LAFakes.stands_in("plant_carbon"):
		return 1.0     # nothing greens the ground yet, so the stand-in is the whole crop
	return clampf(b / TREE_BIOMASS_FULL, 0.0, 1.0)


## Height reached, as a fraction of this tree's full stem. A tree that germinated this second is a shoot,
## not nothing, so the smallest it can read is one shoot standing in its own trunk height.
func _grown_fraction() -> float:
	var shoot: float = LAPlant.SEEDLING_SHOOT_M / maxf(trunk_height, LAPlant.SEEDLING_SHOOT_M)
	return clampf(maxf(age / MATURE_SECONDS, shoot), 0.0, 1.0)


func _apply_growth() -> void:
	scale = Vector3.ONE * (_grown_fraction() * max_scale)


func _advance_topple(delta: float) -> void:
	_topple_t = minf(_topple_t + delta / TOPPLE_TIME, 1.0)
	var eased: float = ease(_topple_t, 2.2)   # accelerate as it falls
	var fall: Basis = Basis(_topple_axis, eased * TOPPLE_ANGLE)
	transform.basis = fall * _upright_basis


func get_inspector_payload() -> Dictionary:
	var title: String = "%s Tree" % species.capitalize()
	var status: String = "toppled" if toppled else ("mature" if _grown_fraction() >= 1.0 else "growing")
	return {
		"title": title,
		"lines": [
			"Species: %s" % species,
			"Height: %.1fm" % (trunk_height * max_scale),
			"Age: %.1fs (%s)" % [age, status],
			"Growth: %d%%" % int(_grown_fraction() * 100.0),
		],
	}


# Deterministic HP damage from a blast/lightning. When HP runs out the tree topples away from
# the blow (impulse direction); a felled tree ignores further damage.
func take_damage(amount: float, _cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void:
	if toppled or amount <= 0.0:
		return
	health -= amount
	if health <= 0.0:
		topple(impulse)


func topple(direction: Vector3) -> void:
	if toppled:
		return
	toppled = true
	_render_settled = false   # wake the instanced pose so the fall animates in the batch
	# Rotate about the tangent axis perpendicular to the fall direction. "Down" is along local up
	# (radial on a planet, +Y on the flat island), so project the fall direction into the tangent plane.
	var up: Vector3 = _up_axis()
	var dir: Vector3 = direction - up * direction.dot(up)
	if dir.length() < 0.001:
		var r: Vector3 = Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		dir = r - up * r.dot(up)
		if dir.length() < 0.001:
			dir = up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD)
	dir = dir.normalized()
	# Axis is perpendicular to fall direction and to up, so the crown swings
	# toward `direction`.
	_topple_axis = up.cross(dir).normalized()
	if _topple_axis.length() < 0.001:
		_topple_axis = Vector3.RIGHT
	_topple_t = 0.0

	# Animate via Tween if we are inside a tree; otherwise _physics_process lerps.
	if is_inside_tree():
		_topple_tween_active = true
		var tween: Tween = create_tween()
		tween.tween_method(_set_topple_progress, 0.0, 1.0, TOPPLE_TIME)
		tween.tween_callback(func() -> void: _topple_tween_active = false)


func _set_topple_progress(t: float) -> void:
	_topple_t = clampf(t, 0.0, 1.0)
	var eased: float = ease(_topple_t, 2.2)
	var fall: Basis = Basis(_topple_axis, eased * TOPPLE_ANGLE)
	transform.basis = fall * _upright_basis


# Injected by LAEcologyService before setup(): the shared GPU-instanced vegetation renderer.
func set_vegetation_renderer(r) -> void:
	_veg = r


# The instanced visual type is the tree's species — a separate MultiMesh per species keeps oak/pine coloured
# correctly (each has its own recolored prototype). Read from the species record, no per-species branch.
func _render_type() -> String:
	return String(_species_def()["model"])


# Write our current pose into the shared instanced batch. The prototype mesh is height-normalized to 1, so we
# scale by trunk_height; our node transform already carries orientation + growth scale + any topple rotation.
func _sync_render() -> void:
	if _veg_slot < 0 or _veg == null:
		return
	var b: Basis = transform.basis.scaled(Vector3.ONE * trunk_height)
	_veg.set_xform(_render_type(), _veg_slot, Transform3D(b, transform.origin))


func _exit_tree() -> void:
	if _veg_slot >= 0 and _veg != null:
		_veg.release(_render_type(), _veg_slot)
		_veg_slot = -1
