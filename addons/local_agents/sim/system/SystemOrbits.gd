class_name LASystemOrbits
extends Node

## The solar system's MOTION, integrated through the one N-body rule in LAGravity. The simulation stays centred
## on the planet (the field/terrain never move, zero risk), but the planet carries a real orbital STATE — its
## separation from the star, position + velocity — advanced on the PHYSICS tick, in lockstep with the field
## (LAVoxelWorld._physics_process), so the sun's motion per unit of chemistry is framerate-independent.
## That state drives:
##   • the STAR's actual scene position (it is placed AT the orbital distance, not at a decorative one);
##   • the sun's direction across the sky (the terminator);
##   • SEASONS: the tilted spin axis vs the orbit plane makes the sub-solar latitude swing over a year;
##   • INSOLATION intensity = (nominal/dist)^2 × atmospheric transmission (dust/cloud), fed to the field as the
##     MAGNITUDE of sun_dir (the solar kernel does target = AMBIENT + SOLAR_WARMTH·max(0,dot(radial,sun_dir))),
##     so nearer sun bakes, farther freezes, and airborne debris dims the sun → impact winter, all emergent.
## A meteor impact transfers MOMENTUM into the orbital velocity (`apply_impulse`), so a big enough strike (or a
## volley) drops the planet onto a decaying orbit into the sun, or past escape velocity out of the system.
## Explicit types; no ':='.
##
## ONE SYSTEM (unified 2026-07-30). Three constants used to describe three different, mutually inconsistent
## suns: `SUN_MU = 1e6` drove the orbit in abstract units, `SUN_SCENE_DISTANCE = 1200` drew the disc somewhere
## unrelated, and `PLANET_MASS_EFF = 6e5` was an invented planet mass for impulses that did not match the
## planet's actual 1e6. All three are gone. There is one G (LAGravity), one star mass (LAStar.mass()), one
## planet mass (LAPlanetBody.mass()), and the star is drawn exactly where the orbit says it is. The orbital
## acceleration is now literally `LAGravity.acceleration_at()` evaluated at the star, so the moon perturbs
## the planet's year for free and nothing here can drift out of agreement with what a meteor feels.
##
## THE FRAME IS RELATIVE — see the frame note in LAGravity. The planet does not move; the star does. `_helio_pos`
## is the planet MINUS the star, so the star is drawn at `planet_centre - _helio_pos` and "the orbit" means the
## separation, not an absolute place in space. That is why the orbital equation carries G(M_star + M_planet):
## it is relative motion, not motion about a fixed centre.
##
## SCALE — why these numbers and not others. Fix the planet (radius 500, mass 1e6, SURFACE_G 55) and the moon
## (3.2 planet radii) and the rest is forced, because the star's TIDAL field at the planet depends only on the
## length of the year: a_tide = 3·(2π/T)²·x. A 200 s year — what the old abstract orbit ran — puts the moon at
## 0.96 of the planet's Hill radius, i.e. barely bound and shedding. Backing the year off to ~670 s puts the
## moon at 0.41 Hill, which is comfortable. Kepler then fixes the pair (orbit radius, star mass): 12000 units
## and 1e7 is the combination that also leaves the star 10x the planet, which is what makes it the primary of
## the system rather than a third moon. Consequence worth knowing: the visible sun disc is now ~0.6° across
## (realistic) where it used to be ~5.7°, because it is genuinely ten times farther away than it was drawn.

const ORBIT_RADIUS: float = 12000.0       # nominal orbital separation; insolation == 1 here. Kepler + the moon's
                                          # Hill margin pin this against LAStar.DEFAULT_MASS (see SCALE above).
const INSOLATION_MIN: float = 0.02        # never fully zero (numeric floor)
const INSOLATION_MAX: float = 4.0         # cap the bake so the field can't NaN
const DUST_OPACITY: float = 3.5           # how strongly atmospheric dust/cloud blocks the sun (impact winter)
const CLOUD_OPACITY_K: float = 0.35       # per-unit-cover cloud opacity
# The one admitted exaggeration left in this file: a 400-mass rock genuinely cannot move a 1e6 planet, so the
# knock is scaled up to keep impacts consequential. 5.9 is not a taste value — it reproduces the pre-unification
# response EXACTLY. The old code divided the impulse by an invented PLANET_MASS_EFF of 6e5 against an orbital
# speed of 31.6; the real divisor is the planet's real mass 1e6 and the real orbital speed is 112.3, so the same
# impulse needs 112.3/31.6 × 1e6/6e5 = 5.9x to shift the orbit by the same FRACTION of its velocity.
const KNOCK_GAIN: float = 5.9

# Moon: a real orbit about the planet, integrated through LAGravity like everything else. Its period is NOT a
# constant here any more — it falls out of the separation and the masses (~104 s at 3.2 planet radii).
const MOON_RADIUS_MULT: float = 3.2       # orbit radius = planet_radius * this
const MOON_INCLINATION: float = 0.28      # radians the moon plane is tipped from the planet equator

# Tides: the moon's pull raises the sea toward it and on the antipode, so the shell radius swings as the moon
# orbits. A justified fake — nearly free: sea_radius = base + TIDE_AMP·cos(2·moon_angle) (two bulges per orbit).
# The ocean shell (LAOceanPlane) and the near-cap surface (LAMaterialFieldRender3D) both read the tided radius,
# so the shoreline advances/recedes with no per-cell simulation.
const TIDE_AMP: float = 4.0               # peak sea-level swing (world units) — ~0.8% of the 500u planet radius

var _body: Node3D = null                  # LAPlanetBody (the planet — orbit reference + scene centre)
var _sky_ctrl: Node = null                # LAVoxelSkyController (owns the star node + the sky sun)
var _material = null                      # LAMaterialField3D (read atmospheric dust; it reads the sun back)
var _star: Node3D = null                  # LAStar — the gravity body this planet orbits
var _moon: Node3D = null                  # LAMoon (set via set_moon)
var _ocean = null                         # LAOceanPlane — the sea shell (tided via apply_tide)
var _sea_surface = null                   # LAMaterialFieldRender3D — near-cap surface (tided via set_sea_radius)
var _sea_base_radius: float = 0.0         # un-tided sea radius (base the tide swings around)

# Orbital state of the planet RELATIVE TO THE STAR (planet minus star). The orbit plane maps to world XZ,
# normal = world Y. The star is drawn at `centre - _helio_pos`, so this one state is both the physics and
# the placement — they cannot disagree.
var _helio_pos: Vector3 = Vector3(ORBIT_RADIUS, 0.0, 0.0)
var _helio_vel: Vector3 = Vector3.ZERO
# Moon state, likewise relative to the planet centre (the world-frame origin).
var _moon_pos: Vector3 = Vector3.ZERO
var _moon_vel: Vector3 = Vector3.ZERO
var _moon_angle: float = 0.0              # tide phase, READ OFF the moon's real position (not a driven angle)
var _atmos_t: float = 1.0                 # cached atmospheric transmission (dust changes slowly — sampled, not per-frame)
var _tick: int = 0


func setup(body: Node3D, sky_ctrl: Node, material) -> void:
	_body = body
	_sky_ctrl = sky_ctrl
	_material = material
	_star = sky_ctrl.star() if sky_ctrl != null and sky_ctrl.has_method("star") else null
	_helio_pos = Vector3(ORBIT_RADIUS, 0.0, 0.0)
	_seed_circular()
	# Place the star NOW, not on the first update: it is a 1e7 mass and it enters the gravity group during
	# LAStar.setup(), so leaving it at its authored placeholder position for a frame would be a real, wrong
	# pull on anything already falling.
	_publish_bodies()


## Wire the moon and seed its orbit: a prograde orbit at MOON_RADIUS_MULT planet radii, tipped by
## MOON_INCLINATION. The speed is MEASURED, not derived from a two-body formula — place the moon, ask
## LAGravity what the summed field actually is there, and take v = sqrt(a_inward · r). That is the same
## circular-speed rule a player-fired meteor gets, and it means the seed already accounts for the star's tide
## at the moon's distance instead of being corrected for it afterwards. Called after setup(), once the
## planet's radius is known.
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


# Circular orbital velocity for the current separation, perpendicular to it in the world-XZ orbit plane.
# Split out because the moon arrives after setup() and its mass is part of what swings around the star.
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


## Advance the orbit + moon and push the derived sun direction / position / insolation into the scene. Called
## from LAVoxelWorld._physics_process BEFORE the sky-cycle update, so the sun-shine direction is fresh when
## the sky reads it. `delta` must be the fixed physics delta — never a render delta.
func update(delta: float) -> void:
	if _body == null or _sky_ctrl == null:
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
	if _sky_ctrl.has_method("enter_space_mode"):
		_sky_ctrl.enter_space_mode(centre)

	# Insolation = inverse-square of the orbital distance × atmospheric transmission (dust/cloud block the sun).
	# Stamp it on the sky sun as metadata; the field step multiplies sun_dir by it so intensity rides direction.
	var sun_light = _sky_ctrl.sun() if _sky_ctrl.has_method("sun") else null
	if sun_light != null:
		sun_light.set_meta("insolation", _insolation())

	_update_tide()


# --- State → scene -----------------------------------------------------------

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
	if _moon != null:
		_moon.global_position = centre + _moon_pos
		# The tide wants a phase, and the moon's real position is where that phase now comes from: the
		# projection of its separation onto the equatorial plane. At seed this reads 0, matching the angle
		# the old driven-cosine moon started at.
		_moon_angle = atan2(_moon_pos.z, _moon_pos.x)


# --- Integration -------------------------------------------------------------

## Advance the orbital separation under the SAME summed field a meteor feels. `acceleration_at` evaluated at
## the star (excluding the star's own direct pull) is the star's acceleration relative to the planet, and it
## already contains the star→planet term, the planet→star term (as the frame's indirect correction) and the
## moon's pull, so not one line of this is a constant typed into this file.
##
## Measured against the BARYCENTRE, not the planet. The planet swings toward the moon once a month; LAGravity
## reports that swing because it is real — a meteor genuinely feels the ground accelerate under it — but what
## traces a Kepler ellipse about the star is the planet-moon pair's centre of mass. Integrating the monthly
## wobble as though it were orbital motion pumps the year into an ellipse: measured 2026-07-30, the planetocentric
## form drove the orbit from 12000 to 15812 units in 700 s, e = 0.14, swinging insolation 1.00 down to 0.57 with
## nothing but the moon to cause it. With the planet pinned at the world origin, the barycentre's acceleration
## is just the moon's, weighted by the moon's share of the pair's mass — two lines, and the drift is gone.
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


## Advance the moon the same way: its acceleration is the summed field at its own position, minus its own
## direct pull. What is left is G(M_planet + M_moon) toward the planet plus the star's tide — a real orbit
## that can be perturbed and can perturb back.
func _integrate_moon(delta: float) -> void:
	if _moon == null:
		return
	var accel: Vector3 = LAGravity.acceleration_at(get_tree(), _moon.global_position, _moon)
	_moon_vel += accel * delta
	_moon_pos += _moon_vel * delta


# --- Derived quantities ------------------------------------------------------

# G(M_star + M_planet + M_moon): the relative-motion parameter for the separation between the star and the
# planet-moon pair's barycentre — not a mu about a fixed centre, and not the planet's mass alone, because it
# is the whole pair that swings around the star.
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
	# DUST — unbounded (impact winter can go dark). `avg_atmos_dust()` requests the demand-gated `dust`
	# readback itself, which is what keeps this mechanism alive without a diagnostic having to be running.
	if _material != null and _material.has_method("avg_atmos_dust"):
		dust_op = float(_material.avg_atmos_dust())
	var cloud_op: float = 0.0
	if _material != null and _material.has_method("avg_cloud_cover"):
		cloud_op = float(_material.avg_cloud_cover()) * CLOUD_OPACITY_K
	var t: float = 1.0 / (1.0 + DUST_OPACITY * maxf(dust_op + cloud_op, 0.0))
	# IMPACT WINTER IS AN EVENT, NOT A LEVEL, so a single end-of-run scalar cannot show it. These are gauges
	# (cur/min/max over the run) because the thing worth knowing is HOW DARK IT GOT and for how long, and
	# `insolation` — the only number published before — is an instantaneous sample of a spiky quantity.
	LASimReport.gauge("atmos_dust_opacity", dust_op)
	LASimReport.gauge("atmos_cloud_opacity", cloud_op)
	LASimReport.gauge("atmos_transmission", t)
	return t


# The moon drags the tide: raise/lower the sea shell (and the near-cap surface) around the base radius so the
# shoreline advances/recedes as the moon orbits. Both sinks read the SAME offset → they stay in step.
func _update_tide() -> void:
	if _moon == null:
		return
	var offset: float = tide_offset()
	if _ocean != null and _ocean.has_method("apply_tide"):
		_ocean.apply_tide(offset)
	if _sea_surface != null and _sea_surface.has_method("set_sea_radius"):
		_sea_surface.set_sea_radius(_sea_base_radius + offset)


# --- Stimuli + telemetry -----------------------------------------------------

## Momentum transfer from a meteor strike: Δv = impulse × KNOCK_GAIN / the planet's REAL mass, added to the
## orbital velocity. A large/fast rock (or a volley) accumulates enough Δv to destabilise the orbit — into the
## sun, or out of the system. `world_impulse` is the meteor's momentum vector (mass × velocity) at impact.
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
