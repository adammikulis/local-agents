class_name LASystemOrbits
extends Node

## THE SYSTEM, IN SI. Bodies are masses at positions with velocities; the star's light falls off as the
## inverse square of a separation the integrator produced. Nothing here is normalised against a nominal
## orbit, so eccentricity, a knocked orbit and an impact winter all show up on their own.

var _body: Node3D = null                  # LAPlanetBody (the planet — orbit reference + scene centre)
var _sky_ctrl: Node = null                # LAVoxelSkyController (owns the star node + the sky sun)
var _material = null                      # LAMaterialField3D
var _star: Node3D = null                  # LAStar — the body this planet orbits
var _moon: Node3D = null                  # LAMoon (set via set_moon)

## The planet-Moon barycentre relative to the star, and the Moon relative to the planet centre. Doubles,
## because binary32 cannot carry an astronomical unit and a step's displacement in the same number.
var _helio: Object = ClassDB.instantiate(&"LAOrbitState")
var _moon_state: Object = ClassDB.instantiate(&"LAOrbitState")


func setup(body: Node3D, star: Node3D, material) -> void:
	_body = body
	_material = material
	_star = star
	var row: Dictionary = LANativeTables.body_seeds().of("planet")
	_helio.set_position(row.get("position_m", Vector3.ZERO) - LANativeTables.body_seeds().of("star").get(
		"position_m", Vector3.ZERO))
	_helio.set_velocity(row.get("velocity_m_s", Vector3.ZERO))
	_publish_bodies()


func set_moon(moon: Node3D) -> void:
	_moon = moon
	if _moon == null:
		return
	var row: Dictionary = LANativeTables.body_seeds().of("moon")
	_moon_state.set_position(row.get("position_m", Vector3.ZERO))
	_moon_state.set_velocity(row.get("velocity_m_s", Vector3.ZERO))
	_publish_bodies()


## Optional presentation sink: the sky cycle, told which way the sun shines each frame. Absent without --ui.
func set_sky_controller(sky_ctrl: Node) -> void:
	_sky_ctrl = sky_ctrl


## Advance the orbit + moon and push the derived sun direction, position and IRRADIANCE into the scene.
## `delta` must be the fixed physics delta — never a render delta.
func update(delta: float) -> void:
	if _body == null:
		return
	# Publish state → integrate → derive. Publishing FIRST means both integrators (and any meteor stepping
	# this frame) read one consistent set of body positions out of the gravity group.
	_publish_bodies()
	_advance(_helio, _star, delta, true)
	_advance(_moon_state, _moon, delta, false)

	var centre: Vector3 = _body.center()
	# Presentation only — the sky cycle's own light/environment. Absent in a run with no presentation layer.
	if _sky_ctrl != null and _sky_ctrl.has_method("enter_space_mode"):
		_sky_ctrl.enter_space_mode(centre)

	if _star != null and _star.light() != null and _star.has_method("irradiance_at"):
		# W/m^2 at the top of the atmosphere. What each cell then absorbs is the band model's business:
		# dust and cloud attenuate per cell per wavelength, never as one number over the whole planet.
		_star.light().set_meta("irradiance_w_m2", _star.irradiance_at(centre))
		_star.light().set_meta("xuv_w_m2", _star.xuv_irradiance_at(centre))


# Offset of the planet-moon barycentre from the planet, in the world (planet-centred) frame. The pair swings
# about this point every month; it is the barycentre, not the planet, that traces the yearly ellipse.
func _barycentre() -> Vector3:
	if _moon == null or _body == null:
		return Vector3.ZERO
	var mm: float = _mass_of(_moon)
	var mp: float = _mass_of(_body)
	if mm + mp <= 0.0:
		return Vector3.ZERO
	return _moon_state.position() * (mm / (mm + mp))


# Write the orbital state onto the actual body nodes. This is the ONLY place either body is positioned, so
# the drawn system and the integrated system are the same system by construction.
func _publish_bodies() -> void:
	if _body == null:
		return
	var centre: Vector3 = _body.center()
	if _star != null:
		_star.global_position = centre + _barycentre() - _helio.position()
		# Re-aim after moving: the light's basis is the field's sun direction, and setup() aimed it once from
		# the star's ORIGINAL position, so without this the solar term drifts as the orbit advances.
		if _star.has_method("aim_at"):
			_star.aim_at(centre)
	if _moon != null:
		_moon.global_position = centre + _moon_state.position()


## One integrator for both orbits. The heliocentric state is the BARYCENTRE's, so the moon's share of the
## pull is folded in; the lunar state is the moon's own about the planet.
func _advance(state: Object, node: Node3D, delta: float, heliocentric: bool) -> void:
	if node == null:
		return
	var tree: SceneTree = get_tree()
	var accel: Vector3 = LAGravity.acceleration_at(tree, node.global_position, node)
	if not heliocentric:
		state.advance(accel, delta)
		return
	var a_bary: Vector3 = Vector3.ZERO
	if _moon != null and _body != null:
		var mm: float = _mass_of(_moon)
		var mp: float = _mass_of(_body)
		if mm + mp > 0.0:
			a_bary = LAGravity.acceleration_at(tree, _moon.global_position, _moon) * (mm / (mm + mp))
	# The state is the star SEEN FROM the pair, so the pair's acceleration enters with the opposite sign.
	state.advance(a_bary - accel, delta)


## A body's mass, or zero when it cannot answer. A body with no measurement contributes no pull rather
## than a plausible one.
func _mass_of(node: Node3D) -> float:
	if node == null or not node.has_method("mass"):
		return 0.0
	var m: float = float(node.mass())
	return m if is_finite(m) and m > 0.0 else 0.0


func _system_mu() -> float:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0.0
	return LAGravity.mu(tree, _star) + LAGravity.mu(tree, _body) + LAGravity.mu(tree, _moon)


## An impact's momentum, divided by the mass it lands on. There is no gain factor: a body's response to a
## push is the push over its mass.
func apply_impulse(world_impulse: Vector3) -> void:
	var m: float = _mass_of(_body)
	if m <= 0.0:
		return
	var dv: Vector3 = world_impulse / m
	_helio.vx += dv.x
	_helio.vy += dv.y
	_helio.vz += dv.z


## Where this orbit ENDS UP, read off its own conic. Unbound above zero specific energy; it meets the star
## when its perihelion falls inside the star. No fitted fraction of a nominal radius.
func status() -> String:
	var mu: float = _system_mu()
	var r: float = _helio.distance()
	if mu <= 0.0 or r <= 0.0:
		return "unmeasured"
	var energy: float = 0.5 * _helio.speed() * _helio.speed() - mu / r
	if energy >= 0.0:
		return "escaping the system"
	var h: Vector3 = _helio.position().cross(_helio.velocity())
	var e: float = sqrt(maxf(1.0 + 2.0 * energy * h.length_squared() / (mu * mu), 0.0))
	var perihelion: float = (-mu / (2.0 * energy)) * (1.0 - e)
	var star_r: float = float(LANativeTables.body_seeds().of("star").get("radius_m", 0.0))
	if star_r > 0.0 and perihelion <= star_r:
		return "falling into the sun"
	return "stable orbit"


## Orbital telemetry for SIM_REPORT. Separations are METRES and irradiance is W/m^2, because a fraction of a
## nominal orbit is a number that can only ever read 1.
func report() -> Dictionary:
	var centre: Vector3 = _body.center() if _body != null else Vector3.ZERO
	var irr: float = _star.irradiance_at(centre) if _star != null \
		and _star.has_method("irradiance_at") else NAN
	return {
		"orbit_dist_m": _helio.distance(),
		"orbit_speed_m_s": _helio.speed(),
		"irradiance_w_m2": irr,
		"orbit_status": status(),
		"moon_dist_m": _moon_state.distance(),
	}
