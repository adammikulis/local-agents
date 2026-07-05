@tool
class_name LAMeteor
extends Node3D

## A spawnable fireball that plummets toward a target world position, carves the
## voxel terrain and damages nearby life on impact, then cleans itself up after
## the FX. Built entirely in code (no external assets). Primary live-test tool
## for destruction. (Explicit types only — project rule: no ':=' inferred typing.)

# --- Tunables -----------------------------------------------------------------
const SPAWN_HEIGHT: float = 140.0          # how far above the target it appears
const START_SPEED: float = 70.0            # initial fall speed (units/s)
const GRAVITY: float = 55.0                # downward acceleration (units/s^2)
const MAX_SPEED: float = 260.0
const IMPACT_RADIUS: float = 10.0          # carve radius — large & dramatic
const DAMAGE_SCALE: float = 1.6            # ecology damage radius = radius * this
const BODY_RADIUS: float = 1.4
const FX_LINGER: float = 1.8               # seconds of FX after impact before free
const SAFETY_FALL_TIME: float = 12.0       # force impact if it never reaches ground

enum State { IDLE, FALLING, IMPACTED }

var _terrain: Object = null                # LAVoxelTerrainService (duck-typed)
var _ecology: Object = null                # LAEcologyService (duck-typed)
var _state: int = State.IDLE
var _velocity: Vector3 = Vector3.ZERO
var _target: Vector3 = Vector3.ZERO
var _fall_time: float = 0.0
var _fx_time: float = 0.0
var _impact_point: Vector3 = Vector3.ZERO
var _spawned_at: Vector3 = Vector3.ZERO

var _body: MeshInstance3D = null
var _glow: OmniLight3D = null
var _trail: GPUParticles3D = null
var _flash: OmniLight3D = null
var _burst: GPUParticles3D = null
var _picker: StaticBody3D = null

# Per-meteor size (randomized on launch): scales the rock, crater, heat, blast and ground shake so
# strikes vary from small bright pebbles to landscape-cratering giants.
var _size: float = 1.0


func _ready() -> void:
	add_to_group("selectable")
	_build_visuals()


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


## Effective impact radius for THIS meteor (base * its random size).
func _radius() -> float:
	return IMPACT_RADIUS * _size


## Launch toward `target`. If `from_pos` is finite it starts high ABOVE THAT POINT (the user's head)
## and streaks in from the player's direction; otherwise it falls from above the target. Size is
## randomized each launch so strikes vary in scale.
func launch(target: Vector3, from_pos: Vector3 = Vector3(INF, INF, INF)) -> void:
	_target = target
	_size = randf_range(0.55, 2.3)
	if is_finite(from_pos.x) and is_finite(from_pos.y) and is_finite(from_pos.z):
		# Start well over the user's head so the fireball arcs in from their vantage toward the target.
		_spawned_at = from_pos + Vector3(0.0, SPAWN_HEIGHT, 0.0)
	else:
		var lateral: Vector3 = Vector3(randf_range(-24.0, 24.0), 0.0, randf_range(-24.0, 24.0))
		_spawned_at = target + Vector3(0.0, SPAWN_HEIGHT, 0.0) + lateral
	global_position = _spawned_at
	# Bigger rock = bigger visual body, glow and trail.
	if _body != null:
		_body.scale = Vector3.ONE * _size
	if _glow != null:
		_glow.omni_range = 30.0 * _size
	var dir: Vector3 = _target - _spawned_at
	if dir.length() < 0.001:
		dir = Vector3.DOWN
	dir = dir.normalized()
	_velocity = dir * START_SPEED
	_fall_time = 0.0
	_state = State.FALLING
	if _trail != null:
		_trail.emitting = true


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	match _state:
		State.FALLING:
			lines.append("Status: falling")
			lines.append("Speed: %.0f u/s" % _velocity.length())
			lines.append("Altitude: %.0f" % global_position.y)
		State.IMPACTED:
			lines.append("Status: impacted")
			lines.append("Crater radius: %.0f" % IMPACT_RADIUS)
		_:
			lines.append("Status: idle")
	lines.append("Target: (%.0f, %.0f, %.0f)" % [_target.x, _target.y, _target.z])
	return {"title": "Meteor", "lines": lines}


func _physics_process(delta: float) -> void:
	match _state:
		State.FALLING:
			_step_fall(delta)
		State.IMPACTED:
			_fx_time += delta
			if _fx_time >= FX_LINGER:
				queue_free()


func _step_fall(delta: float) -> void:
	_fall_time += delta
	_velocity.y -= GRAVITY * delta
	if _velocity.length() > MAX_SPEED:
		_velocity = _velocity.normalized() * MAX_SPEED

	var next_pos: Vector3 = global_position + _velocity * delta
	var impact: Dictionary = _detect_impact(global_position, next_pos)
	if bool(impact.get("hit", false)):
		_impact_point = impact.get("point", next_pos)
		global_position = _impact_point
		_on_impact()
		return

	global_position = next_pos
	if _velocity.length() > 0.01:
		look_at(global_position + _velocity, Vector3.UP)

	if _fall_time > SAFETY_FALL_TIME:
		_impact_point = global_position
		_on_impact()


## Returns {"hit": bool, "point": Vector3}. Tries surface_height, then a swept
## raycast, then a fallback target plane so it always resolves.
func _detect_impact(from: Vector3, to: Vector3) -> Dictionary:
	var no_hit: Dictionary = {"hit": false, "point": Vector3.ZERO}

	if _terrain != null and _terrain.has_method("surface_height"):
		var gy: float = _terrain.surface_height(to.x, to.z)
		if not is_nan(gy) and to.y <= gy:
			return {"hit": true, "point": Vector3(to.x, gy, to.z)}

	if _terrain != null and _terrain.has_method("raycast_terrain"):
		var seg: Vector3 = to - from
		var dist: float = seg.length()
		if dist > 0.0001:
			var res: Dictionary = _terrain.raycast_terrain(from, seg / dist, dist + BODY_RADIUS)
			if bool(res.get("hit", false)):
				return {"hit": true, "point": res.get("position", to)}

	if _terrain == null and to.y <= _target.y:
		return {"hit": true, "point": Vector3(to.x, _target.y, to.z)}

	return no_hit


func _on_impact() -> void:
	_state = State.IMPACTED
	_fx_time = 0.0

	var r: float = _radius()                                   # size-scaled crater
	if _terrain != null and _terrain.has_method("carve_sphere"):
		_terrain.carve_sphere(_impact_point, r)
	if _ecology != null and _ecology.has_method("damage_sphere"):
		_ecology.damage_sphere(_impact_point, r * DAMAGE_SCALE)
	# Big splash if it struck water.
	if _ecology != null and _ecology.has_method("material_field"):
		var water: Object = _ecology.material_field()
		if water != null and water.has_method("is_water_at") and water.is_water_at(_impact_point.x, _impact_point.z):
			water.splash(_impact_point, 3.5 * _size)
			# White-hot rock hitting water flashes to steam — sizzle + a steam hiss.
			LocalAgentsAudioDirector.emit(get_tree(), "sizzle", _impact_point)
			LocalAgentsAudioDirector.emit(get_tree(), "steam", _impact_point)
	# Terror shockwave: everything that hears/feels the impact panics and flees.
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_impact_point, r * 6.0, 1.0)
	# The strike dumps its kinetic+thermal energy into the ground as a molten HEAT spike: the crater
	# glows incandescently (terrain shader) and cools over time, and vegetation that crosses the
	# ignition temperature catches fire — all emergent from the temperature field, nothing scripted.
	if _ecology != null and _ecology.has_method("material_field"):
		var field: Object = _ecology.material_field()
		if field != null and field.has_method("add_heat"):
			field.add_heat(_impact_point, 1600.0, r * 2.2)     # molten rock ~1600°C
	# Shake the ground: steep terrain in the blast radius slumps downhill under gravity (a meteor into
	# a mountainside triggers a slide — pure material physics, no landslide code).
	if _ecology != null and _ecology.has_method("disturb_ground"):
		_ecology.disturb_ground(_impact_point, r * 2.0, _size)

	if _body != null:
		_body.visible = false
	if _glow != null:
		_glow.visible = false
	if _trail != null:
		_trail.emitting = false
	if _picker != null:
		_picker.queue_free()
		_picker = null

	_spawn_impact_fx()
	_spawn_debris_chunks(_impact_point)

	# Procedural impact boom (presentation only; resolves the AudioDirector by group).
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _impact_point)


# Fling physical debris outward from the impact — a MIX of whatever was hit:
# topsoil, dirt clods and rock, colored to match the surface. Parented to the
# meteor's parent so debris persists after the meteor frees itself.
func _spawn_debris_chunks(world_point: Vector3) -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var palette: Array = _impact_material_palette(world_point)
	var n: int = 22
	for i in n:
		var chunk: RigidBody3D = RigidBody3D.new()
		chunk.collision_layer = 4          # debris layer (not pickable, not creatures)
		chunk.collision_mask = 1           # collide with terrain only
		chunk.gravity_scale = 1.4
		var is_dirt: bool = randf() < 0.6
		var sz: float = randf_range(0.22, 0.5) if is_dirt else randf_range(0.5, 1.2)
		var tint: Color = palette[randi() % palette.size()]
		if is_dirt:
			tint = tint.darkened(randf_range(0.0, 0.15))
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = LARockMesh.make(sz, randi(), 0.55 if is_dirt else 0.5)
		mi.material_override = LARockMesh.material(tint)
		chunk.add_child(mi)
		var col: CollisionShape3D = CollisionShape3D.new()
		var bs: SphereShape3D = SphereShape3D.new()
		bs.radius = sz * 0.85
		col.shape = bs
		chunk.add_child(col)
		parent.add_child(chunk)
		chunk.global_position = world_point + Vector3(randf_range(-2.5, 2.5), randf_range(1.0, 3.5), randf_range(-2.5, 2.5))
		var dir: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(1.1, 2.2), randf_range(-1.0, 1.0)).normalized()
		chunk.linear_velocity = dir * randf_range(11.0, 30.0)
		chunk.angular_velocity = Vector3(randf_range(-7, 7), randf_range(-7, 7), randf_range(-7, 7))
		var timer: SceneTreeTimer = get_tree().create_timer(16.0)
		timer.timeout.connect(func(): if is_instance_valid(chunk): chunk.queue_free())


# Approximate the surface materials at the impact (matching the triplanar terrain
# shader's height/slope rule) so debris is dirt/sand/grass/rock/snow as appropriate.
func _impact_material_palette(point: Vector3) -> Array:
	var normal: Vector3 = Vector3.UP
	if _terrain != null and _terrain.has_method("raycast_terrain"):
		var hit: Dictionary = _terrain.raycast_terrain(point + Vector3(0, 6, 0), Vector3.DOWN, 14.0)
		if bool(hit.get("hit", false)):
			normal = hit.get("normal", Vector3.UP)
	var y: float = point.y
	var steep: bool = normal.y < 0.62
	var dirt: Color = Color(0.40, 0.28, 0.18)
	var out: Array = [dirt, dirt]              # subsurface dirt is always thrown
	if steep:
		out.append(Color(0.45, 0.45, 0.47))
		out.append(Color(0.38, 0.37, 0.38))
	elif y < 2.5:
		out.append(Color(0.80, 0.74, 0.55))
	elif y > 55.0:
		out.append(Color(0.90, 0.93, 0.97))
		out.append(Color(0.62, 0.6, 0.6))
	else:
		out.append(Color(0.30, 0.55, 0.24))
		out.append(Color(0.34, 0.24, 0.15))
	return out


func _spawn_impact_fx() -> void:
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.75, 0.35)
	_flash.light_energy = 24.0
	_flash.omni_range = IMPACT_RADIUS * 8.0
	_flash.position = Vector3.ZERO
	add_child(_flash)
	var tw: Tween = create_tween()
	tw.tween_property(_flash, "light_energy", 0.0, FX_LINGER)

	_burst = GPUParticles3D.new()
	_burst.one_shot = true
	_burst.emitting = true
	_burst.amount = 96
	_burst.lifetime = FX_LINGER
	_burst.explosiveness = 1.0
	_burst.draw_pass_1 = _make_debris_mesh()
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = IMPACT_RADIUS * 0.6
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 75.0
	pm.initial_velocity_min = 12.0
	pm.initial_velocity_max = 42.0
	pm.gravity = Vector3(0.0, -30.0, 0.0)
	pm.scale_min = 0.4
	pm.scale_max = 1.6
	pm.color = Color(1.0, 0.55, 0.2)
	_burst.process_material = pm
	add_child(_burst)


func _build_visuals() -> void:
	# Molten core mesh with a bright emissive material.
	_body = MeshInstance3D.new()
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = BODY_RADIUS
	sphere.height = BODY_RADIUS * 2.0
	_body.mesh = sphere
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.25, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15)
	mat.emission_energy_multiplier = 6.0
	_body.material_override = mat
	add_child(_body)

	_glow = OmniLight3D.new()
	_glow.light_color = Color(1.0, 0.6, 0.25)
	_glow.light_energy = 6.0
	_glow.omni_range = 30.0
	add_child(_glow)

	_trail = GPUParticles3D.new()
	_trail.emitting = false
	_trail.amount = 120
	_trail.lifetime = 0.7
	_trail.draw_pass_1 = _make_trail_mesh()
	var tp: ParticleProcessMaterial = ParticleProcessMaterial.new()
	tp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	tp.emission_sphere_radius = BODY_RADIUS * 0.7
	tp.direction = Vector3(0.0, 1.0, 0.0)
	tp.spread = 25.0
	tp.initial_velocity_min = 2.0
	tp.initial_velocity_max = 8.0
	tp.gravity = Vector3.ZERO
	tp.scale_min = 0.5
	tp.scale_max = 1.4
	tp.color = Color(1.0, 0.65, 0.2)
	_trail.process_material = tp
	add_child(_trail)

	# Selection collider (layer 2) so it can be picked while falling.
	_picker = StaticBody3D.new()
	_picker.collision_layer = 2
	_picker.collision_mask = 0
	var col: CollisionShape3D = CollisionShape3D.new()
	var cs: SphereShape3D = SphereShape3D.new()
	cs.radius = BODY_RADIUS * 1.2
	col.shape = cs
	_picker.add_child(col)
	add_child(_picker)


func _make_trail_mesh() -> Mesh:
	var m: SphereMesh = SphereMesh.new()
	m.radius = 0.5
	m.height = 1.0
	m.radial_segments = 6
	m.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(1.0, 0.5, 0.1)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.material = mat
	return m


func _make_debris_mesh() -> Mesh:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(0.6, 0.6, 0.6)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.18, 0.14)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.35, 0.1)
	mat.emission_energy_multiplier = 2.0
	m.material = mat
	return m
