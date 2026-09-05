@tool
class_name LAMeteor
extends Node3D


const SPAWN_HEIGHT: float = 140.0          # drop height above the target for an ambient strike
const START_SPEED: float = 70.0            # initial fall speed for that drop
const BODY_RADIUS: float = 1.4
const FX_LINGER: float = 1.8               # seconds of FX after impact before free
const DAMAGE_SCALE: float = 1.6            # ecology damage radius = crater radius * this

enum State { IDLE, FALLING, IMPACTED }

var _terrain: Object = null                # LAVoxelTerrainService (duck-typed)
var _ecology: Object = null                # LAEcologyService (duck-typed)
var _state: int = State.IDLE
var _body_id: int = -1                     # the free body LABallistics is flying
var _impact_velocity: Vector3 = Vector3.ZERO
var _body_material: StandardMaterial3D = null
var _target: Vector3 = Vector3.ZERO
var _fx_time: float = 0.0
var _impact_point: Vector3 = Vector3.ZERO
var _spawned_at: Vector3 = Vector3.ZERO

var _body: MeshInstance3D = null
var _glow: OmniLight3D = null
var _trail: GPUParticles3D = null
var _picker: StaticBody3D = null

# Per-meteor size, drawn on launch: the impactor's own diameter, in body radii.
var _size: float = 1.0


func _ready() -> void:
	add_to_group("selectable")
	add_to_group("la_ballistics")
	_build_visuals()


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


## Transient crater radius, m: D = 1.161 (rho_i/rho_t)^(1/3) L^0.78 v^0.44 g^-0.22 (sin theta)^(1/3)
## (Melosh 1989, Impact Cratering, eq. 7.8.4). Rock into rock, so the density ratio is 1.
func _radius() -> float:
	var g: float = LABallistics.g_at(_impact_point).length()
	var v: float = _impact_velocity.length()
	if not (g > 0.0 and v > 0.0):
		return 0.0
	var up: Vector3 = _up_at(_impact_point)
	var sin_theta: float = clampf(-_impact_velocity.normalized().dot(up), 0.0, 1.0)
	if sin_theta <= 0.0:
		return 0.0
	var l: float = 2.0 * BODY_RADIUS * _size
	return 0.5 * 1.161 * pow(l, 0.78) * pow(v, 0.44) * pow(g, -0.22) * pow(sin_theta, 1.0 / 3.0)


func launch(target: Vector3, from_pos: Vector3 = Vector3(INF, INF, INF), size_scale: float = 1.0) -> void:
	_target = target
	# The caller's size hint scales the rock the brush flings.
	_size = clampf(LASimRng.for_domain("planet").randf_range(0.55, 2.3) * size_scale, 0.2, 8.0)
	var velocity: Vector3 = Vector3.ZERO
	if is_finite(from_pos.x) and is_finite(from_pos.y) and is_finite(from_pos.z):
		# Player-fired: leave the camera along the aim ray at the local circular-orbit speed and coast.
		var aim: Vector3 = target - from_pos
		if aim.length() < 0.001:
			aim = Vector3.DOWN
		aim = aim.normalized()
		_spawned_at = from_pos + aim * 3.0
		velocity = aim * LAGravity.circular_speed(get_tree(), _spawned_at)
	else:
		# Auto/ambient drop: spawn radially "up" (away from the nearest body's core) above the target and
		# fall inward, so ballistic strikes head straight at the planet instead of drifting toward world -Y.
		var up0: Vector3 = _up_at(target)
		var tangent: Vector3 = up0.cross(Vector3.RIGHT)
		if tangent.length() < 0.01:
			tangent = up0.cross(Vector3.FORWARD)
		tangent = tangent.normalized()
		var lateral: Vector3 = tangent * LASimRng.for_domain("planet").randf_range(-24.0, 24.0) + up0.cross(tangent).normalized() * LASimRng.for_domain("planet").randf_range(-24.0, 24.0)
		_spawned_at = target + up0 * SPAWN_HEIGHT + lateral
		var dir: Vector3 = _target - _spawned_at
		if dir.length() < 0.001:
			dir = -up0
		velocity = dir.normalized() * START_SPEED
	global_position = _spawned_at
	_body_id = LABallistics.drop(_spawned_at, velocity, _impact_mass_kg(), BODY_RADIUS * _size)
	# Bigger rock = bigger visual body, glow and trail.
	if _body != null:
		_body.scale = Vector3.ONE * _size
	if _glow != null:
		_glow.omni_range = 30.0 * _size
	_state = State.FALLING
	if _trail != null:
		_trail.emitting = true


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	match _state:
		State.FALLING:
			lines.append("Status: falling")
			lines.append("Speed: %.0f m/s" % float(LABallistics.state(_body_id).get("speed", 0.0)))
			var alt: float = _terrain.altitude_at(global_position) if _terrain != null and _terrain.has_method("altitude_at") else global_position.y
			lines.append("Altitude: %.0f" % alt)
		State.IMPACTED:
			lines.append("Status: impacted")
			lines.append("Crater radius: %.0f" % _radius())
		_:
			lines.append("Status: idle")
	lines.append("Target: (%.0f, %.0f, %.0f)" % [_target.x, _target.y, _target.z])
	return {"title": "Meteor", "lines": lines}


func _physics_process(delta: float) -> void:
	match _state:
		State.FALLING:
			_follow_body()
		State.IMPACTED:
			_fx_time += delta
			if _fx_time >= FX_LINGER:
				queue_free()


## The rock is where LABallistics put it. Nothing here integrates: this reads the one integrator's state
## and points the mesh along the flight.
func _follow_body() -> void:
	var st: Dictionary = LABallistics.state(_body_id)
	if st.is_empty():
		queue_free()
		return
	global_position = st["position"]
	var vel: Vector3 = st["velocity"]
	if vel.length() > 0.01:
		var vdir: Vector3 = vel.normalized()
		var up_hint: Vector3 = _up_at(global_position)
		look_at(global_position + vel, up_hint if absf(up_hint.dot(vdir)) < 0.98 else Vector3.UP)
	# It left the system: the orbit about the body it is nearest is unbound. An orbiting rock stays.
	if LAGravity.is_unbound(get_tree(), global_position, vel):
		LABallistics.release(_body_id)
		queue_free()


## The integrator's landing report.
func on_bodies_landed(rows: Array) -> void:
	if _state != State.FALLING:
		return
	for row in rows:
		if int(row["id"]) != _body_id:
			continue
		_impact_point = row["position"]
		_impact_velocity = LABallistics.state(_body_id).get("velocity", Vector3.ZERO)
		global_position = _impact_point
		LABallistics.release(_body_id)
		_on_impact()
		return


func _impact_mass_kg() -> float:
	var r: float = BODY_RADIUS * _size
	return LAPhysical.ROCK_DENSITY_KG_M3 * (4.0 / 3.0) * PI * r * r * r


func _impact_energy_j() -> float:
	var speed: float = _impact_velocity.length()
	return 0.5 * _impact_mass_kg() * speed * speed


## Radial "up" (away from the nearest gravity body's core) at a world point — the dominant body, else the
## terrain planet, else world up. Used for the ballistic spawn + orientation so nothing assumes world +Y.
func _up_at(pos: Vector3) -> Vector3:
	var b: Object = LAGravity.dominant_body(get_tree(), pos) if is_inside_tree() else null
	if b != null and b.has_method("center"):
		var r: Vector3 = pos - (b.center() as Vector3)
		if r.length() > 0.001:
			return r.normalized()
	if _terrain != null and _terrain.has_method("up_at"):
		return _terrain.up_at(pos)
	return Vector3.UP


func _on_impact() -> void:
	_state = State.IMPACTED
	_fx_time = 0.0

	# Momentum into the planet's orbit: the rock's own mass times its impact velocity.
	var orbits: Node = get_tree().get_first_node_in_group("system_orbits")
	if orbits != null and orbits.has_method("apply_impulse"):
		orbits.apply_impulse(_impact_velocity * _impact_mass_kg())

	var r: float = _radius()
	if _terrain != null and _terrain.has_method("carve_sphere"):
		_terrain.carve_sphere(_impact_point, r)
		if _ecology != null and _ecology.has_method("material_field"):
			var substrate: Object = _ecology.material_field()
			if substrate != null and substrate.has_method("resample_terrain"):
				substrate.resample_terrain(_impact_point, r * 1.5)
	if _ecology != null and _ecology.has_method("damage_sphere"):
		_ecology.damage_sphere(_impact_point, r * DAMAGE_SCALE)
	# Big splash if it struck water.
	if _ecology != null and _ecology.has_method("material_field"):
		var water: Object = _ecology.material_field()
		if water != null and water.has_method("is_water_at") and water.is_water_at(_impact_point):
			water.splash(_impact_point, 3.5 * _size)
			# White-hot rock hitting water flashes to steam — sizzle + a steam hiss.
			LAAudioDirector.emit(get_tree(), "sizzle", _impact_point)
			LAAudioDirector.emit(get_tree(), "steam", _impact_point)
	# Terror shockwave: everything that hears/feels the impact panics and flees.
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_impact_point, r * 6.0, 1.0)
	if _ecology != null and _ecology.has_method("material_field"):
		var field: Object = _ecology.material_field()
		if field != null and field._inject != null and field._inject.has_method("add_heat_energy"):
			field._inject.add_heat_energy(_impact_point, _impact_energy_j(), r * 2.2)
		# The impact is an ejecta source, the substrate's own primitive.
		if field != null and field.has_method("eject"):
			var up: Vector3 = (_impact_point - field._origin).normalized() if "_origin" in field else Vector3.UP
			field.eject(_impact_point, 0.4 * _size, 900.0 * _size, up * 0.6)
	# Steep terrain in the blast radius slumps downhill under gravity.
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

	LAAudioDirector.emit(get_tree(), "meteor_impact", _impact_point)


func _build_visuals() -> void:
	# Molten core mesh with a bright emissive material.
	_body = MeshInstance3D.new()
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = BODY_RADIUS
	sphere.height = BODY_RADIUS * 2.0
	_body.mesh = sphere
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.3, 0.28)
	_body_material = mat
	_body.material_override = mat
	add_child(_body)

	_glow = OmniLight3D.new()
	_glow.light_energy = 6.0
	_glow.omni_range = 30.0
	_glow.visible = false
	add_child(_glow)

	_trail = GPUParticles3D.new()
	_trail.emitting = false
	_trail.amount = 240
	_trail.lifetime = 1.1
	_trail.draw_pass_1 = _make_trail_mesh()
	var tp: ParticleProcessMaterial = ParticleProcessMaterial.new()
	tp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	tp.emission_sphere_radius = BODY_RADIUS * 0.8
	# Particles are emitted with almost no velocity so they hang in the air where the fireball WAS,
	# leaving a burning trail behind the moving meteor. They shrink and darken over their life.
	tp.direction = Vector3(0.0, 1.0, 0.0)
	tp.spread = 40.0
	tp.initial_velocity_min = 0.5
	tp.initial_velocity_max = 4.0
	tp.gravity = Vector3(0.0, 4.0, 0.0)          # hot embers loft a little as they trail
	tp.scale_min = 0.7
	tp.scale_max = 1.8
	tp.scale_curve = _trail_scale_curve()        # taper to nothing so it reads as a tapering tail
	tp.color = Color(1.0, 0.6, 0.18)
	tp.color_ramp = _fire_ramp()                 # white-hot -> orange -> smoke over the ember's life
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


# White-hot at birth (just off the fireball) fading through orange to dark smoke as each ember ages —
# the classic burning-reentry tail.
func _fire_ramp() -> GradientTexture1D:
	# Alpha fades from a hazy-hot core to fully transparent smoke, so the trail is translucent — you
	# see terrain through it and it dissolves rather than reading as a solid ribbon.
	var g: Gradient = Gradient.new()
	g.set_color(0, Color(1.0, 0.95, 0.7, 0.75))
	g.add_point(0.35, Color(1.0, 0.55, 0.12, 0.5))
	g.add_point(0.7, Color(0.6, 0.16, 0.05, 0.22))
	g.set_color(1, Color(0.12, 0.11, 0.11, 0.0))
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


# Embers start full-size and shrink to nothing, so the trail tapers to a point behind the meteor.
func _trail_scale_curve() -> CurveTexture:
	var c: Curve = Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	var tex: CurveTexture = CurveTexture.new()
	tex.curve = c
	return tex


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
