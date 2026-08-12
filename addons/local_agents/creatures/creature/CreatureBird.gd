class_name LACreatureBird
extends RefCounted


const BANK_STRENGTH: float = 0.35
# How hard birds are nudged up when skimming the ground, and the height band it acts over.
const GROUND_AVOID_STRENGTH: float = 0.6
const GROUND_AVOID_BAND: float = 4.0
# Thermal bob: vertical amplitude (metres) and how fast it cycles against age.
const THERMAL_AMPLITUDE: float = 3.0
const THERMAL_RATE: float = 0.4
# Never fly nearer the surface than this.
const MIN_CLEARANCE: float = 1.5


static func steer(c, pos: Vector3) -> Vector3:
	var out: Vector3 = LACreatureFlocking.steer(c, pos, false)
	var fwd: Vector3 = c._heading
	fwd.y = 0.0
	if fwd.length() > 0.001:
		var bank: float = sin(c.age * 0.3) * BANK_STRENGTH
		var perp: Vector3 = Vector3(-fwd.z, 0.0, fwd.x).normalized()
		out += perp * bank
	# Soft separation from the ground: push up (radially) harder the lower the bird is skimming.
	if c.terrain != null and c.terrain.has_method("altitude_at"):
		var above: float = c.terrain.altitude_at(pos)         # height above local ground (radial)
		if not is_nan(above) and above < GROUND_AVOID_BAND:
			var t: float = clampf(1.0 - above / GROUND_AVOID_BAND, 0.0, 1.0)
			var up: Vector3 = c.terrain.up_at(pos) if c.terrain.has_method("up_at") else Vector3.UP
			out += up * (GROUND_AVOID_STRENGTH * t)
	return out


static func soar_altitude(c, surf: float) -> float:
	var thermal: float = sin(c.age * THERMAL_RATE) * THERMAL_AMPLITUDE
	var y: float = surf + c.cruise_height + thermal
	return maxf(y, surf + MIN_CLEARANCE)


static func wants_to_land(c) -> bool:
	return c.energy < c.max_energy * 0.55 or c.hydration < c.max_hydration * 0.5
