@tool
class_name LAMeteor
extends Node3D

## A meteor is NOT a scripted explosion — it is a falling hot fast rock (a seed/marker + visual) whose
## impact seeds the shared substrate ONCE. Everything downstream emerges with zero meteor code:
##   • emit_shock radiates a seismic wave (tremor + felt panic);
##   • eject throws molten mass as ballistic ejecta parcels that arc under radial gravity and re-deposit
##     — the debris fling and the ejecta blanket both fall out of the field, no per-actor chunk code;
##   • add_charge ionises the air above the crater → the field's breakdown discharges a bolt (the same
##     charge→bolt primitive a storm feeds);
##   • add_heat dumps the kinetic+thermal energy as a molten spike (crater glows, vegetation ignites);
##   • broadcast_scare / damage_sphere / disturb_ground panic, kill and slump via the shared stimuli;
##   • the crater itself emerges from the existing carve + ejecta redeposit.
##
## Deleted vs the old scripted meteor: `_spawn_debris_chunks` (22 RigidBody3D debris chunks with random
## velocities), `_impact_material_palette`, `_spawn_impact_fx` (one-shot burst particles + flash light) and
## `_make_debris_mesh`. A "debris chunk", a "crater", a "shockwave" — all just words for what the one
## substrate does. The actor is now seed + falling visual + one impact→substrate call.
## (Explicit types only — project rule: no ':=' inferred typing.)

# --- Tunables -----------------------------------------------------------------
const SPAWN_HEIGHT: float = 140.0          # fallback drop height when launched with no camera origin
const START_SPEED: float = 70.0            # initial fall speed (units/s) for the fallback drop
const LAUNCH_SPEED: float = 150.0          # speed when fired from the camera like an FPS projectile
const STEER_RATE: float = 3.4              # how fast the projectile homes its heading onto the target
const GRAVITY: float = 55.0                # downward acceleration (units/s^2), fallback drop only
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
var _guided: bool = false                  # true = FPS-style homing projectile; false = ballistic drop

var _body: MeshInstance3D = null
var _glow: OmniLight3D = null
var _trail: GPUParticles3D = null
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


## Launch toward `target`. If `from_pos` is finite it fires FROM THAT POINT (the camera / screen
## centre) like an FPS projectile, streaking straight out and homing onto the target so it always
## lands on the click point; otherwise it falls ballistically from above the target. Size is
## randomized each launch so strikes vary in scale.
func launch(target: Vector3, from_pos: Vector3 = Vector3(INF, INF, INF)) -> void:
	_target = target
	_size = randf_range(0.55, 2.3)
	if is_finite(from_pos.x) and is_finite(from_pos.y) and is_finite(from_pos.z):
		# Fire from the camera itself so it reads as a projectile leaving screen centre toward the
		# crosshair; a small forward nudge keeps it from spawning inside the near plane.
		var aim: Vector3 = target - from_pos
		if aim.length() < 0.001:
			aim = Vector3.DOWN
		aim = aim.normalized()
		_spawned_at = from_pos + aim * 3.0
		_guided = true
		_velocity = aim * LAUNCH_SPEED
	else:
		var lateral: Vector3 = Vector3(randf_range(-24.0, 24.0), 0.0, randf_range(-24.0, 24.0))
		_spawned_at = target + Vector3(0.0, SPAWN_HEIGHT, 0.0) + lateral
		_guided = false
		var dir: Vector3 = _target - _spawned_at
		if dir.length() < 0.001:
			dir = Vector3.DOWN
		_velocity = dir.normalized() * START_SPEED
	global_position = _spawned_at
	# Bigger rock = bigger visual body, glow and trail.
	if _body != null:
		_body.scale = Vector3.ONE * _size
	if _glow != null:
		_glow.omni_range = 30.0 * _size
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
	if _guided:
		# FPS projectile: hold a constant speed and steer the heading onto the target so it lands
		# exactly on the click point regardless of where it was fired from.
		var to_target: Vector3 = _target - global_position
		if to_target.length() > 0.001:
			var want: Vector3 = to_target.normalized()
			var cur: Vector3 = _velocity.normalized() if _velocity.length() > 0.001 else want
			var steered: Vector3 = cur.lerp(want, clampf(STEER_RATE * delta, 0.0, 1.0)).normalized()
			_velocity = steered * LAUNCH_SPEED
	else:
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

	if _terrain != null and _terrain.has_method("altitude_at"):
		var alt: float = _terrain.altitude_at(to)             # height above the local ground (radial); <0 = below
		if not is_nan(alt) and alt <= 0.0:
			var sp: Vector3 = _terrain.ground_point(to) if _terrain.has_method("ground_point") else to
			return {"hit": true, "point": (to if is_nan(sp.x) else sp)}

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
		if water != null and water.has_method("is_water_at") and water.is_water_at(_impact_point):
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
		# The impact IS a shock source + an ejecta source — both are the substrate's own primitives now (no
		# per-actor wave/debris code). emit_shock radiates a seismic wave (tremor + panic); eject throws molten
		# debris parcels that arc under radial gravity and re-deposit on landing (a glowing ejecta blanket).
		if field != null and field.has_method("emit_shock"):
			field.emit_shock(_impact_point, 2.0 + _size * 2.0)
		if field != null and field.has_method("eject"):
			var up: Vector3 = (_impact_point - field._origin).normalized() if "_origin" in field else Vector3.UP
			field.eject(_impact_point, 0.4 * _size, 900.0 * _size, up * 0.6)
			# Hypervelocity impact IONISES the air above the crater — a charge seed the field's breakdown then
			# discharges as a bolt (the same charge→bolt primitive a storm feeds; here from impact plasma).
			if field.has_method("add_charge"):
				field.add_charge(_impact_point + up * 20.0, 12.0, r)
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

	# Procedural impact boom (presentation only; resolves the AudioDirector by group). The flash, debris
	# fling and ejecta blanket are no longer scripted here — they emerge from the eject/add_heat/add_charge
	# seeds above (glowing ejecta parcels + molten crater glow + a discharge bolt).
	LocalAgentsAudioDirector.emit(get_tree(), "meteor_impact", _impact_point)


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
