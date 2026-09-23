@tool
class_name LASplashView
extends GPUParticles3D

## A splash: one burst of droplets from where the field announced it, thrown up against the local gravity.


## Radius R, m, of the hemisphere of liquid water whose lift against `g_m_s2` stores `joules`:
## (pi/4) rho g R^4 = E. -1 when either is absent.
static func cavity_radius_m(joules: float, g_m_s2: float) -> float:
	var rho: float = LASubstances.liquid_density("h2o")
	if not (joules > 0.0 and g_m_s2 > 0.0 and rho > 0.0):
		return -1.0
	return pow(4.0 * joules / (PI * rho * g_m_s2), 0.25)


## Restart the burst at `world_pos` for an impact that delivered `joules` to the water: droplets leave from
## within R at up to sqrt(2 g R), so the crown climbs R, and the rim, 2 pi R long, holds as many as fit
## at the drawn droplet's diameter.
func play(world_pos: Vector3, joules: float) -> void:
	if Engine.is_editor_hint() or not world_pos.is_finite():
		return
	var g: Vector3 = LABallistics.g_at(world_pos)
	var r: float = cavity_radius_m(joules, g.length())
	var pm: ParticleProcessMaterial = process_material as ParticleProcessMaterial
	var droplet_m: float = draw_pass_1.get_aabb().size.x if draw_pass_1 != null else 0.0
	if r <= 0.0 or pm == null or droplet_m <= 0.0 or not (pm.initial_velocity_max > 0.0):
		return
	var up: Vector3 = -g.normalized()
	var side: Vector3 = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	global_transform = Transform3D(Basis(side, up, side.cross(up)), world_pos)
	var v: float = sqrt(2.0 * g.length() * r)
	pm.initial_velocity_min *= v / pm.initial_velocity_max
	pm.initial_velocity_max = v
	pm.emission_sphere_radius = r
	pm.gravity = g
	amount = ceili(TAU * r / droplet_m)
	lifetime = 2.0 * v / g.length()
	# The emission sphere plus the farthest a spread droplet travels before its lifetime ends.
	visibility_aabb = AABB(Vector3.ONE * -4.0 * r, Vector3.ONE * 8.0 * r)
	restart()


func _get_configuration_warnings() -> PackedStringArray:
	if not (process_material is ParticleProcessMaterial) or draw_pass_1 == null:
		return PackedStringArray(["No droplet material or mesh: instance SplashView.tscn, which authors both."])
	return PackedStringArray()
