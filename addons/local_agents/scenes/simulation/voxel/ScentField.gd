class_name LAScentField
extends Node3D

# LAScentField — DECOUPLED OBSERVER per-species scent-trail system.
#
# Watches creatures from the outside and records a decaying trail of per-species
# "scent" markers as they move. Predators query the scent gradient to follow a
# trail toward the strongest/freshest scent of a given species. Never modifies
# creature scripts — reads only the `species` property and global transform of
# nodes in the "creature" group. All visuals generated in code (no assets).
#
# Weather coupling: WIND advects markers (predators downwind smell prey), and RAIN
# washes scent away (set_wash raises the decay rate). Poop/carrion deposit strong
# scent via the public deposit() API. (Explicit types only — no ':=' inferred typing.)

# --- Tunables ---------------------------------------------------------------
const DEPOSIT_DISTANCE: float = 0.6
## Seconds a fresh marker takes to fully decay in still, dry air. Rain multiplies this.
const LIFETIME: float = 42.0
## Fraction of the wind vector a marker drifts by each second.
const WIND_DRIFT: float = 0.35
const DEPOSIT_STRENGTH: float = 1.0
const SELF_IGNORE_RADIUS: float = 1.0
const MAX_MARKERS: int = 1500
const TEX_SIZE: int = 64
const BLOB_RADIUS: float = 1.6
const BLOB_HEIGHT_OFFSET: float = 0.6

const SPECIES_COLORS: Dictionary = {
	"rabbit": Color(0.45, 0.65, 1.0),
	"fox": Color(1.0, 0.55, 0.2),
	"bird": Color(0.3, 0.9, 1.0),
	"villager": Color(0.7, 0.4, 1.0),
}

# --- State ------------------------------------------------------------------
var _terrain = null
var _wind: Vector3 = Vector3.ZERO
var _wash: float = 1.0
var _last_deposit_pos: Dictionary = {}
# Each marker: { "pos": Vector3, "species": String, "strength": float, "age": float }
var _markers: Array = []

var _scent_visible: bool = false
var _mmi: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null
var _blob_texture: ImageTexture = null
var _blob_material: StandardMaterial3D = null


func setup(terrain) -> void:
	_terrain = terrain


# --- Observer loop ----------------------------------------------------------

func _physics_process(delta: float) -> void:
	_observe_creatures()
	_decay_markers(delta)
	if _scent_visible:
		_update_visualization()


func _observe_creatures() -> void:
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var creatures: Array = tree.get_nodes_in_group("creature")
	var seen: Dictionary = {}

	for node in creatures:
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		var id: int = node.get_instance_id()
		seen[id] = true
		var pos: Vector3 = (node as Node3D).global_transform.origin

		if not _last_deposit_pos.has(id):
			# First sighting: seed position, no deposit yet.
			_last_deposit_pos[id] = pos
			continue

		var last: Vector3 = _last_deposit_pos[id]
		var dx: float = pos.x - last.x
		var dz: float = pos.z - last.z
		if (dx * dx + dz * dz) < (DEPOSIT_DISTANCE * DEPOSIT_DISTANCE):
			continue

		var species: String = String(node.get("species")) if node.get("species") != null else "creature"
		_deposit(pos, species)
		_last_deposit_pos[id] = pos

	# Prune per-creature entries for creatures that vanished this frame.
	if _last_deposit_pos.size() != seen.size():
		for key in _last_deposit_pos.keys():
			if not seen.has(key):
				_last_deposit_pos.erase(key)


func _deposit(world_pos: Vector3, species: String) -> void:
	# Snap the marker onto the terrain surface when known.
	var y: float = world_pos.y
	if _terrain != null and _terrain.has_method("surface_height"):
		var h = _terrain.surface_height(world_pos.x, world_pos.z)
		if typeof(h) == TYPE_FLOAT or typeof(h) == TYPE_INT:
			var hf: float = float(h)
			if not (is_nan(hf) or is_inf(hf)):
				y = hf

	_markers.append({
		"pos": Vector3(world_pos.x, y, world_pos.z),
		"species": species,
		"strength": DEPOSIT_STRENGTH,
		"age": 0.0,
	})
	while _markers.size() > MAX_MARKERS:
		_markers.pop_front()


func _decay_markers(delta: float) -> void:
	if _markers.is_empty():
		return
	# Rain accelerates decay (washes scent away); wind drifts each marker.
	var rate: float = delta / LIFETIME * maxf(0.1, _wash)
	var drift: Vector3 = _wind * (WIND_DRIFT * delta)
	var has_wind: bool = _wind.length_squared() > 0.0001
	for i in range(_markers.size() - 1, -1, -1):
		var m: Dictionary = _markers[i]
		m["strength"] -= rate
		m["age"] += delta
		if has_wind:
			m["pos"] = (m["pos"] as Vector3) + drift
		if m["strength"] <= 0.0:
			_markers.remove_at(i)


# Weather hooks (called each frame by the world).
func set_wind(w: Vector3) -> void:
	_wind = Vector3(w.x, 0.0, w.z)


func set_wash(rain_intensity: float) -> void:
	# Dry: 1x decay. Downpour: up to ~5x (scent washed away fast).
	_wash = 1.0 + clampf(rain_intensity, 0.0, 1.0) * 4.0


# Public strong-deposit API (poop, carrion, marking).
func deposit(world_pos: Vector3, species: String, strength: float) -> void:
	_markers.append({
		"pos": world_pos,
		"species": species,
		"strength": clampf(strength, 0.0, 8.0),
		"age": 0.0,
	})
	while _markers.size() > MAX_MARKERS:
		_markers.pop_front()


# --- Query API for predators ------------------------------------------------

## Normalized direction toward the strength-weighted average marker position of
## `species` within `radius` (gradient ascent up the trail). ZERO if no trail.
func scent_direction(from: Vector3, species: String, radius: float) -> Vector3:
	if radius <= 0.0 or _markers.is_empty():
		return Vector3.ZERO
	var r2: float = radius * radius
	var self2: float = SELF_IGNORE_RADIUS * SELF_IGNORE_RADIUS
	var weighted: Vector3 = Vector3.ZERO
	var total_w: float = 0.0
	for m in _markers:
		if m["species"] != species:
			continue
		var p: Vector3 = m["pos"]
		var d2: float = from.distance_squared_to(p)
		if d2 > r2 or d2 < self2:
			continue
		var w: float = m["strength"]
		weighted += p * w
		total_w += w
	if total_w <= 0.0:
		return Vector3.ZERO
	var center: Vector3 = weighted / total_w
	var dir: Vector3 = center - from
	if dir.length() < 0.0001:
		return Vector3.ZERO
	return dir.normalized()


## Summed strength of markers of `species` within `radius` of `pos`.
func scent_strength(pos: Vector3, species: String, radius: float) -> float:
	if radius <= 0.0 or _markers.is_empty():
		return 0.0
	var r2: float = radius * radius
	var total: float = 0.0
	for m in _markers:
		if m["species"] != species:
			continue
		if pos.distance_squared_to(m["pos"]) <= r2:
			total += float(m["strength"])
	return total


func marker_count() -> int:
	return _markers.size()


# --- Smooth visualization (default OFF) -------------------------------------

func set_scent_visible(on: bool) -> void:
	_scent_visible = on
	if on and _mmi == null:
		_build_visualization()
	if _mmi != null:
		_mmi.visible = on
	if on:
		_update_visualization()


func _build_visualization() -> void:
	if _blob_texture == null:
		_blob_texture = _build_blob_texture()

	_blob_material = StandardMaterial3D.new()
	_blob_material.albedo_texture = _blob_texture
	_blob_material.vertex_color_use_as_albedo = true
	_blob_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_blob_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_blob_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_blob_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_blob_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_blob_material.disable_receive_shadows = true
	_blob_material.no_depth_test = false
	_blob_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(BLOB_RADIUS * 2.0, BLOB_RADIUS * 2.0)
	quad.material = _blob_material

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = quad
	_multimesh.instance_count = 0

	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _multimesh
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)


func _build_blob_texture() -> ImageTexture:
	# Soft radial gradient: white core fading smoothly to transparent edges — the
	# feathered falloff is what makes trails read as clouds, not blocky sprites.
	var img: Image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	var c: float = float(TEX_SIZE) * 0.5
	var r: float = float(TEX_SIZE) * 0.5
	for y in range(TEX_SIZE):
		for x in range(TEX_SIZE):
			var dx: float = (float(x) + 0.5 - c) / r
			var dy: float = (float(y) + 0.5 - c) / r
			var d: float = sqrt(dx * dx + dy * dy)
			if d >= 1.0:
				continue
			var a: float = 1.0 - d
			a = a * a * (3.0 - 2.0 * a)   # smoothstep easing
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _update_visualization() -> void:
	if _multimesh == null:
		return
	var count: int = _markers.size()
	if _multimesh.instance_count != count:
		_multimesh.instance_count = count
	for i in range(count):
		var m: Dictionary = _markers[i]
		var strength: float = clampf(float(m["strength"]), 0.0, 1.0)
		var p: Vector3 = m["pos"]
		var s: float = lerpf(0.5, 1.0, strength)
		var basis: Basis = Basis().scaled(Vector3(s, s, s))
		var origin: Vector3 = Vector3(p.x, p.y + BLOB_HEIGHT_OFFSET, p.z)
		_multimesh.set_instance_transform(i, Transform3D(basis, origin))
		var col: Color = _species_color(String(m["species"]))
		col.a = strength * 0.6
		_multimesh.set_instance_color(i, col)


func _species_color(species: String) -> Color:
	if SPECIES_COLORS.has(species):
		return SPECIES_COLORS[species]
	var h: float = float(hash(species) % 360) / 360.0
	return Color.from_hsv(h, 0.7, 1.0, 1.0)
