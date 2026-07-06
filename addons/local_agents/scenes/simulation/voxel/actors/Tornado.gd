class_name LATornado
extends Node3D

## A PERSISTENT tornado — it lives for tens of seconds, WANDERS driven by the atmosphere's wind, and its
## strength EMERGES from what it feeds on: each step it reads the LOCAL temperature + relative humidity
## (and whether it stands over ocean) at its base. WARM + HUMID air feeds it (strength climbs → it can
## intensify), COOL / DRY air starves it (strength falls → it DISSIPATES). Nothing about its life is
## scripted on a timeline — a tornado that drifts off warm humid ground onto a cold dry ridge withers on
## its own; one that tracks along a warm coast keeps spinning. Strength drives the funnel size, the
## scatter/suction radius, and the throw impulse. Over ocean it becomes a WATERSPOUT: it lifts moisture
## into the sky (add_vapor at its base) and kicks up spray (splash). It only READS the field + throws
## stimuli (scare + physical impulse) at wildlife; everything else emerges. Built in code, no assets.
## (Explicit types only — no ':=' inferred typing.)

# --- Lifecycle ---------------------------------------------------------------
const LIFETIME_MAX: float = 55.0          # hard cap: even a well-fed twister eventually spins down
const STRENGTH_START: float = 0.45
const STRENGTH_MAX: float = 1.6
const DISSIPATE_STRENGTH: float = 0.12    # below this it has lost its funnel and dies
const FUEL_STARVE: float = 0.46           # fuel below this starves the twister; above it, it intensifies
const GROWTH_RATE: float = 0.28           # how fast strength chases the fuel gradient

# --- Wander (driven by wind + per-index noise so many twisters don't move in lockstep) ---
const WIND_FOLLOW: float = 0.9            # fraction of the atmosphere wind the base drifts with
const WANDER_SPEED: float = 6.0           # amplitude of the noise wander (world u/s)
const PLAY_HALF_EXTENT: float = 285.0     # keep the base inside the island play area

# --- Effect radii / forces (all scale with strength) -------------------------
const SCATTER_BASE: float = 16.0          # suction/scatter radius at strength 1
const SCARE_BASE: float = 40.0            # continuous panic radius at strength 1
const THROW_BASE: float = 26.0            # outward+up impulse scale at strength 1
const SWIRL_GAIN: float = 1.4             # tangential (spin) component of the fling
const LIFT_GAIN: float = 1.1              # upward component of the fling
const SCARE_INTERVAL: float = 0.5

# --- Funnel geometry ---------------------------------------------------------
# A real tornado is WIDE up in the cloud and tapers to a narrow foot, with a downwind LEAN and a slow
# sway. We build it as an outer dusty sheath + a darker denser inner core (both tapered cones), pivoted
# at the FOOT so it leans/sways from the ground the way a real funnel does.
const FUNNEL_HEIGHT: float = 62.0         # wide top up near cloud base, narrow foot on the ground
const FUNNEL_TOP_R: float = 20.0          # top radius at strength 1 (wide — up in the wall cloud)
const FUNNEL_BASE_R: float = 1.4          # foot radius at strength 1 (narrow touchdown)
const FUNNEL_CORE_FRAC: float = 0.52      # inner dark-core radius as a fraction of the sheath
const SPIN_SPEED: float = 7.5             # visual funnel yaw spin (rad/s)
const LEAN_MAX: float = deg_to_rad(16.0)  # how far the top leans downwind at full strength
const SWAY_AMPL: float = deg_to_rad(4.5)  # gentle side-to-side sway of the funnel
const SWAY_SPEED: float = 1.3             # sway oscillation rate

# --- Waterspout moisture lift ------------------------------------------------
const SPOUT_VAPOR_PER_SEC: float = 0.9    # vapor injected/s at the base over ocean (feeds cloud→rain)
const SPOUT_SPLASH_INTERVAL: float = 0.18

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null

var _base: Vector3 = Vector3.ZERO         # world foot of the funnel (on the ground / sea surface)
var _strength: float = STRENGTH_START
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
	_phase = randf() * TAU


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


## Touch down at `point`. The twister is born weak and lives or dies by the air it finds there.
func touch_down(point: Vector3) -> void:
	_base = point
	_strength = STRENGTH_START
	global_position = _base
	_build_fx()
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_base, SCARE_BASE, 0.7)
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", _base)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	var over_ocean: bool = _field != null and _field.has_method("is_ocean_at") and _field.is_ocean_at(_base.x, _base.z)
	lines.append("Status: %s" % ("waterspout" if over_ocean else "tornado"))
	lines.append("Strength: %.0f%%" % (_strength / STRENGTH_MAX * 100.0))
	lines.append("Fuel (warm+humid): %.0f%%" % (_fuel() * 100.0))
	lines.append("Age: %.0fs / %.0fs" % [_age, LIFETIME_MAX])
	return {"title": "Tornado", "lines": lines}


# Warm + humid air (and open ocean beneath) FEEDS the twister; cool / dry air starves it. Pure reads —
# the tornado's whole life arc falls out of this local sample of the atmosphere at its foot.
func _fuel() -> float:
	if _field == null:
		return 0.5
	var t: float = 15.0
	if _field.has_method("temp_at"):
		t = float(_field.temp_at(_base.x, _base.z))
	var rh: float = 0.5
	if _field.has_method("relative_humidity_at"):
		rh = float(_field.relative_humidity_at(_base.x, _base.z))
	var warm: float = clampf((t - 8.0) / 24.0, 0.0, 1.0)          # 8°C → starved, 32°C → full
	var humid: float = clampf(rh, 0.0, 1.2)
	var ocean: float = 0.0
	if _field.has_method("is_ocean_at") and _field.is_ocean_at(_base.x, _base.z):
		ocean = 1.0                                              # endless moisture over warm water
	return clampf(0.5 * warm + 0.55 * humid + 0.22 * ocean, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	_age += delta
	_spin += SPIN_SPEED * delta

	# STRENGTH — emerges from the fuel gradient: warm+humid feeds it (intensifies), cool/dry starves it.
	var fuel: float = _fuel()
	_strength += (fuel - FUEL_STARVE) * GROWTH_RATE * delta * 2.0
	_strength = clampf(_strength, 0.0, STRENGTH_MAX)
	if _strength <= DISSIPATE_STRENGTH or _age >= LIFETIME_MAX:
		_dissipate()
		return

	# WANDER — drift with the LOCAL wind at the twister's own position (so it funnels down valleys / gets
	# pulled toward heated lows) plus independent noise so each tracks its own path.
	var wind: Vector2 = Vector2.ZERO
	if _field != null and _field.has_method("wind_at"):
		wind = _field.wind_at(_base.x, _base.z)
	elif _field != null and _field.has_method("wind"):
		wind = _field.wind()
	_wind_dir = wind
	var nx: float = sin(_age * 0.7 + _phase) + 0.5 * sin(_age * 1.9 + _phase * 2.0)
	var nz: float = cos(_age * 0.6 + _phase * 1.3) + 0.5 * cos(_age * 1.7 + _phase)
	_base.x += (wind.x * WIND_FOLLOW + nx * WANDER_SPEED) * delta
	_base.z += (wind.y * WIND_FOLLOW + nz * WANDER_SPEED) * delta
	_base.x = clampf(_base.x, -PLAY_HALF_EXTENT, PLAY_HALF_EXTENT)
	_base.z = clampf(_base.z, -PLAY_HALF_EXTENT, PLAY_HALF_EXTENT)
	# Keep the foot on the ground (or sea surface); hold the last height off the meshed area.
	if _terrain != null and _terrain.has_method("surface_height"):
		var gy: float = _terrain.surface_height(_base.x, _base.z)
		if not is_nan(gy):
			_base.y = gy
	global_position = _base

	_update_fx()

	# STIMULI — continuous panic + physical fling of nearby wildlife (impulse outward+up ∝ strength/dist).
	_scare_cd -= delta
	if _scare_cd <= 0.0:
		_scare_cd = SCARE_INTERVAL
		if _ecology != null and _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(_base, SCARE_BASE * (0.6 + _strength), minf(1.0, 0.4 + _strength))
	_fling_wildlife()

	# WATERSPOUT spray — over open water the funnel kicks up a ring of spray (a cheap ripple). It no longer
	# SCRIPT-INJECTS vapor (that low, base-level add_vapor condensed and rained puddles on the ground,
	# especially near the coast). A real waterspout lifting moisture should EMERGE from the wind field's
	# vortex once the tornado is rebuilt as an emergent low-pressure feature of MaterialField3D — not be
	# faked by an actor pumping vapor into the air.
	if _field != null and _field.has_method("is_ocean_at") and _field.is_ocean_at(_base.x, _base.z):
		_splash_cd -= delta
		if _splash_cd <= 0.0:
			_splash_cd = SPOUT_SPLASH_INTERVAL
			if _field.has_method("splash"):
				_field.splash(_base, 1.0 + _strength)


# Fling + LIFT nearby animals: for each creature inside the strength-scaled scatter radius, impart an
# impulse that is outward (thrown clear), upward (sucked up the funnel) and tangential (caught in the
# spin), stronger the CLOSER it is and the STRONGER the twister. Uses the creature's ballistic throw()
# so it arcs through the air and lands — no damage, just the toss.
func _fling_wildlife() -> void:
	var radius: float = SCATTER_BASE * _strength
	if radius <= 0.5:
		return
	var r2: float = radius * radius
	for actor in get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		var a: Node3D = actor as Node3D
		if not a.has_method("throw"):
			continue
		var to: Vector3 = a.global_position - _base
		to.y = 0.0
		var d: float = to.length()
		if d > radius or d < 0.001:
			continue
		var closeness: float = 1.0 - d / radius
		var out_dir: Vector3 = to / d
		var tangent: Vector3 = Vector3(-out_dir.z, 0.0, out_dir.x)      # perpendicular = swirl direction
		var mag: float = THROW_BASE * _strength * (0.35 + 0.65 * closeness)
		var vel: Vector3 = out_dir * mag + tangent * (mag * SWIRL_GAIN) + Vector3.UP * (mag * LIFT_GAIN)
		a.throw(vel)


func _dissipate() -> void:
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_base, SCARE_BASE * 0.5, 0.3)
	queue_free()


# --- Visuals -----------------------------------------------------------------

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
		quad.size = Vector2(0.34, 0.34)                # small flecks (was 0.7 blocky quads)
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
	# Radius scales with strength (a weak twister is a thin rope, a strong one a broad wedge); the FOOT
	# pivot leans the funnel downwind + sways it, so it curves off the ground instead of standing rigid.
	var s: float = clampf(_strength, 0.1, STRENGTH_MAX)
	if _funnel != null:
		_funnel.rotation.y = _spin
	if _core != null:
		_core.rotation.y = -_spin * 1.3          # counter-spin the core so the two layers shear (visible churn)
	if _funnel_pivot != null:
		var strength_frac: float = clampf(_strength / STRENGTH_MAX, 0.0, 1.0)
		# Downwind lean (grows with strength) + a gentle perpendicular sway, expressed as a tilt vector.
		var wdir: Vector2 = _wind_dir
		if wdir.length() < 0.001:
			wdir = Vector2(sin(_age * 0.5 + _phase), cos(_age * 0.5 + _phase))
		wdir = wdir.normalized()
		var perp: Vector2 = Vector2(-wdir.y, wdir.x)
		var sway: float = SWAY_AMPL * sin(_age * SWAY_SPEED + _phase)
		var tilt: Vector2 = wdir * (LEAN_MAX * strength_frac) + perp * sway
		var angle: float = tilt.length()
		var lean_basis: Basis = Basis()
		if angle > 0.0001:
			var d: Vector2 = tilt / angle
			var axis: Vector3 = Vector3(d.y, 0.0, -d.x)      # tilt +Y toward the lean direction (world XZ)
			lean_basis = Basis(axis.normalized(), angle)
		_funnel_pivot.transform.basis = lean_basis * Basis().scaled(Vector3(s, 1.0, s))
	if _debris != null:
		_debris.amount_ratio = clampf(0.25 + 0.75 * (_strength / STRENGTH_MAX), 0.1, 1.0)
		var pm: ParticleProcessMaterial = _debris.process_material as ParticleProcessMaterial
		if pm != null:
			pm.emission_ring_radius = FUNNEL_BASE_R * 2.4 * _strength
