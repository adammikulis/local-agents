@tool
class_name LAImpactPuff
extends GPUParticles3D

## The grit a struck stone throws up, falling back under the gravity where it struck.


## Throw the grit up the local vertical at `at`, under the gravity there, and free the puff once it is down.
func burst(at: Vector3) -> void:
	var up: Vector3 = -LAGravity.acceleration_at(get_tree(), at).normalized()
	if up == Vector3.ZERO:
		push_error("ImpactPuff: no gravity body at %s, so the grit has no up to be thrown along." % at)
		queue_free()
		return
	global_transform = Transform3D(Basis.IDENTITY, at)
	var grit: ParticleProcessMaterial = process_material as ParticleProcessMaterial
	grit.direction = up
	grit.gravity = LABallistics.g_at(at)
	finished.connect(queue_free)
	emitting = true


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not one_shot:
		out.append("One Shot is off: the puff never finishes, so it is never freed.")
	if not process_material is ParticleProcessMaterial:
		out.append("burst() aims a ParticleProcessMaterial along the local gravity, and this puff has none.")
	return out
