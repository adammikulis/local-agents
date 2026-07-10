class_name LASystemOrbits
extends Node

## MOVING-FRAME solar system (0.3). The simulation stays centred on the planet (the field/terrain never move —
## zero risk), but the planet carries a real HELIOCENTRIC orbital STATE (position + velocity about the sun) that
## we integrate every frame. That state drives, in the planet's frame:
##   • the SUN's direction across the sky (the terminator) + its scene position (the visible disc moves);
##   • SEASONS — the tilted spin axis vs the orbit plane makes the sub-solar latitude swing over a year;
##   • INSOLATION intensity = (nominal/dist)^2 × atmospheric transmission (dust/cloud), fed to the field as the
##     MAGNITUDE of sun_dir (the solar kernel does target = AMBIENT + SOLAR_WARMTH·max(0,dot(radial,sun_dir))),
##     so nearer sun bakes, farther freezes, and airborne debris dims the sun → impact winter — all emergent.
## A meteor impact transfers MOMENTUM into the orbital velocity (`apply_impulse`), so a big enough strike (or a
## volley) drops the planet onto a decaying orbit into the sun, or past escape velocity out of the system.
## The moon is a light body on a kinematic orbit about the planet (and a gravity source meteors can slingshot).
## (Full literal planet-flight-through-space is the 0.4 moving-frame-field migration.) Explicit types; no ':='.

const SUN_MU: float = 171300.0            # GM of the sun (abstract orbital units) — sets the year length with R0
const ORBIT_RADIUS: float = 1000.0        # nominal orbital radius (abstract) — insolation == 1 here
const SUN_SCENE_DISTANCE: float = 1200.0  # how far the visible sun disc sits from the planet in the SCENE
const INSOLATION_MIN: float = 0.02        # never fully zero (numeric floor)
const INSOLATION_MAX: float = 4.0         # cap the bake so the field can't NaN
const DUST_OPACITY: float = 3.5           # how strongly atmospheric dust/cloud blocks the sun (impact winter)
const KNOCK_GAIN: float = 1.0             # tuning: how hard a meteor's momentum perturbs the orbit
const PLANET_MASS_EFF: float = 6.0e5      # effective planet mass for impact momentum → Δvelocity

# Moon: kinematic orbit about the planet, in the scene frame.
const MOON_RADIUS_MULT: float = 3.2       # orbit radius = planet_radius * this
const MOON_RATE: float = 0.06             # rad/s (a moon-month a few× the day)
const MOON_INCLINATION: float = 0.28      # radians the moon plane is tipped from the planet equator

var _body: Node3D = null                  # LAPlanetBody (the planet — orbit reference + scene centre)
var _sky_ctrl: Node = null                # LAVoxelSkyController (owns the star node + the sky sun)
var _material = null                      # LAMaterialField3D (read atmospheric dust; it reads the sun back)
var _moon: Node3D = null                  # LAMoon (set via set_moon)

# Heliocentric orbital state of the planet (abstract units; the orbit plane maps to world XZ, normal = world Y).
var _helio_pos: Vector3 = Vector3(ORBIT_RADIUS, 0.0, 0.0)
var _helio_vel: Vector3 = Vector3.ZERO
var _moon_angle: float = 0.0
var _atmos_t: float = 1.0                 # cached atmospheric transmission (dust changes slowly — sampled, not per-frame)
var _tick: int = 0


func setup(body: Node3D, sky_ctrl: Node, material) -> void:
	_body = body
	_sky_ctrl = sky_ctrl
	_material = material
	# Start on a circular orbit: v = sqrt(mu/r) perpendicular to the radius, in the orbit plane (world XZ).
	var v0: float = sqrt(SUN_MU / ORBIT_RADIUS)
	_helio_pos = Vector3(ORBIT_RADIUS, 0.0, 0.0)
	_helio_vel = Vector3(0.0, 0.0, v0)


func set_moon(moon: Node3D) -> void:
	_moon = moon


## Advance the orbit + moon and push the derived sun direction / position / insolation into the scene. Called
## from the world's process BEFORE the sky-cycle update (so the sun-shine direction is fresh when the sky reads it).
func update(delta: float) -> void:
	if _body == null or _sky_ctrl == null:
		return
	_integrate_orbit(delta)
	# Dust/cloud change slowly — resample atmospheric transmission every ~15 frames, not the full-grid sweep each frame.
	_tick += 1
	if _tick % 15 == 0:
		_atmos_t = _compute_transmission()

	var centre: Vector3 = _body.center()
	# Planet → sun direction in the scene (the orbit plane is world XZ). The sun sits opposite the planet's
	# heliocentric position, so from the planet the sun lies along -_helio_pos.
	var to_sun: Vector3 = (-_helio_pos)
	if to_sun.length() < 0.001:
		to_sun = Vector3.RIGHT
	to_sun = to_sun.normalized()

	# Move the visible sun disc/star to that direction at a fixed scene distance, then let the sky recompute its
	# shine direction from the star's new position (reuses the existing space-mode wiring).
	var star: Node3D = _sky_ctrl.star() if _sky_ctrl.has_method("star") else null
	if star != null:
		star.global_position = centre + to_sun * SUN_SCENE_DISTANCE
	if _sky_ctrl.has_method("enter_space_mode"):
		_sky_ctrl.enter_space_mode(centre)

	# Insolation = inverse-square of the orbital distance × atmospheric transmission (dust/cloud block the sun).
	# Stamp it on the sky sun as metadata; the field step multiplies sun_dir by it so intensity rides direction.
	var dist_factor: float = ORBIT_RADIUS / maxf(_helio_pos.length(), 1.0)
	var insol: float = clampf(dist_factor * dist_factor * _atmos_t, INSOLATION_MIN, INSOLATION_MAX)
	var sun_light = _sky_ctrl.sun() if _sky_ctrl.has_method("sun") else null
	if sun_light != null:
		sun_light.set_meta("insolation", insol)

	_update_moon(delta, centre)


## Integrate the planet's heliocentric orbit under the sun's gravity (symplectic Euler). Perturbations from
## impacts change the orbit here → decay into the sun or escape.
func _integrate_orbit(delta: float) -> void:
	var r: float = maxf(_helio_pos.length(), 1.0)
	var accel: Vector3 = -_helio_pos.normalized() * (SUN_MU / (r * r))
	_helio_vel += accel * delta
	_helio_pos += _helio_vel * delta


## Atmospheric transmission (0..1): airborne dust + cloud block sunlight (a meteor volley → impact winter).
func _compute_transmission() -> float:
	var opacity: float = 0.0
	if _material != null and _material.has_method("avg_atmos_dust"):
		opacity += float(_material.avg_atmos_dust())
	if _material != null and _material.has_method("avg_cloud_cover"):
		opacity += float(_material.avg_cloud_cover()) * 0.35
	return 1.0 / (1.0 + DUST_OPACITY * maxf(opacity, 0.0))


func _update_moon(delta: float, centre: Vector3) -> void:
	if _moon == null:
		return
	_moon_angle = wrapf(_moon_angle + MOON_RATE * delta, 0.0, TAU)
	var radius: float = _body.radius() * MOON_RADIUS_MULT if _body.has_method("radius") else 300.0
	# Circular orbit in world XZ, tilted by MOON_INCLINATION about world X so it doesn't sit in the equator.
	var pos: Vector3 = Vector3(cos(_moon_angle), 0.0, sin(_moon_angle)) * radius
	_moon.global_position = centre + pos.rotated(Vector3.RIGHT, MOON_INCLINATION)


## Momentum transfer from a meteor strike: Δv = impulse / effective-planet-mass, added to the orbital velocity.
## A large/fast rock (or a volley) accumulates enough Δv to destabilise the orbit — into the sun, or out of the
## system. `world_impulse` is the meteor's momentum vector (mass × velocity) at impact, in world/orbit axes.
func apply_impulse(world_impulse: Vector3) -> void:
	_helio_vel += world_impulse * (KNOCK_GAIN / PLANET_MASS_EFF)


## Human-readable orbital fate for the HUD / telemetry / streamer.
func status() -> String:
	var r: float = maxf(_helio_pos.length(), 1.0)
	var energy: float = 0.5 * _helio_vel.length_squared() - SUN_MU / r
	if energy >= 0.0:
		return "escaping the system"
	if r < ORBIT_RADIUS * 0.35:
		return "falling into the sun"
	return "stable orbit"


## Orbital telemetry for SIM_REPORT (distance as a fraction of nominal, insolation, fate).
func report() -> Dictionary:
	var dist_factor: float = ORBIT_RADIUS / maxf(_helio_pos.length(), 1.0)
	return {
		"orbit_dist": snappedf(1.0 / maxf(dist_factor, 0.0001), 0.01),
		"insolation": snappedf(clampf(dist_factor * dist_factor * _atmos_t, INSOLATION_MIN, INSOLATION_MAX), 0.01),
		"orbit_status": status(),
	}
