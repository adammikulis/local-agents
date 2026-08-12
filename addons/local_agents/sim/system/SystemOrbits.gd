class_name LASystemOrbits
extends Node


const ORBIT_RADIUS: float = 12000.0       # nominal orbital separation (world units); insolation == 1 here
const INSOLATION_MIN: float = 0.02        # never fully zero (numeric floor)
const INSOLATION_MAX: float = 4.0         # cap the bake so the field can't NaN
const DUST_OPACITY: float = 3.5           # how strongly atmospheric dust/cloud blocks the sun (impact winter)
const CLOUD_OPACITY_K: float = 0.35       # per-unit-cover cloud opacity
# Impact momentum handed to the orbit is multiplied by this. Not physics: a declared exaggeration.
const KNOCK_GAIN: float = 5.9

const MOON_RADIUS_MULT: float = 3.2       # orbit radius = planet_radius * this
const MOON_INCLINATION: float = 0.28      # radians the moon plane is tipped from the planet equator

# sea_radius = base + TIDE_AMP*cos(2*moon_angle). Not a per-cell tide: a declared modelling choice.
const TIDE_AMP: float = 4.0               # peak sea-level swing, world units

var _body: Node3D = null                  # LAPlanetBody (the planet — orbit reference + scene centre)
var _sky_ctrl: Node = null                # LAVoxelSkyController (owns the star node + the sky sun)
var _material = null                      # LAMaterialField3D (read atmospheric dust; it reads the sun back)
var _star: Node3D = null                  # LAStar — the gravity body this planet orbits
var _moon: Node3D = null                  # LAMoon (set via set_moon)
var _ocean = null                         # LAOceanPlane — the sea shell (tided via apply_tide)
var _sea_surface = null                   # LAMaterialFieldRender3D — near-cap surface (tided via set_sea_radius)
var _sea_base_radius: float = 0.0         # un-tided sea radius (base the tide swings around)

var _helio_pos: Vector3 = Vector3(ORBIT_RADIUS, 0.0, 0.0)
var _helio_vel: Vector3 = Vector3.ZERO
# Moon state, likewise relative to the planet centre (the world-frame origin).
var _moon_pos: Vector3 = Vector3.ZERO
var _moon_vel: Vector3 = Vector3.ZERO
var _moon_angle: float = 0.0              # tide phase, READ OFF the moon's real position (not a driven angle)
var _atmos_t: float = 1.0                 # cached atmospheric transmission (dust changes slowly — sampled, not per-frame)
var _tick: int = 0


func setup(body: Node3D, star: Node3D, material) -> void:
	_body = body
	_material = material
	_star = star
	_helio_pos = Vector3(ORBIT_RADIUS, 0.0, 0.0)
	_seed_circular()
	_publish_bodies()


func set_moon(moon: Node3D) -> void:
	_moon = moon
	if _moon == null:
		return
	var a: float = _moon_orbit_radius()
	_moon_pos = Vector3(a, 0.0, 0.0)
	_publish_bodies()                      # place it first: the field is measured AT its real position
	var accel: Vector3 = LAGravity.acceleration_at(get_tree(), _moon.global_position, _moon)
	var inward: float = maxf(-accel.dot(_moon_pos.normalized()), 0.0)
	# Tangent to the circle at angle 0 is +Z; the plane is tipped about world X by MOON_INCLINATION.
	_moon_vel = Vector3(0.0, -sin(MOON_INCLINATION), cos(MOON_INCLINATION)) * sqrt(inward * a)
	_seed_circular()   # the moon is part of the orbiting pair, so its mass belongs in the year's mu
	_publish_bodies()


func _seed_circular() -> void:
	_helio_vel = Vector3(0.0, 0.0, sqrt(_system_mu() / maxf(_helio_pos.length(), 1.0)))


## Wire the tide targets: the ocean shell + the near-cap fluid surface both take the moon-driven sea radius.
## `base_radius` is the un-tided sea level the tide swings around.
func set_tide_targets(ocean, sea_surface, base_radius: float) -> void:
	_ocean = ocean
	_sea_surface = sea_surface
	_sea_base_radius = base_radius


## Current tide offset (world units) from the moon's orbital phase — two bulges per orbit (sub-lunar + antipode).
func tide_offset() -> float:
	return TIDE_AMP * cos(2.0 * _moon_angle)


## Optional presentation sink: the sky cycle, told which way the sun shines each frame. Absent without --ui.
func set_sky_controller(sky_ctrl: Node) -> void:
	_sky_ctrl = sky_ctrl


## Advance the orbit + moon and push the derived sun direction / position / insolation into the scene. Called
## from LAVoxelWorld._physics_process BEFORE the sky-cycle update, so the sun-shine direction is fresh when
## the sky reads it. `delta` must be the fixed physics delta — never a render delta.
func update(delta: float) -> void:
	if _body == null:
		return
	# Publish state → integrate → derive. Publishing FIRST means both integrators (and any meteor stepping
	# this frame) read one consistent set of body positions out of the gravity group.
	_publish_bodies()
	_integrate_orbit(delta)
	_integrate_moon(delta)

	# Dust/cloud change slowly — resample atmospheric transmission every ~15 frames, not the full-grid sweep each frame.
	_tick += 1
	if _tick % 15 == 0:
		_atmos_t = _compute_transmission()

	var centre: Vector3 = _body.center()
	# Presentation only — the sky cycle's own light/environment. Absent in a run with no presentation layer.
	if _sky_ctrl != null and _sky_ctrl.has_method("enter_space_mode"):
		_sky_ctrl.enter_space_mode(centre)

	if _star != null and _star.light() != null:
		_star.light().set_meta("insolation", _insolation())

	_update_tide()


# Offset of the planet-moon barycentre from the planet, in the world (planet-centred) frame. The pair swings
# about this point every month; it is the barycentre, not the planet, that traces the yearly ellipse.
func _barycentre() -> Vector3:
	if _moon == null or _body == null:
		return Vector3.ZERO
	var mm: float = float(_moon.mass()) if _moon.has_method("mass") else 0.0
	var mp: float = float(_body.mass()) if _body.has_method("mass") else 0.0
	if mm + mp <= 0.0:
		return Vector3.ZERO
	return _moon_pos * (mm / (mm + mp))


# Write the orbital state onto the actual body nodes. This is the ONLY place either body is positioned, so
# the drawn system and the integrated system are the same system by construction.
func _publish_bodies() -> void:
	if _body == null:
		return
	var centre: Vector3 = _body.center()
	if _star != null:
		_star.global_position = centre + _barycentre() - _helio_pos
		# Re-aim after moving: the light's basis is the field's sun direction, and setup() aimed it once from
		# the star's ORIGINAL position, so without this the solar term drifts as the orbit advances.
		if _star.has_method("aim_at"):
			_star.aim_at(centre)
	if _moon != null:
		_moon.global_position = centre + _moon_pos
		_moon_angle = atan2(_moon_pos.z, _moon_pos.x)


func _integrate_orbit(delta: float) -> void:
	if _star == null:
		return
	var tree: SceneTree = get_tree()
	var a_star: Vector3 = LAGravity.acceleration_at(tree, _star.global_position, _star)
	var a_bary: Vector3 = Vector3.ZERO
	if _moon != null and _body != null:
		var mm: float = float(_moon.mass()) if _moon.has_method("mass") else 0.0
		var mp: float = float(_body.mass()) if _body.has_method("mass") else 0.0
		if mm + mp > 0.0:
			a_bary = LAGravity.acceleration_at(tree, _moon.global_position, _moon) * (mm / (mm + mp))
	_helio_vel += (a_bary - a_star) * delta
	_helio_pos += _helio_vel * delta


func _integrate_moon(delta: float) -> void:
	if _moon == null:
		return
	var accel: Vector3 = LAGravity.acceleration_at(get_tree(), _moon.global_position, _moon)
	_moon_vel += accel * delta
	_moon_pos += _moon_vel * delta


func _system_mu() -> float:
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0.0
	return LAGravity.mu(tree, _star) + LAGravity.mu(tree, _body) + LAGravity.mu(tree, _moon)


func _moon_orbit_radius() -> float:
	var r: float = float(_body.radius()) if _body != null and _body.has_method("radius") else 0.0
	return (r if r > 1.0 else 500.0) * MOON_RADIUS_MULT


func _insolation() -> float:
	var dist_factor: float = ORBIT_RADIUS / maxf(_helio_pos.length(), 1.0)
	return clampf(dist_factor * dist_factor * _atmos_t, INSOLATION_MIN, INSOLATION_MAX)


## Atmospheric transmission (0..1): airborne dust + cloud block sunlight (a meteor volley → impact winter).
func _compute_transmission() -> float:
	var dust_op: float = 0.0
	# AIRBORNE MINERAL — unbounded, so an impact winter can go dark.
	if _material != null and _material.has_method("avg_airborne_mineral"):
		dust_op = float(_material.avg_airborne_mineral())
	var cloud_op: float = 0.0
	if _material != null and _material.has_method("avg_cloud_cover"):
		cloud_op = float(_material.avg_cloud_cover()) * CLOUD_OPACITY_K
	var t: float = 1.0 / (1.0 + DUST_OPACITY * maxf(dust_op + cloud_op, 0.0))
	LASimReport.gauge("atmos_dust_opacity", dust_op)
	LASimReport.gauge("atmos_cloud_opacity", cloud_op)
	LASimReport.gauge("atmos_transmission", t)
	return t


func _update_tide() -> void:
	if _moon == null:
		return
	var offset: float = tide_offset()
	if _ocean != null and _ocean.has_method("apply_tide"):
		_ocean.apply_tide(offset)
	if _sea_surface != null and _sea_surface.has_method("set_sea_radius"):
		_sea_surface.set_sea_radius(_sea_base_radius + offset)


func apply_impulse(world_impulse: Vector3) -> void:
	var m: float = float(_body.mass()) if _body != null and _body.has_method("mass") else 0.0
	_helio_vel += world_impulse * (KNOCK_GAIN / maxf(m, 1.0))


## Human-readable orbital fate for the HUD / telemetry / streamer.
func status() -> String:
	var r: float = maxf(_helio_pos.length(), 1.0)
	var energy: float = 0.5 * _helio_vel.length_squared() - _system_mu() / r
	if energy >= 0.0:
		return "escaping the system"
	if r < ORBIT_RADIUS * 0.35:
		return "falling into the sun"
	return "stable orbit"


## Orbital telemetry for SIM_REPORT (distance as a fraction of nominal, insolation, fate). `orbit_speed` and
## `moon_dist` are the two numbers that make the unified system falsifiable at a glance: the first moves when
## an impact lands, the second must sit at the seeded separation or the moon is not actually bound.
func report() -> Dictionary:
	return {
		"orbit_dist": snappedf(_helio_pos.length() / ORBIT_RADIUS, 0.01),
		"orbit_speed": snappedf(_helio_vel.length(), 0.01),
		"insolation": snappedf(_insolation(), 0.01),
		"orbit_status": status(),
		"moon_dist": snappedf(_moon_pos.length(), 0.1),
		"moon_angle": snappedf(_moon_angle, 0.01),
		"tide": snappedf(tide_offset(), 0.01),
	}
