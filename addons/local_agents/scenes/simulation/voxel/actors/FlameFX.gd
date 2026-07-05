class_name LAFlameFX
extends RefCounted

## Shared code-built flame effect: rising orange particles + a warm point light. Parent it to any
## burning thing (a tree, a creature that combusted) and it frees with the host. Organic matter
## COMBUSTS (this) rather than glowing incandescently — glow is for inorganic hot material.
## (Explicit types only — no ':=' inferred typing.)

static func make() -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "FlameFX"

	var particles: GPUParticles3D = GPUParticles3D.new()
	particles.amount = 24
	particles.lifetime = 0.9
	particles.one_shot = false
	particles.emitting = true
	var flame: QuadMesh = QuadMesh.new()
	flame.size = Vector2(0.5, 0.5)
	var fmat: StandardMaterial3D = StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.5, 0.12)
	fmat.emission_energy_multiplier = 3.0
	fmat.albedo_color = Color(1.0, 0.55, 0.15, 0.9)
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flame.material = fmat
	particles.draw_pass_1 = flame
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.8
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 20.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 4.5
	pm.gravity = Vector3(0.0, 2.5, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.color = Color(1.0, 0.6, 0.2)
	particles.process_material = pm
	particles.position = Vector3(0.0, 1.2, 0.0)
	root.add_child(particles)

	var light: OmniLight3D = OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 3.0
	light.omni_range = 9.0
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
	return root
