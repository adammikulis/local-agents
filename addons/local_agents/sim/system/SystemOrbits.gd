class_name LASystemOrbits
extends Node

## THE SYSTEM, IN SI. Bodies are masses at positions with velocities; the star's light falls off as the
## inverse square of a separation the integrator produced. Nothing here is normalised against a nominal
## orbit, so eccentricity, a knocked orbit and an impact winter all show up on their own.

var _body: Node3D = null                  # LAPlanetBody (the planet — orbit reference + scene centre)
var _material = null                      # LAMaterialField3D
var _star: Node3D = null                  # LAStar — the body this planet orbits
var _moon: Node3D = null                  # LAMoon (set via set_moon)

## The planet-Moon barycentre relative to the star, and the Moon relative to the planet centre. Doubles,
## because binary32 cannot carry an astronomical unit and a step's displacement in the same number.
var _helio: LAOrbitState = LAOrbitState.new()
var _moon_state: LAOrbitState = LAOrbitState.new()


func setup(body: Node3D, star: Node3D, material) -> void:
	_body = body
	_material = material
	_star = star
	var row: Dictionary = LABodySeeds.of("planet")
	_helio.set_position(row.get("position_m", Vector3.ZERO) - LABodySeeds.of("star").get(
		"position_m", Vector3.ZERO))
	_helio.set_velocity(row.get("velocity_m_s", Vector3.ZERO))
	_publish_bodies()


func set_moon(moon: Node3D) -> void:
	_moon = moon
	if _moon == null:
		return
	var row: Dictionary = LABodySeeds.of("moon")
	_moon_state.set_position(row.get("position_m", Vector3.ZERO))
	_moon_state.set_velocity(row.get("velocity_m_s", Vector3.ZERO))
	_publish_bodies()


## Advance the orbit + moon and place the bodies. `delta` must be the fixed physics delta — never a render
## delta.
func update(delta: float) -> void:
	if _body == null:
		return
	# Publish state → integrate → derive. Publishing FIRST means every integrator reads one consistent set
	# of body positions and one field.
	_publish_bodies()
	LAGravity.publish_field(_material)
	_advance(_helio, _star, delta, true)
	_advance(_moon_state, _moon, delta, false)
	# Every free body — a meteor, an ejecta parcel, a dropped test mass — on the SIMULATED clock the
	# orbit advances on, never a render frame's.
	_land_bodies(LABallistics.step(delta))
	_book_drag_heat(LABallistics.drag_work())


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
	_position_bodies()
	LAGravity.publish(get_tree())


func _position_bodies() -> void:
	var centre: Vector3 = _body.center()
	if _star != null:
		_star.global_position = centre + _barycentre() - _helio.position()
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


## A body that reached the ground: the owner registered under `la_ballistics` is told, so the deposit,
## the crater and the heat are the owner's own business rather than the integrator's.
func _land_bodies(rows: Array) -> void:
	if rows.is_empty():
		return
	for owner in get_tree().get_nodes_in_group("la_ballistics"):
		if owner.has_method("on_bodies_landed"):
			owner.on_bodies_landed(rows)


## The kinetic energy ram drag took out of the free bodies, put back into the air it was taken from.
func _book_drag_heat(rows: Array) -> void:
	if rows.is_empty() or _material == null or _material._inject == null:
		return
	if not _material._inject.has_method("add_heat_energy"):
		return
	var r: float = float(_material._cell_size) if "_cell_size" in _material else 0.0
	for row in rows:
		_material._inject.add_heat_energy(row["position"], float(row["joules"]), r)


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
	var mu: float = LAGravity.system_mu(get_tree())
	var r: float = _helio.distance()
	if mu <= 0.0 or r <= 0.0:
		return "unmeasured"
	var energy: float = 0.5 * _helio.speed() * _helio.speed() - mu / r
	if energy >= 0.0:
		return "escaping the system"
	var h: Vector3 = _helio.position().cross(_helio.velocity())
	var e: float = sqrt(maxf(1.0 + 2.0 * energy * h.length_squared() / (mu * mu), 0.0))
	var perihelion: float = (-mu / (2.0 * energy)) * (1.0 - e)
	var star_r: float = float(LABodySeeds.of("star").get("radius_m", 0.0))
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
		"ballistics_read_rel": LABallistics.read_check(64),
		"ballistics_live": LABallistics.live_count(),
		"orbit_dist_m": _helio.distance(),
		"orbit_speed_m_s": _helio.speed(),
		"irradiance_w_m2": irr,
		"orbit_status": status(),
		"moon_dist_m": _moon_state.distance(),
		"tide_peak_ratio": LABallistics.tide_peak_ratio(),
	}
