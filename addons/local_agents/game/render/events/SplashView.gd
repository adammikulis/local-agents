@tool
class_name LASplashView
extends LAEventView

## A splash: one burst of droplets from where the field announced it, thrown up against the local gravity.


## Radius R, m, of the hemisphere of liquid water whose lift against `g_m_s2` stores `joules`:
## (pi/4) rho g R^4 = E. -1 when either is absent.
static func cavity_radius_m(joules: float, g_m_s2: float) -> float:
	var rho: float = LASubstances.liquid_density("h2o")
	if not (joules > 0.0 and g_m_s2 > 0.0 and rho > 0.0):
		return -1.0
	return pow(4.0 * joules / (PI * rho * g_m_s2), 0.25)


## `observation` carries "pos" and "joules", the energy an impact delivered to the water there: droplets
## leave from within R at up to sqrt(2 g R), so the crown climbs R, and the rim, 2 pi R long, holds as many
## as fit at the drawn droplet's diameter.
func show_event(observation: Dictionary) -> void:
	var at: Vector3 = observation["pos"]
	var g: Vector3 = LABallistics.g_at(at)
	var r: float = cavity_radius_m(float(observation["joules"]), g.length())
	var pm: ParticleProcessMaterial = particles.process_material as ParticleProcessMaterial
	var droplet_m: float = particles.draw_pass_1.get_aabb().size.x if particles.draw_pass_1 != null else 0.0
	if r <= 0.0 or pm == null or droplet_m <= 0.0 or not (pm.initial_velocity_max > 0.0) \
			or stand_at(at) == Vector3.ZERO:
		finish()
		return
	var v: float = sqrt(2.0 * g.length() * r)
	pm.initial_velocity_min *= v / pm.initial_velocity_max
	pm.initial_velocity_max = v
	pm.emission_sphere_radius = r
	pm.gravity = g
	particles.amount = ceili(TAU * r / droplet_m)
	particles.lifetime = 2.0 * v / g.length()
	# The emission sphere plus the farthest a spread droplet travels before its lifetime ends.
	particles.visibility_aabb = AABB(Vector3.ONE * -4.0 * r, Vector3.ONE * 8.0 * r)
	lifetime_s = particles.lifetime
	particles.restart()


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = super()
	var burst: GPUParticles3D = get_node_or_null("Particles") as GPUParticles3D
	if burst != null and (not (burst.process_material is ParticleProcessMaterial) or burst.draw_pass_1 == null):
		out.append("No droplet material or mesh: instance SplashView.tscn, which authors both.")
	return out
