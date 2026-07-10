class_name LAVoxelSpawnBrush
extends Node3D

# Radius spawn brush + placement for the voxel world, factored out of the root. RMB (click or drag)
# applies the armed kind across a disk, so one gesture paints a grove of trees, a herd of rabbits, or a
# spreading flood — general over any armed kind (no per-kind branch beyond the terminal spawn). Owns the
# armed kind, brush radius, the ground footprint ring, and the paint stroke state. Dependency-free of the
# LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types only — no ':=' .)

const MeteorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Meteor.gd")
const EarthquakeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Earthquake.gd")
const FloodScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Flood.gd")

# Big self-directed storm systems place ONCE at the cursor (not scattered across the brush disk).
const SINGLETON_STORMS: PackedStringArray = ["tornado", "thunderstorm", "hurricane"]

const BRUSH_MIN: float = 1.0
const BRUSH_MAX: float = 28.0
const BRUSH_STEP: float = 1.5

var _world = null            # LAVoxelWorld (dynamic; method calls only)
var _terrain = null
var _camera: Camera3D = null
var _ecology: Node = null
var _hud: CanvasLayer = null
var _audio = null
var _actors_root: Node3D = null
var _disasters = null        # LAVoxelDisasters

var _armed_kind: String = ""
var _brush_radius: float = 5.0
var _painting: bool = false
var _paint_last_world: Vector3 = Vector3(INF, INF, INF)
var _brush_ring: MeshInstance3D = null


func setup(world, terrain, camera: Camera3D, ecology: Node, hud: CanvasLayer, audio, actors_root: Node3D, disasters) -> void:
	_world = world
	_terrain = terrain
	_camera = camera
	_ecology = ecology
	_hud = hud
	_audio = audio
	_actors_root = actors_root
	_disasters = disasters


func armed_kind() -> String:
	return _armed_kind


func set_armed_kind(kind: String) -> void:
	_armed_kind = kind


func is_painting() -> bool:
	return _painting


func brush_radius() -> float:
	return _brush_radius


# Begin a paint stroke (RMB press): drag keeps painting until stop_paint.
func start_paint(screen_pos: Vector2) -> void:
	_painting = true
	_paint_last_world = Vector3(INF, INF, INF)
	place_armed(screen_pos)


func stop_paint() -> void:
	_painting = false


# Ctrl + wheel resizes the brush disk.
func adjust_radius(grow: bool) -> void:
	var d: float = BRUSH_STEP if grow else -BRUSH_STEP
	_brush_radius = clampf(_brush_radius + d, BRUSH_MIN, BRUSH_MAX)
	_hud.set_status("Brush radius: %.0f m" % _brush_radius)


# RMB entry point: resolve the terrain point under the cursor and paint the armed kind there.
func place_armed(screen_pos: Vector2) -> void:
	var point: Vector3 = _terrain_point(screen_pos)
	if not is_finite(point.x):
		# Meteors can be flung at EMPTY SPACE — aim along the camera ray so you can put one into orbit, sling it
		# past the moon, or graze the atmosphere. It then coasts under real gravity. Everything else needs ground.
		if _armed_kind == "meteor":
			var ray: Dictionary = _camera.aim_ray(screen_pos)
			_apply_at(ray["origin"] + ray["dir"] * 1500.0)
			return
		_hud.set_status("No ground under cursor — aim at the terrain.")
		return
	_paint_brush(point)


# The terrain surface point under a screen position, or an INF vector if the cursor misses terrain.
func _terrain_point(screen_pos: Vector2) -> Vector3:
	var ray: Dictionary = _camera.aim_ray(screen_pos)
	var hit: Dictionary = _terrain.raycast_terrain(ray["origin"], ray["dir"], 2000.0)
	if not bool(hit.get("hit", false)):
		return Vector3(INF, INF, INF)
	return hit["position"]


# Apply the armed kind across the brush disk: one placement at the centre for a pinpoint brush,
# else a size-scaled scatter of placements. General over all kinds — trees, herds, floods alike.
func _paint_brush(center: Vector3) -> void:
	if _brush_radius <= BRUSH_MIN + 0.01 or SINGLETON_STORMS.has(_armed_kind):
		_apply_at(center)
	else:
		var n: int = clampi(int(round(_brush_radius * 0.6)), 1, 12)
		for i in n:
			_apply_at(_scatter_point(center))
	if _audio != null:
		_audio.play_sfx("spawn", center)
	_spawn_puff(center, _kind_color(_armed_kind))
	_paint_last_world = center


# A random point in the brush disk around `center`, re-snapped to the terrain surface (falls back
# to the centre height when the offset lands off the meshed area).
func _scatter_point(center: Vector3) -> Vector3:
	var ang: float = randf() * TAU
	var rad: float = sqrt(randf()) * _brush_radius
	var p: Vector3 = center + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	if _terrain != null and _terrain.has_method("ground_point"):
		var gp: Vector3 = _terrain.ground_point(p)          # radial re-seat onto the surface
		if not is_nan(gp.x):
			p = gp
	return p


# The single-point action for the armed kind (no puff/audio — the brush handles those once).
func _apply_at(point: Vector3) -> void:
	if _armed_kind == "meteor":
		var meteor: MeteorScript = MeteorScript.new()
		_actors_root.add_child(meteor)
		meteor.setup(_terrain, _ecology)
		# Launch from over the user's head, streaking toward the clicked point.
		meteor.launch(point, _camera.global_position)
		_world.set_destruction(1.0)
		_hud.set_status("Meteor inbound!")
	elif _armed_kind == "volcano":
		_disasters.spawn_volcano(point)
		_world.set_destruction(1.0)
		_hud.set_status("A volcano rises — stand back!")
	elif _armed_kind == "lightning":
		_disasters.spawn_lightning(point)
		_world.set_destruction(0.7)
		_hud.set_status("A bolt strikes!")
	elif _armed_kind == "earthquake":
		var quake: Node = EarthquakeScript.new()
		_actors_root.add_child(quake)
		quake.setup(_terrain, _ecology)
		quake.rupture(point)
		_world.set_destruction(1.0)
		_hud.set_status("The ground heaves!")
	elif _armed_kind == "flood":
		var flood: Node = FloodScript.new()
		_actors_root.add_child(flood)
		flood.setup(_terrain, _ecology)
		# Tie the surge footprint to the spawn brush so a flood only covers where the player aimed.
		flood.surge(point, _brush_radius)
		_hud.set_status("Flood surge!")
	elif _armed_kind == "tornado":
		_disasters.spawn_tornado(point)
		_world.set_destruction(0.8)
		_hud.set_status("A tornado touches down!")
	elif _armed_kind == "thunderstorm":
		_disasters.spawn_thunderstorm(point)
		_hud.set_status("A thunderstorm gathers!")
	elif _armed_kind == "hurricane":
		_disasters.spawn_hurricane(point)
		_world.set_destruction(1.0)
		_hud.set_status("A hurricane spins up!")
	else:
		_ecology.spawn(_armed_kind, point)
		_hud.set_status("Spawned %s." % _armed_kind)


# Continue a paint stroke as the cursor drags: re-paint once the brush has moved far enough that
# strokes don't stack on the same spot (spacing scales with radius).
func paint_drag(screen_pos: Vector2) -> void:
	var point: Vector3 = _terrain_point(screen_pos)
	if not is_finite(point.x):
		return
	if is_finite(_paint_last_world.x):
		var spacing: float = maxf(_brush_radius * 0.6, 1.5)
		if _paint_last_world.distance_to(point) < spacing:
			return
	_paint_brush(point)


# A flat ground ring showing the brush footprint, following the cursor whenever a kind is armed.
func update_brush_ring() -> void:
	if _armed_kind == "" or _camera == null or _terrain == null:
		if _brush_ring != null:
			_brush_ring.visible = false
		return
	_ensure_brush_ring()
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var mpos: Vector2 = vp.get_mouse_position()
	if _hud != null and _hud.has_method("is_pointer_over_ui") and _hud.is_pointer_over_ui(mpos):
		_brush_ring.visible = false
		return
	var p: Vector3 = _terrain_point(mpos)
	if not is_finite(p.x):
		_brush_ring.visible = false
		return
	_brush_ring.visible = true
	# Lie the flat torus in the tangent plane at p: its Y (the torus's flat-plane normal) tracks the local
	# radial normal, so on a sphere the ring hugs the surface instead of lying in the world XZ plane. Radius
	# scaling stays on the ring's own in-plane axes (X/Z), leaving the normal (Y) axis unit-length.
	var up: Vector3 = _terrain.up_at(p)
	var ring_basis: Basis = _ring_basis_from_up(up)
	ring_basis.x *= _brush_radius
	ring_basis.z *= _brush_radius
	_brush_ring.global_transform = Transform3D(ring_basis, p + up * 0.15)
	var mat: StandardMaterial3D = _brush_ring.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = _kind_color(_armed_kind)


func _ensure_brush_ring() -> void:
	if _brush_ring != null and is_instance_valid(_brush_ring):
		return
	var ring: MeshInstance3D = MeshInstance3D.new()
	ring.name = "BrushRing"
	var torus: TorusMesh = TorusMesh.new()   # lies flat in the XZ plane; scaled to the radius
	torus.inner_radius = 0.95
	torus.outer_radius = 1.0
	torus.rings = 48
	ring.mesh = torus
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.9, 0.9, 0.9, 0.75)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	add_child(ring)
	_brush_ring = ring


# An orthonormal basis whose Y axis is the given surface normal, so a flat (XZ-plane) mesh laid on it
# sits in the tangent plane at that point. The in-plane X/Z axes are an arbitrary but stable tangent
# pair (the ring is rotationally symmetric, so their heading doesn't matter).
func _ring_basis_from_up(up: Vector3) -> Basis:
	var n: Vector3 = up.normalized() if up.length() > 0.0001 else Vector3.UP
	var ref: Vector3 = Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
	var t: Vector3 = ref.cross(n).normalized()
	var b: Vector3 = n.cross(t)
	return Basis(t, n, b)


func _kind_color(kind: String) -> Color:
	match kind:
		"plant": return Color(0.35, 0.85, 0.3)
		"tree": return Color(0.2, 0.6, 0.25)
		"rabbit": return Color(0.92, 0.92, 0.95)
		"fox": return Color(0.95, 0.5, 0.15)
		"bird": return Color(0.3, 0.6, 0.95)
		"villager": return Color(0.75, 0.5, 0.9)
		"fish": return Color(0.55, 0.72, 0.86)
		"meteor": return Color(1.0, 0.5, 0.2)
		"volcano": return Color(0.95, 0.42, 0.12)
		"lightning": return Color(0.82, 0.88, 1.0)
		"earthquake": return Color(0.55, 0.40, 0.28)
		"flood": return Color(0.30, 0.55, 0.90)
		"tornado": return Color(0.55, 0.52, 0.5)
		"thunderstorm": return Color(0.4, 0.45, 0.6)
		"hurricane": return Color(0.35, 0.55, 0.75)
		_: return Color(0.8, 0.9, 0.6)


# Brief upward sparkle at a spawn point — instant "it worked" feedback.
func _spawn_puff(pos: Vector3, tint: Color) -> void:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 28
	p.lifetime = 1.1
	p.explosiveness = 0.85
	p.global_position = pos + Vector3(0, 0.4, 0)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)
	var qmat: StandardMaterial3D = StandardMaterial3D.new()
	qmat.albedo_color = tint
	qmat.emission_enabled = true
	qmat.emission = tint
	qmat.emission_energy_multiplier = 3.0
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = qmat
	p.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.6
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 2.5
	pm.initial_velocity_max = 5.0
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.color = tint
	p.process_material = pm
	add_child(p)
	var t: SceneTreeTimer = get_tree().create_timer(1.6)
	t.timeout.connect(func(): if is_instance_valid(p): p.queue_free())
