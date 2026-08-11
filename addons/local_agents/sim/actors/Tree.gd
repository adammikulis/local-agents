class_name LATree
extends StaticBody3D

## A natural-looking tree built entirely from code meshes (no external assets).
## A tapered brown trunk (CylinderMesh) plus a layered green canopy of overlapping
## foliage blobs. Per-tree seeded jitter in size / tilt / hue keeps a forest varied
## rather than cloned. Starts as a small sapling and grows to full size over ~20s.
##
## Species:
##   "oak" (default) -> rounded broadleaf, overlapping foliage spheres
##   "pine"          -> conical stacked cones, darker/taller/narrower
##
## Config keys (all optional):
##   "height":       float   base trunk height (units, ~3-7 typical)
##   "canopy_color": Color   foliage albedo (overrides species default)
##   "scale":        float   full-grown scale multiplier
##   "species":      String  "oak" | "pine"
##   "seed":         int     deterministic per-tree variation seed

const GROUP_SELECTABLE: String = "selectable"
const GROUP_TREE: String = "tree"

const GROW_TIME: float = 20.0        # seconds sapling -> full size ON FULLY PRODUCTIVE GROUND (see _growth_rate)
const START_FRACTION: float = 0.35   # freshly planted trees are visible immediately

## A TREE GROWS AT THE SPEED ITS GROUND FIXES CARBON, NOT AT THE SPEED OF A CLOCK.
##
## WHY THIS IS A GATE AND NOT A STOCK, stated because the Plant node next door got the opposite treatment and
## the difference is deliberate. A plant's edible RESERVE is CONSUMED: a herbivore eats it and it becomes
## animal energy, so it has to be real mass drawn out of the field's biomass channel or the food web mints
## matter. A tree's SCALE is not consumed by anything — the wood standing in a cell is already counted once,
## in that cell's `biomass`, and giving the node a second private wood stock would double-count the same
## carbon. So the honest fix here is to make the visual track the chemistry rather than to invent a ledger:
## a tree on ground photosynthesis never greened simply stops growing.
##
## The scale is the biomass at the tree's own cell against TREE_BIOMASS_FULL: the local standing crop at
## which a tree grows as fast as it can. A declared modelling choice, listed in docs/MODEL_PARAMETERS.md.
## Nothing about the tree's appearance enters it.
const TREE_BIOMASS_FULL: float = 0.0025
const TREE_GROWTH_FLOOR: float = 0.05   # a trickle even on poor ground, so a sapling on thin soil creeps up
                                        # rather than freezing forever at exactly START_FRACTION
const TOPPLE_TIME: float = 1.5       # seconds to fall flat
const TOPPLE_ANGLE: float = 1.483529 # ~85 degrees, avoids clipping through ground

var terrain = null             # terrain service exposing surface_height(x, z)
var _material = null           # LAMaterialField3D — the shared substrate this tree's growth reads (see _growth_rate)
var config: Dictionary = {}


## Wire the shared material field so this tree's growth tracks the carbon its ground actually fixes. Injected
## by LAEcologyService at spawn, exactly as plants and creatures get theirs.
func set_material_field(m) -> void:
	_material = m

## SPECIES ARE DATA, NOT BRANCHES. Trunk height range, canopy colour, canopy form and model id are all
## fields of a record here, so a third tree is a RECORD rather than an edit to five functions. `canopy` names
## the FORM, so a new species picks an existing canopy shape instead of needing new geometry code. Anything
## unlisted falls back to DEFAULT_SPECIES.
const SPECIES: Dictionary = {
	"oak": {
		"height": Vector2(3.0, 5.5),
		"canopy_color": Color(0.18, 0.42, 0.16),
		"canopy": "broadleaf",
		"model": "tree_oak",
	},
	"pine": {
		"height": Vector2(5.0, 7.0),
		"canopy_color": Color(0.12, 0.32, 0.14),   # darker evergreen
		"canopy": "conifer",
		"model": "tree_pine",
	},
}
const DEFAULT_SPECIES: String = "oak"

var species: String = "oak"
var trunk_height: float = 4.5
var canopy_color: Color = Color(0.18, 0.42, 0.16)
var trunk_color: Color = Color(0.32, 0.22, 0.13)
var max_scale: float = 1.0

var age: float = 0.0
var toppled: bool = false

# --- health / HP: a taller trunk takes more punishment before a blast fells it. 0 HP = topple. ---
var health: float = 100.0
var max_health: float = 100.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _tilt: float = 0.0               # small resting lean of the whole tree
var _upright_basis: Basis = Basis.IDENTITY
var _topple_axis: Vector3 = Vector3.RIGHT
var _topple_t: float = 0.0
var _topple_tween_active: bool = false

# GPU-instanced rendering: the tree registers with the shared LAVegetationRenderer and pushes its transform
# WHILE growing or toppling, then settles (zero per-frame render cost). Falls back to procedural trunk+canopy
# meshes if no renderer is wired (headless tests). Its visual type ("tree_oak"/"tree_pine") is its species.
var _veg = null                      # LAVegetationRenderer (injected before setup)
var _veg_slot: int = -1
var _render_settled: bool = false


func setup(_terrain, _config: Dictionary = {}) -> void:
	terrain = _terrain
	config = _config.duplicate(true)

	species = String(config.get("species", species)).to_lower()
	if not SPECIES.has(species):
		species = DEFAULT_SPECIES

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

	# Species foliage default, then optional override, then small hue jitter.
	canopy_color = def["canopy_color"]
	if config.has("canopy_color"):
		canopy_color = config["canopy_color"]
	canopy_color = _jitter_hue(canopy_color)
	trunk_color = _jitter_hue(Color(0.32, 0.22, 0.13), 0.03)

	# Slight resting lean so a stand of trees doesn't look regimented.
	_tilt = _rng.randf_range(-0.06, 0.06)

	# HP scales with trunk height: a big tree survives a blast that fells a sapling.
	max_health = maxf(60.0 + trunk_height * 40.0, 40.0)
	health = max_health

	collision_layer = 2
	collision_mask = 0
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_TREE)

	# Prefer the shared GPU-instanced renderer (one batched draw for every tree of this species). If wired,
	# register a slot and skip the per-tree model — the MultiMesh draws it. Otherwise build a Kenney Nature
	# Kit model (base-anchored), falling back to procedural trunk+canopy.
	var instanced: bool = false
	if _veg != null:
		_veg_slot = _veg.register(_render_type())
		instanced = _veg_slot >= 0
	if not instanced and not _build_model():
		_build_trunk()
		if String(_species_def()["canopy"]) == "conifer":
			_build_pine_canopy()
		else:
			_build_broadleaf_canopy()
	_build_collision()

	_apply_resting_tilt()
	_snap_to_surface()
	_apply_growth()
	_sync_render()   # push the initial sapling pose into the instanced batch


## This tree's species record, falling back to the default for an unrecognised name. setup() already coerces
## `species` into the table, so the fallback only matters if something writes the field directly.
func _species_def() -> Dictionary:
	return SPECIES.get(species, SPECIES[DEFAULT_SPECIES])


func _jitter_hue(base: Color, amount: float = 0.05) -> Color:
	var h: float = base.h + _rng.randf_range(-amount, amount)
	var s: float = clampf(base.s + _rng.randf_range(-0.06, 0.06), 0.0, 1.0)
	var v: float = clampf(base.v + _rng.randf_range(-0.08, 0.08), 0.0, 1.0)
	return Color.from_hsv(fposmod(h, 1.0), s, v, base.a)


func _make_material(col: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.95
	mat.metallic = 0.0
	return mat


## Build the species model at trunk height. Returns true on success, false to trigger the
## procedural fallback (unknown species model / load failure).
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


func _build_trunk() -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "Trunk"
	var trunk: CylinderMesh = CylinderMesh.new()
	var bottom: float = lerpf(0.22, 0.42, clampf(trunk_height / 7.0, 0.0, 1.0))
	trunk.bottom_radius = bottom
	trunk.top_radius = bottom * 0.55       # taper: top narrower than bottom
	trunk.height = trunk_height
	trunk.radial_segments = 8
	mesh.mesh = trunk
	mesh.position = Vector3(0.0, trunk_height * 0.5, 0.0)
	mesh.material_override = _make_material(trunk_color)
	add_child(mesh)


func _build_broadleaf_canopy() -> void:
	# 2-4 overlapping spheres clustered at the crown for a rounded, natural look.
	var blobs: int = _rng.randi_range(3, 4)
	var crown: float = trunk_height
	var base_r: float = maxf(trunk_height * 0.34, 0.9)
	var mat: StandardMaterial3D = _make_material(canopy_color)
	for i in range(blobs):
		var blob: MeshInstance3D = MeshInstance3D.new()
		blob.name = "Foliage%d" % i
		var ball: SphereMesh = SphereMesh.new()
		var r: float = base_r * _rng.randf_range(0.7, 1.05)
		ball.radius = r
		ball.height = r * 2.0
		ball.radial_segments = 10
		ball.rings = 6
		blob.mesh = ball
		# First blob centred on the crown; the rest offset around/above it.
		var off: Vector3 = Vector3.ZERO
		if i > 0:
			off = Vector3(
				_rng.randf_range(-base_r * 0.6, base_r * 0.6),
				_rng.randf_range(-base_r * 0.1, base_r * 0.5),
				_rng.randf_range(-base_r * 0.6, base_r * 0.6))
		blob.position = Vector3(0.0, crown + base_r * 0.4, 0.0) + off
		blob.material_override = mat
		add_child(blob)


func _build_pine_canopy() -> void:
	# Stacked cones tapering upward for a conical evergreen silhouette.
	var tiers: int = _rng.randi_range(3, 4)
	var mat: StandardMaterial3D = _make_material(canopy_color)
	var base_r: float = maxf(trunk_height * 0.3, 0.8)
	var tier_h: float = trunk_height * 0.42
	var start_y: float = trunk_height * 0.55
	for i in range(tiers):
		var frac: float = float(i) / float(tiers)
		var cone: MeshInstance3D = MeshInstance3D.new()
		cone.name = "Cone%d" % i
		var mesh: CylinderMesh = CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = base_r * (1.0 - frac * 0.7)
		mesh.height = tier_h
		mesh.radial_segments = 8
		cone.mesh = mesh
		cone.position = Vector3(0.0, start_y + frac * (trunk_height * 0.75) + tier_h * 0.5, 0.0)
		cone.material_override = mat
		add_child(cone)


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


func _snap_to_surface() -> void:
	if terrain == null:
		return
	# Snap onto the solid surface along our radial ray.
	var center: Vector3 = terrain.planet_center()
	var dir: Vector3 = (global_position - center).normalized()
	var surf: Vector3 = terrain.surface_point(dir)
	if not is_nan(surf.x):
		global_position = surf


const TREE_SETTLE_STRIDE: int = 30   # a mature tree advances age ~every 30 frames (catch-up dt) — Big-O by relevance
var _settle_accum: float = 0.0
var _settle_phase: int = -1

func _physics_process(delta: float) -> void:
	if LAAblate.off("trees"):
		return
	if toppled:
		# The Tween (if any) drives the fall; otherwise lerp it here.
		if not _topple_tween_active:
			_advance_topple(delta)
		# Follow the fall in the instanced batch until it settles flat.
		if not _render_settled:
			_sync_render()
			if _topple_t >= 1.0:
				_render_settled = true
		return
	# A mature tree (settled, not toppled) has no per-frame work — its scale is final and the render batch is
	# already synced — so advance its age on a coarse staggered cadence (catch-up dt) and skip the redundant
	# _apply_growth() scale write. Hundreds of grown trees stop each dirtying a transform every frame; a
	# topple (handled above, every frame) still wakes it live.
	if _render_settled:
		if _settle_phase < 0:
			_settle_phase = int(get_instance_id())
		_settle_accum += delta
		if LALodStride.should_run(int(Engine.get_physics_frames()), _settle_phase, TREE_SETTLE_STRIDE):
			age += _settle_accum
			_settle_accum = 0.0
		return
	age += delta * _growth_rate()
	_apply_growth()
	# Push the growing pose until mature; then settle (no per-frame render cost) until a topple wakes it.
	_sync_render()
	if _grown_fraction() >= 1.0:
		_render_settled = true


## How fast this tree may add wood right now, in [TREE_GROWTH_FLOOR, 1], from the standing biomass the
## photosynthesis chemistry has fixed in its own cell. This is the whole coupling: a grove on rich equatorial
## ground fills out in GROW_TIME, a sapling on a cold thin margin creeps, and neither needs a per-species
## branch or a placement table. With no field wired (headless tests, the box demo) it falls back to 1.0 so
## nothing that has no chemistry to consult silently stops growing.
func _growth_rate() -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 1.0
	var pos: Vector3 = global_position
	var b: float = _material.biomass_at(pos.x, pos.y, pos.z)
	return clampf(b / TREE_BIOMASS_FULL, TREE_GROWTH_FLOOR, 1.0)


func _grown_fraction() -> float:
	return clampf(age / GROW_TIME, START_FRACTION, 1.0)


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
