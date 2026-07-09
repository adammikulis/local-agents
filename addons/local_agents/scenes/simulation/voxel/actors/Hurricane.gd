class_name LAHurricane
extends Node3D

## A HURRICANE — a big, slow, rotating storm system with a calm EYE. It is essentially a large,
## structured, self-sustaining storm built from the SAME field reads as the thunderstorm and tornado; it
## differs only by CONFIG (huge scale, rotation, a calm eye, ocean genesis), not by copy-pasted logic. Its
## GENESIS is emergent: it only sustains + intensifies over WARM OCEAN (high temp AND is_ocean_at across
## its eyewall) and WEAKENS over land or cool water — so it strengthens at sea and falls apart on
## landfall, read fresh each step. Structure: it pumps moisture + cool air aloft in an ANNULUS around the
## eye (never at the centre), so the field's condense→rain rules raise a dense spiral of cloud + torrential
## rain around a rain-free eye. It rotates: nearby wildlife is swept tangentially + slightly inward (advected
## by the cyclonic wind force via EcologyStimulus.apply_wind_force — no direct throw()) and panicked. Embedded
## severe weather is EMERGENT, not scripted: the eyewall pumps moisture + cold aloft, so the field's own charge
## physics builds charge under the convective annulus and fires lightning where it breaks down (via
## LAMaterialCharge3D). Built in code, no assets. (Explicit types only — no ':=' inferred typing.)

const LIFETIME_MAX: float = 150.0         # a hurricane is long-lived; ocean fuel keeps it going within this
const STRENGTH_START: float = 0.5
const STRENGTH_MAX: float = 1.8
const DISSIPATE_STRENGTH: float = 0.14
const SPINUP_TIME: float = 22.0           # slow genesis: grace while Coriolis spins the warm-ocean low up
const VORT_TO_STRENGTH: float = 0.55      # K: |vorticity| → strength; tuned so a well-fed vortex saturates STRENGTH_MAX
const STRENGTH_RATE: float = 0.1          # smoothing of strength toward the field-read target
const WARM_OCEAN_TEMP: float = 16.0       # sea at least this warm counts as fuel (gates the SEEDING)

# --- Vortex tracking (steer the eye toward the strongest nearby vorticity — the low the seeding grew) ---
const VORTEX_STEER: float = 0.4
const VORTEX_PROBE: float = 60.0

# --- Structure (all in world units; the rain/cloud fills the annulus, the eye stays calm) ---
const EYE_RADIUS: float = 26.0
const OUTER_RADIUS: float = 150.0
const EYEWALL_POINTS: int = 12            # moisture-pump points around the eyewall ring
const VAPOR_PER_SEC: float = 9.0          # total vapor/s at full strength (spread over the eyewall points)
const VAPOR_INJECT_R: float = 20.0
const COOL_PER_SEC: float = 10.0          # aloft cooling at each eyewall point (°C/s)
const COOL_INJECT_R: float = 26.0

# --- Motion (slow, wind-steered track) ---
const TRACK_SPEED: float = 7.0            # base forward crawl (world u/s)
const WIND_STEER: float = 0.5
const PLAY_HALF_EXTENT: float = 290.0

# --- Rotation + wind (the rotating cyclonic wind, felt by wildlife in the annulus) ---
const SPIN_SPEED: float = 1.4             # visual + swirl rotation (rad/s)
const WIND_FORCE: float = 14.0            # tangential wind speed (world u/s) at strength 1, advecting creatures
const WIND_INWARD_FRAC: float = 0.15      # slight inward spiral (fraction of the tangential wind)
const WIND_LIFT_FRAC: float = 0.25        # updraft lift (fraction of the tangential wind)
const SCARE_INTERVAL: float = 0.8

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null

var _center: Vector3 = Vector3.ZERO
var _heading: Vector2 = Vector2(1.0, 0.0)
var _strength: float = STRENGTH_START
var _age: float = 0.0
var _spin: float = 0.0
var _scare_cd: float = 0.0

var _spiral: GPUParticles3D = null
var _picker: StaticBody3D = null


func _ready() -> void:
	add_to_group("selectable")


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()


func begin(point: Vector3) -> void:
	_center = point
	global_position = _center
	var ang: float = randf() * TAU
	_heading = Vector2(cos(ang), sin(ang))
	_build_fx()
	LocalAgentsAudioDirector.emit(get_tree(), "crumble", _center)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	var frac: float = _warm_ocean_fraction()
	lines.append("Status: %s" % ("intensifying (warm sea)" if frac > 0.5 else "weakening (landfall)"))
	lines.append("Strength: %.0f%%" % (_strength / STRENGTH_MAX * 100.0))
	lines.append("Spin (vorticity): %.2f" % _core_vorticity())
	lines.append("Warm-ocean fuel: %.0f%%" % (frac * 100.0))
	lines.append("Age: %.0fs / %.0fs" % [_age, LIFETIME_MAX])
	return {"title": "Hurricane", "lines": lines}


# GENESIS FUEL: sample the eyewall ring — the fraction of it sitting over WARM OCEAN. Pure field reads;
# high over the sea (intensifies), low over land/cool water (decays). This is the whole life arc.
func _warm_ocean_fraction() -> float:
	if _field == null:
		return 0.0
	var warm_ocean: int = 0
	var total: int = 0
	for i in range(EYEWALL_POINTS):
		var a: float = TAU * float(i) / float(EYEWALL_POINTS)
		var px: float = _center.x + cos(a) * (EYE_RADIUS + OUTER_RADIUS) * 0.5
		var pz: float = _center.z + sin(a) * (EYE_RADIUS + OUTER_RADIUS) * 0.5
		total += 1
		var is_ocean: bool = _field.has_method("is_ocean_at") and _field.is_ocean_at(px, pz)
		if not is_ocean:
			continue
		var t: float = 20.0
		if _field.has_method("temp_at"):
			t = float(_field.temp_at(px, pz))
		if t >= WARM_OCEAN_TEMP:
			warm_ocean += 1
	return float(warm_ocean) / float(maxi(1, total))


# The peak vertical vorticity (air SPIN) of the mesocyclone — sampled at the centre + around the eyewall
# ring so a broad rotating low reads high even though the eye itself is calm. This is what the seeded
# warm-ocean low grows via Coriolis, and what the storm's strength now READS.
func _core_vorticity() -> float:
	if _field == null or not _field.has_method("vorticity_at"):
		return 0.0
	var peak: float = absf(_field.vorticity_at(_center.x, _center.z))
	var ring_r: float = (EYE_RADIUS + OUTER_RADIUS) * 0.5
	for i in range(EYEWALL_POINTS):
		var a: float = TAU * float(i) / float(EYEWALL_POINTS)
		var px: float = _center.x + cos(a) * ring_r
		var pz: float = _center.z + sin(a) * ring_r
		var v: float = absf(_field.vorticity_at(px, pz))
		if v > peak:
			peak = v
	return peak


# Direction (world XZ) toward the strongest nearby vorticity — used to re-centre the eye onto the low the
# field grew if it advects off. Zero when the eye is already sitting on the vortex core (nothing stronger).
func _vortex_gradient() -> Vector2:
	if _field == null or not _field.has_method("vorticity_at"):
		return Vector2.ZERO
	var best_dir: Vector2 = Vector2.ZERO
	var best_val: float = absf(_field.vorticity_at(_center.x, _center.z))
	for i in range(6):
		var a: float = TAU * float(i) / 6.0
		var ox: float = cos(a) * VORTEX_PROBE
		var oz: float = sin(a) * VORTEX_PROBE
		var v: float = absf(_field.vorticity_at(_center.x + ox, _center.z + oz))
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
		return

	# GENESIS FUEL still emerges from a field read — the fraction of the eyewall over WARM OCEAN — but it
	# now GATES the SEEDING (below) rather than scripting strength: over warm sea the actor pumps the low
	# that grows the vortex; over land it stops feeding, so the vortex spins down and the storm falls apart.
	var frac: float = _warm_ocean_fraction()

	# STRENGTH — no scripted intensify/decay: it READS the emergent vertical vorticity of the mesocyclone the
	# seeded low grew (peak over the core + eyewall). A well-fed warm-ocean vortex reads high |vorticity| →
	# full strength; after landfall the seeding stops, the spin decays, |vorticity| falls, and it dies.
	_strength = lerpf(_strength, VORT_TO_STRENGTH * _core_vorticity(), STRENGTH_RATE)
	if _age < SPINUP_TIME:
		_strength = maxf(_strength, STRENGTH_START)   # hold visible while the warm-ocean low spins up
	_strength = clampf(_strength, 0.0, STRENGTH_MAX)
	if _age >= LIFETIME_MAX or (_age >= SPINUP_TIME and _strength <= DISSIPATE_STRENGTH):
		_dissipate()
		return

	# TRACK — a slow forward crawl, gently steered by the LOCAL wind at the eye's own position AND biased
	# toward the strongest nearby vorticity so the eye tracks the low the field grew (re-centres if it drifts).
	if _field.has_method("wind_at") or _field.has_method("wind"):
		var wind: Vector2 = _field.wind_at(_center.x, _center.z) if _field.has_method("wind_at") else _field.wind()
		if wind.length() > 0.01:
			_heading = _heading.lerp(wind.normalized(), clampf(WIND_STEER * delta, 0.0, 1.0)).normalized()
	var vdir: Vector2 = _vortex_gradient()
	if vdir.length() > 0.001:
		_heading = _heading.lerp(vdir, clampf(VORTEX_STEER * delta, 0.0, 1.0)).normalized()
	_center.x += _heading.x * TRACK_SPEED * delta
	_center.z += _heading.y * TRACK_SPEED * delta
	_center.x = clampf(_center.x, -PLAY_HALF_EXTENT, PLAY_HALF_EXTENT)
	_center.z = clampf(_center.z, -PLAY_HALF_EXTENT, PLAY_HALF_EXTENT)
	if _terrain != null and _terrain.has_method("surface_height"):
		var gy: float = _terrain.surface_height(_center.x, _center.z)
		if not is_nan(gy):
			_center.y = gy
	global_position = _center

	_pump_eyewall(frac, delta)
	_stir_wildlife(delta)
	_update_fx()


# SEED the low: pump moisture + cool air aloft around the EYEWALL (never the calm eye) so a dense
# rain-bearing spiral builds around a rain-free centre — the eye emerges because nothing is injected there.
# Gated by the warm-ocean fuel `fuel`: over the sea it feeds the low that Coriolis spins into the hurricane
# vortex; over land `fuel`→0, the seeding stops, and the vortex (hence strength) decays — landfall EMERGES.
func _pump_eyewall(fuel: float, delta: float) -> void:
	if fuel <= 0.0:
		return
	var cloud_base: float = _center.y + 60.0
	if _field.has_method("cloud_base_y"):
		cloud_base = float(_field.cloud_base_y())
	var ring_r: float = (EYE_RADIUS + OUTER_RADIUS) * 0.5
	var drive: float = maxf(_strength, STRENGTH_START) * fuel   # keep a seeding floor during spin-up
	var per_point: float = VAPOR_PER_SEC * drive * delta / float(EYEWALL_POINTS)
	for i in range(EYEWALL_POINTS):
		var a: float = TAU * float(i) / float(EYEWALL_POINTS) + _spin
		var px: float = _center.x + cos(a) * ring_r
		var pz: float = _center.z + sin(a) * ring_r
		var gy: float = _center.y
		if _terrain != null and _terrain.has_method("surface_height"):
			var h: float = _terrain.surface_height(px, pz)
			if not is_nan(h):
				gy = h
		if _field.has_method("add_vapor"):
			_field.add_vapor(Vector3(px, gy + 3.0, pz), per_point, VAPOR_INJECT_R)
		if _field.has_method("add_cooling"):
			_field.add_cooling(Vector3(px, cloud_base, pz), COOL_PER_SEC * drive * delta, COOL_INJECT_R)


# The rotating wind: sweep wildlife in the annulus through the substrate's field-force seam (the same
# advection every gust/gale drives) instead of directly throwing them — the cyclonic wind carries each
# creature tangentially + slightly inward + lofts it, emergently, and panics them. Weaker per-creature than
# a tornado (spread over a huge area) but it makes the whole system feel alive.
func _stir_wildlife(delta: float) -> void:
	_scare_cd -= delta
	if _scare_cd <= 0.0:
		_scare_cd = SCARE_INTERVAL
		if _ecology != null and _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(_center, OUTER_RADIUS, minf(1.0, 0.3 + _strength * 0.5))
	if _strength <= DISSIPATE_STRENGTH:
		return
	if _ecology != null and _ecology.has_method("apply_wind_force"):
		_ecology.apply_wind_force(_center, OUTER_RADIUS, _wind_force_at, delta)


# The cyclonic wind velocity (world u/s) at a world point — the force `apply_wind_force` samples per
# creature. Calm eye (zero inside EYE_RADIUS); a tangential swirl that curls slightly inward and lifts,
# falling off toward the outer edge, scaled by the storm's emergent strength.
func _wind_force_at(pos: Vector3) -> Vector3:
	var to: Vector3 = pos - _center
	to.y = 0.0
	var d: float = to.length()
	if d < EYE_RADIUS or d < 0.001:
		return Vector3.ZERO                                   # the eye is calm
	var out_dir: Vector3 = to / d
	var tangent: Vector3 = Vector3(-out_dir.z, 0.0, out_dir.x)
	var mag: float = WIND_FORCE * _strength * clampf(1.0 - d / OUTER_RADIUS, 0.2, 1.0)
	return tangent * mag - out_dir * (mag * WIND_INWARD_FRAC) + Vector3.UP * (mag * WIND_LIFT_FRAC)


func _dissipate() -> void:
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_center, OUTER_RADIUS * 0.5, 0.3)
	queue_free()


# --- Visuals: a large slowly-rotating cloud spiral with a clear eye at the centre ---

# Soft storm-cloud fade for the spiral: transparent → bright storm-grey → transparent, so the disc
# has soft edges and reads as a dense cloud mass against the dark ocean instead of flat dark quads.
func _spiral_ramp() -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color(0.66, 0.69, 0.74, 0.0),
		Color(0.70, 0.73, 0.78, 0.62),
		Color(0.40, 0.43, 0.50, 0.46),
		Color(0.30, 0.33, 0.40, 0.0),
	])
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


func _build_fx() -> void:
	if _spiral == null:
		_spiral = GPUParticles3D.new()
		_spiral.amount = 660                             # denser disc so the spiral reads from far/high
		_spiral.lifetime = 9.0
		_spiral.emitting = true
		_spiral.local_coords = false
		_spiral.position = Vector3(0.0, 66.0, 0.0)
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(40.0, 40.0)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)     # tint from the per-particle ramp below
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = mat
		_spiral.draw_pass_1 = quad
		var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3(0.0, 1.0, 0.0)
		pm.emission_ring_radius = OUTER_RADIUS
		pm.emission_ring_inner_radius = EYE_RADIUS       # clears a calm eye at the centre
		pm.emission_ring_height = 16.0                   # thicker band = more cloud volume
		pm.direction = Vector3(0.0, 0.0, 0.0)
		pm.spread = 10.0
		pm.initial_velocity_min = 0.0
		pm.initial_velocity_max = 2.0
		pm.gravity = Vector3(0.0, 0.0, 0.0)
		pm.tangential_accel_min = 10.0                   # the whole disc rotates
		pm.tangential_accel_max = 20.0
		pm.radial_accel_min = -3.0                       # gentle inward curl → a spiral toward the eye
		pm.radial_accel_max = -1.0
		pm.scale_min = 1.0
		pm.scale_max = 3.0
		pm.color_ramp = _spiral_ramp()
		_spiral.process_material = pm
		_spiral.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_spiral)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = 20.0
		col.shape = cs
		_picker.position = Vector3(0.0, 30.0, 0.0)
		_picker.add_child(col)
		add_child(_picker)


func _update_fx() -> void:
	if _spiral != null:
		_spiral.amount_ratio = clampf(0.25 + 0.75 * (_strength / STRENGTH_MAX), 0.1, 1.0)
