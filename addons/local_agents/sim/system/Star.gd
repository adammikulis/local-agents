class_name LAStar
extends Node3D

## The system's star in the SOLAR-SYSTEM-FIRST spine: a POSITIONED body (not a global sun_dir) that is at once
## the light source, the GRAVITY source, and the driver of every body's per-cell solar terminator. A body's
## sun direction is `normalize(star_pos - body_center)` and its insolation falls off as `1/dist²`. One planet
## today, N tomorrow, same rule. (Explicit types only, no ':=' inferred typing.)
##
## IT IS A REAL GRAVITY BODY. It joins the `gravity_body` group and exposes the same center()/mass()/radius()
## contract as LAPlanetBody and LAMoon, so LAGravity sums it like anything else and the planet's own orbit is
## integrated from THIS mass.
##
## MASS is set relative to the planet, not in isolation: DEFAULT_MASS is 10x LAPlanetBody's default 1e6, which
## is what makes it the primary of the system rather than a third moon. It is NOT the calibration body — see
## LAGravity.reference_body(): SURFACE_G is calibrated against the planet you stand on, never against this.

const DEFAULT_MASS: float = 1.0e7        # 10x the planet's 1e6 — the star has to dominate to be a star
# Physical body radius, world units. Its one behavioural use is LAMeteor's escape test, which frees a rock
# once it is further than 30 radii from whichever body dominates there, i.e. once it has left the planet's
# sphere of influence rather than merely coasting sunward.
const DEFAULT_RADIUS: float = 250.0

var _light: DirectionalLight3D = null       # for a single close body, a directional light reads as "the sun"
var _mass: float = DEFAULT_MASS
var _radius: float = DEFAULT_RADIUS
var _base_energy: float = 1.4
var _ref_distance: float = 600.0            # distance at which insolation == _base_energy (for 1/dist² scaling)


func setup(opts: Dictionary = {}) -> void:
	_mass = float(opts.get("mass", DEFAULT_MASS))
	_radius = float(opts.get("radius", DEFAULT_RADIUS))
	_base_energy = float(opts.get("energy", 1.4))
	_ref_distance = float(opts.get("ref_distance", 600.0))
	position = opts.get("position", Vector3(900.0, 300.0, 600.0))

	_light = DirectionalLight3D.new()
	_light.name = "StarLight"
	_light.light_energy = _base_energy
	_light.shadow_enabled = true
	add_child(_light)
	_aim_at(Vector3.ZERO)

	# Join the N-body group only once the position above is real. Registering in _ready() would put a mass
	# this large at the world origin — on top of the planet — for the window between add_child and setup.
	add_to_group(LAGravity.GROUP)


func mass() -> float:
	return _mass

## Physical radius of the star. Its intended job is the softening/escape scale — "how far out has a rock left
## this body's neighbourhood" — and in normal operation LAGravity calibrates G on the planet, not here.
##
## It is NOT, however, safe to describe this as "not a gravity-calibration radius", which is what this comment
## used to say. `LAGravity.reference_body()` falls back to the most massive body until one declares
## `is_gravity_reference()`, and this star is ten times the planet's mass — so any gravity query made before
## the planet registers calibrates G right here, as 55*250^2/1e7 = 0.34375, giving a surface gravity of 1.37
## instead of 55. LAGravity now re-derives when the reference body changes, so that state no longer persists,
## but this radius does feed the calibration in that window and the comment should not claim otherwise.
func radius() -> float:
	return _radius

## World-space centre — the N-body contract shared with LAPlanetBody and LAMoon.
func center() -> Vector3:
	return global_position

func light() -> DirectionalLight3D:
	return _light

## Unit direction from a body's centre TOWARD the star — the body's local "sun_dir" for the terminator.
func sun_dir_for(body_center: Vector3) -> Vector3:
	var d: Vector3 = global_position - body_center
	return d.normalized() if d.length() > 0.001 else Vector3.UP

## Insolation (light energy) reaching a body at `body_center`: inverse-square from the reference distance.
func insolation_at(body_center: Vector3) -> float:
	var dist: float = maxf(1.0, global_position.distance_to(body_center))
	return _base_energy * (_ref_distance * _ref_distance) / (dist * dist)

## Point the directional light from the star toward a target (the primary body) so shading matches the geometry.
func _aim_at(target: Vector3) -> void:
	if _light == null:
		return
	var to: Vector3 = target - global_position
	if to.length() > 0.001:
		_light.look_at_from_position(global_position, target, Vector3.UP)
