class_name LABodySeeds
extends RefCounted

## WHAT A BODY IS GIVEN. Everything else about it — radius, surface gravity, day length, luminosity,
## insolation, orbital elements — is MEASURED off the substrate or derived from these.
##
## `mass_kg` is the matter budget. For a body the field seeds cell by cell it is the budget the seeder
## spends and the field's own sum is what lives afterwards; for a body with no grid of its own it is all
## there is to say.

## Reference values the seeds below are built from. Each is a cited measurement of OUR system, which is
## why none of them belongs in LAPhysical.
const SOLAR_MASS_KG: float = 1.98847e30                 # IAU 2015 B3 nominal solar mass
const SOLAR_LUMINOSITY_W: float = 3.828e26              # IAU 2015 B3 nominal solar luminosity
const SOLAR_RADIUS_M: float = 6.957e8                   # IAU 2015 B3 nominal solar radius
## Age of the system, years (Connelly et al. 2012, Science 338:651, CAI Pb-Pb).
const SOLAR_SYSTEM_AGE_YEARS: float = 4.567e9

const EARTH_MASS_KG: float = 5.97217e24                 # IAU 2015 B3 nominal terrestrial mass
const LUNAR_MASS_KG: float = 7.346e22                   # Williams et al. 2014, LLR

## Total angular momentum of the Earth-Moon pair. Tides move it between spin and orbit; they do not
## change the sum, so this one number holds for the epoch as it does for today (Canup 2012, Science
## 338:1052; Touma & Wisdom 1994, AJ 108:1943).
const EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S: float = 3.5e34

## The Moon just after the accretion disc cleared, in metres (Canup 2004, Icarus 168:433). It is an
## INITIAL POSITION, not a property: it is where the body starts, and the tides move it from there.
const LUNAR_SEPARATION_AT_EPOCH_M: float = 2.42e7

## Semi-major axis of the planet's orbit, metres. The au is exact by definition (IAU 2012 B2).
const ASTRONOMICAL_UNIT_M: float = 1.495978707e11

## Obliquity: the DIRECTION of the planet's spin angular momentum, an initial condition like any other.
const SPIN_AXIS: Vector3 = Vector3(0.40, 0.92, 0.0)

## Young-sun XUV (1-1200 A), erg cm^-2 s^-1 at 1 au for a sun tau Gyr old, valid past 0.1 Gyr
## (Ribas et al. 2005, ApJ 622:680). Carried as a LUMINOSITY so no body's orbit is baked into it.
const XUV_1AU_1GYR_W_M2: float = 0.0297
## The tau exponent of the fit above (Ribas et al. 2005).
const XUV_AGE_EXPONENT: float = 1.23


## The seed of every body in the system. Angular momentum is carried as a UNIT AXIS and a MAGNITUDE, never
## as one Vector3: Vector3 is binary32, and squaring a component of order 1e34 to take a length overflows it
## to infinity. The spin RATE is then an output of whatever inertia the seeded matter turns out to have.
static func rows() -> Dictionary:
	var moon_orbit_l: float = _circular_orbit_angular_momentum(
		EARTH_MASS_KG, LUNAR_MASS_KG, LUNAR_SEPARATION_AT_EPOCH_M)
	# What the pair's conserved total leaves for the planet to spin with. Its DAY is that over the inertia
	# the seeded matter turns out to have, so the day length is an output.
	var spin_l: float = EARTH_MOON_ANGULAR_MOMENTUM_KG_M2_S - moon_orbit_l
	var v_orbit: float = _circular_speed(SOLAR_MASS_KG + EARTH_MASS_KG + LUNAR_MASS_KG, ASTRONOMICAL_UNIT_M)
	var v_moon: float = _circular_speed(EARTH_MASS_KG + LUNAR_MASS_KG, LUNAR_SEPARATION_AT_EPOCH_M)
	# The Moon starts in the planet's EQUATORIAL plane, which is what a giant impact leaves behind; the
	# inclination it has today is something the tides did to it, not something it was given.
	var spin: Vector3 = SPIN_AXIS.normalized()
	var moon_dir: Vector3 = spin.cross(Vector3.RIGHT if absf(spin.x) < 0.9 else Vector3.UP).normalized()
	return {
		"star": {
			"mass_kg": SOLAR_MASS_KG,
			"luminosity_w": luminosity_at_epoch_w(),
			"xuv_luminosity_w": xuv_luminosity_at_epoch_w(),
			"radius_m": SOLAR_RADIUS_M,
			"position_m": Vector3(ASTRONOMICAL_UNIT_M, 0.0, 0.0),
			"velocity_m_s": Vector3.ZERO,
			"spin_axis": Vector3.ZERO,
			"spin_l_kg_m2_s": 0.0,
			"gridded": false,
		},
		"planet": {
			"mass_kg": EARTH_MASS_KG,
			"position_m": Vector3.ZERO,
			"velocity_m_s": Vector3(0.0, 0.0, v_orbit),
			"spin_axis": SPIN_AXIS.normalized(),
			"spin_l_kg_m2_s": spin_l,
			"gridded": true,
		},
		"moon": {
			"mass_kg": LUNAR_MASS_KG,
			"position_m": moon_dir * LUNAR_SEPARATION_AT_EPOCH_M,
			"velocity_m_s": spin.cross(moon_dir).normalized() * v_moon,
			"spin_axis": Vector3.ZERO,
			"spin_l_kg_m2_s": 0.0,
			"gridded": false,
		},
	}


static func of(key: String) -> Dictionary:
	return rows().get(key, {})


## Gough 1981 (Solar Phys. 74:21): L(t)/L0 = 1 / (1 + (2/5)(1 - t/t0)).
static func luminosity_at_epoch_w() -> float:
	return SOLAR_LUMINOSITY_W \
		/ (1.0 + 0.4 * (LAPhysical.PLANET_EPOCH_YEARS_BEFORE_PRESENT / SOLAR_SYSTEM_AGE_YEARS))


static func star_age_at_epoch_gyr() -> float:
	return (SOLAR_SYSTEM_AGE_YEARS - LAPhysical.PLANET_EPOCH_YEARS_BEFORE_PRESENT) / 1.0e9


## The 1-au flux Ribas measured, turned back into the luminosity that produced it.
static func xuv_luminosity_at_epoch_w() -> float:
	var flux_1au: float = XUV_1AU_1GYR_W_M2 * pow(star_age_at_epoch_gyr(), -XUV_AGE_EXPONENT)
	return flux_1au * 4.0 * PI * ASTRONOMICAL_UNIT_M * ASTRONOMICAL_UNIT_M


## Irradiance a body at `separation_m` receives from a star of `luminosity_w`. The whole of insolation:
## no nominal orbit, no normalisation, so eccentricity and a knocked orbit both show up on their own.
static func irradiance_w_m2(luminosity_w: float, separation_m: float) -> float:
	var r: float = maxf(separation_m, 1.0)
	return luminosity_w / (4.0 * PI * r * r)


static func _circular_speed(total_mass_kg: float, separation_m: float) -> float:
	return sqrt(LAPhysical.GRAVITATIONAL_CONSTANT * total_mass_kg / maxf(separation_m, 1.0))


## Orbital angular momentum of a circular two-body pair about their barycentre.
static func _circular_orbit_angular_momentum(m_a: float, m_b: float, separation_m: float) -> float:
	var reduced: float = m_a * m_b / maxf(m_a + m_b, 1.0)
	return reduced * sqrt(LAPhysical.GRAVITATIONAL_CONSTANT * (m_a + m_b) * separation_m)


## Direction of a body's seeded spin angular momentum: the axis it turns on. Zero when it does not turn.
static func spin_axis_of(key: String) -> Vector3:
	var a: Vector3 = of(key).get("spin_axis", Vector3.ZERO)
	return a.normalized() if a.length() > 0.0 else Vector3.ZERO


## Magnitude of that angular momentum, kg m^2/s. The spin RATE is this over the body's measured inertia.
static func spin_l_of(key: String) -> float:
	return float(of(key).get("spin_l_kg_m2_s", 0.0))


## Radius the seeded matter FILLS BEFORE it is laid down, metres: the mass over the bulk density of the
## composition it is made of. Only the terrain generator needs this — it has to cut a shape before there is
## any matter to measure — and every reader after the seal takes LABodyMeasure.surface_r_m instead.
static func seed_radius_m(key: String) -> float:
	var m: float = float(of(key).get("mass_kg", 0.0))
	var rho: float = bulk_density_kg_m3()
	if m <= 0.0 or rho <= 0.0:
		return -1.0
	return pow(3.0 * m / (4.0 * PI * rho), 1.0 / 3.0)


## Bulk density of a differentiated body, kg/m^3. Volumes add: the shell's own mineral mix fills all but
## the core's volume fraction, and the core carries the registry's core mass fraction.
static func bulk_density_kg_m3() -> float:
	var comp: Object = LANativeTables.composition()
	if comp == null:
		return -1.0
	var t_c: float = LAMaterialField3D.INITIAL_TEMP
	var rho_shell: float = float(comp.shell_density(t_c, LAPhysical.STANDARD_PRESSURE_PA))
	var x: float = float(comp.core_radius_frac(t_c, LAPhysical.STANDARD_PRESSURE_PA))
	var f_core: float = LAPhysical.EARTH_CORE_MASS_FRACTION
	if rho_shell <= 0.0 or x < 0.0 or x >= 1.0 or f_core <= 0.0 or f_core >= 1.0:
		return -1.0
	return rho_shell * (1.0 - x * x * x) / (1.0 - f_core)
