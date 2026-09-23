class_name LAMeteor
extends Node3D


const FX_LINGER: float = 1.8               # seconds of FX after impact before free
## Transient cavity depth over its diameter (Melosh 1989, Impact Cratering, ch. 7).
const TRANSIENT_DEPTH_PER_DIAMETER: float = 1.0 / 3.0

## The rock left its release point as a ball of this radius, m.
signal launched(radius_m: float)
## The rock reached the ground at `point`.
signal impacted(point: Vector3)

enum State { IDLE, FALLING, IMPACTED }

var _terrain: Object = null                # LAVoxelTerrainService (duck-typed)
var _ecology: Object = null                # LAEcologyService (duck-typed)
var _state: int = State.IDLE
var _body_id: int = -1                     # the free body LABallistics is flying
var _impact_velocity: Vector3 = Vector3.ZERO
var _target: Vector3 = Vector3.ZERO
var _fx_time: float = 0.0
var _impact_point: Vector3 = Vector3.ZERO
var _spawned_at: Vector3 = Vector3.ZERO

# The rock itself, fixed on launch: the mass the measured flux delivered and the ball that mass makes.
var _mass_kg: float = 0.0
var _radius_m: float = 0.0


func _ready() -> void:
	add_to_group("selectable")
	add_to_group("la_ballistics")


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
	var l: float = 2.0 * _radius_m
	return 0.5 * 1.161 * pow(l, 0.78) * pow(v, 0.44) * pow(g, -0.22) * pow(sin_theta, 1.0 / 3.0)


## False when this world could not say what arrives or how fast, in which case nothing was launched.
func launch(target: Vector3, from_pos: Vector3 = Vector3(INF, INF, INF), size_scale: float = 1.0) -> bool:
	_target = target
	# DECISION: the caller's hint is a player's hand picking a bigger rock; an ambient arrival passes 1.0
	# and is the flux law's own draw.
	var energy_j: float = _draw_energy_j(LASimRng.for_domain("planet")) * size_scale
	var velocity: Vector3 = Vector3.ZERO
	if is_finite(from_pos.x) and is_finite(from_pos.y) and is_finite(from_pos.z):
		# Player-fired: leave the camera along the aim ray at the local circular-orbit speed and coast.
		var aim: Vector3 = (target - from_pos).normalized()
		if aim == Vector3.ZERO:
			aim = Vector3.DOWN
		_spawned_at = from_pos + aim * 3.0
		var speed: float = LAGravity.circular_speed(get_tree(), _spawned_at)
		if not _size_from(energy_j, speed):
			return false
		velocity = aim * speed
	else:
		var approach: Dictionary = _approach(target, energy_j)
		if approach.is_empty():
			return false
		_spawned_at = approach["release"] as Vector3
		velocity = approach["velocity"] as Vector3
	global_position = _spawned_at
	_body_id = LABallistics.drop(_spawned_at, velocity, _mass_kg, _radius_m)
	_state = State.FALLING
	launched.emit(_radius_m)
	return true


## ONE ARRIVAL'S ENERGY, J: the measured bolide flux N(>E) (Brown et al. 2002, Nature 420:294) inverted
## at a uniform draw, over the energies it was fitted across.
static func _draw_energy_j(rng: LASimRng) -> float:
	var a: float = LAPhysical.BOLIDE_FLUX_EXPONENT
	var u: float = rng.randf()
	return pow(u * pow(LAPhysical.BOLIDE_FIT_KT[0], -a)
		+ (1.0 - u) * pow(LAPhysical.BOLIDE_FIT_KT[1], -a), -1.0 / a) * LAPhysical.KILOTON_TNT_J


## The rock that carries `energy_j` at `speed`, and the ball an ordinary chondrite of that mass makes.
func _size_from(energy_j: float, speed: float) -> bool:
	if not (energy_j > 0.0 and speed > 0.0):
		push_error("LAMeteor: an arrival with no speed carries no energy, so it has no mass.")
		return false
	_mass_kg = 2.0 * energy_j / (speed * speed)
	_radius_m = pow(3.0 * _mass_kg / (4.0 * PI * LAPhysical.CHONDRITE_DENSITY_KG_M3), 1.0 / 3.0)
	return true


## WHERE A ROCK COMES IN AND HOW FAST: the incidence angle follows the sin(2 theta) law an isotropic flux
## makes on a sphere (Melosh 1989, ch. 2), and the release point is the first altitude above the target
## that carries no air.
func _approach(target: Vector3, energy_j: float) -> Dictionary:
	var up0: Vector3 = _up_at(target)                            # publishes the system this reads back
	var i: int = LABallistics.dominant(target)
	var mu: float = LABallistics.body_mu(i) if i >= 0 else 0.0
	var r0: float = (target - LABallistics.body_center(i)).length() if i >= 0 else 0.0
	if mu <= 0.0 or r0 <= 0.0:
		push_error("LAMeteor: no body with a measured mass at %s, so no arrival speed can be read." % target)
		return {}
	# The rock is what carries the drawn energy in at the speed a zero-excess arrival reaches the ground.
	if not _size_from(energy_j, sqrt(2.0 * mu / r0)):
		return {}
	var tangent: Vector3 = up0.cross(Vector3.RIGHT)
	if tangent.length() < 0.01:
		tangent = up0.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	var rng: LASimRng = LASimRng.for_domain("planet")
	var elevation: float = asin(sqrt(rng.randf()))               # CDF sin^2(theta) of the sin(2 theta) law
	var azimuth: float = rng.randf() * TAU
	var across: Vector3 = up0.cross(tangent).normalized()
	var horizontal: Vector3 = tangent * cos(azimuth) + across * sin(azimuth)
	var incoming: Vector3 = -(up0 * sin(elevation) + horizontal * cos(elevation)).normalized()
	var altitude: float = _air_top(target, up0)
	var path: float = altitude / sin(elevation) if sin(elevation) > 0.0 else 0.0
	var release: Vector3 = target - incoming * path
	var radius: float = (release - LABallistics.body_center(i)).length()
	if radius <= 0.0:
		return {}
	# DECISION: zero hyperbolic excess, so the escape speed is the arrival speed — the low end of the real
	# 11-72 km/s range (Ceplecha et al. 1998); the excess needs a heliocentric encounter geometry.
	return {"release": release, "velocity": incoming * sqrt(2.0 * mu / radius)}


## Altitude above `target` at which this world's air runs out, bracketed by doubling from the impactor's
## own diameter. A world with no field carries no air and answers zero.
func _air_top(target: Vector3, up0: Vector3) -> float:
	if not LABallistics.has_field():
		return 0.0
	var ceiling: float = LABallistics.body_radius(LABallistics.dominant(target))
	var altitude: float = 2.0 * _radius_m
	while altitude < ceiling:
		if LABallistics.medium_density_at(target + up0 * altitude) <= 0.0:
			return altitude
		altitude *= 2.0
	push_error("LAMeteor: air out to a body radius above %s, so no release point is outside it." % target)
	return ceiling


## The transient cavity (Melosh 1989, ch. 7): a paraboloid of revolution of radius `crater_r` and depth
## D/3, whose volume is half its enclosing cylinder's and whose centroid lies a third of the depth down.
static func cavity(crater_r: float) -> Dictionary:
	var depth: float = 2.0 * crater_r * TRANSIENT_DEPTH_PER_DIAMETER
	return {"depth_m": depth, "volume_m3": 0.5 * PI * crater_r * crater_r * depth,
		"centroid_m": depth / 3.0}


## What the excavated mass leaves the centroid with: enough to climb out against g and still hold
## sqrt(g R) at the surface, the 45-degree launch whose ballistic range is the rim.
static func ejecta_launch_speed(g: float, crater_r: float) -> float:
	if g <= 0.0 or crater_r <= 0.0:
		return 0.0
	return sqrt(2.0 * g * float(cavity(crater_r)["centroid_m"]) + g * crater_r)


## ONE impact energy, three shares: lifting the thrown mass out of the cavity, the ballistic energy it
## still holds at the surface, and the remainder, which stays as heat. `thrown_kg` is what was given up.
static func partition(energy_j: float, thrown_kg: float, g: float, crater_r: float) -> Dictionary:
	var speed: float = ejecta_launch_speed(g, crater_r)
	var launch: float = 0.5 * thrown_kg * speed * speed
	var excavation: float = thrown_kg * g * float(cavity(crater_r)["centroid_m"])
	return {"launch_speed_m_s": speed, "excavation_j": excavation, "ballistic_j": launch - excavation,
		"ejecta_j": launch, "heat_j": energy_j - launch}


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


## The rock is where LABallistics put it. Nothing here integrates: this reads the one integrator's state.
func _follow_body() -> void:
	var st: Dictionary = LABallistics.state(_body_id)
	if st.is_empty():
		queue_free()
		return
	global_position = st["position"]
	var vel: Vector3 = st["velocity"]
	# It left the system: unbound AND receding. An arriving rock is on an unbound orbit too, inbound.
	if vel.dot(_up_at(global_position)) > 0.0 and LAGravity.is_unbound(get_tree(), global_position, vel):
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


## Radial up at `pos`, away from the dominant body's centre. ZERO with no gravity body: no vertical.
func _up_at(pos: Vector3) -> Vector3:
	var b: Object = LAGravity.dominant_body(get_tree(), pos) if is_inside_tree() else null
	if b != null and b.has_method("center"):
		var r: Vector3 = pos - (b.center() as Vector3)
		if r.length() > 0.001:
			return r.normalized()
	return Vector3.ZERO


func _on_impact() -> void:
	_state = State.IMPACTED
	_fx_time = 0.0

	# Momentum into the planet's orbit: the rock's own mass times its impact velocity.
	var orbits: Node = get_tree().get_first_node_in_group("system_orbits")
	if orbits != null and orbits.has_method("apply_impulse"):
		orbits.apply_impulse(_impact_velocity * _mass_kg)

	var r: float = _radius()
	if _terrain != null and _terrain.has_method("carve_sphere"):
		_terrain.carve_sphere(_impact_point, r)
		if _ecology != null and _ecology.has_method("material_field"):
			var substrate: Object = _ecology.material_field()
			if substrate != null and substrate.has_method("resample_terrain"):
				substrate.resample_terrain(_impact_point, r * 1.5)
	# Big splash if it struck water.
	if _ecology != null and _ecology.has_method("material_field"):
		var water: Object = _ecology.material_field()
		if water != null and water.has_method("is_water_at") and water.is_water_at(_impact_point):
			water.splash(_impact_point, r)
			# White-hot rock hitting water flashes to steam — sizzle + a steam hiss.
			LAAudioDirector.emit(get_tree(), "sizzle", _impact_point)
			LAAudioDirector.emit(get_tree(), "steam", _impact_point)
	if _ecology != null and _ecology.has_method("material_field") and r > 0.0:
		_spend_impact(_ecology.material_field(), r)

	impacted.emit(_impact_point)
	LAAudioDirector.emit(get_tree(), "meteor_impact", _impact_point)


## THE IMPACT ENERGY IS ONE NUMBER. What the cavity gives up leaves at the launch speed and the rest stays
## as heat: nothing is added to the impactor's own kinetic energy.
func _spend_impact(field: Object, crater_r: float) -> void:
	var g: float = LABallistics.g_at(_impact_point).length()
	if field == null or not field.has_method("eject") or g <= 0.0:
		return
	var cav: Dictionary = cavity(crater_r)
	var speed: float = ejecta_launch_speed(g, crater_r)
	var centroid: Vector3 = _impact_point - _up_at(_impact_point) * float(cav["centroid_m"])
	var want_kg: float = LAPhysical.ROCK_DENSITY_KG_M3 * float(cav["volume_m3"])
	var thrown_j: float = field.eject(centroid, want_kg, speed)
	var arrived_j: float = 0.5 * _mass_kg * _impact_velocity.length_squared()
	var share: Dictionary = partition(arrived_j, 2.0 * thrown_j / (speed * speed), g, crater_r)
	if float(share["heat_j"]) < 0.0:
		push_error("LAMeteor: a %.1f m crater's ejecta wants more than the impact arrived with." % crater_r)
		return
	if field._inject != null and field._inject.has_method("add_heat_energy"):
		field._inject.add_heat_energy(_impact_point, float(share["heat_j"]), crater_r)
