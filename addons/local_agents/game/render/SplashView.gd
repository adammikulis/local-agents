@tool
class_name LASplashView
extends GPUParticles3D

## A splash: one burst of droplets from where the field announced it, thrown up against the local gravity.

@export_group("Burst")
## Strength past which a splash draws no larger.
@export var max_strength: float = 4.0


## Restart the burst at `world_pos`, its spread and speed scaled by `strength`, living until its fastest
## droplet falls back to where it left.
func play(world_pos: Vector3, strength: float) -> void:
	if not world_pos.is_finite() or not (strength > 0.0):
		return
	var g: Vector3 = LABallistics.g_at(world_pos)
	if g.length_squared() <= 0.0:
		return
	var pm: ParticleProcessMaterial = process_material as ParticleProcessMaterial
	var s: float = minf(strength, max_strength)
	var up: Vector3 = -g.normalized()
	var side: Vector3 = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	global_transform = Transform3D(Basis(side, up, side.cross(up)).scaled(Vector3.ONE * s), world_pos)
	pm.gravity = g
	lifetime = 2.0 * pm.initial_velocity_max * s / g.length()
	restart()


func _get_configuration_warnings() -> PackedStringArray:
	if not (process_material is ParticleProcessMaterial) or draw_pass_1 == null:
		return PackedStringArray(["No droplet material or mesh: instance SplashView.tscn, which authors both."])
	return PackedStringArray()
