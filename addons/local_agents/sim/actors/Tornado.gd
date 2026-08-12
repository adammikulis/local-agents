class_name LATornado
extends Node3D


const VORTEX_FOLLOW: float = 8.0          # base drifts toward the strongest nearby vorticity (the real mesocyclone)
const VORTEX_PROBE: float = 26.0          # radius at which vorticity is sampled to find the vortex-core direction
const WIND_FOLLOW: float = 0.9            # fraction of the atmosphere wind the base drifts with
const WANDER_SPEED: float = 3.0           # amplitude of the residual noise wander (world u/s)

const SCARE_BASE: float = 40.0            # panic radius (world u)
const SCARE_INTERVAL: float = 0.5

const FUNNEL_HEIGHT: float = 62.0         # wide top up near cloud base, narrow foot on the ground
const FUNNEL_TOP_R: float = 20.0          # top radius (wide — up in the wall cloud)
const FUNNEL_BASE_R: float = 1.4          # foot radius (narrow touchdown)
const FUNNEL_CORE_FRAC: float = 0.52      # inner dark-core radius as a fraction of the sheath
const SPIN_SPEED: float = 7.5             # visual funnel yaw spin (rad/s)
const LEAN_MAX: float = deg_to_rad(16.0)  # how far the top leans downwind at full strength
const SWAY_AMPL: float = deg_to_rad(4.5)  # gentle side-to-side sway of the funnel
const SWAY_SPEED: float = 1.3             # sway oscillation rate

const SPOUT_SPLASH_INTERVAL: float = 0.18

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null

var _base: Vector3 = Vector3.ZERO         # world foot of the funnel (on the ground / sea surface)
var _age: float = 0.0
var _phase: float = 0.0                    # per-index noise phase so twisters wander independently
var _scare_cd: float = 0.0
var _splash_cd: float = 0.0
var _spin: float = 0.0
var _wind_dir: Vector2 = Vector2.ZERO      # last atmosphere wind (drives the funnel's downwind lean)

var _funnel_pivot: Node3D = null          # sits at the foot; lean + sway rotate about here
var _funnel: MeshInstance3D = null        # outer dusty sheath
var _funnel_mesh: CylinderMesh = null
var _core: MeshInstance3D = null          # inner darker, denser core column
var _debris: GPUParticles3D = null
var _picker: StaticBody3D = null


func _ready() -> void:
	add_to_group("selectable")
	_phase = LASimRng.for_domain("planet").randf() * TAU


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


## Touch down at `point`. The twister lives or dies by the air it finds there.
func touch_down(point: Vector3) -> void:
	_base = point
	global_position = _base
	_build_fx()
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_base, SCARE_BASE, 0.7)
	LAAudioDirector.emit(get_tree(), "crumble", _base)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	if _field == null:
		return {"title": "Tornado", "lines": ["No material field: nothing to read."]}
	var core: float = _core_vorticity()
	var ambient: float = _ambient_vorticity()
	lines.append("Status: %s" % ("waterspout" if _field.is_ocean_at(_base) else "tornado"))
	lines.append("Vortex: %s" % ("foot out-spins its surroundings" if core > ambient else "none"))
	lines.append("Foot |curl|: %.4f u/s" % core)
	lines.append("Surrounding |curl|: %.4f u/s" % ambient)
	lines.append("Air at the foot: %.1f °C" % float(_field.temp_at(_base)))
	lines.append("Relative humidity: %.2f" % float(_field.relative_humidity_at(_base.x, _base.z)))
	lines.append("Age: %.0fs" % _age)
	return {"title": "Tornado", "lines": lines}


# |curl| of the horizontal wind at the funnel's foot — the spin the field actually has there.
func _core_vorticity() -> float:
	if _field == null or not _field.has_method("vorticity_at"):
		return 0.0
	return absf(_field.vorticity_at(_base))


# Mean |curl| of the air around the foot, on the same probe ring the drift follows. The environment the
# foot is compared against; no constant separates them, only the two readings.
func _ambient_vorticity() -> float:
	if _field == null or not _field.has_method("vorticity_at"):
		return 0.0
	var total: float = 0.0
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		var ox: float = cos(a) * VORTEX_PROBE
		var oz: float = sin(a) * VORTEX_PROBE
		total += absf(_field.vorticity_at(_base + Vector3(ox, 0.0, oz)))
	return total / 6.0


# Direction (world XZ) toward the strongest nearby vertical vorticity — the actual vortex core the field
# grew. Sampled at a ring of probe offsets around the foot; the funnel drifts that way so it tracks the
# real mesocyclone instead of wandering on pure noise. Zero if there is no stronger spin nearby to follow.
func _vortex_gradient() -> Vector2:
	if _field == null or not _field.has_method("vorticity_at"):
		return Vector2.ZERO
	var best_dir: Vector2 = Vector2.ZERO
	var best_val: float = absf(_field.vorticity_at(_base))
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		var ox: float = cos(a) * VORTEX_PROBE
		var oz: float = sin(a) * VORTEX_PROBE
		var v: float = absf(_field.vorticity_at(_base + Vector3(ox, 0.0, oz)))
		if v > best_val:
			best_val = v
			best_dir = Vector2(ox, oz)
	if best_dir.length() > 0.001:
		return best_dir.normalized()
	return Vector2.ZERO


func _physics_process(delta: float) -> void:
	_age += delta
	_spin += SPIN_SPEED * delta
	if _field == null:
		push_error("Tornado has no material field: there is no atmosphere to read a vortex from.")
		queue_free()
		return

	# The funnel exists while its foot out-spins the air around it. Two field reads, no threshold between
	# them: when the spin flattens out, there is no vortex left to be a tornado.
	var core: float = _core_vorticity()
	var ambient: float = _ambient_vorticity()
	if core != 0.0 or ambient != 0.0:      # both exactly zero = no velocity readback yet, which decides nothing
		if core <= ambient:
			_dissipate()
			return

	# WANDER — TRACK THE VORTEX the field grew: bias motion toward the strongest nearby vertical vorticity
	# (the real mesocyclone core), still riding the LOCAL wind for the downwind lean + a little noise so
	# each twister tracks its own path instead of moving in lockstep.
	var wind: Vector2 = Vector2.ZERO
	if _field.has_method("wind_at"):
		wind = _field.wind_at(_base)
	elif _field.has_method("wind"):
		wind = _field.wind()
	_wind_dir = wind
	var vortex_dir: Vector2 = _vortex_gradient()
	var nx: float = sin(_age * 0.7 + _phase) + 0.5 * sin(_age * 1.9 + _phase * 2.0)
	var nz: float = cos(_age * 0.6 + _phase * 1.3) + 0.5 * cos(_age * 1.7 + _phase)
	_base.x += (vortex_dir.x * VORTEX_FOLLOW + wind.x * WIND_FOLLOW + nx * WANDER_SPEED) * delta
	_base.z += (vortex_dir.y * VORTEX_FOLLOW + wind.y * WIND_FOLLOW + nz * WANDER_SPEED) * delta
	# Re-seat the foot radially onto the ground/sea surface (no XZ box clamp — the planet is a sphere; the
	# radial re-seat keeps the funnel on the surface wherever it wanders). Hold the last height off the meshed area.
	if _terrain != null and _terrain.has_method("ground_point"):
		var sp: Vector3 = _terrain.ground_point(_base)
		if not is_nan(sp.x):
			_base = sp
	global_position = _base

	_update_fx()

	# Panic only. The funnel no longer pushes creatures: every creature already rides the field's own wind
	# every frame (CreatureFieldForces reads wind3_at), and a swirl this actor synthesised on top of that was
	# a wind the field does not have. The grid cannot resolve a tornado; that is the finding, not a licence.
	_scare_cd -= delta
	if _scare_cd <= 0.0:
		_scare_cd = SCARE_INTERVAL
		if _ecology != null and _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(_base, SCARE_BASE, 1.0)

	if _field.has_method("is_ocean_at") and _field.is_ocean_at(_base):
		_splash_cd -= delta
		if _splash_cd <= 0.0:
			_splash_cd = SPOUT_SPLASH_INTERVAL
			if _field.has_method("splash"):
				_field.splash(_base, 1.0)


func _dissipate() -> void:
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_base, SCARE_BASE * 0.5, 0.3)
	queue_free()


# Dust-colored fade for the debris motes: transparent → tan → transparent over each mote's life, so
# they read as a soft dust cloud that swirls up and dissolves rather than hard flecks popping in/out.
func _dust_ramp() -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.18, 0.65, 1.0])
	g.colors = PackedColorArray([
		Color(0.60, 0.53, 0.42, 0.0),
		Color(0.58, 0.51, 0.40, 0.72),
		Color(0.50, 0.45, 0.38, 0.45),
		Color(0.46, 0.42, 0.36, 0.0),
	])
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


func _build_fx() -> void:
	if _funnel_pivot == null:
		# Pivot at the FOOT (tornado origin sits on the ground), so lean/sway swing the top, not the base.
		_funnel_pivot = Node3D.new()
		add_child(_funnel_pivot)

		# Outer dusty sheath — a strongly-tapered cone: WIDE at the top, narrow at the foot.
		_funnel_mesh = CylinderMesh.new()
		_funnel_mesh.top_radius = FUNNEL_TOP_R
		_funnel_mesh.bottom_radius = FUNNEL_BASE_R
		_funnel_mesh.height = FUNNEL_HEIGHT
		_funnel_mesh.radial_segments = 28
		_funnel_mesh.rings = 12
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.42, 0.40, 0.38, 0.34)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_funnel_mesh.material = mat
		_funnel = MeshInstance3D.new()
		_funnel.mesh = _funnel_mesh
		_funnel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_funnel.position = Vector3(0.0, FUNNEL_HEIGHT * 0.5, 0.0)
		_funnel_pivot.add_child(_funnel)

		# Inner core — a narrower, darker, denser column that gives the funnel visible depth + a dark heart.
		var cmesh: CylinderMesh = CylinderMesh.new()
		cmesh.top_radius = FUNNEL_TOP_R * FUNNEL_CORE_FRAC
		cmesh.bottom_radius = FUNNEL_BASE_R * 0.7
		cmesh.height = FUNNEL_HEIGHT
		cmesh.radial_segments = 20
		cmesh.rings = 10
		var cmat: StandardMaterial3D = StandardMaterial3D.new()
		cmat.albedo_color = Color(0.18, 0.17, 0.16, 0.62)
		cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cmat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		cmesh.material = cmat
		_core = MeshInstance3D.new()
		_core.mesh = cmesh
		_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_core.position = Vector3(0.0, FUNNEL_HEIGHT * 0.5, 0.0)
		_funnel_pivot.add_child(_core)
	if _debris == null:
		_debris = GPUParticles3D.new()
		_debris.amount = 520                           # many small motes read as a dust cloud, not scattered cubes
		_debris.lifetime = 2.6
		_debris.emitting = true
		_debris.local_coords = false
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(0.34, 0.34)                # small flecks
		var dmat: StandardMaterial3D = StandardMaterial3D.new()
		dmat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)  # tint comes from the per-particle color ramp below
		dmat.vertex_color_use_as_albedo = true
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = dmat
		_debris.draw_pass_1 = quad
		var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3(0.0, 1.0, 0.0)
		pm.emission_ring_radius = FUNNEL_TOP_R * 0.7    # picked up from a wide ring around the foot...
		pm.emission_ring_inner_radius = FUNNEL_BASE_R * 2.0
		pm.emission_ring_height = 2.0
		pm.direction = Vector3(0.0, 1.0, 0.0)
		pm.spread = 26.0
		pm.initial_velocity_min = 6.0
		pm.initial_velocity_max = 16.0
		pm.gravity = Vector3(0.0, 5.0, 0.0)             # ...sucked UP the funnel...
		pm.radial_accel_min = -34.0                     # ...and DRAWN INWARD toward the core (spirals in)
		pm.radial_accel_max = -18.0
		pm.tangential_accel_min = 30.0                  # caught hard in the spin
		pm.tangential_accel_max = 52.0
		pm.damping_min = 1.0
		pm.damping_max = 3.0
		pm.scale_min = 0.25                             # mostly small, a few larger — varied sizes
		pm.scale_max = 1.3
		pm.angle_min = -180.0                           # random start rotation...
		pm.angle_max = 180.0
		pm.angular_velocity_min = -220.0                # ...and tumbling as they fly
		pm.angular_velocity_max = 220.0
		pm.color_ramp = _dust_ramp()                    # dust-tan, fades in then out over life
		_debris.process_material = pm
		_debris.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_debris)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = FUNNEL_TOP_R
		col.shape = cs
		_picker.position = Vector3(0.0, FUNNEL_HEIGHT * 0.4, 0.0)
		_picker.add_child(col)
		add_child(_picker)


func _update_fx() -> void:
	# The FOOT pivot leans the funnel downwind + sways it, so it curves off the ground instead of standing
	# rigid. Size is fixed: the field carries no funnel radius, so there is nothing to scale it by.
	if _funnel != null:
		_funnel.rotation.y = _spin
	if _core != null:
		_core.rotation.y = -_spin * 1.3          # counter-spin the core so the two layers shear (visible churn)
	if _funnel_pivot != null:
		# Downwind lean + a gentle perpendicular sway, expressed as a tilt vector.
		var wdir: Vector2 = _wind_dir
		if wdir.length() < 0.001:
			wdir = Vector2(sin(_age * 0.5 + _phase), cos(_age * 0.5 + _phase))
		wdir = wdir.normalized()
		var perp: Vector2 = Vector2(-wdir.y, wdir.x)
		var sway: float = SWAY_AMPL * sin(_age * SWAY_SPEED + _phase)
		var tilt: Vector2 = wdir * LEAN_MAX + perp * sway
		var angle: float = tilt.length()
		var lean_basis: Basis = Basis()
		if angle > 0.0001:
			var d: Vector2 = tilt / angle
			var axis: Vector3 = Vector3(d.y, 0.0, -d.x)      # tilt +Y toward the lean direction (world XZ)
			lean_basis = Basis(axis.normalized(), angle)
		_funnel_pivot.transform.basis = lean_basis
